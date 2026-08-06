#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# OpenCache PoP installer — FreeBSD NATIVE (no Docker).
#
#   fetch -qo - https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh \
#     | sh -s -- --pop-id PAR1 --baas-host <url> --baas-token <token>
#
# Turns a bare FreeBSD server into a serving OpenCache PoP with every
# component running NATIVELY under rc.d — there are no containers anywhere:
#
#   nginx            source-built (brotli, cache_purge, headers-more, geoip2,
#                    njs — scripts/build-nginx-freebsd.sh, the twin of
#                    nginx/Dockerfile), single instance on public 80/443
#   config-watcher   node app (bundle native payload) in --exec-mode local:
#                    validates staged configs with the HOST nginx and reloads
#                    it directly
#   prefix-monitor   node app, metrics on 127.0.0.1:9101
#   bird             pkg net/bird2 driven by rc.d/opencache_bird (renders
#                    bird.conf.template from env on every start)
#   birdwatcher      go build of alice-lg/birdwatcher (best-effort)
#   alloy            official FreeBSD release binary (pinned below)
#   nginx-exporter   official FreeBSD release binary (best-effort)
#   geoipupdate      pkg + cron
#
# DELIBERATE DIFFERENCES from the Linux/Swarm PoP:
#   * NO blue/green and NO L4 nftables switch — nginx binds 80/443 itself.
#     Upgrades that change the nginx binary restart it (a brief blip) instead
#     of flipping colors.
#   * log-cleaner does not exist — newsyslog rotates (punch-hole is Linux-only).
#   * QUIC/HTTP3 runs on the OpenSSL compat layer: no 0-RTT early data.
#
# SOURCE OF TRUTH is packaging/install-freebsd.sh in the private
# pfoundation/opencache repo; CI mirrors it to the public installer repo on
# each release tag — do not edit the public copy by hand.
#
# The runtime bundle is fetched from ghcr.io WITHOUT docker: the anonymous
# registry HTTP API serves the (public) bundle image's layers, which are plain
# tarballs. The same bundle serves Linux PoPs — it additionally carries
# native/ (compiled app payload) and freebsd/ (rc.d + launchers) for this
# installer.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   install-freebsd.sh [options]
#
#   --version <tag>        Bundle version (default: newest published vX.Y[.Z],
#                          across BOTH distribution channels — see below)
#   --dir <path>           Install directory (default: /opt/opencache)
#   --pop-id <id>          Node identity, e.g. PAR1
#   --baas-host <url>      BaaS origin serving BOTH /items/* and /dsb/v1/*
#   --baas-token <token>   Bearer token for both surfaces
#   --baas-version <ver>   DSB API version segment (default: v1)
#   --baas-project-id <id> Project UUID the PoP's KVS records live under
#                          (deprecated aliases: --dus-upstream / --kvs-api-base
#                           -> --baas-host, --dus-token -> --baas-token,
#                           --kvs-project-id -> --baas-project-id)
#   --geoip-account-id <id>
#   --geoip-license-key <key>
#   --gcloud-metrics-id <id>
#   --gcloud-logs-id <id>
#   --gcloud-api-key <key>
#   --bundle-tarball <p>   Install from a specific opencache-<ver>.tar.gz —
#                          local path or http(s) URL (air-gap / local build).
#                          Without it the bundle is resolved automatically:
#                          GHCR image layers first, then the PUBLIC installer
#                          repo's release asset (the CI-outage channel)
#   --upgrade              Upgrade an existing install
#   --skip-ssh             Do not install SSH keys or touch sshd_config
#   --skip-sysctl          Do not apply kernel tuning
#   --skip-nginx-build     Fail instead of building nginx when it is missing
#   --no-deploy            Lay everything down but do not start services
#   --force-env            Overwrite .env values that are already populated
#   --dry-run              Print what would happen, change nothing
#   --yes                  Never prompt; take the documented default
#   --help
#
# Re-running is safe. Node-local state (.env values, certs/, env/, cache
# dirs, nginx/generated/) is never overwritten.
# ─────────────────────────────────────────────────────────────────────────────
set -eu

REGISTRY="ghcr.io"
GHCR_REPO="${GHCR_REPO:-pfoundation/opencache}"
INSTALLER_URL="https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh"
# The PUBLIC repo whose GitHub releases double as a second, anonymously
# fetchable bundle channel (opencache-<ver>.tar.gz assets). The main repo is
# private, so its release assets are useless to a PoP — this one is not.
# Populated by CI's publish-installer job and, during CI outages, by hand;
# version resolution takes the newest tag across BOTH channels.
INSTALLER_RELEASES_REPO="pfoundation/opencacheInstaller"

# ── Pinned third-party binaries ──────────────────────────────────────────────
# Bumped deliberately, never floating. alloy ships an official FreeBSD build;
# nginx-prometheus-exporter does too (goreleaser naming).
ALLOY_VERSION="v1.18.1"
ALLOY_URL="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-freebsd-amd64.zip"
NGINX_EXPORTER_VERSION="1.4.2"
NGINX_EXPORTER_URL="https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_freebsd_amd64.tar.gz"

# ── SSH provisioning ─────────────────────────────────────────────────────────
# The ops key below plus everything currently published for the GitHub account
# are installed for root (and the invoking doas/sudo user, when any); password
# authentication is then disabled — but ONLY after at least one key verifiably
# landed in root's authorized_keys (lockout guard).
SSH_OPS_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINQFZdzxoig35GtInrJP91TSrDyPPMG/Hy5Izl8Hc3bW"
SSH_GITHUB_KEYS_URL="https://github.com/judsd.keys"

INSTALL_DIR="/opt/opencache"
VERSION=""
MODE="install"
SKIP_SSH=0
SKIP_SYSCTL=0
SKIP_NGINX_BUILD=0
NO_DEPLOY=0
FORCE_ENV=0
DRY_RUN=0
ASSUME_YES=0
BUNDLE_TARBALL=""

OPT_POP_ID=""
OPT_BAAS_HOST=""
OPT_BAAS_TOKEN=""
OPT_BAAS_VERSION=""
OPT_BAAS_PROJECT_ID=""
OPT_GEOIP_ACCOUNT_ID=""
OPT_GEOIP_LICENSE_KEY=""
OPT_GCLOUD_METRICS_ID=""
OPT_GCLOUD_LOGS_ID=""
OPT_GCLOUD_API_KEY=""

# Node-local state that must survive an upgrade. Mirrors packaging/install.sh's
# list (kept even where a path is Swarm-only — guarding a path that cannot
# exist is free; missing one is not).
PROTECTED_PATHS=".env .env.sites certs env cache cache-blue cache-green nginx/generated docker-stack.override.yml"

# Set while a bundle is being staged so an interrupted run leaves no debris.
STAGE_DIR=""
cleanup() { [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"; return 0; }
trap cleanup EXIT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET="$(printf '\033[0m')"; C_BOLD="$(printf '\033[1m')"
    C_RED="$(printf '\033[31m')"; C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"; C_BLUE="$(printf '\033[36m')"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step()  { echo; echo "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
info()  { echo "    $*"; }
ok()    { echo "    ${C_GREEN}ok${C_RESET}   $*"; }
warn()  { echo "    ${C_YELLOW}warn${C_RESET} $*" >&2; }
err()   { echo "${C_RED}ERROR${C_RESET}: $*" >&2; }
die()   { err "$*"; exit 1; }

usage() { sed -n '/^# ── Usage/,/^# ─\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//'; }

# Every mutating action funnels through run() so --dry-run stays honest.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} $*" >&2
        return 0
    fi
    "$@"
}

# curl|sh consumes stdin; prompt from the controlling terminal, and probe it
# by actually opening it (the node can exist while the open fails — see the
# Linux installer for the war story).
hasTty() {
    [ -e /dev/tty ] || return 1
    (exec < /dev/tty) > /dev/null 2>&1
}

promptYesNo() {
    question="$1"; default="${2:-n}"; reply=""
    if [ "$ASSUME_YES" -eq 1 ] || ! hasTty; then
        [ "$default" = "y" ]
        return
    fi
    hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
    printf '    %s %s ' "$question" "$hint" > /dev/tty
    read -r reply < /dev/tty || reply=""
    reply="${reply:-$default}"
    case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

promptValue() {
    question="$1"; reply=""
    if [ "$ASSUME_YES" -eq 1 ] || ! hasTty; then
        return 1
    fi
    printf '    %s: ' "$question" > /dev/tty
    read -r reply < /dev/tty || reply=""
    [ -n "$reply" ] || return 1
    printf '%s' "$reply"
}

# ── .env helpers ─────────────────────────────────────────────────────────────
# Rewrite-through-a-loop rather than sed -i: tokens routinely contain /, &, |
# — all special on a sed replacement side — and BSD sed -i needs a suffix arg
# anyway.
envValue() {
    file="$1"; key="$2"
    [ -f "$file" ] || return 0
    grep -E "^${key}=" "$file" 2> /dev/null | head -1 | cut -d'=' -f2- || true
}

setEnvKv() {
    file="$1"; key="$2"; val="$3"
    tmp="$(mktemp)"; found=0
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
    # cat-over rather than mv: preserves the original inode and 0600 mode.
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Applies a value from an explicit CLI flag ("" = flag absent = no-op). Same
# asymmetric conflict rule as the Linux installer: template defaults lose to
# flags, operator-set values win unless --force-env.
setEnvFromFlag() {
    file="$1"; key="$2"; val="$3"
    [ -n "$val" ] || return 0
    cur="$(envValue "$file" "$key")"
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

# Collect BAAS_HOST from whichever flag supplied it — two different values is
# a contradiction the operator must resolve (one origin serves both surfaces).
# Same rule (and same war story) as the Linux installer.
setBaasHost() {
    val="$1"; flag="$2"
    if [ -n "$OPT_BAAS_HOST" ] && [ "$OPT_BAAS_HOST" != "$val" ]; then
        die "conflicting values for the BaaS origin: '$OPT_BAAS_HOST' vs $flag '$val'. BAAS_HOST is ONE origin serving both /items/* and /dsb/v1/* — pass a single --baas-host."
    fi
    OPT_BAAS_HOST="$val"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version)           VERSION="${2:?--version needs a value}"; shift 2 ;;
        --dir)               INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --pop-id)            OPT_POP_ID="${2:?}"; shift 2 ;;
        --baas-host)         setBaasHost "${2:?}" --baas-host; shift 2 ;;
        --baas-token)        OPT_BAAS_TOKEN="${2:?}"; shift 2 ;;
        # Deprecated aliases, kept in lockstep with install.sh so one set of
        # provisioning docs works on both platforms.
        --dus-upstream)      setBaasHost "${2:?}" --dus-upstream; shift 2 ;;
        --kvs-api-base)      setBaasHost "${2:?}" --kvs-api-base; shift 2 ;;
        --dus-token)         OPT_BAAS_TOKEN="${2:?}"; shift 2 ;;
        --kvs-project-id)    OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        --baas-version)      OPT_BAAS_VERSION="${2:?}"; shift 2 ;;
        --baas-project-id)   OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        --geoip-account-id)  OPT_GEOIP_ACCOUNT_ID="${2:?}"; shift 2 ;;
        --geoip-license-key) OPT_GEOIP_LICENSE_KEY="${2:?}"; shift 2 ;;
        --gcloud-metrics-id) OPT_GCLOUD_METRICS_ID="${2:?}"; shift 2 ;;
        --gcloud-logs-id)    OPT_GCLOUD_LOGS_ID="${2:?}"; shift 2 ;;
        --gcloud-api-key)    OPT_GCLOUD_API_KEY="${2:?}"; shift 2 ;;
        --bundle-tarball)    BUNDLE_TARBALL="${2:?}"; shift 2 ;;
        --upgrade)           MODE="upgrade"; shift ;;
        --skip-ssh)          SKIP_SSH=1; shift ;;
        --skip-sysctl)       SKIP_SYSCTL=1; shift ;;
        --skip-nginx-build)  SKIP_NGINX_BUILD=1; shift ;;
        --no-deploy)         NO_DEPLOY=1; shift ;;
        --force-env)         FORCE_ENV=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --yes | -y)          ASSUME_YES=1; shift ;;
        --help | -h)         usage; exit 0 ;;
        *)                   err "unknown argument: $1"; usage; exit 1 ;;
    esac
done

ENV_FILE="$INSTALL_DIR/.env"
ENV_WAS_CREATED=0
NGINX_BIN="/usr/local/sbin/nginx"
# Set by installNginx when this run actually (re)built the binary — decides
# restart vs reload on upgrade.
NGINX_REBUILT=0
ALLOY_CFG_HASH_BEFORE=""

fileHash() {
    f="$1"
    [ -f "$f" ] || return 0
    sha256 -q "$f" 2> /dev/null || sha256sum "$f" | cut -d' ' -f1
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
    step "Preflight"

    [ "$(uname -s)" = "FreeBSD" ] || die "this installer is FreeBSD-only — use install.sh for Linux/Swarm PoPs"
    [ "$(id -u)" -eq 0 ] || die "must run as root (installs packages, rc.d services and builds nginx)"

    case "$(uname -m)" in
        amd64) ;;
        *) warn "pinned third-party binaries (alloy, nginx-exporter) are amd64 — $(uname -m) is untested" ;;
    esac

    osrel="$(freebsd-version -u 2> /dev/null || uname -r)"
    info "host   : FreeBSD $osrel $(uname -m)"
    info "target : $INSTALL_DIR"
    case "$osrel" in
        1[3-9].* | [2-9][0-9].*) ;;
        *) warn "FreeBSD 13+ expected — $osrel is untested" ;;
    esac

    # pkg may be unbootstrapped on a fresh host.
    if ! pkg -N > /dev/null 2>&1; then
        info "bootstrapping pkg"
        run env ASSUME_ALWAYS_YES=YES pkg bootstrap -f
    fi
    ok "preflight passed"
}

# One name from a preference list of candidate packages (node LTS naming moves
# over time). Prints the first that installs; fails if none do.
installFirstOf() {
    for p in "$@"; do
        if pkg info -e "$p" 2> /dev/null; then
            echo "$p"
            return 0
        fi
    done
    for p in "$@"; do
        if run pkg install -y "$p" > /dev/null 2>&1; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

installPackages() {
    step "Packages"

    # Base needs: curl (registry API with auth headers — fetch(1) cannot send
    # them), jq (manifest JSON), git/cmake/pcre2/libmaxminddb (nginx build),
    # gettext-runtime (envsubst for bird.conf), bird2, geoipupdate,
    # ca_root_nss (TLS trust for fetch/curl/node).
    run pkg install -y \
        curl jq git cmake pcre2 libmaxminddb gettext-runtime \
        bird2 geoipupdate ca_root_nss > /dev/null
    ok "core packages installed"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: skipping node runtime selection"
        return 0
    fi
    if command -v node > /dev/null 2>&1; then
        ok "node present: $(node --version)"
    else
        nodePkg="$(installFirstOf node22 node24 node20 node)" \
            || die "could not install a node runtime (tried node22/node24/node20/node)"
        ok "node installed ($nodePkg): $(node --version 2> /dev/null || echo '?')"
    fi
    case "$(node --version 2> /dev/null)" in
        v1[0-9].*) warn "node >= 20 required by the app payload — $(node --version) is too old" ;;
    esac
}

# ── Version resolution (anonymous GHCR API — no credentials) ─────────────────
ghcrToken() {
    curl -fsSL "https://${REGISTRY}/token?scope=repository:${GHCR_REPO}/bundle:pull&service=${REGISTRY}" 2> /dev/null \
        | jq -r '.token // empty'
}

ghcrBundleTags() {
    token="$(ghcrToken)" || return 1
    [ -n "$token" ] || return 1
    curl -fsSL -H "Authorization: Bearer $token" \
        "https://${REGISTRY}/v2/${GHCR_REPO}/bundle/tags/list" 2> /dev/null \
        | jq -r '.tags[]? // empty'
}

# Tags of public-repo releases that actually CARRY a bundle tarball. A release
# without the asset (e.g. an accidental tag) must not win version resolution —
# fetchBundle would then 404 on both channels.
releaseAssetTags() {
    curl -fsSL "https://api.github.com/repos/${INSTALLER_RELEASES_REPO}/releases?per_page=100" 2> /dev/null \
        | jq -r '.[] | select([.assets[]?.name] | any(test("^opencache-v[0-9].*\\.tar\\.gz$"))) | .tag_name'
}

# Newest release across BOTH channels. Normally they agree (CI publishes
# both); during an Actions outage the release-asset channel can be AHEAD of
# GHCR, which is precisely the situation this dual resolution exists for.
resolveLatestVersion() {
    {
        ghcrBundleTags || true
        releaseAssetTags || true
    } \
        | grep -E '^v[0-9]' \
        | sort -V \
        | tail -1
}

resolveVersion() {
    step "Version"
    if [ -n "$BUNDLE_TARBALL" ] && [ -z "$VERSION" ]; then
        VERSION="local"
        info "local tarball install — version read from the bundle itself"
        return 0
    fi
    if [ -n "$VERSION" ]; then
        info "pinned by --version"
    else
        info "resolving newest published release from ${REGISTRY}/${GHCR_REPO}/bundle"
        VERSION="$(resolveLatestVersion || true)"
        [ -n "$VERSION" ] || die "could not resolve a published vX.Y[.Z] bundle tag — pass --version explicitly"
    fi
    ok "version: ${C_BOLD}${VERSION}${C_RESET}"
}

# ── Bundle fetch (no docker: raw registry layers) ────────────────────────────
# The bundle image is busybox + ONE COPY layer holding /opt/opencache-bundle.
# Every layer blob is a plain (gzip) tarball, so extracting the
# opt/opencache-bundle/ subtree from each layer in order reproduces the tree
# `docker run … tar -c` would have produced — without a container runtime.
#
# Failures here are WARN + return 1, not fatal: the release-asset channel
# below is the fallback (a version can legitimately be absent from GHCR when
# CI never ran for it — the Actions-outage case).
fetchBundleFromRegistry() {
    token="$(ghcrToken)"
    if [ -z "$token" ]; then
        warn "could not obtain an anonymous pull token from $REGISTRY"
        return 1
    fi

    accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
    manifest="$(curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $accept" \
        "https://${REGISTRY}/v2/${GHCR_REPO}/bundle/manifests/${VERSION}")" || {
        warn "no bundle manifest for ${VERSION} on $REGISTRY"
        return 1
    }

    # buildx publishes an OCI index (platform manifest + provenance
    # attestation); select the real amd64/linux entry before reading layers.
    case "$(printf '%s' "$manifest" | jq -r '.mediaType // empty')" in
        *index* | *list*)
            digest="$(printf '%s' "$manifest" | jq -r \
                '[.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux")][0].digest // empty')"
            if [ -z "$digest" ]; then
                warn "no linux/amd64 manifest in the bundle index"
                return 1
            fi
            manifest="$(curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $accept" \
                "https://${REGISTRY}/v2/${GHCR_REPO}/bundle/manifests/${digest}")" || {
                warn "could not fetch the platform manifest"
                return 1
            }
            ;;
    esac

    layers="$(printf '%s' "$manifest" | jq -r '.layers[].digest')"
    if [ -z "$layers" ]; then
        warn "bundle manifest carries no layers"
        return 1
    fi

    for digest in $layers; do
        blob="$STAGE_DIR/blob"
        curl -fsSL -H "Authorization: Bearer $token" -o "$blob" \
            "https://${REGISTRY}/v2/${GHCR_REPO}/bundle/blobs/${digest}" || {
            warn "could not download layer ${digest}"
            return 1
        }
        # Only the subtree we ship; the busybox layer has no such path and
        # bsdtar then exits non-zero, which is expected.
        tar -xf "$blob" -C "$STAGE_DIR" opt/opencache-bundle 2> /dev/null || true
        rm -f "$blob"
    done

    if [ ! -f "$STAGE_DIR/opt/opencache-bundle/VERSION" ]; then
        warn "no opt/opencache-bundle/VERSION in any layer — registry format drift?"
        return 1
    fi
    BUNDLE_TREE="$STAGE_DIR/opt/opencache-bundle"
}

# Fallback channel: the tarball attached to the PUBLIC installer repo's
# release for this version — the same tree makeBundle.sh staged for the image,
# so the two channels can never disagree for a given tag.
fetchBundleFromRelease() {
    relUrl="https://github.com/${INSTALLER_RELEASES_REPO}/releases/download/${VERSION}/opencache-${VERSION}.tar.gz"
    info "trying release asset: $relUrl"
    if ! curl -fsSL -o "$STAGE_DIR/bundle.tar.gz" "$relUrl" 2> /dev/null \
        && ! fetch -qo "$STAGE_DIR/bundle.tar.gz" "$relUrl" 2> /dev/null; then
        warn "no release asset for ${VERSION} on ${INSTALLER_RELEASES_REPO}"
        return 1
    fi
    mkdir -p "$STAGE_DIR/tree"
    tar -xf "$STAGE_DIR/bundle.tar.gz" -C "$STAGE_DIR/tree" || {
        warn "could not extract the release asset"
        return 1
    }
    rm -f "$STAGE_DIR/bundle.tar.gz"
    BUNDLE_TREE="$STAGE_DIR/tree"
}

fetchBundle() {
    step "Runtime bundle"

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$BUNDLE_TARBALL" ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} extract $BUNDLE_TARBALL -> $INSTALL_DIR"
        else
            echo "    ${C_YELLOW}dry-run${C_RESET} fetch ${REGISTRY}/${GHCR_REPO}/bundle:${VERSION} via registry API -> $INSTALL_DIR"
        fi
        return 0
    fi

    STAGE_DIR="$(mktemp -d)"
    if [ -n "$BUNDLE_TARBALL" ]; then
        info "source: $BUNDLE_TARBALL"
        case "$BUNDLE_TARBALL" in
            http://* | https://*)
                if ! curl -fsSL -o "$STAGE_DIR/bundle.tar.gz" "$BUNDLE_TARBALL" 2> /dev/null \
                    && ! fetch -qo "$STAGE_DIR/bundle.tar.gz" "$BUNDLE_TARBALL" 2> /dev/null; then
                    die "could not download $BUNDLE_TARBALL"
                fi
                localTar="$STAGE_DIR/bundle.tar.gz"
                ;;
            *)
                [ -f "$BUNDLE_TARBALL" ] || die "tarball not found: $BUNDLE_TARBALL"
                localTar="$BUNDLE_TARBALL"
                ;;
        esac
        mkdir -p "$STAGE_DIR/tree"
        tar -xf "$localTar" -C "$STAGE_DIR/tree" || die "could not extract $BUNDLE_TARBALL"
        BUNDLE_TREE="$STAGE_DIR/tree"
    else
        # Channel order is deliberate: GHCR is the canonical CI-published
        # artifact; the release asset exists so a version published while
        # Actions is down still installs with the same one-liner.
        info "image: ${REGISTRY}/${GHCR_REPO}/bundle:${VERSION} (via anonymous registry API)"
        if ! fetchBundleFromRegistry; then
            fetchBundleFromRelease \
                || die "bundle ${VERSION} is on NEITHER channel (GHCR image, ${INSTALLER_RELEASES_REPO} release asset) — pass --version or --bundle-tarball"
        fi
    fi

    # The native payload is what this PoP RUNS — a bundle without it (built
    # before FreeBSD support, or a local makeBundle.sh run without --native)
    # cannot work here.
    if [ ! -d "$BUNDLE_TREE/native/config-generator/dist" ] \
        || [ ! -d "$BUNDLE_TREE/native/prefix-monitor/dist" ]; then
        die "bundle carries no native app payload (native/…) — it predates FreeBSD support; use a newer --version"
    fi
    [ -d "$BUNDLE_TREE/freebsd/rc.d" ] \
        || die "bundle carries no freebsd/ tree — it predates FreeBSD support; use a newer --version"

    # A bundle carrying node-local state would overwrite operator credentials
    # or cache on upgrade. Refuse rather than proceed.
    leaked=""
    for p in $PROTECTED_PATHS; do
        [ -e "$BUNDLE_TREE/$p" ] && leaked="$leaked $p"
    done
    [ -z "$leaked" ] || die "bundle contains protected node-local path(s):$leaked — refusing to extract"

    n="$(find "$BUNDLE_TREE" -type f | wc -l | tr -d ' ')"
    mkdir -p "$INSTALL_DIR"
    cp -Rp "$BUNDLE_TREE/." "$INSTALL_DIR/"
    rm -rf "$STAGE_DIR"; STAGE_DIR=""

    ok "extracted $n files to $INSTALL_DIR (version $(cat "$INSTALL_DIR/VERSION" 2> /dev/null || echo '?'))"
}

# ── nginx (source build + layout) ────────────────────────────────────────────
ensureNginxUser() {
    if ! pw groupshow nginx > /dev/null 2>&1; then
        run pw groupadd nginx
    fi
    if ! pw usershow nginx > /dev/null 2>&1; then
        run pw useradd nginx -g nginx -d /nonexistent -s /usr/sbin/nologin -c "OpenCache nginx worker"
    fi
}

# Replace <link> with a symlink to <target>, tolerating: already correct,
# missing, or an empty real directory. A NON-empty real directory is left
# alone with a warning — never silently discard operator data.
ensureSymlink() {
    link="$1"; target="$2"
    if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$target" ] && return 0
        run rm -f "$link"
    elif [ -d "$link" ]; then
        if rmdir "$link" 2> /dev/null; then
            :
        else
            warn "$link is a non-empty directory — expected a symlink to $target; leaving it (resolve manually)"
            return 0
        fi
    elif [ -e "$link" ]; then
        run rm -f "$link"
    fi
    run ln -s "$target" "$link"
    info "$link -> $target"
}

installNginx() {
    step "nginx (source build)"

    ensureNginxUser

    markerBefore="$(cat /var/db/opencache/nginx-build.info 2> /dev/null || true)"
    if [ "$SKIP_NGINX_BUILD" -eq 1 ] && [ ! -x "$NGINX_BIN" ]; then
        die "nginx not installed and --skip-nginx-build was given"
    fi
    run sh "$INSTALL_DIR/scripts/build-nginx-freebsd.sh"
    markerAfter="$(cat /var/db/opencache/nginx-build.info 2> /dev/null || true)"
    if [ "$DRY_RUN" -eq 0 ] && [ "$markerBefore" != "$markerAfter" ]; then
        NGINX_REBUILT=1
    fi

    # Fleet nginx.conf is bundle-owned: always current. (build-nginx leaves
    # the stock one only for bare-build testing.)
    run cp -p "$INSTALL_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf

    # The generated-config, certificate and GeoIP paths inside nginx.conf and
    # every generated file are the CONTAINER paths — symlinking them onto the
    # native locations is what lets both platforms share one generator with
    # zero divergence in emitted config.
    run mkdir -p "$INSTALL_DIR/nginx/generated" "$INSTALL_DIR/certs" "$INSTALL_DIR/env"
    ensureSymlink /etc/nginx/conf.d  "$INSTALL_DIR/nginx/generated"
    ensureSymlink /etc/nginx/certs   "$INSTALL_DIR/certs"
    run mkdir -p /usr/local/share/GeoIP
    ensureSymlink /usr/share/GeoIP   /usr/local/share/GeoIP

    # Same rationale, different mechanism: generated configs reference the
    # LINUX CA bundle path (ssl_trusted_certificate / proxy_ssl_trusted_
    # certificate → /etc/ssl/certs/ca-certificates.crt), which does not exist
    # on FreeBSD — without this, staged `nginx -t` fails on every cycle and NO
    # config ever goes live. A COPY rather than a symlink, deliberately:
    # certctl(8) rehash (triggered by ca_root_nss pkg upgrades) purges
    # symlinks in /etc/ssl/certs, and a purge would put the node right back
    # into the everything-fails state. Refreshed on every install/upgrade run.
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} install CA bundle at /etc/ssl/certs/ca-certificates.crt"
    elif [ -f /usr/local/share/certs/ca-root-nss.crt ]; then
        mkdir -p /etc/ssl/certs
        install -m 0644 /usr/local/share/certs/ca-root-nss.crt /etc/ssl/certs/ca-certificates.crt
        info "CA bundle installed at /etc/ssl/certs/ca-certificates.crt (from ca_root_nss)"
    elif [ -f /etc/ssl/cert.pem ]; then
        mkdir -p /etc/ssl/certs
        install -m 0644 /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt
        info "CA bundle installed at /etc/ssl/certs/ca-certificates.crt (from base cert.pem)"
    else
        warn "no CA bundle found (ca_root_nss missing?) — nginx -t will fail on ssl_trusted_certificate"
    fi

    run mkdir -p /var/log/nginx /var/run/nginx
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p /var/cache/nginx
        chown nginx:nginx /var/cache/nginx /var/log/nginx /var/run/nginx 2> /dev/null || true
    fi

    ok "nginx ready: $($NGINX_BIN -v 2>&1 || echo 'not built (dry-run)')"
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
    setEnvFromFlag "$ENV_FILE" BAAS_HOST                "$OPT_BAAS_HOST"
    setEnvFromFlag "$ENV_FILE" BAAS_TOKEN               "$OPT_BAAS_TOKEN"
    setEnvFromFlag "$ENV_FILE" BAAS_VERSION             "$OPT_BAAS_VERSION"
    setEnvFromFlag "$ENV_FILE" BAAS_PROJECT_ID          "$OPT_BAAS_PROJECT_ID"
    setEnvFromFlag "$ENV_FILE" GEOIP_ACCOUNT_ID         "$OPT_GEOIP_ACCOUNT_ID"
    setEnvFromFlag "$ENV_FILE" GEOIP_LICENSE_KEY        "$OPT_GEOIP_LICENSE_KEY"
    setEnvFromFlag "$ENV_FILE" GCLOUD_HOSTED_METRICS_ID "$OPT_GCLOUD_METRICS_ID"
    setEnvFromFlag "$ENV_FILE" GCLOUD_HOSTED_LOGS_ID    "$OPT_GCLOUD_LOGS_ID"
    setEnvFromFlag "$ENV_FILE" GCLOUD_RW_API_KEY        "$OPT_GCLOUD_API_KEY"

    promptForRequired
}

promptForRequired() {
    [ "$DRY_RUN" -eq 0 ] || return 0
    for key in BAAS_HOST BAAS_TOKEN POP_ID BAAS_PROJECT_ID; do
        val="$(envValue "$ENV_FILE" "$key")"
        [ -n "$val" ] && continue
        case "$key" in
            BAAS_HOST)       hint=" (origin serving BOTH /items/* and /dsb/v1/*, e.g. https://baas.example.com)" ;;
            BAAS_PROJECT_ID) hint=" (project UUID the PoP's KVS records live under)" ;;
            *)               hint="" ;;
        esac
        if val="$(promptValue "$key is required$hint — enter value")"; then
            setEnvKv "$ENV_FILE" "$key" "$val"
            ok "$key set"
        else
            case "$key" in
                BAAS_PROJECT_ID) consequence="this node will not report metrics or BGP prefixes" ;;
                *)               consequence="config generation will not work" ;;
            esac
            warn "$key is empty — $consequence until it is set in $ENV_FILE"
        fi
    done
}

# ── tmpfs mounts (RAM-backed certs + memory cache tier) ──────────────────────
ensureTmpfs() {
    mnt="$1"; opts="$2"; label="$3"

    run mkdir -p "$mnt"
    if mount -p 2> /dev/null | awk '{print $2}' | grep -qx "$mnt"; then
        ok "$label already mounted at $mnt"
    else
        run mount -t tmpfs -o "$opts" tmpfs "$mnt"
        ok "$label mounted at $mnt ($opts)"
    fi
    if ! grep -Eq "[[:space:]]${mnt}[[:space:]]" /etc/fstab 2> /dev/null; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} append $mnt tmpfs entry to /etc/fstab"
        else
            printf 'tmpfs\t%s\ttmpfs\trw,%s\t0\t0\n' "$mnt" "$opts" >> /etc/fstab
            ok "persisted to /etc/fstab"
        fi
    fi
}

configureTmpfs() {
    step "RAM-backed mounts"

    # Certificates: private keys must never reach the block device. If keys
    # already sat on disk (pre-tmpfs install), the migration order is
    # load-bearing:
    #
    #   1. stage into a THROWAWAY tmpfs — never /tmp, which on FreeBSD is
    #      commonly disk-backed, so a plain mktemp staging dir would copy the
    #      keys onto a second disk location
    #   2. scrub the on-disk originals BEFORE the permanent tmpfs mounts over
    #      the directory — mounting first merely HIDES them underneath the
    #      mount, permanently out of reach of any overwrite
    #   3. mount the permanent tmpfs and restore from the staging tmpfs
    #
    # rm -P overwrites before unlinking: real on UFS, advisory on ZFS (CoW
    # keeps old blocks in snapshots — rotate this node's certs in the KVS if
    # that matters).
    certsDir="$INSTALL_DIR/certs"
    mkdir -p "$certsDir"
    if mount -p 2> /dev/null | awk '{print $2}' | grep -qx "$certsDir"; then
        ensureTmpfs "$certsDir" "mode=0700,size=67108864" "certificate store"
    elif [ -n "$(find "$certsDir" -type f 2> /dev/null | head -1)" ] && [ "$DRY_RUN" -eq 0 ]; then
        info "migrating existing ON-DISK certs into RAM"
        migrate="$(mktemp -d)"
        mount -t tmpfs -o mode=0700,size=67108864 tmpfs "$migrate" \
            || die "could not mount a staging tmpfs for the cert migration"
        cp -Rp "$certsDir/." "$migrate/"
        find "$certsDir" -type f -exec rm -P -- {} + 2> /dev/null \
            || find "$certsDir" -type f -exec rm -- {} +
        ensureTmpfs "$certsDir" "mode=0700,size=67108864" "certificate store"
        cp -Rp "$migrate/." "$certsDir/"
        umount "$migrate" 2> /dev/null || true
        rmdir "$migrate" 2> /dev/null || true
        warn "certs were previously ON DISK — originals scrubbed with rm -P (thorough on UFS;"
        warn "ZFS snapshots can retain old blocks — consider rotating this node's certs in the KVS)"
    else
        ensureTmpfs "$certsDir" "mode=0700,size=67108864" "certificate store"
    fi

    # Memory cache tier (proxy_cache_path on tmpfs). Size follows the .env the
    # same way docker-stack.yml's tmpfs mount did.
    memBytes="$(envValue "$ENV_FILE" MEMORY_CACHE_SIZE_BYTES)"
    [ -n "$memBytes" ] || memBytes=8589934592
    ensureTmpfs /var/cache/nginx/memory "mode=0700,size=$memBytes" "memory cache tier"

    if [ "$(swapinfo 2> /dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
        warn "swap is ENABLED — tmpfs pages (incl. TLS keys) can reach the swap device."
        warn "Run 'swapoff -a' and remove swap from /etc/fstab, or use encrypted swap."
    fi
}

# ── Kernel tuning ────────────────────────────────────────────────────────────
# FreeBSD twin of scripts/sysctl-tuning.sh. Values are written to
# /etc/sysctl.conf.local inside a managed marker block (re-run = replace) and
# applied immediately. Everything below is runtime-settable — no reboot.
configureSysctl() {
    step "Kernel tuning"

    if [ "$SKIP_SYSCTL" -eq 1 ]; then
        info "skipped (--skip-sysctl)"
        return 0
    fi

    f=/etc/sysctl.conf.local
    tmp="$(mktemp)"
    cat > "$tmp" <<- 'EOF'
	# BEGIN opencache-managed — edits inside this block are overwritten by install-freebsd.sh
	# Fleet-wide edge tuning. Rationale mirrors scripts/sysctl-tuning.sh (Linux).
	# nginx worker_rlimit_nofile is 1048576 — the per-process ceiling must exceed it.
	kern.maxfiles=2097152
	kern.maxfilesperproc=1300000
	# Accept queue for 65536-connection workers (somaxconn is the legacy alias).
	kern.ipc.soacceptqueue=65535
	# Socket buffer ceilings: 16 MiB auto-tuned TCP buffers for long-fat client paths.
	kern.ipc.maxsockbuf=33554432
	net.inet.tcp.sendbuf_max=16777216
	net.inet.tcp.recvbuf_max=16777216
	net.inet.tcp.sendspace=131072
	net.inet.tcp.recvspace=131072
	# More outbound ports for origin fetches.
	net.inet.ip.portrange.first=1024
	# Recycle FIN_WAIT_2 sockets aggressively — cache traffic churns connections.
	net.inet.tcp.fast_finwait2_recycle=1
	# END opencache-managed
	EOF

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write managed block to $f and apply via sysctl"
        rm -f "$tmp"
        return 0
    fi

    if [ -f "$f" ]; then
        awk '/^# BEGIN opencache-managed/{skip=1} skip==0{print} /^# END opencache-managed/{skip=0}' "$f" > "$tmp.rest"
    else
        : > "$tmp.rest"
    fi
    cat "$tmp.rest" "$tmp" > "$f"
    rm -f "$tmp" "$tmp.rest"

    applied=0
    while IFS= read -r line; do
        case "$line" in
            \#* | "") continue ;;
            *=*)
                if sysctl "$line" > /dev/null 2>&1; then
                    applied=$((applied + 1))
                else
                    warn "could not apply: $line"
                fi
                ;;
        esac
    done <<- EOF
	$(sed -n '/^# BEGIN opencache-managed/,/^# END opencache-managed/p' "$f")
	EOF

    ok "$applied sysctl value(s) applied and persisted to $f"
}

# ── Cache disk scan ──────────────────────────────────────────────────────────
# Convention: dedicated cache disks are mounted at /mnt/nvme-<i> and
# /mnt/hdd-<i>. Natively there is no override file to generate (that is a
# Swarm bind-mount concern) — the disks are used at their real paths, so all
# this must do is find them, hand them to the nginx user, and tell the
# operator what the KVS nodeConfig should reference.
scanCacheDisks() {
    step "Cache disks"

    found=""
    for mp in $(mount -p 2> /dev/null | awk '{print $2}'); do
        case "$mp" in
            /mnt/nvme-* | /mnt/hdd-*)
                suffix="${mp##*-}"
                case "$suffix" in
                    '' | *[!0-9]*) continue ;;
                esac
                found="$found $mp"
                ;;
        esac
    done

    if [ -z "$found" ]; then
        info "no /mnt/nvme-<i> or /mnt/hdd-<i> mounts found — caching under $INSTALL_DIR and /var/cache/nginx only"
        return 0
    fi

    for mp in $found; do
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} chown nginx:nginx $mp (mode 750)"
        else
            chown nginx:nginx "$mp"
            chmod 750 "$mp"
        fi
        info "cache disk: $mp ($(df -h "$mp" 2> /dev/null | awk 'NR==2{print $2}' || echo '?'))"
    done
    ok "$(echo "$found" | wc -w | tr -d ' ') cache disk(s) prepared"
    info "reference these paths from the KVS nodeConfig (cache.zoneOverrides /"
    info "multi-volume zone volumes) — config-watcher picks changes up live"
}

# ── SSH hardening ────────────────────────────────────────────────────────────
# Keys first, hardening second, and hardening ONLY if a key verifiably landed
# for root — an installer must never be able to lock every operator out.
appendKeysToUser() {
    # $1 = username, $2 = home dir, $3 = file holding candidate keys
    user="$1"; home="$2"; keysFile="$3"
    added=0; present=0
    sshDir="$home/.ssh"; auth="$sshDir/authorized_keys"
    mkdir -p "$sshDir"; chmod 700 "$sshDir"
    [ -f "$auth" ] || touch "$auth"
    chmod 600 "$auth"
    while IFS= read -r key; do
        case "$key" in ssh-* | ecdsa-* | sk-*) ;; *) continue ;; esac
        blob="$(printf '%s' "$key" | awk '{print $2}')"
        [ -n "$blob" ] || continue
        if grep -qF "$blob" "$auth" 2> /dev/null; then
            present=$((present + 1))
        else
            printf '%s\n' "$key" >> "$auth"
            added=$((added + 1))
        fi
    done < "$keysFile"
    chown -R "$user" "$sshDir" 2> /dev/null || true
    info "$user: $added key(s) added, $present already present"
    echo $((added + present)) > "$keysFile.count"
}

configureSsh() {
    step "SSH access"

    if [ "$SKIP_SSH" -eq 1 ]; then
        info "skipped (--skip-ssh)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} install ops keys (+ $SSH_GITHUB_KEYS_URL) for root${SUDO_USER:+ and $SUDO_USER}"
        echo "    ${C_YELLOW}dry-run${C_RESET} disable sshd password authentication (lockout-guarded)"
        return 0
    fi

    keysFile="$(mktemp)"
    printf '%s\n' "$SSH_OPS_KEY" > "$keysFile"
    if ghKeys="$(fetch -qo - -T 15 "$SSH_GITHUB_KEYS_URL" 2> /dev/null || curl -fsSL -m 15 "$SSH_GITHUB_KEYS_URL" 2> /dev/null)"; then
        printf '%s\n' "$ghKeys" >> "$keysFile"
        ok "fetched $(printf '%s\n' "$ghKeys" | grep -Ec '^(ssh|ecdsa|sk)-' || true) key(s) from $SSH_GITHUB_KEYS_URL"
    else
        warn "could not fetch $SSH_GITHUB_KEYS_URL — continuing with the built-in ops key only"
    fi

    appendKeysToUser root /root "$keysFile"
    rootKeys="$(cat "$keysFile.count" 2> /dev/null || echo 0)"

    # The user who invoked the installer via sudo/doas, when resolvable.
    invoker="${SUDO_USER:-${DOAS_USER:-}}"
    if [ -n "$invoker" ] && [ "$invoker" != "root" ]; then
        invokerHome="$(getent passwd "$invoker" | cut -d: -f6)"
        if [ -n "$invokerHome" ] && [ -d "$invokerHome" ]; then
            appendKeysToUser "$invoker" "$invokerHome" "$keysFile"
        fi
    fi
    rm -f "$keysFile" "$keysFile.count"

    if [ "$rootKeys" -lt 1 ]; then
        warn "no SSH key made it into root's authorized_keys — NOT disabling password authentication"
        return 0
    fi

    # sshd applies the FIRST occurrence of a keyword, so the managed block is
    # PREPENDED — appending would silently lose to any earlier explicit
    # `PasswordAuthentication yes`.
    cfg=/etc/ssh/sshd_config
    tmp="$(mktemp)"
    {
        echo "# BEGIN opencache-managed — prepended (first match wins in sshd_config); maintained by install-freebsd.sh"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "# END opencache-managed"
    } > "$tmp"
    if [ -f "$cfg" ]; then
        awk '/^# BEGIN opencache-managed/{skip=1} skip==0{print} /^# END opencache-managed/{skip=0}' "$cfg" >> "$tmp"
    fi

    if cmp -s "$tmp" "$cfg" 2> /dev/null; then
        rm -f "$tmp"
        ok "sshd already hardened (password authentication disabled)"
        return 0
    fi

    if ! sshd -t -f "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        warn "hardened sshd_config failed validation — leaving sshd untouched"
        return 0
    fi
    cat "$tmp" > "$cfg"
    rm -f "$tmp"

    if service sshd status > /dev/null 2>&1; then
        service sshd reload > /dev/null 2>&1 || service sshd restart > /dev/null 2>&1 || true
        ok "password authentication disabled; sshd reloaded (existing sessions unaffected)"
    else
        ok "password authentication disabled (sshd not currently running)"
    fi
}

# ── GeoIP ────────────────────────────────────────────────────────────────────
configureGeoip() {
    step "GeoIP"

    acct="$(envValue "$ENV_FILE" GEOIP_ACCOUNT_ID)"
    lic="$(envValue "$ENV_FILE" GEOIP_LICENSE_KEY)"
    if [ -z "$acct" ] || [ -z "$lic" ]; then
        info "GEOIP_ACCOUNT_ID / GEOIP_LICENSE_KEY not set — nginx will use the GeoIP fallback config"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write /usr/local/etc/GeoIP.conf + weekly cron + initial geoipupdate"
        return 0
    fi

    cat > /usr/local/etc/GeoIP.conf <<- EOF
	# Managed by install-freebsd.sh (credentials from $ENV_FILE)
	AccountID $acct
	LicenseKey $lic
	EditionIDs GeoLite2-Country GeoLite2-City GeoLite2-ASN
	DatabaseDirectory /usr/local/share/GeoIP
	EOF
    chmod 600 /usr/local/etc/GeoIP.conf

    mkdir -p /usr/local/etc/cron.d
    cat > /usr/local/etc/cron.d/opencache-geoipupdate <<- 'EOF'
	# OpenCache — refresh MaxMind GeoLite2 databases weekly (Sunday 03:17).
	# The container stack ran the geoipupdate sidecar every 168h; same cadence.
	17 3 * * 0 root /usr/local/bin/geoipupdate > /dev/null 2>&1
	EOF

    info "fetching GeoLite2 databases (initial run)"
    if geoipupdate > /dev/null 2>&1; then
        ok "GeoIP databases at /usr/local/share/GeoIP (weekly cron installed)"
    else
        warn "initial geoipupdate failed — nginx uses the fallback config until the cron succeeds"
    fi
}

# ── Third-party binaries (alloy, nginx-exporter, birdwatcher) ────────────────
installAlloy() {
    step "Grafana Alloy"

    if command -v alloy > /dev/null 2>&1 \
        && alloy --version 2> /dev/null | grep -q "${ALLOY_VERSION#v}"; then
        ok "alloy ${ALLOY_VERSION} already installed"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} fetch $ALLOY_URL -> /usr/local/bin/alloy"
        return 0
    fi

    tmpd="$(mktemp -d)"
    if ! fetch -qo "$tmpd/alloy.zip" "$ALLOY_URL" 2> /dev/null \
        && ! curl -fsSL -o "$tmpd/alloy.zip" "$ALLOY_URL"; then
        rm -rf "$tmpd"
        warn "could not download alloy ${ALLOY_VERSION} — log/metric shipping unavailable until installed manually"
        return 0
    fi
    # bsdtar reads zip archives natively.
    tar -xf "$tmpd/alloy.zip" -C "$tmpd"
    bin="$(find "$tmpd" -type f -name 'alloy-freebsd-amd64' | head -1)"
    if [ -z "$bin" ]; then
        bin="$(find "$tmpd" -type f -name 'alloy*' ! -name '*.zip' | head -1)"
    fi
    if [ -z "$bin" ]; then
        rm -rf "$tmpd"
        warn "alloy archive layout unexpected — skipping"
        return 0
    fi
    install -m 0755 "$bin" /usr/local/bin/alloy
    rm -rf "$tmpd"
    ok "alloy installed: $(alloy --version 2> /dev/null | head -1 || echo '?')"
}

installNginxExporter() {
    step "nginx-prometheus-exporter"

    if command -v nginx-prometheus-exporter > /dev/null 2>&1; then
        ok "already installed"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} fetch $NGINX_EXPORTER_URL -> /usr/local/bin/nginx-prometheus-exporter"
        return 0
    fi

    tmpd="$(mktemp -d)"
    if ! fetch -qo "$tmpd/exp.tar.gz" "$NGINX_EXPORTER_URL" 2> /dev/null \
        && ! curl -fsSL -o "$tmpd/exp.tar.gz" "$NGINX_EXPORTER_URL"; then
        rm -rf "$tmpd"
        warn "could not download nginx-prometheus-exporter ${NGINX_EXPORTER_VERSION} — nginx metrics pipeline disabled"
        return 0
    fi
    tar -xf "$tmpd/exp.tar.gz" -C "$tmpd"
    bin="$(find "$tmpd" -type f -name 'nginx-prometheus-exporter' | head -1)"
    if [ -z "$bin" ]; then
        rm -rf "$tmpd"
        warn "exporter archive layout unexpected — skipping"
        return 0
    fi
    install -m 0755 "$bin" /usr/local/bin/nginx-prometheus-exporter
    rm -rf "$tmpd"
    ok "nginx-prometheus-exporter installed"
}

installBirdwatcher() {
    step "Birdwatcher (best-effort)"

    if command -v birdwatcher > /dev/null 2>&1; then
        ok "already installed"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} go build alice-lg/birdwatcher -> /usr/local/bin/birdwatcher"
        return 0
    fi

    if ! command -v go > /dev/null 2>&1; then
        info "installing go toolchain (birdwatcher has no FreeBSD release binary)"
        pkg install -y go > /dev/null 2>&1 || {
            warn "go unavailable — birdwatcher skipped (prefix-monitor uses birdc directly; only the HTTP fallback is lost)"
            return 0
        }
    fi
    tmpd="$(mktemp -d)"
    if git clone -q --depth 1 https://github.com/alice-lg/birdwatcher.git "$tmpd/birdwatcher" \
        && (cd "$tmpd/birdwatcher" && env GOFLAGS=-buildvcs=false go build -o /usr/local/bin/birdwatcher .) > /dev/null 2>&1; then
        ok "birdwatcher built and installed"
    else
        warn "birdwatcher build failed — skipped (prefix-monitor uses birdc directly)"
    fi
    rm -rf "$tmpd"
}

# ── Services (rc.d + newsyslog + enables) ────────────────────────────────────
installServices() {
    step "Services (rc.d)"

    for f in "$INSTALL_DIR"/freebsd/rc.d/*; do
        run install -m 0755 "$f" "/usr/local/etc/rc.d/$(basename "$f")"
    done
    ok "rc.d scripts installed"

    run mkdir -p /usr/local/etc/newsyslog.conf.d /var/log/opencache
    run install -m 0644 "$INSTALL_DIR/freebsd/newsyslog-opencache.conf" /usr/local/etc/newsyslog.conf.d/opencache.conf
    ok "newsyslog rotation installed (replaces the Linux log-cleaner sidecar)"

    run sysrc -q opencache_root="$INSTALL_DIR" > /dev/null
    run sysrc -q opencache_nginx_enable=YES > /dev/null
    run sysrc -q opencache_watcher_enable=YES > /dev/null
    run sysrc -q opencache_prefix_monitor_enable=YES > /dev/null
    run sysrc -q opencache_bird_enable=YES > /dev/null
    # The pkg's own bird rc script must stay OFF — opencache_bird replaces it
    # (it renders bird.conf from the KVS-driven env on every start).
    run sysrc -q bird_enable=NO > /dev/null

    if command -v birdwatcher > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
        run sysrc -q opencache_birdwatcher_enable=YES > /dev/null
    else
        run sysrc -q opencache_birdwatcher_enable=NO > /dev/null
    fi
    if command -v nginx-prometheus-exporter > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
        run sysrc -q opencache_nginx_exporter_enable=YES > /dev/null
    else
        run sysrc -q opencache_nginx_exporter_enable=NO > /dev/null
    fi
    if command -v alloy > /dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
        run sysrc -q opencache_alloy_enable=YES > /dev/null
    else
        run sysrc -q opencache_alloy_enable=NO > /dev/null
    fi
    ok "services enabled in rc.conf"
}

svc() {
    # service(8) wrapper that tolerates a disabled/absent service.
    action="$1"; name="$2"
    run service "$name" "$action" > /dev/null 2>&1 || true
}

deployServices() {
    step "Start"

    if [ "$NO_DEPLOY" -eq 1 ]; then
        info "skipped (--no-deploy)"
        info "start later with: service opencache_bird start; service opencache_watcher start; …"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} start bird, watcher (initial config generation), nginx, monitor, exporter, alloy"
        return 0
    fi

    # ORDER IS LOAD-BEARING. The watcher's first cycle produces BOTH the
    # initial config set (nginx wants it before first start) AND the
    # nodeConfig-derived env files — env/.env.bird in particular, without
    # which opencache_bird renders an EMPTY bird.conf (envsubst substitutes
    # blanks) and BIRD exits on a parse error. Starting bird before the
    # watcher is exactly the first-deploy bug this ordering fixes.
    svc start opencache_watcher
    info "waiting for the first generated config set (up to 180s)…"
    i=0
    while [ "$i" -lt 180 ]; do
        [ -n "$(find "$INSTALL_DIR/nginx/generated" -maxdepth 1 -name '*.conf' 2> /dev/null | head -1)" ] && break
        i=$((i + 5)); sleep 5
    done
    if [ "$i" -ge 180 ]; then
        warn "no generated configs after 180s — check: tail -50 /var/log/opencache/watcher.log"
        warn "(BAAS_HOST/BAAS_TOKEN/POP_ID wrong or unreachable is the usual cause)"
    else
        ok "config set generated after ${i}s"
    fi

    if [ -f "$INSTALL_DIR/env/.env.bird" ]; then
        svc start opencache_bird
        svc start opencache_birdwatcher
    else
        warn "env/.env.bird not written yet (no nodeConfig for this POP_ID?) — NOT starting bird"
        warn "once the watcher writes it: service opencache_bird start && service opencache_birdwatcher start"
    fi

    svc start opencache_nginx
    svc start opencache_prefix_monitor
    svc start opencache_nginx_exporter
    svc start opencache_alloy
    ok "services started"
}

verifyInstall() {
    step "Verify"

    if [ "$NO_DEPLOY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
        info "skipped"
        return 0
    fi

    if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        ok "CA bundle present (generated configs reference it for TLS trust)"
    else
        warn "/etc/ssl/certs/ca-certificates.crt MISSING — staged nginx -t will fail every cycle"
    fi

    sleep 2
    if fetch -qo /dev/null -T 10 "http://127.0.0.1/oc-cgi/health" 2> /dev/null; then
        ok "nginx answers /oc-cgi/health on :80"
    else
        warn "http://127.0.0.1/oc-cgi/health not answering (yet) — check 'service opencache_nginx status' and /var/log/nginx/error.log"
    fi
    if birdc show status > /dev/null 2>&1; then
        ok "BIRD is up ($(birdc show status 2> /dev/null | sed -n '$p' | tr -d '\r'))"
    else
        warn "birdc cannot reach BIRD — check 'service opencache_bird status'"
    fi
    for s in opencache_nginx opencache_watcher opencache_prefix_monitor opencache_bird; do
        if service "$s" status > /dev/null 2>&1; then
            ok "$s running"
        else
            warn "$s NOT running"
        fi
    done
}

# ── Upgrade ──────────────────────────────────────────────────────────────────
doUpgrade() {
    previous="unknown"
    [ -f "$INSTALL_DIR/VERSION" ] && previous="$(cat "$INSTALL_DIR/VERSION")"

    step "Upgrade"
    info "from : $previous"
    info "to   : $VERSION"

    [ -d "$INSTALL_DIR" ] || die "$INSTALL_DIR does not exist — run without --upgrade for a fresh install"
    [ -f "$ENV_FILE" ] || die "$ENV_FILE not found — this does not look like an OpenCache install"

    ALLOY_CFG_HASH_BEFORE="$(fileHash "$INSTALL_DIR/alloy/config.alloy")"

    fetchBundle
    installNginx
    installAlloy
    installNginxExporter
    installBirdwatcher
    installServices
    configureTmpfs
    configureSysctl
    scanCacheDisks
    configureSsh
    configureGeoip

    step "Restarting services"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} restart watcher/monitor/exporter/birdwatcher; nginx restart-or-reload; alloy if config changed"
    else
        svc restart opencache_watcher
        svc restart opencache_prefix_monitor
        svc restart opencache_nginx_exporter
        svc restart opencache_birdwatcher

        # BIRD is deliberately NOT restarted when it is healthy: that would
        # drop the BGP session and withdraw this PoP's routes for nothing (the
        # watcher restarts it when its env actually changes). A bird that is
        # DOWN is a different story — start it, its env files exist by now.
        if service opencache_bird status > /dev/null 2>&1; then
            info "bird left running (watcher restarts it on env drift)"
        elif [ -f "$INSTALL_DIR/env/.env.bird" ]; then
            info "bird was down — starting it"
            svc start opencache_bird
        else
            warn "bird is down and env/.env.bird does not exist — check the watcher log"
        fi

        if [ "$NGINX_REBUILT" -eq 1 ]; then
            info "nginx binary changed — full restart (brief blip; no blue/green on FreeBSD)"
            svc restart opencache_nginx
        elif service opencache_nginx status > /dev/null 2>&1; then
            svc reload opencache_nginx
            info "nginx reloaded (binary unchanged)"
        else
            info "nginx was down — starting it"
            svc start opencache_nginx
        fi

        if [ "$ALLOY_CFG_HASH_BEFORE" != "$(fileHash "$INSTALL_DIR/alloy/config.alloy")" ]; then
            info "config.alloy changed — restarting alloy"
            svc restart opencache_alloy
        else
            info "alloy unchanged — not restarted (a restart costs a Loki catch-up window)"
        fi
    fi

    verifyInstall
    summary
}

summary() {
    echo
    echo "${C_BOLD}${C_GREEN}OpenCache ${VERSION} (FreeBSD native) — ${MODE} complete${C_RESET}"
    echo
    echo "  install dir : $INSTALL_DIR"
    echo "  config      : $ENV_FILE"
    echo
    echo "  Services    : for s in opencache_nginx opencache_watcher opencache_prefix_monitor opencache_bird; do service \$s status; done"
    echo "  Logs        : /var/log/opencache/*.log  /var/log/nginx/error.log"
    echo "  Trace       : fetch -qo - http://127.0.0.1/oc-cgi/trace"
    echo "  BGP         : birdc show protocols"
    echo
    echo "  Upgrade to the newest release:"
    echo "    fetch -qo - $INSTALLER_URL | sh -s -- --upgrade"
    echo
}

main() {
    echo "${C_BOLD}OpenCache installer (FreeBSD native)${C_RESET}"
    [ "$DRY_RUN" -eq 0 ] || warn "DRY RUN — no changes will be made"

    preflight
    installPackages
    resolveVersion

    if [ "$MODE" = "upgrade" ]; then
        doUpgrade
        return
    fi

    fetchBundle
    installNginx
    seedEnv
    configureTmpfs
    configureSysctl
    scanCacheDisks
    configureSsh
    configureGeoip
    installAlloy
    installNginxExporter
    installBirdwatcher
    installServices
    deployServices
    verifyInstall
    summary
}

# Sourceable for testing: `OPENCACHE_INSTALL_LIB=1 . install-freebsd.sh` loads
# the helpers without running an install.
[ "${OPENCACHE_INSTALL_LIB:-0}" = "1" ] || main
