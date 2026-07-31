#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenCache PoP installer.
#
#   curl -fsSL https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install.sh \
#     | sudo bash -s -- --pop-id PAR1 --dus-token <token>
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
#   --dus-upstream <url>   Directus URL
#   --dus-token <token>    Directus access token
#   --kvs-api-base <url>   KVS API URL prefix-monitor publishes to (/dsb/v1/kvs)
#   --kvs-project-id <id>  Project UUID the PoP's KVS records live under
#   --geoip-account-id <id>
#   --geoip-license-key <key>
#   --gcloud-metrics-id <id>
#   --gcloud-logs-id <id>
#   --gcloud-api-key <key>
#   --wan-iface <iface>    Scope the L4 redirect to one NIC (default: any)
#   --bundle-image <ref>   Override the bundle image (mirrored registry, air-gap,
#                          or local testing). Skips the pull when already present.
#   --upgrade              Upgrade an existing install (gap-free; see below)
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
OPT_DUS_UPSTREAM=""
OPT_DUS_TOKEN=""
OPT_KVS_API_BASE=""
OPT_KVS_PROJECT_ID=""
OPT_GEOIP_ACCOUNT_ID=""
OPT_GEOIP_LICENSE_KEY=""
OPT_GCLOUD_METRICS_ID=""
OPT_GCLOUD_LOGS_ID=""
OPT_GCLOUD_API_KEY=""
OPT_WAN_IFACE=""
BUNDLE_IMAGE="${OPENCACHE_BUNDLE_IMAGE:-}"

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
        echo "    ${C_YELLOW}dry-run${C_RESET} $*"
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

# ── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version)             VERSION="${2:?--version needs a value}"; shift 2 ;;
        --dir)                 INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --pop-id)              OPT_POP_ID="${2:?}"; shift 2 ;;
        --dus-upstream)        OPT_DUS_UPSTREAM="${2:?}"; shift 2 ;;
        --dus-token)           OPT_DUS_TOKEN="${2:?}"; shift 2 ;;
        --kvs-api-base)        OPT_KVS_API_BASE="${2:?}"; shift 2 ;;
        --kvs-project-id)      OPT_KVS_PROJECT_ID="${2:?}"; shift 2 ;;
        --geoip-account-id)    OPT_GEOIP_ACCOUNT_ID="${2:?}"; shift 2 ;;
        --geoip-license-key)   OPT_GEOIP_LICENSE_KEY="${2:?}"; shift 2 ;;
        --gcloud-metrics-id)   OPT_GCLOUD_METRICS_ID="${2:?}"; shift 2 ;;
        --gcloud-logs-id)      OPT_GCLOUD_LOGS_ID="${2:?}"; shift 2 ;;
        --gcloud-api-key)      OPT_GCLOUD_API_KEY="${2:?}"; shift 2 ;;
        --wan-iface)           OPT_WAN_IFACE="${2:?}"; shift 2 ;;
        --bundle-image)        BUNDLE_IMAGE="${2:?}"; shift 2 ;;
        --upgrade)             MODE="upgrade"; shift ;;
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

    setEnvFromFlag "$ENV_FILE" POP_ID                   "$OPT_POP_ID"
    setEnvFromFlag "$ENV_FILE" BAAS_HOST        "$OPT_DUS_UPSTREAM"
    setEnvFromFlag "$ENV_FILE" BAAS_TOKEN           "$OPT_DUS_TOKEN"
    setEnvFromFlag "$ENV_FILE" BAAS_HOST        "$OPT_KVS_API_BASE"
    setEnvFromFlag "$ENV_FILE" EDGE_PROJECT_ID      "$OPT_KVS_PROJECT_ID"
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
# swarm-init.sh hard-fails on EDGE_DUS_* anyway; asking here produces a far
# better error than a stack trace three phases later.
#
# The EDGE_KVS_* pair is a softer failure — the stack still serves traffic, it
# just stops reporting to the dashboard — so the warning is worded per key
# rather than claiming the stack will not start. These are absent (not empty)
# on an UPGRADE of a PoP installed before they existed, which is exactly when
# this rescue matters.
promptForRequired() {
    [ "$DRY_RUN" -eq 0 ] || return 0

    local key val consequence
    for key in BAAS_HOST BAAS_TOKEN POP_ID BAAS_HOST EDGE_PROJECT_ID; do
        val="$(envValue "$ENV_FILE" "$key")"
        [ -n "$val" ] && continue
        if val="$(promptValue "$key is required — enter value")"; then
            setEnvKv "$ENV_FILE" "$key" "$val"
            ok "$key set"
        else
            case "$key" in
                EDGE_KVS_*) consequence="this node will not report metrics or BGP prefixes" ;;
                *)          consequence="the stack will not start" ;;
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

    fetchBundle

    # The switch template ships in the bundle and may have changed between
    # versions; re-render so the persisted ruleset matches the new template.
    run "$INSTALL_DIR/scripts/l4-switch.sh" install
    run cp "$INSTALL_DIR/l4-switch/occ-switch.service" /etc/systemd/system/occ-switch.service
    run systemctl daemon-reload

    step "Rolling nginx-cache (gap-free)"
    run "$INSTALL_DIR/scripts/rollout.sh" --image-tag "$VERSION" --yes

    step "Updating shared services"
    local pair svc img
    for pair in $SHARED_SERVICES; do
        svc="${pair%%:*}"
        img="${pair##*:}"
        if docker service inspect "${STACK_NAME}_${svc}" > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
            run docker service update \
                --image "${REGISTRY}/${GHCR_REPO}/${img}:${VERSION}" \
                --with-registry-auth --force "${STACK_NAME}_${svc}" > /dev/null
            ok "$svc -> $img:$VERSION"
        else
            warn "service ${STACK_NAME}_${svc} not found — skipped"
        fi
    done

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
    configureFirewall
    deployStack
    verifyInstall
    summary
}

# Sourceable for testing: `OPENCACHE_INSTALL_LIB=1 . install.sh` loads the
# helpers without running an install.
[ "${OPENCACHE_INSTALL_LIB:-0}" = "1" ] || main
