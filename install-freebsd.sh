#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# OpenCache PoP installer — FreeBSD.
#
#   fetch -qo - https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh \
#     | sh -s -- --pop-id PAR1 --baas-host <url> --baas-token <token>
#
# Turns a bare FreeBSD server into a serving OpenCache PoP, every component
# running under rc.d:
#
#   nginx            source-built (brotli, cache_purge, headers-more, geoip2,
#                    njs — scripts/build-nginx-freebsd.sh), single instance on
#                    public 80/443
#   config-watcher   node app (bundle native payload): validates staged configs
#                    with the host nginx and reloads it directly
#   prefix-monitor   node app, metrics on 127.0.0.1:9101
#   bird             pkg net/bird2 driven by rc.d/opencache_bird (renders
#                    bird.conf.template from env on every start)
#   birdwatcher      go build of alice-lg/birdwatcher (best-effort)
#   alloy            official FreeBSD release binary (pinned below)
#   nginx-exporter   official FreeBSD release binary (best-effort)
#   geoipupdate      pkg + cron
#
# KNOWN LIMITS:
#   * A single nginx binds 80/443, so an upgrade that changes the nginx binary
#     restarts it — a brief blip. Config changes are reloads and are seamless.
#   * QUIC/HTTP3 runs on the OpenSSL compat layer: no 0-RTT early data.
#
# SOURCE OF TRUTH is packaging/install-freebsd.sh in the private
# pfoundation/opencache repo; CI mirrors it to the public installer repo on
# each release tag — do not edit the public copy by hand.
#
# The runtime bundle is a tarball attached to a release on the PUBLIC installer
# repo, fetched anonymously — this repo is private, so its own release assets
# would be unreachable from a PoP. The bundle carries the host files, the
# compiled app payload (native/) and the rc.d services (freebsd/).
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   install-freebsd.sh [options]
#
#   --version <tag>        Bundle version (default: newest published vX.Y[.Z])
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
#   --logs-push-url <url>  ClickHouse warehouse ingest endpoint (full
#                          Loki-push URL incl. /loki/api/v1/push; metrics
#                          derive their /v1/metrics endpoint from it)
#   --logs-push-user <u>   Basic-auth user for it (default: opencache)
#   --logs-push-password <pw>
#   --bundle-tarball <p>   Install from a specific opencache-<ver>.tar.gz —
#                          local path or http(s) URL (air-gap / local build /
#                          mirror). Without it the newest published release
#                          asset is used.
#   --upgrade              Upgrade an existing install
#   --skip-ssh             Do not install SSH keys or touch sshd_config
#   --skip-sysctl          Do not apply kernel tuning
#   --skip-loader-conf     Do not write boot-time tunables to
#                          /boot/loader.conf.local (pf state hash sizing)
#   --skip-firewall        Do not enable pf or install the default ruleset
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

INSTALLER_URL="https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh"
# The PUBLIC repo whose GitHub releases carry the bundle (opencache-<ver>.tar.gz
# assets). The main repo is private, so its own release assets are useless to a
# PoP — this one is not. Populated by CI's publish-installer job.
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
SKIP_LOADER_CONF=0
SKIP_FIREWALL=0
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
OPT_LOGS_PUSH_URL=""
OPT_LOGS_PUSH_USER=""
OPT_LOGS_PUSH_PASSWORD=""

# Node-local state that must survive an upgrade. Deliberately maintained
# SEPARATELY from packaging/bundleManifest.txt: two independent lists means a
# mis-edit of one cannot silently clobber node state.
PROTECTED_PATHS=".env .env.sites certs env cache nginx/generated"

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
        # Deprecated aliases, kept so one set of
        # provisioning docs works on both platforms.
        --dus-upstream)      setBaasHost "${2:?}" --dus-upstream; shift 2 ;;
        --kvs-api-base)      setBaasHost "${2:?}" --kvs-api-base; shift 2 ;;
        --dus-token)         OPT_BAAS_TOKEN="${2:?}"; shift 2 ;;
        --kvs-project-id)    OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        --baas-version)      OPT_BAAS_VERSION="${2:?}"; shift 2 ;;
        --baas-project-id)   OPT_BAAS_PROJECT_ID="${2:?}"; shift 2 ;;
        --geoip-account-id)  OPT_GEOIP_ACCOUNT_ID="${2:?}"; shift 2 ;;
        --geoip-license-key) OPT_GEOIP_LICENSE_KEY="${2:?}"; shift 2 ;;
        # Retired: nothing ships to Grafana Cloud anymore (logs AND metrics go
        # to the ClickHouse warehouse). Accepted (and ignored with a warning)
        # so existing provisioning scripts don't break.
        --gcloud-metrics-id|--gcloud-logs-id|--gcloud-api-key)
            warn "$1 is retired (observability ships to the ClickHouse warehouse — use --logs-push-*)"; shift 2 ;;
        --logs-push-url)      OPT_LOGS_PUSH_URL="${2:?}"; shift 2 ;;
        --logs-push-user)     OPT_LOGS_PUSH_USER="${2:?}"; shift 2 ;;
        --logs-push-password) OPT_LOGS_PUSH_PASSWORD="${2:?}"; shift 2 ;;
        --bundle-tarball)    BUNDLE_TARBALL="${2:?}"; shift 2 ;;
        --upgrade)           MODE="upgrade"; shift ;;
        --skip-ssh)          SKIP_SSH=1; shift ;;
        --skip-sysctl)       SKIP_SYSCTL=1; shift ;;
        --skip-loader-conf)  SKIP_LOADER_CONF=1; shift ;;
        --skip-firewall)     SKIP_FIREWALL=1; shift ;;
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

    [ "$(uname -s)" = "FreeBSD" ] || die "OpenCache runs on FreeBSD — this host reports $(uname -s)"
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

    # Base needs: curl (releases API with headers — fetch(1) cannot send
    # them), jq (manifest JSON), git/cmake/pcre2/libmaxminddb (nginx build),
    # gettext-runtime (envsubst for bird.conf), bird2, geoipupdate,
    # ca_root_nss (TLS trust for fetch/curl/node).
    run pkg install -y \
        curl jq git cmake pcre2 libmaxminddb gettext-runtime \
        bird2 geoipupdate ca_root_nss > /dev/null
    ok "core packages installed"
}

# ── Node runtime ─────────────────────────────────────────────────────────────
# Called from BOTH main() and doUpgrade(). installPackages() is not run on an
# upgrade, so before this existed an established PoP kept whatever node major
# it was first installed with, forever — the fleet drifted away from CI with
# nothing to correct it.
#
# NODE_TARGET_MAJOR is what CI builds and tests against. NODE_MIN_MAJOR is the
# floor the compiled payload actually needs; between the two we warn but keep
# running, so a fleet mid-rollout is not half-broken.
NODE_TARGET_MAJOR=24
NODE_MIN_MAJOR=20

nodeMajor() {
    node --version 2> /dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*$/\1/p'
}

ensureNodeRuntime() {
    step "Node runtime"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: would ensure node >= $NODE_TARGET_MAJOR"
        return 0
    fi

    major="$(nodeMajor)"

    # No runtime at all — plain install, newest first.
    if [ -z "$major" ]; then
        nodePkg="$(installFirstOf node24 node22 node20 node)" \
            || die "could not install a node runtime (tried node24/node22/node20/node)"
        ok "node installed ($nodePkg): $(node --version 2> /dev/null || echo '?')"
        return 0
    fi

    if [ "$major" -ge "$NODE_TARGET_MAJOR" ]; then
        ok "node v$major (target: v$NODE_TARGET_MAJOR)"
        return 0
    fi

    if [ "$major" -lt "$NODE_MIN_MAJOR" ]; then
        die "node v$major is below the v$NODE_MIN_MAJOR floor the app payload needs. Install node$NODE_TARGET_MAJOR and re-run."
    fi

    info "node v$major is below the v$NODE_TARGET_MAJOR target — upgrading"

    # FreeBSD's node majors CONFLICT over /usr/local/bin/node, so this is a
    # delete-then-install, not an in-place upgrade. Fetch FIRST: that is the
    # difference between a clean swap and a host left with no runtime at all
    # if the repo is unreachable or node24 is absent for this FreeBSD major.
    if ! pkg fetch -y "node${NODE_TARGET_MAJOR}" > /dev/null 2>&1; then
        warn "node${NODE_TARGET_MAJOR} is not available from pkg — staying on v$major"
        warn "  (v$major still runs the payload; CI targets v$NODE_TARGET_MAJOR, so this host is drifted)"
        return 0
    fi

    # Ask pkg which package owns the current binary rather than guessing the
    # name — it may be node22, node20, or plain `node`.
    nodeOwner="$(pkg which -q "$(command -v node)" 2> /dev/null || true)"

    if [ -n "$nodeOwner" ]; then
        info "removing $nodeOwner"
        # Running processes keep executing from the unlinked inode, so the
        # watcher and prefix-monitor survive this window; doUpgrade's existing
        # restarts are what actually move them onto the new runtime.
        run pkg delete -y "$nodeOwner" > /dev/null 2>&1 \
            || warn "could not cleanly remove $nodeOwner — continuing"
    fi

    if ! run pkg install -y "node${NODE_TARGET_MAJOR}" > /dev/null 2>&1; then
        die "node${NODE_TARGET_MAJOR} install FAILED after removing ${nodeOwner:-the previous runtime}.
    This host currently has NO node runtime. Services already running survive on
    the unlinked binary — do NOT restart opencache_watcher or
    opencache_prefix_monitor until this is fixed:
        pkg install -y node${NODE_TARGET_MAJOR} && $0 --upgrade"
    fi

    newMajor="$(nodeMajor)"
    if [ -z "$newMajor" ] || [ "$newMajor" -lt "$NODE_TARGET_MAJOR" ]; then
        die "node${NODE_TARGET_MAJOR} installed but 'node --version' reports '${newMajor:-nothing}'. Resolve before restarting services."
    fi
    ok "node upgraded: v$major -> v$newMajor"
}

# ── Version resolution (anonymous GitHub releases API — no credentials) ──────
# Releases that actually CARRY a bundle tarball. A release without the asset
# (e.g. an accidental tag) must not win version resolution — fetchBundle would
# then 404.
releaseAssetTags() {
    curl -fsSL "https://api.github.com/repos/${INSTALLER_RELEASES_REPO}/releases?per_page=100" 2> /dev/null \
        | jq -r '.[] | select([.assets[]?.name] | any(test("^opencache-v[0-9].*\\.tar\\.gz$"))) | .tag_name'
}

resolveLatestVersion() {
    releaseAssetTags | grep -E '^v[0-9]' | sort -V | tail -1
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
        info "resolving newest published release from ${INSTALLER_RELEASES_REPO}"
        VERSION="$(resolveLatestVersion || true)"
        [ -n "$VERSION" ] || die "could not resolve a published vX.Y[.Z] release — pass --version explicitly"
    fi
    ok "version: ${C_BOLD}${VERSION}${C_RESET}"
}

# ── Bundle fetch ─────────────────────────────────────────────────────────────
# The tarball attached to the PUBLIC installer repo's release for this version
# — the exact tree makeBundle.sh staged.
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
            echo "    ${C_YELLOW}dry-run${C_RESET} fetch opencache-${VERSION}.tar.gz from ${INSTALLER_RELEASES_REPO} releases -> $INSTALL_DIR"
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
        fetchBundleFromRelease \
            || die "no bundle for ${VERSION} on ${INSTALLER_RELEASES_REPO} — pass --version or --bundle-tarball"
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
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_URL         "$OPT_LOGS_PUSH_URL"
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_USER        "$OPT_LOGS_PUSH_USER"
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_PASSWORD    "$OPT_LOGS_PUSH_PASSWORD"

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
# ensureTmpfs <mountpoint> <mount-opts> <label> [owner:group] [mode]
#
# owner/mode (optional) are re-applied to the tmpfs ROOT on EVERY run, mounted
# or not: tmpfs root attributes reset on each mount, so a mount (or fstab
# line) without uid=/gid= leaves the root root:wheel — and for the memory
# cache tier that means the nginx WORKER cannot even traverse into the
# mountpoint and every cache open() fails with EACCES (nginx's master chowns
# the proxy_cache_path root INSIDE the mount, never the mountpoint above it).
# The certs store deliberately passes no owner: 0700 root is correct there
# (only nginx's root master reads key files, at config load).
#
# The fstab entry is REPLACED when its options drifted from the desired ones —
# a pre-fix line (rw,mode=0700,size=...) would silently re-break the memory
# tier on the next reboot even after the live mount was repaired.
ensureTmpfs() {
    mnt="$1"; opts="$2"; label="$3"; tmpOwner="${4:-}"; tmpMode="${5:-}"

    run mkdir -p "$mnt"
    if mount -p 2> /dev/null | awk '{print $2}' | grep -qx "$mnt"; then
        ok "$label already mounted at $mnt"
    else
        run mount -t tmpfs -o "$opts" tmpfs "$mnt"
        ok "$label mounted at $mnt ($opts)"
    fi
    if [ -n "$tmpOwner" ]; then
        run chown "$tmpOwner" "$mnt"
        [ -n "$tmpMode" ] && run chmod "$tmpMode" "$mnt"
    fi
    wantLine="$(printf 'tmpfs\t%s\ttmpfs\trw,%s\t0\t0' "$mnt" "$opts")"
    haveLine="$(awk -v m="$mnt" '$2 == m && $3 == "tmpfs" { print; exit }' /etc/fstab 2> /dev/null)"
    if [ "$haveLine" = "$wantLine" ]; then
        : # fstab already current
    elif [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$haveLine" ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} replace stale $mnt tmpfs entry in /etc/fstab"
        else
            echo "    ${C_YELLOW}dry-run${C_RESET} append $mnt tmpfs entry to /etc/fstab"
        fi
    else
        if [ -n "$haveLine" ]; then
            awk -v m="$mnt" '!($2 == m && $3 == "tmpfs")' /etc/fstab > /etc/fstab.opencache.tmp \
                && cat /etc/fstab.opencache.tmp > /etc/fstab
            rm -f /etc/fstab.opencache.tmp
        fi
        printf '%s\n' "$wantLine" >> /etc/fstab
        ok "persisted to /etc/fstab${haveLine:+ (stale entry replaced)}"
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
    # Owned by the nginx WORKER
    # user (numeric uid/gid — boot-time fstab must not depend on name
    # resolution): unlike the certs store this filesystem is written and read
    # by the workers, and a root:wheel 0700 root (the pre-v26.08.11 mount)
    # made every memory-zone cache open() fail with EACCES.
    # Sizing follows nodeConfig: the config generator sums the memory-tier
    # zones (+20% headroom) and writes MEMORY_CACHE_SIZE_BYTES to
    # env/.env.nginx. Root .env is checked FIRST so an operator can pin the
    # size locally; the generated value is the normal source.
    #
    # NOTE: this runs at install/upgrade only. Growing the memory tier in the
    # KVS therefore takes effect at the next upgrade (or a manual remount) —
    # the watcher does not resize a live mount.
    memBytes="$(envValue "$ENV_FILE" MEMORY_CACHE_SIZE_BYTES)"
    [ -n "$memBytes" ] || memBytes="$(envValue "$INSTALL_DIR/env/.env.nginx" MEMORY_CACHE_SIZE_BYTES)"
    [ -n "$memBytes" ] || memBytes=8589934592
    nginxUid="$(id -u nginx 2> /dev/null)"
    nginxGid="$(pw groupshow nginx 2> /dev/null | cut -d: -f3)"
    if [ -n "$nginxUid" ] && [ -n "$nginxGid" ]; then
        ensureTmpfs /var/cache/nginx/memory \
            "mode=0750,uid=$nginxUid,gid=$nginxGid,size=$memBytes" \
            "memory cache tier" nginx:nginx 0750
    else
        warn "nginx user/group not resolvable — mounting memory tier root-owned (cache writes WILL fail until fixed)"
        ensureTmpfs /var/cache/nginx/memory "mode=0750,size=$memBytes" "memory cache tier"
    fi

    if [ "$(swapinfo 2> /dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
        warn "swap is ENABLED — tmpfs pages (incl. TLS keys) can reach the swap device."
        warn "Run 'swapoff -a' and remove swap from /etc/fstab, or use encrypted swap."
    fi
}

# ── Kernel tuning ────────────────────────────────────────────────────────────
# Values are written to
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
	# Fleet-wide edge tuning.
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

# ── Boot-time kernel tunables ────────────────────────────────────────────────
# Deliberately separate from configureSysctl(): NOTHING here can be applied
# live. The loader sets these before the kernel starts, and pf sizes its state
# hash exactly once, when the module loads. Writing the file is therefore only
# half the job, and this function says a reboot is pending rather than
# reporting success the way configureSysctl() legitimately can.
#
# /boot/loader.conf.local is read AFTER /boot/loader.conf and is the designated
# place for local overrides, so this cannot fight the base system or whatever a
# hosting provider wrote into loader.conf.
configureLoaderConf() {
    step "Boot-time kernel tunables"

    if [ "$SKIP_LOADER_CONF" -eq 1 ]; then
        info "skipped (--skip-loader-conf)"
        return 0
    fi

    # Sized to `set limit states` in the generated ruleset (PF_LIMIT_FLOOR in
    # config-generator/src/firewall.ts) and in freebsd/pf.conf.default. Keep the
    # three in step.
    #
    # pf defaults to 32768 buckets. Once ACTIVE states exceed the bucket count,
    # state lookups degrade into chain walks and throughput drops several-fold —
    # so a node raised to 2,000,000 states on the default hash buys capacity and
    # keeps the slowdown. The rule of thumb is hash >= max states, rounded to a
    # power of two; 2^21 costs roughly 80 B/bucket (~168 MiB) wired when pf
    # loads, which is the only part of pf's memory paid up front.
    #
    # net.pf.source_nodes_hashsize is deliberately NOT raised. FirewallRule
    # exposes no sticky-address / max-src-conn surface, so nothing ever
    # populates the source-node table, and its hash is allocated up front all
    # the same — raising it would wire memory for a table that stays empty.
    pfStatesHashsize=2097152

    f=/boot/loader.conf.local
    tmp="$(mktemp)"
    cat > "$tmp" <<- EOF
	# BEGIN opencache-managed — edits inside this block are overwritten by install-freebsd.sh
	# pf state hash buckets. MUST track \`set limit states\` in the pf ruleset;
	# past this count state lookups become bucket chain walks. Boot-time only.
	net.pf.states_hashsize="$pfStatesHashsize"
	# END opencache-managed
	EOF

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write managed block to $f (net.pf.states_hashsize=$pfStatesHashsize)" >&2
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

    # Unreadable when pf.ko is not loaded, which is the normal state on a fresh
    # install at this point — configurePf() runs later. Not a failure.
    running="$(sysctl -n net.pf.states_hashsize 2> /dev/null || true)"

    if [ -z "$running" ]; then
        ok "net.pf.states_hashsize=$pfStatesHashsize written to $f (applies at next boot)"
    elif [ "$running" = "$pfStatesHashsize" ]; then
        ok "net.pf.states_hashsize is $running (persisted to $f)"
    else
        warn "REBOOT PENDING: $f now sets net.pf.states_hashsize=$pfStatesHashsize but the running kernel has $running. This is a boot-time tunable and does NOT take effect now. Until the next reboot pf runs $running hash buckets against a 2000000-state limit, which still works but makes state lookups walk long bucket chains."
    fi
}

# ── Cache mount hardening (nosuid / noexec) ──────────────────────────────────
# FreeBSD's nightly periodic(8) security run walks every ufs/zfs mount on the
# host twice — once for setuid files, once for negative group permissions:
#
#   /etc/periodic/security/100.chksetuid
#   /etc/periodic/security/110.neggrpperm
#
# Both build their target list with the SAME expression:
#
#   MP=`mount -t ufs,zfs | awk '$0 !~ /no(suid|exec)/ { ...print mountpoint... }'`
#   find -sx $MP ...
#
# so a mount is skipped if — and only if — `nosuid` or `noexec` appears in its
# option string. A cache disk without either is therefore fully walked by find
# every night: on a PoP holding tens of millions of cache objects that is a
# multi-HOUR metadata storm at high CPU, competing with live traffic and with
# nginx's own cache loader, repeating daily and overlapping itself. One
# observed node spent 14.5 hours at 80% CPU on a single run.
#
# Marking the cache mounts nosuid+noexec removes them from that scan and is the
# correct posture independently: a cache store holds response bodies and must
# never hold an executable, let alone a setuid one. It is NOT the same as
# disabling the periodic check (`daily_status_security_chksetuid_enable=NO`),
# which would also stop covering the root filesystem — the part that matters.
#
# Applied live, and persisted: UFS via `mount -u` plus an in-place rewrite of
# the fstab options field, ZFS via dataset properties.
cacheMountIsExcluded() {
    # Replicates the periodic(8) filter verbatim so this answers the real
    # question — "would tonight's scan skip this mount?" — rather than a proxy
    # for it. Exits 0 (success) when the mount is NOT in the scan list.
    mount -t ufs,zfs 2> /dev/null | awk -v mp="$1" '
        $0 !~ /no(suid|exec)/ {
            sub(/^.* on \//, "/")
            sub(/ \(.*\)/, "")
            if ($0 == mp) found = 1
        }
        END { exit(found ? 1 : 0) }
    '
}

# Add nosuid,noexec to the OPTIONS field of the fstab line for one mountpoint.
#
# Deliberately narrow: it edits field 4 of the line whose mountpoint matches and
# nothing else, leaving the device, dump and pass fields exactly as the operator
# wrote them, and it never APPENDS a line — an fstab entry we did not find is an
# entry we must not invent. Cache-disk fstab lines are operator-owned (see
# newSetup.md); the tmpfs lines this installer manages are handled separately by
# ensureTmpfs.
hardenFstabOptions() {
    mp="$1"
    if [ ! -f /etc/fstab ]; then
        warn "no /etc/fstab — nosuid,noexec on $mp will not survive a reboot"
        return 0
    fi
    if awk -v m="$mp" '$2 == m && $4 ~ /(^|,)(nosuid|noexec)(,|$)/ { f = 1 }
                       END { exit(f ? 0 : 1) }' /etc/fstab; then
        return 0 # already persisted
    fi
    if ! awk -v m="$mp" '$2 == m { f = 1 } END { exit(f ? 0 : 1) }' /etc/fstab; then
        warn "$mp has no /etc/fstab entry — nosuid,noexec will be lost at reboot (see newSetup.md)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} add nosuid,noexec to the /etc/fstab options for $mp" >&2
        return 0
    fi
    awk -v m="$mp" '
        BEGIN { OFS = "\t" }
        /^[[:space:]]*#/ || NF < 4 { print; next }
        $2 != m { print; next }
        {
            opts = $4
            if (opts !~ /(^|,)nosuid(,|$)/) opts = opts ",nosuid"
            if (opts !~ /(^|,)noexec(,|$)/) opts = opts ",noexec"
            $4 = opts
            print
        }
    ' /etc/fstab > /etc/fstab.opencache.tmp \
        && cat /etc/fstab.opencache.tmp > /etc/fstab
    rm -f /etc/fstab.opencache.tmp
    ok "persisted nosuid,noexec for $mp to /etc/fstab"
}

hardenCacheMount() {
    mp="$1"
    fstype=$(mount -p 2> /dev/null | awk -v m="$mp" '$2 == m { print $3; exit }')
    src=$(mount -p 2> /dev/null | awk -v m="$mp" '$2 == m { print $1; exit }')

    if cacheMountIsExcluded "$mp"; then
        return 0 # already outside the nightly scan
    fi

    case "$fstype" in
        zfs)
            # Per-dataset, not by inheritance: a child dataset can carry its own
            # local or temporary value that the parent's setting never reaches.
            run zfs set setuid=off "$src"
            run zfs set exec=off "$src"
            # A property supplied at MOUNT time is recorded with source
            # `temporary` and outranks the persistent one until the dataset is
            # remounted — `zfs set` appears to succeed and changes nothing.
            if [ "$(zfs get -H -o source setuid "$src" 2> /dev/null)" = "temporary" ]; then
                warn "$src: setuid is overridden by a temporary (mount-time) option — the persistent property is set, but only a remount will apply it"
            fi
            ;;
        ufs)
            run mount -u -o nosuid,noexec "$mp"
            hardenFstabOptions "$mp"
            ;;
        '')
            warn "$mp is not in the mount table — skipping nosuid/noexec"
            return 0
            ;;
        *)
            # Not scanned by periodic(8) at all (it filters -t ufs,zfs).
            return 0
            ;;
    esac

    # Verify against the periodic filter itself rather than trusting the set.
    if cacheMountIsExcluded "$mp"; then
        ok "$mp excluded from the nightly setuid scan (nosuid,noexec)"
    elif [ "$DRY_RUN" -eq 0 ]; then
        warn "$mp is STILL in the nightly periodic(8) setuid scan — 'find' will walk the whole cache tree every night. Check: mount | grep ' $mp '"
    fi
}

# ── Cache disk scan ──────────────────────────────────────────────────────────
# Convention: dedicated cache disks are mounted at /mnt/nvme-<i> and
# /mnt/hdd-<i>. The disks are used at their real paths, so all this must do is
# find them, hand them to the nginx user, harden the mount, and tell the
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
        hardenCacheMount "$mp"
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

# ── Firewall (pf) ────────────────────────────────────────────────────────────
# Runs AFTER configureSsh deliberately: the ruleset holds 22/tcp open, but the
# keys that make that port useful must already be installed before pf is
# enabled on a box we can only reach over the network.
#
# The ruleset itself is owned by the config-watcher, which renders
# nodeConfig.firewall to $PF_CONF and reloads pf with `pfctl -f`. This function
# only guarantees the two preconditions for that: pf is enabled, and a VALID
# ruleset exists at the path pf_rules points to before pf is ever started.
configurePf() {
    step "Firewall (pf)"

    if [ "$SKIP_FIREWALL" -eq 1 ]; then
        info "skipped (--skip-firewall)"
        return 0
    fi

    pfConf=/usr/local/etc/opencache/pf.conf
    src="$INSTALL_DIR/freebsd/pf.conf.default"

    if [ ! -f "$src" ]; then
        warn "$src missing from the bundle — not enabling pf"
        return 0
    fi

    run mkdir -p /usr/local/etc/opencache

    # NEVER overwrite an existing ruleset. On an upgrade this file is whatever
    # the watcher last generated from the KVS; replacing it with the permissive
    # default would silently un-firewall a configured node.
    if [ -f "$pfConf" ]; then
        info "$pfConf exists — leaving it alone (the config-watcher owns it)"
    else
        run install -m 0644 "$src" "$pfConf"
        ok "default ruleset installed to $pfConf"
    fi

    # Load pf.ko BEFORE the parse-check below, not after. On FreeBSD 15 pfctl
    # opens /dev/pf unconditionally — `pfctl_open()` is called outside the
    # PF_OPT_NOACTION guard — so even `pfctl -n -f`, which was a pure userland
    # parse through FreeBSD 14, now fails with the badly-worded
    # "Failed to open netlink: No such file or directory" when the module is
    # absent. That ENOENT is /dev/pf, not netlink.
    #
    # pf is not in GENERIC, and the thing that normally loads it is
    # /etc/rc.d/pf (required_modules="pf"), which only runs once pf_enable=YES
    # is set BELOW. Parse-checking first therefore deadlocked a fresh install:
    # the check failed, we returned early, pf_enable was never set, rc.d/pf
    # never ran, the module never loaded — permanently, across reboots — and
    # the config-watcher re-hit the same failure every 60s poll while the node
    # sat with no firewall at all.
    #
    # Skipped entirely when pf is statically compiled into the kernel, since
    # /dev/pf exists then. Not routed through run(), which cannot redirect the
    # inner command alone — silencing it there would swallow the dry-run echo.
    if [ ! -c /dev/pf ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} kldload -n pf" >&2
        else
            # -n is a no-op if it is somehow already loaded. A failure here is
            # not fatal on its own — the /dev/pf test below is what decides.
            kldload -n pf > /dev/null 2>&1 || true
        fi
    fi
    if [ "$DRY_RUN" -eq 0 ] && [ ! -c /dev/pf ]; then
        warn "pf.ko could not be loaded (no /dev/pf) — NOT enabling pf. Check \`kldload pf\`; a jail cannot load kernel modules."
        return 0
    fi

    # Parse-check before enabling. A pf_enable=YES pointed at a ruleset that
    # does not load leaves the node with pf up and NO rules on some paths, and
    # is a confusing failure at boot rather than here.
    if [ "$DRY_RUN" -eq 0 ] && ! pfctl -n -f "$pfConf" > /dev/null 2>&1; then
        warn "$pfConf failed \`pfctl -n -f\` — NOT enabling pf. Fix the ruleset and re-run."
        return 0
    fi

    run sysrc -q pf_enable=YES > /dev/null
    run sysrc -q pf_rules="$pfConf" > /dev/null
    # pflog is what makes a rule's `log: true` observable via tcpdump on pflog0.
    run sysrc -q pflog_enable=YES > /dev/null
    ok "pf enabled in rc.conf (rules: $pfConf)"

    # `service pf reload` re-reads pf_rules and swaps the ruleset atomically,
    # keeping the state table — established SSH sessions survive. Only fall
    # back to start when pf is not already running.
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: would load $pfConf"
    elif service pf status > /dev/null 2>&1; then
        svc reload pf
        ok "pf ruleset reloaded (existing connections unaffected)"
    else
        svc start pf
        svc start pflog
        ok "pf started"
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
	# Weekly: the databases themselves are published on roughly that cadence.
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
    ok "newsyslog rotation installed"

    run sysrc -q opencache_root="$INSTALL_DIR" > /dev/null
    run sysrc -q opencache_nginx_enable=YES > /dev/null
    run sysrc -q opencache_watcher_enable=YES > /dev/null
    run sysrc -q opencache_prefix_monitor_enable=YES > /dev/null
    run sysrc -q opencache_bird_enable=YES > /dev/null
    # The pkg's own bird rc script must stay OFF — opencache_bird replaces it
    # (it renders bird.conf from the KVS-driven env on every start).
    run sysrc -q bird_enable=NO > /dev/null
    # Defense against muscle memory: an operator who types `service bird
    # onestart` (the pkg script) must not get a DIFFERENT bird — pkg-default
    # config, no BGP session, but the right control socket, so birdc answers
    # and everything LOOKS alive. Point the pkg script's config variable at
    # the SAME rendered file so both entry points agree; opencache_bird
    # remains the enabled, supported one (it is what re-renders on start).
    run sysrc -q bird_config="/usr/local/etc/opencache/bird.conf" > /dev/null

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
    # service(8) wrapper: tolerant (a failed start must not abort the whole
    # install) but never SILENT — swallowing the error output is how a dead
    # bird on first deploy went undiagnosed.
    #
    # ⚠ Output is captured through a FILE, never a pipe, and that is load
    # bearing. A daemon started here inherits this shell's stdout/stderr and may
    # keep them open for its entire life; command substitution does not wait for
    # the COMMAND to exit, it waits for every writer to close the pipe. So
    # `svcOut="$(service … start 2>&1)"` hangs until the daemon dies — which for
    # a successful start is never. That is exactly what happened with nginx:
    # `error_log stderr` set cycle->log_use_stderr, which suppressed the dup2
    # that would otherwise have repointed fd 2 at the error log, and ngx_daemon()
    # leaves STDERR alone by design. The installer stopped dead at "nginx was
    # down — starting it" with nginx running perfectly.
    #
    # nginx.conf no longer declares that sink, so nginx itself is fixed at the
    # source. This stays because the hazard is generic: any daemon reachable
    # through here can reintroduce it, and an installer that hangs is far worse
    # than one that loses a few lines of service output.
    action="$1"; name="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} service $name $action" >&2
        return 0
    fi
    svcLog="${TMPDIR:-/tmp}/opencache-svc.$$.log"
    rm -f "$svcLog"
    # </dev/null too: a service script that reads stdin would otherwise block on
    # the installer's, which under `curl … | sh` is the download stream.
    if service "$name" "$action" < /dev/null > "$svcLog" 2>&1; then
        rm -f "$svcLog"
        return 0
    fi
    warn "service $name $action FAILED:"
    tail -3 "$svcLog" 2> /dev/null | sed 's/^/          /' >&2
    rm -f "$svcLog"
    return 0
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
        # birdc answering is NOT proof the right bird is running: the pkg's
        # own rc script (`service bird onestart`) starts BIRD on the same
        # control socket but with a different config and therefore no BGP
        # session. Check the running process actually loaded ours.
        if ! pgrep -qf 'bird .*-c /usr/local/etc/opencache/bird.conf' 2> /dev/null; then
            warn "BIRD is running WITHOUT the opencache-rendered config (started via the pkg 'bird' script?)"
            warn "fix: service bird onestop 2>/dev/null; service opencache_bird restart"
        fi
    else
        warn "birdc cannot reach BIRD — run 'service opencache_bird start' and read its output"
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

    # FIRST, before anything else mutates the host: a runtime swap that fails
    # aborts here, leaving the install untouched and — critically — leaving the
    # already-running services alone, since the restart step is far below.
    ensureNodeRuntime

    fetchBundle
    installNginx
    installAlloy
    installNginxExporter
    installBirdwatcher
    installServices
    configureTmpfs
    configureSysctl
    configureLoaderConf
    scanCacheDisks
    configureSsh
    configurePf
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
            info "nginx binary changed — full restart (brief blip)"
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
            info "alloy unchanged — not restarted (a restart costs a log catch-up window)"
        fi

        # Log shipping targets the ClickHouse warehouse; a pre-migration .env
        # only has the retired GCLOUD_HOSTED_LOGS_* keys, and without the new
        # ones the alloy launcher idles (no logs OR metrics ship).
        if [ -z "$(envValue "$ENV_FILE" OC_LOGS_PUSH_URL)" ] || [ -z "$(envValue "$ENV_FILE" OC_LOGS_PUSH_PASSWORD)" ]; then
            warn "OC_LOGS_PUSH_URL / OC_LOGS_PUSH_PASSWORD not set in $ENV_FILE — log/metric shipping is DISABLED"
            warn "add them (ClickHouse warehouse ingest credentials) and run: service opencache_alloy restart"
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
    echo "  BGP         : birdc show protocols   (service name is opencache_bird — NOT the pkg 'bird' script)"
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

    ensureNodeRuntime
    fetchBundle
    installNginx
    seedEnv
    configureTmpfs
    configureSysctl
    configureLoaderConf
    scanCacheDisks
    configureSsh
    configurePf
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
