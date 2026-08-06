#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenCache PoP installer.
#
#   curl -fsSL https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install.sh \
#     | sudo bash -s -- --pop-id PAR1 --baas-host <url> --baas-token <token>
#
# Turns a bare server into a serving OpenCache PoP: installs prerequisites,
# lays down the versioned runtime bundle, seeds .env, tunes the host, installs
# the L4 nftables switch that owns public 80/443, and deploys the Swarm stack.
#
# SOURCE OF TRUTH for this file is packaging/install.sh in the (private)
# pfoundation/opencache repo. CI mirrors it to the public installer repo on each
# release tag — do not edit the public copy by hand, it will be overwritten.
#
# ── Why a bundle image instead of a git clone ────────────────────────────────
# The opencache repo is PRIVATE; the images are PUBLIC. GHCR is therefore the
# only public channel available for shipping host-side files, so the ~17 files a
# PoP actually needs are published as ghcr.io/<repo>/bundle:<tag> and extracted
# here. A PoP is no longer a git checkout, which also removes the `git pull`
# drift vector: bundle files are version-locked to the images they ship with.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   install.sh [options]
#
#   --version <tag>        Bundle/image version (default: newest published vX.Y[.Z])
#   --dir <path>           Install directory (default: /opt/opencache)
#   --pop-id <id>          Node identity, e.g. PAR1
#   --baas-host <url>      BaaS origin. ONE host serving BOTH API surfaces:
#                          /items/*   (Directus)   — config-generator reads
#                          /dsb/v1/*  (DSB KVS API) — prefix-monitor publishes
#   --baas-token <token>   Bearer token used for BOTH surfaces
#   --baas-version <ver>   DSB API version segment (default: v1). Selects
#                          /dsb/<ver>/... for every call the node makes
#   --baas-project-id <id> Project UUID the PoP's KVS records live under
#                          (deprecated aliases: --dus-upstream / --kvs-api-base
#                           -> --baas-host, --dus-token -> --baas-token,
#                           --kvs-project-id -> --baas-project-id)
#   --geoip-account-id <id>
#   --geoip-license-key <key>
#   --gcloud-metrics-id <id>
#   --gcloud-logs-id <id>
#   --gcloud-api-key <key>
#   --wan-iface <iface>    Scope the L4 redirect to one NIC (default: any)
#   --bundle-image <ref>   Override the bundle image (mirrored registry, air-gap,
#                          or local testing). Skips the pull when already present.
#   --upgrade              Upgrade an existing install (gap-free; see below)
#   --restart-alloy        Force the alloy restart that reloads the bind-mounted
#                          alloy/config.alloy. By default it is restarted ONLY
#                          when the upgrade actually changed that file or its
#                          scrape wiring. Use this to RECOVER when the file on
#                          disk is already current but alloy still holds the old
#                          config in memory (nothing else will notice).
#   --no-restart-alloy     Never restart alloy. Env wiring is still applied; the
#                          restart is left to you. A restart costs a Loki
#                          catch-up window, so this exists for busy PoPs.
#   --skip-docker-install  Fail instead of installing Docker when it is missing
#   --skip-sysctl          Do not apply scripts/sysctl-tuning.sh
#   --skip-firewall        Do not touch ufw
#   --no-deploy            Lay everything down but do not deploy the stack
#   --force-env            Overwrite .env values that are already populated
#   --dry-run              Print what would happen, change nothing
#   --yes                  Never prompt; take the documented default
#   --help
#
# Re-running is safe. Node-local state (.env values, certs/, env/, cache*/,
# nginx/generated/, docker-stack.override.yml) is never overwritten.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGISTRY="ghcr.io"
GHCR_REPO="${GHCR_REPO:-pfoundation/opencache}"
STACK_NAME="opencache"
INSTALLER_URL="https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install.sh"

INSTALL_DIR="/opt/opencache"
VERSION=""
MODE="install"
SKIP_DOCKER_INSTALL=0
SKIP_SYSCTL=0
SKIP_FIREWALL=0
NO_DEPLOY=0
FORCE_ENV=0
DRY_RUN=0
ASSUME_YES=0

OPT_POP_ID=""
OPT_BAAS_HOST=""
OPT_BAAS_TOKEN=""
OPT_BAAS_VERSION=""
OPT_BAAS_PROJECT_ID=""
# Which flag supplied OPT_BAAS_HOST, so a conflict can name both sides.
OPT_BAAS_HOST_FLAG=""
OPT_GEOIP_ACCOUNT_ID=""
OPT_GEOIP_LICENSE_KEY=""
OPT_GCLOUD_METRICS_ID=""
OPT_GCLOUD_LOGS_ID=""
OPT_GCLOUD_API_KEY=""
OPT_WAN_IFACE=""
BUNDLE_IMAGE="${OPENCACHE_BUNDLE_IMAGE:-}"

# auto | always | never — see updateObservabilityWiring() for the rationale.
ALLOY_RESTART="auto"
# config.alloy hash captured BEFORE the bundle is extracted, so the wiring step
# can tell a real pipeline change from a no-op upgrade.
ALLOY_CFG_HASH_BEFORE=""

# Node-local state that must survive an upgrade. Deliberately maintained
# SEPARATELY from packaging/bundleManifest.txt rather than derived from it: two
# independent lists means a mistaken manifest edit cannot silently destroy an
# operator's credentials or cache. Belt and braces.
PROTECTED_PATHS=(
    ".env"
    ".env.sites"
    "certs"
    "env"
    "cache"
    "cache-blue"
    "cache-green"
    "nginx/generated"
    "docker-stack.override.yml"
)

# Services whose image follows IMAGE_TAG but which are NOT nginx-cache (that one
# is rolled gap-free by rollout.sh). Maps stack service -> image basename;
# log-cleaner deliberately reuses the nginx-cache image.
SHARED_SERVICES="config-watcher:config-generator prefix-monitor:prefix-monitor bird:bird log-cleaner:nginx-cache"

# Set while a bundle is being extracted so an interrupted run does not leave a
# multi-megabyte staging tree behind in /tmp.
STAGE_DIR=""
cleanup() { [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"; return 0; }
trap cleanup EXIT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step()  { echo; echo "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
info()  { echo "    $*"; }
ok()    { echo "    ${C_GREEN}ok${C_RESET}   $*"; }
warn()  { echo "    ${C_YELLOW}warn${C_RESET} $*" >&2; }
err()   { echo "${C_RED}ERROR${C_RESET}: $*" >&2; }
die()   { err "$*"; exit 1; }

# Renders the "── Usage ─" comment block above, so --help can never drift from
# the documented flag list.
usage() { sed -n '/^# ── Usage/,/^# ─\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# Every mutating action funnels through run() so --dry-run is honest rather than
# aspirational.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        # stderr, not stdout: several call sites redirect the command's stdout
        # to /dev/null (e.g. the noisy `docker service update` progress bar),
        # which would otherwise swallow the dry-run line and make --dry-run
        # silently useless for exactly the commands worth previewing.
        echo "    ${C_YELLOW}dry-run${C_RESET} $*" >&2
        return 0
    fi
    "$@"
}

# curl|bash consumes stdin, so an ordinary `read` sees EOF and every prompt
# would silently take its default. Read from the controlling terminal instead.
#
# `[ -r /dev/tty ]` is NOT sufficient: the device node exists and looks readable
# even when the process has no controlling terminal (systemd units, CI, nested
# pipelines), and the open then fails with ENXIO. Probe by actually opening it.
hasTty() {
    [ -e /dev/tty ] || return 1
    (exec < /dev/tty) > /dev/null 2>&1
}

promptYesNo() {
    local question="$1" default="${2:-n}" reply=""
    if [ "$ASSUME_YES" -eq 1 ] || ! hasTty; then
        [ "$default" = "y" ]
        return
    fi
    local hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
    printf '    %s %s ' "$question" "$hint" > /dev/tty
    read -r reply < /dev/tty || reply=""
    reply="${reply:-$default}"
    case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

promptValue() {
    local question="$1" reply=""
    if [ "$ASSUME_YES" -eq 1 ] || ! hasTty; then
        return 1
    fi
    printf '    %s: ' "$question" > /dev/tty
    read -r reply < /dev/tty || reply=""
    [ -n "$reply" ] || return 1
    printf '%s' "$reply"
}

# ── .env helpers ─────────────────────────────────────────────────────────────
# Rewrite-through-a-loop rather than `sed -i`: Directus tokens and Grafana API
# keys routinely contain /, &, | and backslashes, every one of which is special
# on the replacement side of a sed s/// and would be silently corrupted.
envValue() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    grep -E "^${key}=" "$file" 2> /dev/null | head -1 | cut -d'=' -f2- || true
}

# Value of one env var in a RUNNING service's spec — which is not the same thing
# as the value in .env or docker-stack.yml. `docker stack deploy` expands
# env_file:/environment: client-side and bakes the result into the spec, so the
# spec is the only place that reflects what a container will actually see. Empty
# when the service, or the key, is absent.
serviceEnvValue() {
    local svc="$1" key="$2"
    docker service inspect "$svc" \
        --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2> /dev/null \
        | grep -E "^${key}=" | head -1 | cut -d'=' -f2- || true
}

# Content hash of a file, used to decide whether a bundle upgrade actually
# changed a bind-mounted config. Prints nothing when the file is absent, so a
# first install reads as "changed" against a non-empty later hash.
# sha256sum/md5sum are coreutils and effectively always present; cksum is the
# POSIX floor and only a fallback.
fileHash() {
    local f="$1"
    [ -f "$f" ] || return 0
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$f" | cut -d' ' -f1
    elif command -v md5sum > /dev/null 2>&1; then
        md5sum "$f" | cut -d' ' -f1
    else
        cksum "$f" | cut -d' ' -f1,2 | tr -d ' '
    fi
}

setEnvKv() {
    local file="$1" key="$2" val="$3"
    local tmp found=0
    tmp="$(mktemp)"
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$found" -eq 0 ] && [ "${line%%=*}" = "$key" ] && [ "${line#*=}" != "$line" ]; then
                printf '%s=%s\n' "$key" "$val" >> "$tmp"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$file"
    fi
    [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$val" >> "$tmp"
    # Copy contents rather than mv so the original inode, owner and 0600-ish
    # permissions are preserved.
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Applies a value that came from an explicit CLI flag (callers pass "" when the
# flag was absent, so this is a no-op then).
#
# The conflict rule is deliberately asymmetric:
#
#   * .env we JUST created from .env.example — any pre-existing value is a
#     TEMPLATE default, not an operator decision, so the flag wins. Without this
#     the prefilled BAAS_HOST would silently beat --dus-upstream on
#     every fresh install.
#   * .env already existed — the value may be a hand-tuned or rotated
#     credential, so keep it and say so. --force-env overrides.
setEnvFromFlag() {
    local file="$1" key="$2" val="$3"
    [ -n "$val" ] || return 0

    local cur; cur="$(envValue "$file" "$key")"
    if [ -n "$cur" ] && [ "$cur" != "$val" ] \
        && [ "$ENV_WAS_CREATED" -eq 0 ] && [ "$FORCE_ENV" -eq 0 ]; then
        warn "$key differs from the value already in .env — keeping the existing one (--force-env to replace)"
        return 0
    fi
    [ "$cur" = "$val" ] && return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} set $key in $file"
        return 0
    fi
    setEnvKv "$file" "$key" "$val"
}

# Collect BAAS_HOST from whichever of the three flags supplied it.
#
# --dus-upstream and --kvs-api-base used to name two DIFFERENT variables
# (EDGE_DUS_UPSTREAM / EDGE_KVS_API_BASE). After consolidation both write
# BAAS_HOST, and the original code simply called setEnvFromFlag twice — so
# --kvs-api-base silently overwrote --dus-upstream. An operator passing both
# (which every documented install command did) got only the second one, with
# no warning. Fail loudly instead: one host must serve both surfaces, so two
# different values is a contradiction the operator has to resolve.
setBaasHost() {
    local val="$1" flag="$2"
    if [ -n "$OPT_BAAS_HOST" ] && [ "$OPT_BAAS_HOST" != "$val" ]; then
        die "conflicting values for the BaaS origin: $OPT_BAAS_HOST_FLAG '$OPT_BAAS_HOST' vs $flag '$val'. BAAS_HOST is ONE origin serving both /items/* and /dsb/v1/* — pass a single --baas-host."
    fi
    OPT_BAAS_HOST="$val"
    OPT_BAAS_HOST_FLAG="$flag"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version)             VERSION="${2:?--version needs a value}"; shift 2 ;;
        --dir)                 INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --pop-id)              OPT_POP_ID="${2:?}"; shift 2 ;;
        --baas-host)           setBaasHost "${2:?}" --baas-host; shift 2 ;;
        --baas-token)          OPT_BAAS_TOKEN="${2:?}"; shift 2 ;;
        --baas-version)        OPT_BAAS_VERSION="${2:?}"; shift 2 ;;
        --baas-project-id)     OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        # Deprecated aliases. --dus-upstream and --kvs-api-base named two
        # SEPARATE variables before they were consolidated into BAAS_HOST; both
        # now target the same key, so passing both with different values is a
        # hard error rather than a silent last-write-wins (which is exactly how
        # the consolidation broke PoPs — the second call clobbered the first).
        --dus-upstream)        setBaasHost "${2:?}" --dus-upstream; shift 2 ;;
        --kvs-api-base)        setBaasHost "${2:?}" --kvs-api-base; shift 2 ;;
        --dus-token)           OPT_BAAS_TOKEN="${2:?}"; shift 2 ;;
        --kvs-project-id)      OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        --geoip-account-id)    OPT_GEOIP_ACCOUNT_ID="${2:?}"; shift 2 ;;
        --geoip-license-key)   OPT_GEOIP_LICENSE_KEY="${2:?}"; shift 2 ;;
        --gcloud-metrics-id)   OPT_GCLOUD_METRICS_ID="${2:?}"; shift 2 ;;
        --gcloud-logs-id)      OPT_GCLOUD_LOGS_ID="${2:?}"; shift 2 ;;
        --gcloud-api-key)      OPT_GCLOUD_API_KEY="${2:?}"; shift 2 ;;
        --wan-iface)           OPT_WAN_IFACE="${2:?}"; shift 2 ;;
        --bundle-image)        BUNDLE_IMAGE="${2:?}"; shift 2 ;;
        --upgrade)             MODE="upgrade"; shift ;;
        --restart-alloy)       ALLOY_RESTART="always"; shift ;;
        --no-restart-alloy)    ALLOY_RESTART="never"; shift ;;
        --skip-docker-install) SKIP_DOCKER_INSTALL=1; shift ;;
        --skip-sysctl)         SKIP_SYSCTL=1; shift ;;
        --skip-firewall)       SKIP_FIREWALL=1; shift ;;
        --no-deploy)           NO_DEPLOY=1; shift ;;
        --force-env)           FORCE_ENV=1; shift ;;
        --dry-run)             DRY_RUN=1; shift ;;
        --yes | -y)            ASSUME_YES=1; shift ;;
        --help | -h)           usage; exit 0 ;;
        *)                     err "unknown argument: $1"; usage; exit 1 ;;
    esac
done

ENV_FILE="$INSTALL_DIR/.env"
# Set when seedEnv() creates .env from the template in THIS run — see
# setEnvFromFlag() for why the distinction matters.
ENV_WAS_CREATED=0

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
    step "Preflight"

    [ "$(id -u)" -eq 0 ] || die "must run as root (installs packages, nftables rules and a systemd unit)"

    local os="unknown"
    [ -r /etc/os-release ] && os="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
    info "host   : $(uname -s) $(uname -r) $(uname -m)"
    info "distro : $os"
    info "target : $INSTALL_DIR"

    case "$(uname -m)" in
        x86_64 | amd64) ;;
        *) warn "published images are built for x86_64 — $(uname -m) is untested" ;;
    esac

    local missing=""
    for c in curl tar sed grep; do
        command -v "$c" > /dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || die "missing required tool(s):$missing"

    # nftables is what actually owns public 80/443. Without it the stack can
    # deploy and look healthy on 8080/8443 while serving nothing externally —
    # a failure mode worth catching here rather than at first traffic.
    if ! command -v nft > /dev/null 2>&1; then
        warn "nft (nftables) not found — required by the L4 switch"
        installPackage nftables
    fi
    command -v nft > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] \
        || die "nftables still unavailable after install attempt"

    command -v openssl > /dev/null 2>&1 || installPackage openssl
    command -v openssl > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] \
        || die "openssl is required (TLS session-ticket key generation)"

    ok "preflight passed"
}

installPackage() {
    local pkg="$1"
    info "installing $pkg"
    if command -v apt-get > /dev/null 2>&1; then
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
    elif command -v dnf > /dev/null 2>&1; then
        run dnf install -y -q "$pkg"
    elif command -v yum > /dev/null 2>&1; then
        run yum install -y -q "$pkg"
    else
        die "no supported package manager found — install $pkg manually and re-run"
    fi
}

ensureDocker() {
    step "Docker"

    if command -v docker > /dev/null 2>&1; then
        ok "docker present: $(docker --version 2> /dev/null || echo unknown)"
    else
        [ "$SKIP_DOCKER_INSTALL" -eq 0 ] || die "docker not found and --skip-docker-install was given"
        info "installing Docker via get.docker.com"
        run sh -c 'curl -fsSL https://get.docker.com | sh'
        run systemctl enable --now docker
        command -v docker > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] || die "Docker install failed"
        ok "docker installed"
    fi

    # swarm-init.sh pre-merges docker-stack.override.yml through `docker compose
    # config` — without the plugin, a node with extra cache disks cannot deploy.
    if docker compose version > /dev/null 2>&1; then
        ok "docker compose plugin present"
    else
        warn "docker compose plugin missing — required when docker-stack.override.yml exists"
        installPackage docker-compose-plugin || true
    fi

    if ! docker info > /dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
        die "docker daemon is not responding"
    fi
}

# ── Version resolution ───────────────────────────────────────────────────────
# Uses the ANONYMOUS registry API: the repo is private but the images are
# public, so this needs no GitHub credentials and no `docker login`.
resolveLatestVersion() {
    local token tags
    token="$(curl -fsSL "https://${REGISTRY}/token?scope=repository:${GHCR_REPO}/bundle:pull&service=${REGISTRY}" 2> /dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || return 1
    [ -n "$token" ] || return 1

    tags="$(curl -fsSL -H "Authorization: Bearer $token" \
        "https://${REGISTRY}/v2/${GHCR_REPO}/bundle/tags/list" 2> /dev/null)" || return 1

    printf '%s' "$tags" \
        | sed 's/.*"tags":\[//; s/\].*//' \
        | tr ',' '\n' \
        | tr -d '" ' \
        | grep -E '^v[0-9]' \
        | sort -V \
        | tail -1
}

resolveVersion() {
    step "Version"

    if [ -n "$VERSION" ]; then
        info "pinned by --version"
    else
        info "resolving newest published release from ${REGISTRY}/${GHCR_REPO}/bundle"
        VERSION="$(resolveLatestVersion || true)"
        [ -n "$VERSION" ] || die "could not resolve a published vX.Y[.Z] bundle tag — pass --version explicitly"
    fi

    ok "version: ${C_BOLD}${VERSION}${C_RESET}"
}

# ── Bundle ───────────────────────────────────────────────────────────────────
fetchBundle() {
    step "Runtime bundle"

    local image="${BUNDLE_IMAGE:-${REGISTRY}/${GHCR_REPO}/bundle:${VERSION}}"
    info "image: $image"

    # An explicit override is assumed to be operator-supplied (mirrored registry,
    # side-loaded tar, local build), so a missing remote is not an error there.
    if [ -n "$BUNDLE_IMAGE" ] && docker image inspect "$image" > /dev/null 2>&1; then
        info "using locally-present image (--bundle-image)"
    else
        run docker pull -q "$image"
    fi

    if command -v cosign > /dev/null 2>&1; then
        if run cosign verify \
            --certificate-identity-regexp "^https://github.com/${GHCR_REPO}/" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            "$image" > /dev/null 2>&1; then
            ok "cosign signature verified"
        else
            warn "cosign verification failed — continuing (pass --dry-run to inspect)"
        fi
    else
        info "cosign not installed — skipping signature verification"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} extract $image -> $INSTALL_DIR"
        return 0
    fi

    STAGE_DIR="$(mktemp -d)"
    docker run --rm "$image" tar -cC /opt/opencache-bundle . | tar -xC "$STAGE_DIR"

    # A bundle that carries node-local state would silently overwrite an
    # operator's credentials or cache on upgrade. Refuse rather than proceed.
    local leaked="" p
    for p in "${PROTECTED_PATHS[@]}"; do
        if [ -e "$STAGE_DIR/$p" ]; then
            leaked="$leaked $p"
        fi
    done
    [ -z "$leaked" ] || die "bundle contains protected node-local path(s):$leaked — refusing to extract"

    local n
    n="$(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')"

    mkdir -p "$INSTALL_DIR"
    cp -a "$STAGE_DIR/." "$INSTALL_DIR/"
    rm -rf "$STAGE_DIR"; STAGE_DIR=""

    ok "extracted $n files to $INSTALL_DIR (version $(cat "$INSTALL_DIR/VERSION" 2> /dev/null || echo '?'))"
}

# ── Legacy .env key migration ────────────────────────────────────────────────
# Renames pre-consolidation keys in place:
#
#   EDGE_DUS_UPSTREAM  ─┐
#   EDGE_KVS_API_BASE  ─┴─> BAAS_HOST
#   EDGE_DUS_TOKEN       ─> BAAS_TOKEN
#   EDGE_PROJECT_ID    ─┐
#   EDGE_KVS_PROJECT_ID─┴─> BAAS_PROJECT_ID
#
# WHY THIS IS REQUIRED, not a nicety: seedEnv() copies .env.example ONLY when
# .env is absent, and setEnvFromFlag() is a no-op without an explicit flag. An
# upgrade of a PoP installed before the rename therefore ended up with an .env
# holding EDGE_* keys and NO BAAS_* keys at all — config-generator then either
# aborted on "BAAS_HOST environment variable is required" or, once someone
# answered the prompt with the wrong origin, failed every poll against a host
# that does not serve /items/kvs. Renaming in place makes an upgrade carry the
# operator's working values forward untouched.
#
# Both legacy host keys map onto one target. If they disagree the node was
# genuinely talking to two origins and no automatic choice is safe — keep
# neither and let promptForRequired ask, so the operator makes the call.
migrateLegacyEnvKeys() {
    [ -f "$ENV_FILE" ] || return 0

    local dusUp kvsBase dusTok projA projB chosen

    dusUp="$(envValue "$ENV_FILE" EDGE_DUS_UPSTREAM)"
    kvsBase="$(envValue "$ENV_FILE" EDGE_KVS_API_BASE)"
    dusTok="$(envValue "$ENV_FILE" EDGE_DUS_TOKEN)"
    projA="$(envValue "$ENV_FILE" EDGE_PROJECT_ID)"
    projB="$(envValue "$ENV_FILE" EDGE_KVS_PROJECT_ID)"

    # Nothing legacy present — normal path for a fresh or already-migrated node.
    if [ -z "$dusUp$kvsBase$dusTok$projA$projB" ]; then
        return 0
    fi

    step "Migrating legacy .env keys (EDGE_* -> BAAS_*)"

    if [ -z "$(envValue "$ENV_FILE" BAAS_HOST)" ]; then
        chosen=""
        if [ -n "$dusUp" ] && [ -n "$kvsBase" ] && [ "$dusUp" != "$kvsBase" ]; then
            warn "EDGE_DUS_UPSTREAM ($dusUp) and EDGE_KVS_API_BASE ($kvsBase) differ."
            warn "BAAS_HOST is ONE origin serving both /items/* and /dsb/v1/* — cannot pick automatically."
            warn "Leaving BAAS_HOST unset; you will be asked for the correct origin below."
        else
            chosen="${dusUp:-$kvsBase}"
        fi
        if [ -n "$chosen" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    ${C_YELLOW}dry-run${C_RESET} set BAAS_HOST=$chosen (from legacy key)"
            else
                setEnvKv "$ENV_FILE" BAAS_HOST "$chosen"
                ok "BAAS_HOST=$chosen (migrated)"
            fi
        fi
    fi

    if [ -n "$dusTok" ] && [ -z "$(envValue "$ENV_FILE" BAAS_TOKEN)" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} set BAAS_TOKEN from EDGE_DUS_TOKEN"
        else
            setEnvKv "$ENV_FILE" BAAS_TOKEN "$dusTok"
            ok "BAAS_TOKEN migrated from EDGE_DUS_TOKEN"
        fi
    fi

    chosen="${projA:-$projB}"
    if [ -n "$chosen" ] && [ -z "$(envValue "$ENV_FILE" BAAS_PROJECT_ID)" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} set BAAS_PROJECT_ID=$chosen (from legacy key)"
        else
            setEnvKv "$ENV_FILE" BAAS_PROJECT_ID "$chosen"
            ok "BAAS_PROJECT_ID=$chosen (migrated)"
        fi
    fi

    # The legacy keys are left in place on purpose: nothing reads them any more,
    # and deleting an operator's only copy of a token during an upgrade is a
    # worse failure than a few stale lines. They can be pruned by hand.
    ok "legacy EDGE_* keys retained (unused) — safe to delete once verified"
}

# ── .env ─────────────────────────────────────────────────────────────────────
seedEnv() {
    step "Configuration (.env)"

    if [ ! -f "$ENV_FILE" ]; then
        ENV_WAS_CREATED=1
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} create $ENV_FILE from .env.example"
        else
            cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
            ok "created $ENV_FILE from .env.example (mode 0600)"
        fi
    else
        ok "$ENV_FILE exists — existing values preserved"
    fi

    # Rename pre-consolidation keys BEFORE applying flags, so an upgraded node
    # keeps its working values instead of falling through to the prompt.
    migrateLegacyEnvKeys

    setEnvFromFlag "$ENV_FILE" POP_ID                   "$OPT_POP_ID"
    setEnvFromFlag "$ENV_FILE" BAAS_HOST                "$OPT_BAAS_HOST"
    setEnvFromFlag "$ENV_FILE" BAAS_TOKEN               "$OPT_BAAS_TOKEN"
    setEnvFromFlag "$ENV_FILE" BAAS_VERSION             "$OPT_BAAS_VERSION"
    setEnvFromFlag "$ENV_FILE" BAAS_PROJECT_ID          "$OPT_BAAS_PROJECT_ID"
    setEnvFromFlag "$ENV_FILE" GEOIP_ACCOUNT_ID         "$OPT_GEOIP_ACCOUNT_ID"
    setEnvFromFlag "$ENV_FILE" GEOIP_LICENSE_KEY        "$OPT_GEOIP_LICENSE_KEY"
    setEnvFromFlag "$ENV_FILE" GCLOUD_HOSTED_METRICS_ID "$OPT_GCLOUD_METRICS_ID"
    setEnvFromFlag "$ENV_FILE" GCLOUD_HOSTED_LOGS_ID    "$OPT_GCLOUD_LOGS_ID"
    setEnvFromFlag "$ENV_FILE" GCLOUD_RW_API_KEY        "$OPT_GCLOUD_API_KEY"

    # OCC_WAN_IFACE is read from the environment by l4-switch.sh. rollout.sh
    # does `set -a; source .env; set +a` before invoking it, so persisting the
    # value here makes it survive every future flip — otherwise a rollout
    # re-renders the ruleset without the interface scope.
    setEnvFromFlag "$ENV_FILE" OCC_WAN_IFACE "$OPT_WAN_IFACE"

    # Pin the image tag. The stack defaults to rolling-release, a floating tag —
    # pinning keeps the bundle on disk and the running images at the same
    # version, which is the whole point of a versioned bundle.
    if [ "$DRY_RUN" -eq 0 ]; then
        setEnvKv "$ENV_FILE" IMAGE_TAG "$VERSION"
        setEnvKv "$ENV_FILE" GHCR_REPO "$GHCR_REPO"
    fi
    ok "IMAGE_TAG pinned to $VERSION"

    promptForRequired
}

# Interactive rescue for the settings the stack cannot run correctly without.
# swarm-init.sh hard-fails on BAAS_HOST/BAAS_TOKEN anyway; asking here produces
# a far better error than a stack trace three phases later.
#
# BAAS_PROJECT_ID is a softer failure — the stack still serves traffic, it just
# stops reporting to the dashboard — so the warning is worded per key rather
# than claiming the stack will not start. These are absent (not empty) on an
# UPGRADE of a PoP installed before they existed, which is exactly when this
# rescue matters. .env.example ships them EMPTY (it is published in a public
# image and must not carry infrastructure hostnames), so this also runs on
# every fresh install that did not pass the flags.
promptForRequired() {
    [ "$DRY_RUN" -eq 0 ] || return 0

    local key val consequence hint
    # NOTE: BAAS_HOST appeared TWICE in this list before the consolidation was
    # tidied up — harmless but confusing, since the second pass could never
    # fire. One entry per key.
    for key in BAAS_HOST BAAS_TOKEN POP_ID BAAS_PROJECT_ID; do
        val="$(envValue "$ENV_FILE" "$key")"
        [ -n "$val" ] && continue
        case "$key" in
            BAAS_HOST)
                hint=" (origin serving BOTH /items/* and /dsb/v1/*, e.g. https://baas.example.com)" ;;
            BAAS_PROJECT_ID)
                hint=" (project UUID the PoP's KVS records live under)" ;;
            *)  hint="" ;;
        esac
        if val="$(promptValue "$key is required$hint — enter value")"; then
            setEnvKv "$ENV_FILE" "$key" "$val"
            ok "$key set"
        else
            case "$key" in
                BAAS_PROJECT_ID) consequence="this node will not report metrics or BGP prefixes" ;;
                *)               consequence="the stack will not start" ;;
            esac
            warn "$key is empty — $consequence until it is set in $ENV_FILE"
        fi
    done
}

# ── Per-node cache disks ─────────────────────────────────────────────────────
# Deploying without an override on a node that HAS dedicated cache disks is a
# silent failure: nginx writes cache onto the container overlay filesystem
# instead of the disk. It fills the root volume and produces no error, so it is
# worth an explicit gate rather than swarm-init.sh's after-the-fact warning.
cacheDiskGate() {
    step "Cache disks"

    local override="$INSTALL_DIR/docker-stack.override.yml"
    if [ -f "$override" ]; then
        ok "docker-stack.override.yml present — per-node disk mounts will be applied"
        return 0
    fi

    info "no docker-stack.override.yml — the stack will cache under $INSTALL_DIR only"

    if promptYesNo "Does this node have dedicated cache disks (e.g. /cache1, /cache-hdd)?" n; then
        run cp "$INSTALL_DIR/docker-stack.override.yml.example" "$override"
        echo
        warn "created $override from the example"
        warn "EDIT IT NOW so every cache path is bind-mounted into BOTH colors,"
        warn "then re-run this installer to continue. Stopping before deploy."
        exit 0
    fi

    ok "continuing without per-node disk overrides"
}

# ── Host preparation ─────────────────────────────────────────────────────────
hostPrep() {
    step "Host tuning"

    if [ "$SKIP_SYSCTL" -eq 1 ]; then
        info "skipped (--skip-sysctl)"
    else
        run "$INSTALL_DIR/scripts/sysctl-tuning.sh"
        ok "kernel tuning applied (/etc/sysctl.d/99-opencache.conf)"
    fi

    configureDockerLogging
}

# Unbounded json-file logs will fill the root volume on a busy PoP. Merge rather
# than clobber: a pre-existing daemon.json may carry registry mirrors, storage
# driver or live-restore settings that must not be lost.
configureDockerLogging() {
    local f=/etc/docker/daemon.json

    if [ -f "$f" ] && grep -q 'max-size' "$f" 2> /dev/null; then
        ok "docker log caps already configured"
        return 0
    fi

    if [ ! -f "$f" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} write $f"
        else
            mkdir -p /etc/docker
            cat > "$f" <<- 'JSON'
			{
			  "log-driver": "json-file",
			  "log-opts": {
			    "max-size": "50m",
			    "max-file": "3"
			  }
			}
			JSON
            ok "wrote $f"
        fi
        restartDocker
        return 0
    fi

    if command -v jq > /dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} merge log caps into $f"
        else
            local tmp; tmp="$(mktemp)"
            jq '. + {"log-driver":"json-file"} | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size":"50m","max-file":"3"})' \
                "$f" > "$tmp" && cat "$tmp" > "$f"
            rm -f "$tmp"
            ok "merged log caps into $f"
        fi
        restartDocker
        return 0
    fi

    # No jq: refuse to hand-edit someone else's JSON.
    warn "$f exists and jq is unavailable — not modifying it"
    warn "add manually to keep container logs bounded:"
    warn '  "log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}'
}

restartDocker() {
    info "restarting docker to apply daemon configuration"
    run systemctl restart docker
    # The daemon takes a moment to accept connections again; a deploy issued
    # immediately after the restart otherwise fails on a closed socket.
    if [ "$DRY_RUN" -eq 0 ]; then
        local i=0
        while [ "$i" -lt 30 ]; do
            docker info > /dev/null 2>&1 && break
            i=$((i + 1)); sleep 1
        done
    fi
}

# ── L4 switch ────────────────────────────────────────────────────────────────
installL4Switch() {
    step "L4 blue/green switch"

    # Exported rather than passed: l4-switch.sh reads OCC_WAN_IFACE from the
    # environment and bakes it into the rendered ruleset.
    if [ -n "$OPT_WAN_IFACE" ]; then
        export OCC_WAN_IFACE="$OPT_WAN_IFACE"
        info "scoping redirect to interface: $OPT_WAN_IFACE"
    fi

    run "$INSTALL_DIR/scripts/l4-switch.sh" install
    ok "nftables ruleset loaded and persisted to /etc/opencache/occ-switch.nft"

    run cp "$INSTALL_DIR/l4-switch/occ-switch.service" /etc/systemd/system/occ-switch.service
    run systemctl daemon-reload
    run systemctl enable occ-switch.service > /dev/null 2>&1 || true
    ok "occ-switch.service enabled (ruleset survives reboot)"
}

# ── RAM-backed certificate store ─────────────────────────────────────────────
# TLS private keys must not reach the block device. certs-tmpfs.sh migrates any
# existing on-disk keys into RAM, shreds the originals (mounting a tmpfs over
# them would only HIDE them, permanently out of reach of shred), mounts the
# tmpfs and installs a generated systemd .mount unit so it survives reboot.
#
# The unit is generated rather than bundled because systemd derives a .mount
# unit's NAME from its mount point, which differs between a PoP and any other
# install prefix.
#
# Idempotent: a node already on tmpfs only gets its permissions re-tightened.
configureCertStore() {
    step "Certificate store (RAM-backed)"

    if [ ! -x "$INSTALL_DIR/scripts/certs-tmpfs.sh" ]; then
        warn "scripts/certs-tmpfs.sh missing from this bundle — certificate store left on disk"
        return 0
    fi

    run "$INSTALL_DIR/scripts/certs-tmpfs.sh" install

    # Swap turns the whole exercise into theatre: a tmpfs page can be paged out
    # to an unencrypted swap device, putting key material back on the disk.
    if [ "$(swapon --show --noheadings 2> /dev/null | wc -l)" -ne 0 ]; then
        warn "swap is ENABLED on this host. tmpfs pages — including private keys —"
        warn "can be written to the swap device, which defeats the RAM-backed store."
        warn "Run 'swapoff -a' and remove swap entries from /etc/fstab, or use encrypted swap."
    fi
}

# ── Firewall ─────────────────────────────────────────────────────────────────
# ufw sees the POST-redirect backend ports at filter INPUT, not 80/443. An
# allow-list of only 80/443 therefore drops all external traffic while localhost
# probes and health-check.sh stay green — a genuinely confusing failure. Port
# numbers come from l4-switch.sh, the single source of truth for the scheme.
configureFirewall() {
    step "Firewall"

    if [ "$SKIP_FIREWALL" -eq 1 ]; then
        info "skipped (--skip-firewall)"
        return 0
    fi
    if ! command -v ufw > /dev/null 2>&1; then
        info "ufw not installed — nothing to do"
        return 0
    fi
    if ! ufw status 2> /dev/null | head -1 | grep -qi active; then
        info "ufw installed but inactive — nothing to do"
        return 0
    fi

    if [ ! -x "$INSTALL_DIR/scripts/l4-switch.sh" ]; then
        info "l4-switch.sh not present yet — skipping port allow-list"
        return 0
    fi

    local color ports http https quic
    for color in blue green; do
        ports="$("$INSTALL_DIR/scripts/l4-switch.sh" ports "$color")" || continue
        http="$(echo "$ports" | awk '{print $1}')"
        https="$(echo "$ports" | awk '{print $2}')"
        quic="$(echo "$ports" | awk '{print $3}')"
        run ufw allow "${http}/tcp"  > /dev/null
        run ufw allow "${https}/tcp" > /dev/null
        run ufw allow "${quic}/udp"  > /dev/null
        ok "$color: allowed ${http}/tcp ${https}/tcp ${quic}/udp"
    done

    run ufw allow 80/tcp  > /dev/null
    run ufw allow 443/tcp > /dev/null
    run ufw allow 443/udp > /dev/null
    ok "public 80/443 allowed"
}

# ── Deploy ───────────────────────────────────────────────────────────────────
deployStack() {
    step "Deploy"

    if [ "$NO_DEPLOY" -eq 1 ]; then
        info "skipped (--no-deploy)"
        info "deploy later with: cd $INSTALL_DIR && sudo ./scripts/swarm-init.sh"
        return 0
    fi

    run "$INSTALL_DIR/scripts/swarm-init.sh"
}

verifyInstall() {
    step "Verify"

    if [ "$NO_DEPLOY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
        info "skipped"
        return 0
    fi
    "$INSTALL_DIR/scripts/health-check.sh" || warn "health-check reported problems — see output above"
}

# ── Observability wiring (alloy ⇄ prefix-monitor node metrics) ───────────────
# Two things this path must repair that nothing else will:
#
#  1. alloy BIND-MOUNTS alloy/config.alloy from the bundle and does NOT
#     hot-reload it. alloy is absent from SHARED_SERVICES (correctly — its
#     image is grafana/alloy:latest and does not follow IMAGE_TAG), so an
#     upgrade that ships a new config.alloy would leave the OLD one loaded in
#     memory indefinitely. Symptom: a brand-new scrape/pipeline silently never
#     runs, with every version string on the node reporting current.
#
#  2. `docker service update` NEVER re-reads `environment:`/`env_file:` from
#     docker-stack.yml — those are expanded client-side by `stack deploy` and
#     baked into the spec. Since this path deliberately avoids a stack deploy
#     (it would restart the ACTIVE nginx-cache color and serve a cold cache),
#     any NEW variable introduced by a release has to be pushed in explicitly
#     with --env-add, exactly as the BAAS_* keys above are.
#
# Both are needed for the node-metrics scrape: prefix-monitor must also bind
# :9101 on the docker_gwbridge gateway (alloy is on the overlay and cannot
# reach the host's loopback), and alloy must be told to scrape that address.
#
# ── Why this is GATED rather than unconditional ──────────────────────────────
# Restarting alloy is not free: it drops the in-flight Loki batch, and log
# tailing resumes from positions.yml rather than exactly where it left off, so
# a busy PoP pays a catch-up window. Most upgrades do not touch config.alloy at
# all, and restarting it on every one would be pure cost. So:
#
#   auto (default) — restart only when the bundle actually CHANGED
#                    config.alloy, or when a required env var is missing/stale
#                    in the running spec. A no-op upgrade leaves alloy alone.
#   --restart-alloy   force it. Needed for RECOVERY: if a previous run already
#                     wrote the new config.alloy to disk but never restarted
#                     alloy, the content hash now matches and `auto` would
#                     correctly see no change while alloy still runs the old
#                     config in memory. This is exactly the v26.08.3 case.
#   --no-restart-alloy  never. Env vars are still applied (they are what makes
#                     the scrape work at all); the restart is left to the
#                     operator, and a warning names the command.
updateObservabilityWiring() {
    docker service inspect "${STACK_NAME}_alloy" > /dev/null 2>&1 \
        || [ "$DRY_RUN" -eq 1 ] || return 0

    step "Wiring node metrics (alloy ⇄ prefix-monitor)"

    local gw port cfgChanged=0 envChanged=0 reason=""

    if [ "$ALLOY_CFG_HASH_BEFORE" != "$(fileHash "$INSTALL_DIR/alloy/config.alloy")" ]; then
        cfgChanged=1
        reason="config.alloy changed"
    fi

    gw="$(envValue "$ENV_FILE" GWBRIDGE_GATEWAY)"
    if [ -z "$gw" ]; then
        gw="$(docker network inspect docker_gwbridge \
            --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2> /dev/null || true)"
        # Persist it so later runs (and nginx-exporter) agree on one value.
        [ -n "$gw" ] && [ "$DRY_RUN" -eq 0 ] && setEnvKv "$ENV_FILE" GWBRIDGE_GATEWAY "$gw"
    fi
    if [ -z "$gw" ]; then
        warn "docker_gwbridge gateway not detectable — skipping node-metrics wiring."
        warn "Node metrics (opencache_node_*) will not reach Grafana until you run:"
        warn "  sudo $INSTALL_DIR/scripts/swarm-init.sh --deploy-only"
        return 0
    fi

    port="$(envValue "$ENV_FILE" METRICS_HTTP_PORT)"
    [ -n "$port" ] || port=9101
    info "gwbridge gateway: $gw   metrics port: $port"

    # prefix-monitor: the extra bind that makes :9101 reachable from the overlay
    # at all. Only touched when the running spec disagrees — an --env-add with
    # --force restarts the task, and there is no reason to pay that on a no-op
    # upgrade. A wrong value here degrades scraping rather than taking the
    # service down: the extra bind is non-fatal inside the monitor by design.
    if docker service inspect "${STACK_NAME}_prefix-monitor" > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
        if [ "$(serviceEnvValue "${STACK_NAME}_prefix-monitor" METRICS_HTTP_EXTRA_HOSTS)" = "$gw" ]; then
            info "prefix-monitor already binds :$port on $gw — unchanged"
        else
            run docker service update \
                --env-add "METRICS_HTTP_EXTRA_HOSTS=$gw" \
                --with-registry-auth --force "${STACK_NAME}_prefix-monitor" > /dev/null
            ok "prefix-monitor now binds :$port on $gw"
        fi
    fi

    # alloy: the scrape target. Applied regardless of the restart policy —
    # without it the scrape cannot work, and --env-add carries its own task
    # replacement, which doubles as the config reload.
    local wantTarget="$gw:$port"
    if [ "$(serviceEnvValue "${STACK_NAME}_alloy" PREFIX_MONITOR_SCRAPE_TARGET)" != "$wantTarget" ]; then
        envChanged=1
        [ -n "$reason" ] && reason="$reason, " || true
        reason="${reason}scrape target -> $wantTarget"
    fi

    case "$ALLOY_RESTART" in
        never)
            if [ "$cfgChanged" -eq 1 ] || [ "$envChanged" -eq 1 ]; then
                warn "alloy needs a restart ($reason) but --no-restart-alloy was given."
                warn "Node metrics will not flow until you run:"
                warn "  sudo docker service update --env-add PREFIX_MONITOR_SCRAPE_TARGET=$wantTarget --force ${STACK_NAME}_alloy"
            else
                info "alloy unchanged — nothing to do"
            fi
            return 0
            ;;
        always)
            [ -n "$reason" ] || reason="--restart-alloy"
            ;;
        *)
            # fetchBundle does not extract under --dry-run, so config.alloy on
            # disk cannot have changed and cfgChanged is always 0 here. Say so
            # rather than reporting a confident "unchanged" that a real run
            # might contradict.
            if [ "$DRY_RUN" -eq 1 ] && [ "$cfgChanged" -eq 0 ]; then
                info "dry-run: cannot tell whether the bundle would change config.alloy"
                info "(nothing was extracted) — a real run restarts alloy only if it does"
            fi
            if [ "$cfgChanged" -eq 0 ] && [ "$envChanged" -eq 0 ]; then
                info "alloy config and scrape target unchanged — not restarting"
                info "(force it with --restart-alloy if alloy is running a stale config)"
                return 0
            fi
            ;;
    esac

    info "restarting alloy: $reason"
    run docker service update \
        --env-add "PREFIX_MONITOR_SCRAPE_TARGET=$wantTarget" \
        --force "${STACK_NAME}_alloy" > /dev/null
    ok "alloy scrapes $wantTarget and reloaded config.alloy"
}

# ── Upgrade ──────────────────────────────────────────────────────────────────
# Ordering is deliberate and load-bearing. A plain `docker stack deploy` at a new
# IMAGE_TAG restarts the ACTIVE nginx-cache color, which defeats the whole point
# of the blue/green switch. So: roll nginx-cache gap-free first, update the
# shared services individually (no stack deploy), and only then persist the new
# IMAGE_TAG so a later swarm-init.sh --deploy-only reconciles to a fleet that is
# already there.
doUpgrade() {
    local previous="unknown"
    [ -f "$INSTALL_DIR/VERSION" ] && previous="$(cat "$INSTALL_DIR/VERSION")"

    step "Upgrade"
    info "from : $previous"
    info "to   : $VERSION"

    [ -d "$INSTALL_DIR" ] || die "$INSTALL_DIR does not exist — run without --upgrade for a fresh install"
    [ -f "$ENV_FILE" ] || die "$ENV_FILE not found — this does not look like an OpenCache install"

    # Upgrade is the ONLY path this migration was written for, yet main() used
    # to `return` before seedEnv() (its only caller) — so a PoP predating the
    # BAAS_* rename upgraded into an image that reads BAAS_HOST while .env
    # still only held EDGE_DUS_UPSTREAM, and config-watcher died on
    # "BAAS_HOST environment variable is required" every start until Swarm
    # rolled the update back. Additive: legacy EDGE_* keys are retained.
    migrateLegacyEnvKeys

    # Snapshot before extraction so updateObservabilityWiring can distinguish
    # "this release changed the Alloy pipeline" from "nothing to do here".
    ALLOY_CFG_HASH_BEFORE="$(fileHash "$INSTALL_DIR/alloy/config.alloy")"

    fetchBundle

    # The switch template ships in the bundle and may have changed between
    # versions; re-render so the persisted ruleset matches the new template.
    run "$INSTALL_DIR/scripts/l4-switch.sh" install
    run cp "$INSTALL_DIR/l4-switch/occ-switch.service" /etc/systemd/system/occ-switch.service
    run systemctl daemon-reload

    # Before the rollout: the standby color must come up against a certificate
    # store that is already in its final location, and rollout.sh now refuses to
    # flip to a color that cannot terminate TLS. Migration preserves the keys
    # (staged through RAM, never re-written to disk), so this does not interrupt
    # the running colour.
    configureCertStore

    step "Rolling nginx-cache (gap-free)"
    run "$INSTALL_DIR/scripts/rollout.sh" --image-tag "$VERSION" --yes

    # `env_file:` in docker-stack.yml is expanded CLIENT-SIDE by `docker stack
    # deploy` and baked into the service spec — `docker service update` never
    # re-reads it. Since this path deliberately avoids a stack deploy (it would
    # restart the ACTIVE nginx-cache color), a migrated or edited .env would
    # otherwise never reach a running service. Push the BaaS keys into each
    # spec explicitly so the new image finds them.
    local envAdd=() k v
    for k in BAAS_HOST BAAS_TOKEN BAAS_PROJECT_ID BAAS_VERSION; do
        v="$(envValue "$ENV_FILE" "$k")"
        if [ -n "$v" ]; then
            envAdd+=(--env-add "$k=$v")
        fi
    done
    # Skipped under --dry-run: migrateLegacyEnvKeys did not actually write, so
    # .env still shows the pre-migration state and the check would cry wolf.
    if [ "$DRY_RUN" -eq 0 ] && { [ -z "$(envValue "$ENV_FILE" BAAS_HOST)" ] || [ -z "$(envValue "$ENV_FILE" BAAS_TOKEN)" ]; }; then
        warn "BAAS_HOST / BAAS_TOKEN missing from $ENV_FILE — config-watcher will abort with"
        warn "\"BAAS_HOST environment variable is required\" and Swarm will roll the update back."
        warn "Set them (or the legacy EDGE_DUS_* keys this migrates from) and re-run --upgrade."
    fi

    # Cache-disk ejection knobs, prefix-monitor only. Same --env-add rationale
    # as the BaaS keys above; called out separately because these decide when a
    # PoP takes ITSELF out of rotation, so an operator who pinned a value in
    # .env (most importantly CACHE_DISK_EJECT_RATIO=0 to disable it) must not
    # silently keep running the built-in default after an upgrade.
    #
    # Omitting them entirely is safe — the code defaults match docker-stack.yml,
    # and CACHE_IO_STATS_URL derives from NGINX_HEALTH_URL — so this only ever
    # propagates a deliberate override.
    #
    # The TLS_PROBE_* keys are here for the same reason and matter most for
    # TLS_PROBE_ENABLED=false: that is the only escape hatch for a node that
    # deliberately serves no HTTPS, and losing it on upgrade would drain the
    # node permanently.
    local monitorEnvAdd=()
    for k in CACHE_DISK_EJECT_RATIO CACHE_DISK_EJECT_THRESHOLD \
             CACHE_VOLUME_IO_ERROR_THRESHOLD CACHE_IO_STATS_URL \
             TLS_PROBE_ENABLED NGINX_TLS_PROBE_URL TLS_PROBE_THRESHOLD \
             TLS_PROBE_TIMEOUT_MS CERT_MANIFEST_FILE; do
        v="$(envValue "$ENV_FILE" "$k")"
        if [ -n "$v" ]; then
            monitorEnvAdd+=(--env-add "$k=$v")
        fi
    done

    step "Updating shared services"
    local pair svc img
    for pair in $SHARED_SERVICES; do
        svc="${pair%%:*}"
        img="${pair##*:}"
        local extraEnv=()
        [ "$svc" = "prefix-monitor" ] && extraEnv=("${monitorEnvAdd[@]+"${monitorEnvAdd[@]}"}")
        if docker service inspect "${STACK_NAME}_${svc}" > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
            run docker service update \
                "${envAdd[@]+"${envAdd[@]}"}" \
                "${extraEnv[@]+"${extraEnv[@]}"}" \
                --image "${REGISTRY}/${GHCR_REPO}/${img}:${VERSION}" \
                --with-registry-auth --force "${STACK_NAME}_${svc}" > /dev/null
            ok "$svc -> $img:$VERSION"
        else
            warn "service ${STACK_NAME}_${svc} not found — skipped"
        fi
    done

    updateObservabilityWiring

    # Last, so an interrupted upgrade never leaves .env claiming a version the
    # running services have not reached.
    [ "$DRY_RUN" -eq 1 ] || setEnvKv "$ENV_FILE" IMAGE_TAG "$VERSION"
    ok "IMAGE_TAG pinned to $VERSION"

    verifyInstall
    summary
}

summary() {
    echo
    echo "${C_BOLD}${C_GREEN}OpenCache ${VERSION} — ${MODE} complete${C_RESET}"
    echo
    echo "  install dir : $INSTALL_DIR"
    echo "  config      : $ENV_FILE"
    echo
    echo "  Status      : cd $INSTALL_DIR && ./scripts/health-check.sh"
    echo "  Services    : docker stack services $STACK_NAME"
    echo "  Active color: sudo $INSTALL_DIR/scripts/l4-switch.sh status"
    echo "  Trace       : curl -s http://127.0.0.1/oc-cgi/trace"
    echo
    echo "  Upgrade to the newest release (gap-free):"
    echo "    curl -fsSL $INSTALLER_URL | sudo bash -s -- --upgrade"
    echo
}

main() {
    echo "${C_BOLD}OpenCache installer${C_RESET}"
    [ "$DRY_RUN" -eq 0 ] || warn "DRY RUN — no changes will be made"

    preflight
    ensureDocker
    resolveVersion

    if [ "$MODE" = "upgrade" ]; then
        doUpgrade
        return
    fi

    fetchBundle
    seedEnv
    cacheDiskGate
    hostPrep
    installL4Switch
    # Before deployStack: swarm-init generates the session-ticket key into the
    # certs dir, and that must land in RAM rather than on disk.
    configureCertStore
    configureFirewall
    deployStack
    verifyInstall
    summary
}

# Sourceable for testing: `OPENCACHE_INSTALL_LIB=1 . install.sh` loads the
# helpers without running an install.
[ "${OPENCACHE_INSTALL_LIB:-0}" = "1" ] || main
