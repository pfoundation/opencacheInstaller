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
#   addresses        rc.d/opencache_addresses: re-adds the content-class
#                    aliases the watcher manages at boot, before nginx/BIRD
#   alloy            official FreeBSD release binary (pinned below)
#   nginx-exporter   official FreeBSD release binary (best-effort)
#   geoip            scripts/geoip-update.sh + daily cron: GeoLite2 from the
#                    OpenCache mirror via the BaaS API (no MaxMind credentials
#                    on the node)
#   access logs      scripts/access-log-cleanup.sh + every-minute cron: deletes
#                    the per-property hourly access logs once Alloy shipped
#                    them, keeps the log disk above 10% free
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
# Options: run it with --help, or read usage() below.
# ─────────────────────────────────────────────────────────────────────────────
set -eu

# The option list. A heredoc, not a sed range over "$0": piped into sh
# (`fetch … | sh -s -- --help`) there is no script file to read ($0 is "sh"),
# and in a C/POSIX locale a range ending on `─\{10,\}` never matched (`─` is
# three bytes; the interval repeats only the last), so --help printed the
# whole script (pfoundation/opencache#204).
usage() {
    cat << 'EOF'
── Usage ────────────────────────────────────────────────────────────────────
  install-freebsd.sh [options]

  --version <tag>        Bundle version (default: newest published vX.Y[.Z])
  --dir <path>           Install directory (default: /opt/opencache)
  --pop-id <id>          Node identity, e.g. PAR1
  --baas-host <url>      BaaS origin serving BOTH /items/* and /dsb/v1/*
  --baas-token <token>   Bearer token for both surfaces
  --baas-version <ver>   DSB API version segment (default: v1)
  --baas-project-id <id> Project UUID the PoP's KVS records live under
                         (deprecated aliases: --dus-upstream / --kvs-api-base
                          -> --baas-host, --dus-token -> --baas-token,
                          --kvs-project-id -> --baas-project-id)
  --geoip-account-id <id>, --geoip-license-key <key>
                         Retired (GeoIP comes from the OpenCache mirror via
                         the BaaS API) — accepted and ignored with a notice
  --logs-push-url <url>  ClickHouse warehouse ingest endpoint, e.g.
                         https://<warehouse>/loki/v1/push. Alloy ships
                         logs over OTLP to <origin>/v1/logs and metrics to
                         <origin>/ocmetrics/v1/metrics, both derived from it
  --logs-push-user <u>   Basic-auth user for it (default: opencache)
  --logs-push-password <pw>
  --bundle-tarball <p>   Install from a specific opencache-<ver>.tar.gz —
                         local path or http(s) URL (air-gap / local build /
                         mirror). Without it the newest published release
                         asset is used.
  --upgrade              Upgrade an existing install
  --skip-ssh             Do not install SSH keys or touch sshd_config
  --skip-sysctl          Do not apply kernel tuning
  --skip-loader-conf     Do not write boot-time tunables to
                         /boot/loader.conf.local (pf state hash sizing)
  --skip-firewall        Do not enable pf or install the default ruleset
  --skip-ntp             Do not enable or start ntpd (time sync)
  --skip-hostname        Do not set the hostname from nodeConfig.serverName
  --skip-nginx-build     Fail instead of building nginx when it is missing
  --no-deploy            Lay everything down but do not start services
  --force-env            Overwrite .env values that are already populated
  --dry-run              Print what would happen, change nothing
  --yes, -y              Never prompt; take the documented default
  --help, -h

Re-running is safe. Node-local state (.env values, certs/, env/, cache
dirs, nginx/generated/) is never overwritten.
─────────────────────────────────────────────────────────────────────────────
EOF
}

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
SKIP_NTP=0
SKIP_HOSTNAME=0
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
OPT_LOGS_PUSH_URL=""
OPT_LOGS_PUSH_USER=""
OPT_LOGS_PUSH_PASSWORD=""

# Node-local state that must survive an upgrade. Deliberately maintained
# SEPARATELY from packaging/bundleManifest.txt: two independent lists means a
# mis-edit of one cannot silently clobber node state.
PROTECTED_PATHS=".env .env.sites certs env cache nginx/generated"

# Set while a bundle is being staged so an interrupted run leaves no debris.
# fetchBundle stages in "$INSTALL_DIR/$STAGE_PREFIX.XXXXXX".
STAGE_DIR=""
STAGE_PREFIX=".oc-bundle"
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
err()   { printf '%s\n' "${C_RED}ERROR${C_RESET}: $*" >&2; }
die()   { err "$*"; exit 1; }

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

# promptValue QUESTION [secret] — the value typed at the terminal, on stdout
# (callers read it with `$(…)`). `secret` turns the terminal's echo off while
# it is typed (pfoundation/opencache#236): `stty -echo` before the prompt and
# the saved mode back after the read, on exit, and on INT/TERM/HUP/QUIT (dash
# runs no EXIT trap when a signal kills it, so the signal exits instead) — in
# a subshell, so its traps never replace the installer's. stdin is the
# terminal: no `stty -f`/`-F` (BSD vs GNU), no `read -s` (not POSIX). When
# stty cannot save the mode, the value is read with echo on.
#
# Ctrl-Z, then `fg`: while the job was stopped, the job-control shell (bash,
# zsh) put its own terminal mode back, echo on. SIGCONT turns echo off again.
# A trapped signal ends a `read` early in dash and FreeBSD's sh (bash reads
# on), so the read is retried while SIGCONT was what ended it; what was typed
# before the Ctrl-Z is gone either way (the terminal flushes its input on
# SUSP). Not covered: a SIGTERM sent to the installer's process alone (not to
# its process group, as Ctrl-C and a closed terminal do) leaves this subshell
# reading with echo off until Enter; `stty echo` repairs the terminal.
promptValue() {
    question="$1"; reply=""
    if [ "$ASSUME_YES" -eq 1 ] || ! hasTty; then
        return 1
    fi
    if [ "${2:-}" = secret ]; then
        reply="$(
            pvMode="$(stty -g < /dev/tty 2> /dev/null)" || pvMode=""
            pvCont=0
            if [ -n "$pvMode" ]; then
                trap 'stty "$pvMode" < /dev/tty 2> /dev/null' EXIT
                trap 'exit 130' INT TERM HUP QUIT
                trap 'pvCont=1; stty -echo < /dev/tty 2> /dev/null' CONT
                stty -echo < /dev/tty 2> /dev/null || :
            fi
            printf '    %s: ' "$question" > /dev/tty
            pvReply=""
            while :; do
                pvCont=0; pvPart=""
                if read -r pvPart < /dev/tty; then
                    pvReply="$pvReply$pvPart"
                    break
                fi
                # End of input, unless SIGCONT ended the read: the line typed
                # after `fg` is still to come.
                if [ "$pvCont" -eq 0 ]; then
                    pvReply=""
                    break
                fi
                pvReply="$pvReply$pvPart"
            done
            if [ -n "$pvMode" ]; then
                trap - CONT
                stty "$pvMode" < /dev/tty 2> /dev/null || :
                # The typed newline was not echoed.
                printf '\n' > /dev/tty
            fi
            printf '%s' "$pvReply"
        )" || reply=""
    else
        printf '    %s: ' "$question" > /dev/tty
        read -r reply < /dev/tty || reply=""
    fi
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

# ── Effective env values ─────────────────────────────────────────────────────
# The value a consumer will actually use for KEY, resolved exactly as the
# launchers and the config watcher (readLocalEnv) resolve it:
#
#   1. the root .env, SOURCED by a clean /bin/sh (only a fixed PATH), so
#      quotes, `export` and an empty `KEY=""` behave as on the node — used
#      when NON-EMPTY;
#   2. else, unless another key of KEY's credential group is set in .env,
#      the fleet / per-PoP env default the config watcher wrote to
#      env/.env.defaults (`OC_DEFAULT__<KEY>=<value>`, shell-quoted);
#   3. else nothing.
#
# Credential groups (eevCredentialGroup; ENV_CREDENTIAL_GROUPS in
# config-generator/src/envDefaults.ts, test-guarded) are all-or-nothing at
# the .env boundary, as in the watcher and freebsd/env-defaults.sh: a local
# OC_LOGS_PUSH_PASSWORD never pairs with a fleet push URL.
#
# Each file is sourced in a subshell (stdin from /dev/null: under
# `fetch | sh` stdin is this script), so nothing it sets leaks into the
# installer, and the eval expands only the (validated) NAME — a value is
# never re-parsed. A defaults file that is group- or world-writable, or that
# does not parse, is ignored with a warning naming the file (never a value).
#
# loadEffectiveEnvValue KEY sets EEV_VALUE in the CURRENT shell, which is what
# lets each warning print once per run; effectiveEnvValue KEY prints it.
# Both return 1, resolving nothing, for an invalid KEY.
EEV_VALUE=""
EEV_WARNED=""

eevWarnOnce() {
    case " $EEV_WARNED " in *" $1 "*) return 0 ;; esac
    EEV_WARNED="$EEV_WARNED $1"
    warn "$2"
}

# The keys of KEY's credential group, space-separated; nothing for a key in
# no group (the ALLOY_* tuning keys are per-key).
eevCredentialGroup() {
    case "${1:-}" in
        OC_LOGS_PUSH_URL | OC_LOGS_PUSH_USER | OC_LOGS_PUSH_PASSWORD | \
        OC_METRICS_PUSH_URL | OC_METRICS_PUSH_USER | OC_METRICS_PUSH_PASSWORD)
            echo "OC_LOGS_PUSH_URL OC_LOGS_PUSH_USER OC_LOGS_PUSH_PASSWORD OC_METRICS_PUSH_URL OC_METRICS_PUSH_USER OC_METRICS_PUSH_PASSWORD" ;;
    esac
}

loadEffectiveEnvValue() {
    EEV_VALUE=""
    case "${1:-}" in
        "" | [!ABCDEFGHIJKLMNOPQRSTUVWXYZ]* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*)
            return 1 ;;
    esac

    # `.` searches PATH for a name without a slash.
    eevEnv="$ENV_FILE"
    case "$eevEnv" in /* | ./* | ../*) ;; *) eevEnv="./$eevEnv" ;; esac
    if [ -f "$eevEnv" ]; then
        # Prints `=<value>` when KEY is set, `!` when another key of its
        # credential group is (KEY then takes nothing from the defaults).
        # shellcheck disable=SC2016,SC2046
        if eevOut="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '
                . "$1" > /dev/null 2>&1
                eval "_v=\${$2:-}"
                if [ -n "$_v" ]; then printf "=%s" "$_v"; exit 0; fi
                shift 2
                for _k in "$@"; do
                    eval "[ -z \"\${$_k:-}\" ]" || { printf "!"; exit 0; }
                done
                exit 0' sh "$eevEnv" "$1" $(eevCredentialGroup "$1") < /dev/null 2> /dev/null)"; then
            case "$eevOut" in
                =*) EEV_VALUE="${eevOut#=}"; eevOut=""; return 0 ;;
                "!") eevOut=""; return 0 ;;
            esac
        else
            eevWarnOnce env "$ENV_FILE could not be evaluated — its values are ignored here"
        fi
        eevOut=""
    fi

    eevFile="$INSTALL_DIR/env/.env.defaults"
    case "$eevFile" in /* | ./* | ../*) ;; *) eevFile="./$eevFile" ;; esac
    [ -f "$eevFile" ] || return 0
    if [ -n "$(find -L "$eevFile" -prune \( -perm -0020 -o -perm -0002 \) -print 2> /dev/null || echo bad)" ]; then
        eevWarnOnce defaults-mode "$eevFile is group- or world-writable (or could not be checked) — fleet/per-PoP env defaults ignored"
        return 0
    fi
    # unset first: an OC_DEFAULT__* inherited from the installer's own
    # environment must never stand in for the file.
    if ! EEV_VALUE="$(exec 2> /dev/null < /dev/null
        unset "OC_DEFAULT__$1"
        . "$eevFile" > /dev/null
        eval "printf '%s' \"\${OC_DEFAULT__$1:-}\"")"; then
        EEV_VALUE=""
        eevWarnOnce defaults-parse "$eevFile could not be evaluated — fleet/per-PoP env defaults ignored"
    fi
    return 0
}

effectiveEnvValue() {
    loadEffectiveEnvValue "${1:-}" || return 1
    printf '%s' "$EEV_VALUE"
}

# True when $1 holds a control character (U+0000–U+001F, U+007F) — e.g. the
# trailing CR a CRLF-edited .env leaves behind.
hasControlChar() {
    [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" != "$1" ]
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
    # umask 077: a file that is not there yet is created 0600, never readable
    # by anyone else before its first secret lands.
    (umask 077; cat "$tmp" > "$file")
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
# Same rule (and same war story) as the Linux installer. Trimmed, and checked
# by the runtime's rule (baasHostProblem): a value the config watcher and
# prefix-monitor refuse at startup is refused here, without printing it.
setBaasHost() {
    val="$(trimSpace "$1")"; flag="$2"
    sbhProblem="$(baasHostProblem "$val")"
    if [ -n "$sbhProblem" ]; then
        die "$flag $sbhProblem (its value is not shown)"
    fi
    if [ -n "$OPT_BAAS_HOST" ] && [ "$OPT_BAAS_HOST" != "$val" ]; then
        die "conflicting values for the BaaS origin: '$(redactUserinfo "$OPT_BAAS_HOST")' vs $flag '$(redactUserinfo "$val")'. BAAS_HOST is ONE origin serving both /items/* and /dsb/v1/* — pass a single --baas-host."
    fi
    OPT_BAAS_HOST="$val"
}

# ── Re-run hint ──────────────────────────────────────────────────────────────
# rerunCommand prints the command that runs this installer again exactly as
# it was invoked, for hints printed when a run stops half-way. Never "$0":
# piped into sh (`fetch … | sh -s -- --upgrade`, the documented upgrade) $0
# is "sh", and `$0 --upgrade` read `sh --upgrade` (pfoundation/opencache#220).
# Every option of this run is kept, since a re-run without --skip-firewall,
# --bundle-tarball or --dir does something else. The parser records each
# option as it consumes it (recordRunArg), so a value is exactly what the
# parser took as one.

# The flags whose value is a secret: never printed back.
isSecretFlag() {
    case "$1" in
        --baas-token | --dus-token | --logs-push-password | --geoip-license-key | --gcloud-api-key)
            return 0 ;;
    esac
    return 1
}

# The retired flags: accepted and ignored, so left out of the re-run command
# — a hint asking for a value nothing reads would be refused when pasted
# with its '<redacted>' (pfoundation/opencache#236).
isRetiredFlag() {
    case "$1" in
        --geoip-account-id | --geoip-license-key | --gcloud-metrics-id | --gcloud-logs-id | --gcloud-api-key)
            return 0 ;;
    esac
    return 1
}

# The flags whose parser arm takes the next word as their value (--geoip-*
# only when it does not start with --). Test-guarded against the parser.
takesValue() {
    case "$1" in
        --version | --dir | --pop-id | --baas-host | --baas-token | \
        --dus-upstream | --kvs-api-base | --dus-token | --kvs-project-id | \
        --baas-version | --baas-project-id | --geoip-account-id | \
        --geoip-license-key | --gcloud-metrics-id | --gcloud-logs-id | \
        --gcloud-api-key | --logs-push-url | --logs-push-user | \
        --logs-push-password | --bundle-tarball)
            return 0 ;;
    esac
    return 1
}

# $1 as one shell word: as-is when it is plain, else single-quoted.
shellWord() {
    case "$1" in
        "" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@%+,-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# True when $1 is a URL host with an optional port: a name of letters,
# digits and . _ ~ % - (or an [IP literal]), then nothing or :<digits>.
isHostPort() {
    case "$1" in
        \[*\]*)
            # Up to the first ], which holds no other [.
            ihpPort="${1#*\]}"; ihpHost="${1%"$ihpPort"}"
            case "$ihpHost" in \[\] | \[*\[*) return 1 ;; esac
            ;;
        *)
            case "$1" in
                *:*) ihpHost="${1%%:*}"; ihpPort=":${1#*:}" ;;
                *) ihpHost="$1"; ihpPort="" ;;
            esac
            case "$ihpHost" in
                "" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~%-]*) return 1 ;;
            esac
            ;;
    esac
    case "$ihpPort" in
        "" | :) return 0 ;;
        :*[!0123456789]*) return 1 ;;
        :*) return 0 ;;
    esac
    return 1
}

# $1 with the user[:password]@ of a scheme://user:password@host/… URL
# replaced by <redacted>@; anything else unchanged. The userinfo ends at the
# last @ of the authority (up to the first / ? or #) when the rest of the
# authority is a valid host[:port], so an @ in the path, query or fragment of
# a valid URL stays (pfoundation/opencache#220). A password with an unencoded
# / ? or # mostly leaves no valid authority (user:pa/ss@host reads as host
# "user", port "pa"); the userinfo then runs to the last @ a valid host[:port]
# follows — or to the last @ — so none of the password is printed
# (pfoundation/opencache#236).
#
# Not caught, because the text before the first / ? or # IS a valid
# authority, so the URL reads as one for another host with that @ in its path
# (as curl and fetch(1) read it too) — percent-encode / ? # @ (%2F %3F %23
# %40) in a user name or password:
#   * a password that starts with / ? or # — user:/pw@host: host "user",
#     empty port;
#   * a password whose / ? or # follows only digits — user:123/x@host: port 123;
#   * a password whose / ? or # follows an unencoded @ — user:p@ss/x@host:
#     host "ss";
#   * a user-only token holding / ? or # — https://to/ken@host: host "to".
# Redacting those would also redact the @ in the path of a valid URL.
redactUserinfo() {
    case "$1" in
        *://*@*) ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    ruScheme="${1%%://*}://"
    ruRest="${1#*://}"
    ruAuthority="${ruRest%%[/?#]*}"
    if isHostPort "${ruAuthority##*@}"; then
        case "$ruAuthority" in
            *@*) printf '%s<redacted>@%s' "$ruScheme" "${ruRest#"${ruAuthority%@*}@"}" ;;
            *) printf '%s' "$1" ;;
        esac
        return 0
    fi
    ruUser=""; ruTail="$ruRest"; ruBest=""
    while :; do
        case "$ruTail" in *@*) ;; *) break ;; esac
        ruUser="$ruUser${ruTail%%@*}@"
        ruTail="${ruTail#*@}"
        if isHostPort "${ruTail%%[/?#]*}"; then ruBest="$ruUser"; fi
    done
    [ -n "$ruBest" ] || ruBest="$ruUser"
    printf '%s<redacted>@%s' "$ruScheme" "${ruRest#"$ruBest"}"
}

# $1 without its leading and trailing whitespace, as the runtime reads
# BAAS_HOST (prefix-monitor trims it; config-generator's URL parser does).
trimSpace() {
    tsValue="$1"
    while :; do
        case "$tsValue" in [[:space:]]*) tsValue="${tsValue#?}" ;; *) break ;; esac
    done
    while :; do
        case "$tsValue" in *[[:space:]]) tsValue="${tsValue%?}" ;; *) break ;; esac
    done
    printf '%s' "$tsValue"
    tsValue=""
}

# Why $1 (trimmed — trimSpace) cannot be BAAS_HOST, on stdout; nothing when it
# can. The runtime's rule (baasHostProblem in config-generator/src/baasHost.ts
# and prefix-monitor/src/baasHost.ts, pfoundation/opencache#241), in sh:
# BAAS_HOST is an origin the request paths are appended to, so it is refused
#   * with any "@" — credentials, or a password whose unencoded / ? or # moved
#     its "@" out of the authority (https://user:12/x@host);
#   * with a query string or fragment ("?" or "#");
#   * when it is not a URL, or not an http:// or https:// one.
# The reason never includes the value. "Not a URL" is the URL parser's
# verdict, approximated: the host[:port] after the // is a name (no
# whitespace, % < > [ ] \ ^ |; a name ending in a number must be a dotted
# IPv4 address, each part 0-255) or an [IPv6 literal] of hex digits, ":" and
# ".", the port 0-65535. It agrees with the runtime on every case in
# config-generator/test/fixtures/baasHostCases.json, and is stricter than the
# parser on a few it would accept (no // after the scheme, a %-encoded or
# empty host, a backslash, whitespace in the path — which .env could not hold
# unquoted anyway). Known looser — accepted here, refused by the parser, so the
# config watcher and prefix-monitor exit at startup with "is not a valid URL"
# (none can hold an @, ? or #, so nothing leaks): an [IPv6 literal] of the
# right characters in a wrong shape ([1:2], [:], [1::2::3]); a non-ASCII name
# the parser's IDNA step rejects (U+FFFD, a zero-width non-joiner, a leading
# combining mark, Hebrew next to Latin); full-width digits or dots that make
# the name end in a number (a.１２３, a。1). The fixture's installerLooser list
# pins them. Invalid punycode (xn--a, a.xn--) is accepted here too, and refused
# by some Node releases' parser only (20.20, 24.16; 24.22 accepts it), so the
# fixture lists it nowhere.
baasHostProblem() {
    case "$1" in
        *@*)
            echo 'must not contain credentials (user:password@, or any "@") — the BaaS authenticates with BAAS_TOKEN alone, and no request can be made to a URL that carries credentials'
            return 0 ;;
        *[?#]*)
            echo 'must not contain a query string or fragment ("?" or "#") — the request paths are appended to it'
            return 0 ;;
    esac
    bhpNotUrl="is not a valid URL — expected an origin such as https://baas.example.com"
    case "$1" in
        *[[:space:][:cntrl:]]*) echo "$bhpNotUrl"; return 0 ;;
        [Hh][Tt][Tt][Pp]://* | [Hh][Tt][Tt][Pp][Ss]://*) ;;
        [Hh][Tt][Tt][Pp]:* | [Hh][Tt][Tt][Pp][Ss]:*) echo "$bhpNotUrl"; return 0 ;;
        [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]*:*)
            # Any other scheme (a valid URL of another kind; "host:port" reads
            # as one too).
            case "${1%%:*}" in
                *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+.-]*) echo "$bhpNotUrl" ;;
                *) echo "must be an http:// or https:// URL" ;;
            esac
            return 0 ;;
        *) echo "$bhpNotUrl"; return 0 ;;
    esac
    bhpAuthority="${1#*://}"; bhpAuthority="${bhpAuthority%%/*}"
    case "$bhpAuthority" in
        \[*\]*)
            bhpPort="${bhpAuthority#*\]}"; bhpHost="${bhpAuthority%"$bhpPort"}"
            bhpHost="${bhpHost#\[}"; bhpHost="${bhpHost%\]}"
            case "$bhpHost" in
                *:*) ;;
                *) echo "$bhpNotUrl"; return 0 ;;
            esac
            case "$bhpHost" in
                *[!0123456789abcdefABCDEF:.]*) echo "$bhpNotUrl"; return 0 ;;
            esac
            ;;
        *)
            case "$bhpAuthority" in
                *:*) bhpHost="${bhpAuthority%%:*}"; bhpPort=":${bhpAuthority#*:}" ;;
                *) bhpHost="$bhpAuthority"; bhpPort="" ;;
            esac
            case "$bhpHost" in
                "" | *%* | *\<* | *\>* | *\[* | *\]* | *\\* | *^* | *"|"*)
                    echo "$bhpNotUrl"; return 0 ;;
            esac
            if ! baasHostIpv4Ok "$bhpHost"; then
                echo "$bhpNotUrl"; return 0
            fi
            ;;
    esac
    case "$bhpPort" in
        "" | :) ;;
        :*[!0123456789]*) echo "$bhpNotUrl"; return 0 ;;
        :*)
            bhpPort="${bhpPort#:}"
            while :; do
                case "$bhpPort" in 0?*) bhpPort="${bhpPort#0}" ;; *) break ;; esac
            done
            if [ "${#bhpPort}" -gt 5 ] || [ "$bhpPort" -gt 65535 ]; then
                echo "$bhpNotUrl"; return 0
            fi
            ;;
        *) echo "$bhpNotUrl"; return 0 ;;
    esac
    return 0
}

# False when the host name $1 ends in a number (its last label, one trailing
# dot aside, is digits or 0x…) but is not a dotted IPv4 address of four parts
# 0-255 without leading zeros: the URL parser reads such a name as an IPv4
# address (https://10.0.0.256, https://baas.123 are no URLs). Stricter than
# the parser on its shorthands (127.1, octal 010.0.0.1).
baasHostIpv4Ok() {
    bhiHost="${1%.}"
    case "${bhiHost##*.}" in
        "" | *[!0123456789]*)
            case "${bhiHost##*.}" in 0[xX]*) ;; *) return 0 ;; esac ;;
    esac
    bhiParts=0
    bhiRest="$bhiHost."
    while [ -n "$bhiRest" ]; do
        bhiPart="${bhiRest%%.*}"; bhiRest="${bhiRest#*.}"
        bhiParts=$((bhiParts + 1))
        case "$bhiPart" in
            [0123456789] | [123456789][0123456789] | 1[0123456789][0123456789] | \
            2[01234][0123456789] | 25[012345]) ;;
            *) return 1 ;;
        esac
    done
    [ "$bhiParts" -eq 4 ]
}

# Appends one parsed option to RUN_ARGS: the flag $1 and, when the parser took
# the next word as its value ($3 = 2 words consumed), the value $2 — printed
# as '<redacted>' for a secret flag, with a URL's user:password@ redacted.
# A value still holding "<redacted>" is a pasted hint whose secrets were not
# filled in: refused, or it would land in .env, where a corrected run keeps
# it unless --force-env. A retired flag is left out, value and all.
RUN_ARGS=""
recordRunArg() {
    if isRetiredFlag "$1"; then
        return 0
    fi
    RUN_ARGS="$RUN_ARGS $(shellWord "$1")"
    [ "$3" -eq 2 ] || return 0
    case "$2" in
        *"<redacted>"*) die "$1: replace '<redacted>' with the real value" ;;
    esac
    if isSecretFlag "$1"; then
        RUN_ARGS="$RUN_ARGS '<redacted>'"
    else
        RUN_ARGS="$RUN_ARGS $(shellWord "$(redactUserinfo "$2")")"
    fi
}

# The file this run reads, when there is one — under any name, a renamed
# local copy too — so a re-run runs the same installer. Piped (`sh -s`) $0 is
# the shell: a bare name, or the path of a binary that is not this script.
SELF_PATH=""
if [ -f "$0" ] && [ -r "$0" ] && grep -qF 'OPENCACHE_INSTALL_LIB:-0' "$0" 2> /dev/null; then
    SELF_PATH="$(CDPATH='' cd -- "$(dirname -- "$0")" 2> /dev/null && pwd)/${0##*/}" || SELF_PATH=""
fi

rerunCommand() {
    if [ -n "$SELF_PATH" ]; then
        printf 'sh %s%s' "$(shellWord "$SELF_PATH")" "$RUN_ARGS"
    else
        printf 'fetch -qo - %s | sh -s --%s' "$INSTALLER_URL" "$RUN_ARGS"
    fi
}

# The error for an argument the parser does not know, which must never print
# a secret (pfoundation/opencache#236). A value-taking option followed by a
# secret option takes that option as its value (`--pop-id --baas-token TOKEN`),
# and the token is then the unknown argument. So the word is printed only when
# it looks like an option (starts with -) and is not where a value would be:
# right after a value-taking option (the one parsed last, or the word it took
# as its value), or after a secret value (the rest of a secret holding a
# space). Of an --option=value word only the option is printed. PARSED_FLAG,
# PARSED_VALUE and PARSED_COUNT describe the option parsed last.
unknownArgument() {
    uaShow=1
    case "$1" in -*) ;; *) uaShow=0 ;; esac
    uaPrev="$PARSED_FLAG"
    [ "$PARSED_COUNT" -ne 2 ] || uaPrev="$PARSED_VALUE"
    if takesValue "$uaPrev"; then uaShow=0; fi
    if [ "$PARSED_COUNT" -eq 2 ] && isSecretFlag "$PARSED_FLAG"; then uaShow=0; fi
    uaPrev=""
    if [ "$uaShow" -eq 1 ]; then
        case "$1" in
            *=*) err "unknown argument: ${1%%=*}=… (value not shown) — an option takes its value as the next word: ${1%%=*} <value>" ;;
            *) err "unknown argument: $1" ;;
        esac
    elif [ -z "$PARSED_FLAG" ]; then
        err "unexpected argument (not shown, as it may be a secret) — every option starts with --"
    elif [ "$PARSED_COUNT" -eq 2 ]; then
        err "unexpected argument after the value of $PARSED_FLAG (not shown, as it may be a secret) — did an option miss its value?"
    else
        err "unexpected argument after $PARSED_FLAG (not shown, as it may be a secret) — did an option miss its value?"
    fi
}

# ── Argument parsing ─────────────────────────────────────────────────────────
PARSED_FLAG=""; PARSED_VALUE=""; PARSED_COUNT=0
while [ $# -gt 0 ]; do
    runArgFlag="$1"; runArgValue="${2-}"; runArgCount=$#
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
        # Retired: GeoIP comes from the OpenCache mirror through the BaaS API.
        # Accepted (value included) and ignored so existing runbooks don't break.
        --geoip-account-id|--geoip-license-key)
            warn "$1 is retired and ignored (GeoIP databases come from the OpenCache mirror via the BaaS API)"
            case "${2:-}" in --* | "") shift ;; *) shift 2 ;; esac ;;
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
        --skip-ntp)          SKIP_NTP=1; shift ;;
        --skip-hostname)     SKIP_HOSTNAME=1; shift ;;
        --skip-nginx-build)  SKIP_NGINX_BUILD=1; shift ;;
        --no-deploy)         NO_DEPLOY=1; shift ;;
        --force-env)         FORCE_ENV=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --yes | -y)          ASSUME_YES=1; shift ;;
        --help | -h)         usage; exit 0 ;;
        *)                   unknownArgument "$1"; usage; exit 1 ;;
    esac
    recordRunArg "$runArgFlag" "$runArgValue" $((runArgCount - $#))
    PARSED_FLAG="$runArgFlag"; PARSED_VALUE="$runArgValue"; PARSED_COUNT=$((runArgCount - $#))
done
unset runArgFlag runArgValue runArgCount PARSED_FLAG PARSED_VALUE PARSED_COUNT

ENV_FILE="$INSTALL_DIR/.env"
ENV_WAS_CREATED=0
NGINX_BIN="/usr/local/sbin/nginx"
# Set by installNginx when this run actually (re)built the binary — decides
# restart vs reload on upgrade.
NGINX_REBUILT=0
# Set by syncHostname when this run changed the running hostname — Alloy reads
# it only at start, so the upgrade restarts it.
HOSTNAME_CHANGED=0
ALLOY_INPUTS_HASH_BEFORE=""

fileHash() {
    f="$1"
    [ -f "$f" ] || return 0
    sha256 -q "$f" 2> /dev/null || sha256sum "$f" | cut -d' ' -f1
}

# Everything a running Alloy only picks up at start: its config, its launcher
# and the env-defaults helper the launcher sources. A missing file hashes as
# empty.
alloyInputsHash() {
    printf '%s %s %s' \
        "$(fileHash "$INSTALL_DIR/alloy/config.alloy")" \
        "$(fileHash "$INSTALL_DIR/freebsd/launch-alloy.sh")" \
        "$(fileHash "$INSTALL_DIR/freebsd/env-defaults.sh")"
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
    # gettext-runtime (envsubst for bird.conf), bird2, ca_root_nss (TLS
    # trust for fetch/curl/node). libmaxminddb also ships mmdblookup, which
    # scripts/geoip-update.sh uses to verify a downloaded database.
    run pkg install -y \
        curl jq git cmake pcre2 libmaxminddb gettext-runtime \
        bird2 ca_root_nss > /dev/null
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
        pkg install -y node${NODE_TARGET_MAJOR} && $(rerunCommand)"
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
    tar -xpf "$STAGE_DIR/bundle.tar.gz" -C "$STAGE_DIR/tree" || {
        warn "could not extract the release asset"
        return 1
    }
    rm -f "$STAGE_DIR/bundle.tar.gz"
    BUNDLE_TREE="$STAGE_DIR/tree"
}

# installBundleTree SRC DST — puts every entry of the extracted bundle SRC at
# the same path under DST without rewriting any file in place
# (pfoundation/opencache#232). `cp -Rp` used to truncate and rewrite each file
# — same inode — so a script running or being sourced during the copy (the
# every-minute access-log cleanup cron, geoip-update.sh, the anycast.sh and
# env-defaults.sh helpers, this installer) read on from its old offset into
# the new content. Now each file and symlink is RENAMED over the old one:
# rename(2) swaps the directory entry in one step, so a reader that has the
# old file open keeps its old inode to the end, and a new reader only ever
# sees a complete file. SRC must be on DST's filesystem (fetchBundle stages it
# inside the install directory). mv keeps the mode, owner and mtime tar gave
# the file — what cp -p preserved.
#
# A directory DST lacks is renamed in whole, one it has is merged into and
# keeps its own owner, mode and mtime (cp -Rp reset them to the archive's).
# One mv per directory moves all its files, which keeps an upgrade fast (the
# bundle has ~2000 files in ~200 directories). Nothing DST holds that SRC
# lacks is touched — node-local state, and files a later release dropped,
# stay, as they did with cp -Rp. A directory where the bundle has a file or
# symlink, or a file where it has a directory, stops the run.
installBundleTree() {
    ibtSrc="$1"; ibtDst="$2"
    # The directory list is one name per line.
    ibtNl="$(printf '*\n*')"
    if [ -n "$(find "$ibtSrc" -type d -name "$ibtNl" -print 2> /dev/null | head -1)" ]; then
        err "the bundle holds a directory name with a newline — refusing to install it"
        return 1
    fi
    # Listed before anything moves: a directory moved in whole takes its
    # subdirectories along, and they are skipped below.
    ibtDirs="$(find "$ibtSrc" -type d)" || return 1
    ibtMoved=""
    while IFS= read -r ibtDir; do
        if [ -n "$ibtMoved" ]; then
            case "$ibtDir" in "$ibtMoved"/*) continue ;; esac
        fi
        ibtTarget="$ibtDst${ibtDir#"$ibtSrc"}"
        if [ "$ibtDir" != "$ibtSrc" ] && [ ! -e "$ibtTarget" ] && [ ! -L "$ibtTarget" ]; then
            mv -- "$ibtDir" "$ibtTarget" || return 1
            ibtMoved="$ibtDir"
            continue
        fi
        if [ ! -d "$ibtTarget" ]; then
            err "$ibtTarget is not a directory, but the bundle has one there — move it away and re-run"
            return 1
        fi
        set --
        for ibtEntry in "$ibtDir"/* "$ibtDir"/.[!.]* "$ibtDir"/..?*; do
            [ -e "$ibtEntry" ] || [ -L "$ibtEntry" ] || continue
            [ -d "$ibtEntry" ] && [ ! -L "$ibtEntry" ] && continue
            if [ -d "$ibtTarget/${ibtEntry##*/}" ] && [ ! -L "$ibtTarget/${ibtEntry##*/}" ]; then
                err "$ibtTarget/${ibtEntry##*/} is a directory, but the bundle has a file there — move it away and re-run"
                return 1
            fi
            set -- "$@" "$ibtEntry"
            # Well below ARG_MAX, whatever the directory holds.
            if [ $# -ge 256 ]; then
                mv -f -- "$@" "$ibtTarget/" || return 1
                set --
            fi
        done
        if [ $# -gt 0 ]; then
            mv -f -- "$@" "$ibtTarget/" || return 1
        fi
    done << EOF
$ibtDirs
EOF
    ibtDirs=""
    return 0
}

# A stage an interrupted run left behind (the EXIT trap does not run on
# SIGKILL or a power cut).
removeStaleStages() {
    for rssDir in "$INSTALL_DIR/$STAGE_PREFIX".*; do
        if [ -d "$rssDir" ] && [ ! -L "$rssDir" ]; then
            rm -rf -- "$rssDir"
            info "removed $rssDir (left by an interrupted run)"
        fi
    done
    return 0
}

fetchBundle() {
    step "Runtime bundle"

    # What every message prints of it: a URL's user:password@ never is.
    bundleShown="$(redactUserinfo "$BUNDLE_TARBALL")"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$BUNDLE_TARBALL" ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} extract $bundleShown -> $INSTALL_DIR"
        else
            echo "    ${C_YELLOW}dry-run${C_RESET} fetch opencache-${VERSION}.tar.gz from ${INSTALLER_RELEASES_REPO} releases -> $INSTALL_DIR"
        fi
        return 0
    fi

    # Staged INSIDE the install directory: on the filesystem of the files it
    # replaces, so installBundleTree can rename each one into place. umask
    # 022: a new install directory (and a missing /opt) is 0755 whatever the
    # caller's umask — under 002 a group member could replace the scripts
    # root runs. An existing one keeps its mode. (main sets 022 for the whole
    # run; this keeps fetchBundle right on its own.)
    (umask 022; mkdir -p "$INSTALL_DIR")
    removeStaleStages
    STAGE_DIR="$(mktemp -d "$INSTALL_DIR/$STAGE_PREFIX.XXXXXX")"
    if [ -n "$BUNDLE_TARBALL" ]; then
        info "source: $bundleShown"
        case "$BUNDLE_TARBALL" in
            http://* | https://*)
                if ! curl -fsSL -o "$STAGE_DIR/bundle.tar.gz" "$BUNDLE_TARBALL" 2> /dev/null \
                    && ! fetch -qo "$STAGE_DIR/bundle.tar.gz" "$BUNDLE_TARBALL" 2> /dev/null; then
                    die "could not download $bundleShown"
                fi
                localTar="$STAGE_DIR/bundle.tar.gz"
                ;;
            *)
                [ -f "$BUNDLE_TARBALL" ] || die "tarball not found: $bundleShown"
                localTar="$BUNDLE_TARBALL"
                ;;
        esac
        mkdir -p "$STAGE_DIR/tree"
        # -p: the archive's modes, never the umask (root's default anyway).
        tar -xpf "$localTar" -C "$STAGE_DIR/tree" || die "could not extract $bundleShown"
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
    # -L too: a dangling symlink would replace the path as well.
    for p in $PROTECTED_PATHS; do
        if [ -e "$BUNDLE_TREE/$p" ] || [ -L "$BUNDLE_TREE/$p" ]; then
            leaked="$leaked $p"
        fi
    done
    [ -z "$leaked" ] || die "bundle contains protected node-local path(s):$leaked — refusing to extract"

    n="$(find "$BUNDLE_TREE" -type f | wc -l | tr -d ' ')"
    installBundleTree "$BUNDLE_TREE" "$INSTALL_DIR" \
        || die "could not install the bundle into $INSTALL_DIR (the files already moved are the new release's; re-run to finish)"
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

# The node-local directories the config watcher writes into. A missing one is
# created with its mode from the start (mkdir -m), whatever the umask; an
# existing one keeps its own. certs/ (TLS keys, ssl_session_ticket.key) and
# nginx/generated/ (the live config set, which carries every site's
# secureToken.secret) are read by root only — nginx's master loads both at
# config time, its workers never open them — so 0700. env/ is 0755: its one
# secret file, .env.defaults, the watcher creates 0600.
ensureNodeLocalDirs() {
    run mkdir -p -m 0755 "$INSTALL_DIR/env"
    run mkdir -p -m 0700 "$INSTALL_DIR/certs" "$INSTALL_DIR/nginx/generated"
}

# env/ and certs/ as an older install may have left them: an installer run
# under umask 002 made env/ group-writable, and root's launchers source its
# env/.env.* files. On every install and upgrade run group and other WRITE is
# taken off each directory, and off every file and directory in it (chmod
# go-w; symlinks are not followed, read bits stay), with one notice per
# directory naming its old mode. nginx/generated/ is the watcher's to keep
# (pfoundation/opencache#244).
repairNodeLocalModes() {
    for rnmDir in "$INSTALL_DIR/env" "$INSTALL_DIR/certs"; do
        [ -d "$rnmDir" ] || continue
        rnmState="$(dirIdsMode "$rnmDir")"
        rnmWas="$(printf '%s\n' "$rnmState" | awk 'NF == 5 { printf "%04d", $3 }')"
        # The directory itself (-H: also when it is a symlink), then what is
        # in it, never through a symlink.
        rnmList="$(find -H "$rnmDir" \( -type f -o -type d \) \( -perm -0020 -o -perm -0002 \) -print 2> /dev/null)" || rnmList=""
        [ -n "$rnmList" ] || continue
        rnmSelf=0; rnmEntries=0
        while IFS= read -r rnmPath; do
            if [ "$rnmPath" = "$rnmDir" ]; then rnmSelf=1; else rnmEntries=$((rnmEntries + 1)); fi
        done << EOF
$rnmList
EOF
        rnmWhat=""
        [ "$rnmSelf" -eq 0 ] || rnmWhat="the directory (was ${rnmWas:-?})"
        [ "$rnmEntries" -eq 0 ] || rnmWhat="${rnmWhat:+$rnmWhat and }$rnmEntries entr$([ "$rnmEntries" -eq 1 ] && echo y || echo ies) in it"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} chmod go-w $rnmDir: $rnmWhat" >&2
            continue
        fi
        rnmFailed=0
        while IFS= read -r rnmPath; do
            [ -e "$rnmPath" ] || continue
            chmod go-w "$rnmPath" 2> /dev/null || rnmFailed=1
        done << EOF
$rnmList
EOF
        if [ "$rnmFailed" -eq 0 ]; then
            warn "$rnmDir: group/other write taken off $rnmWhat — root sources and reads files from it, so only root may write there"
        else
            warn "could not take group/other write off everything in $rnmDir ($rnmWhat) — run: chmod -R go-w $rnmDir"
        fi
    done
    rnmList=""
    return 0
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
    ensureNodeLocalDirs
    repairNodeLocalModes
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

    repairRootOwnedDirs
    run mkdir -p /var/log/nginx /var/run/nginx
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p /var/cache/nginx
        chown nginx:nginx /var/cache/nginx /var/log/nginx /var/run/nginx 2> /dev/null || true
    fi
    ensureNginxLogDirs

    ok "nginx ready: $($NGINX_BIN -v 2>&1 || echo 'not built (dry-run)')"
}

# The per-property access logs (/var/log/nginx/access/<rid>.<HOUR>.log) and
# nginx's default document root. A log path with variables is opened per
# request, by the worker, and nginx DROPS the line — silently — when the
# request's root directory is missing; the default root is /etc/nginx/html
# (prefix /etc/nginx), which only `make install` creates. rc.d/opencache_nginx
# re-checks both on every start. OC_ACCESS_LOG_DIR / OC_NGINX_HTML_DIR
# override the paths (tests).
accessLogDirPath() { echo "${OC_ACCESS_LOG_DIR:-/var/log/nginx/access}"; }
nginxHtmlDirPath() { echo "${OC_NGINX_HTML_DIR:-/etc/nginx/html}"; }

ensureNginxLogDirs() {
    enlAccess="$(accessLogDirPath)"
    enlHtml="$(nginxHtmlDirPath)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} install -d -o nginx -g nginx -m 0755 $enlAccess" >&2
        [ -d "$enlHtml" ] || echo "    ${C_YELLOW}dry-run${C_RESET} mkdir -p $enlHtml" >&2
        return 0
    fi
    if mkdir -p "$enlAccess" && chmod 0755 "$enlAccess"; then
        chown nginx:nginx "$enlAccess" 2> /dev/null \
            || warn "could not chown $enlAccess to nginx:nginx — nginx cannot write the per-property access logs"
        info "access logs: $enlAccess"
    else
        warn "could not create $enlAccess — nginx cannot write the per-property access logs"
    fi
    if [ ! -d "$enlHtml" ]; then
        if mkdir -p "$enlHtml"; then
            info "created $enlHtml (nginx drops access-log lines without it)"
        else
            warn "could not create $enlHtml — nginx DROPS the access-log line of every request without its own root until it exists"
        fi
    fi
}

# ── Root-owned system directories ────────────────────────────────────────────
# /var/log and /var/run must stay root:wheel and writable by root only (FreeBSD
# ships them root:wheel 0755). The config watcher's staged validation used to
# chown the PARENT of every directory a generated config references to the
# nginx worker (pfoundation/opencache#203), which handed it /var/run (parent of
# the tier-hop socket dir /var/run/nginx) and /var/log (parent of
# /var/log/nginx): a compromised worker could then replace or delete system
# logs and pid files. Repaired on every install and upgrade, back to
# root:wheel 0755 — only when wrong, so a root:wheel directory that is not
# group/other-writable keeps its mode. scripts/health-check.sh applies the same
# rule (test-guarded). Cache disk mount points are deliberately NOT listed:
# scanCacheDisks hands /mnt/nvme-<i> and /mnt/hdd-<i> to nginx on purpose.
# OC_ROOT_OWNED_DIRS overrides the list (tests).
rootOwnedDirs() { echo "${OC_ROOT_OWNED_DIRS:-/var/log /var/run}"; }

# "<uid> <gid> <mode> <owner> <group>" of a directory (or file — .env:
# secureEnvFile), symlinks followed, or
# nothing when unreadable; the mode keeps its special bits (%Mp%Lp, %a). FreeBSD
# stat -f; GNU stat -c (tests) — GNU stat also takes -f (file-system status),
# so an answer counts only in this shape.
dirIdsMode() {
    dim=$(stat -L -f '%u %g %Mp%Lp %Su %Sg' "$1" 2> /dev/null) || dim=""
    idsModeShape "$dim" || dim=$(stat -L -c '%u %g %a %U %G' "$1" 2> /dev/null) || dim=""
    idsModeShape "$dim" || dim=""
    printf '%s' "$dim"
}
idsModeShape() {
    printf '%s\n' "$1" | awk 'NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-7]+$/ { n++ } END { exit !(n == 1 && NR == 1) }'
}
# Exit 0 when a dirIdsMode answer is uid 0, gid 0 and writable by its owner
# only.
rootOnlyDir() {
    printf '%s\n' "$1" | awk '{
        m = sprintf("%04d", $3)
        g = substr(m, 3, 1); o = substr(m, 4, 1)
        exit !($1 == 0 && $2 == 0 && int(g / 2) % 2 == 0 && int(o / 2) % 2 == 0)
    }'
}

repairRootOwnedDirs() {
    for rod in $(rootOwnedDirs); do
        [ -d "$rod" ] || continue
        rodState="$(dirIdsMode "$rod")"
        if [ -z "$rodState" ]; then
            warn "could not read the owner and mode of $rod — it must be root:wheel 0755"
            continue
        fi
        rootOnlyDir "$rodState" && continue
        rodWas="$(printf '%s\n' "$rodState" | awk '{ printf "%s:%s %04d", $4, $5, $3 }')"
        if run chown root:wheel "$rod" && run chmod 0755 "$rod"; then
            [ "$DRY_RUN" -eq 1 ] || ok "$rod repaired to root:wheel 0755 (was $rodWas — a non-root user could replace or delete the system logs and pid files in it)"
        else
            warn "could not repair $rod (it is $rodWas) — run: chown root:wheel $rod && chmod 0755 $rod"
        fi
    done
}

# ── .env ─────────────────────────────────────────────────────────────────────
seedEnv() {
    step "Configuration (.env)"

    if [ ! -f "$ENV_FILE" ]; then
        ENV_WAS_CREATED=1
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    ${C_YELLOW}dry-run${C_RESET} create $ENV_FILE from .env.example"
        else
            # Created 0600 (umask 077), not chmod'ed after: a reader that
            # opened it while it was 0644 would keep reading it, BAAS_TOKEN
            # included, once setEnvKv writes it. The chmod only narrows an
            # odd archive mode (the copy takes .env.example's, minus 077).
            (umask 077; cp "$INSTALL_DIR/.env.example" "$ENV_FILE")
            chmod 600 "$ENV_FILE"
            ok "created $ENV_FILE from .env.example (mode 0600)"
        fi
    else
        ok "$ENV_FILE exists — existing values preserved"
    fi
    # Before anything is written to it.
    secureEnvFile \
        || die "could not make $ENV_FILE private (owner $(id -un 2> /dev/null || id -u), mode 0600) — nothing was written to it; fix it by hand and re-run"

    setEnvFromFlag "$ENV_FILE" POP_ID                   "$OPT_POP_ID"
    setEnvFromFlag "$ENV_FILE" BAAS_HOST                "$OPT_BAAS_HOST"
    setEnvFromFlag "$ENV_FILE" BAAS_TOKEN               "$OPT_BAAS_TOKEN"
    setEnvFromFlag "$ENV_FILE" BAAS_VERSION             "$OPT_BAAS_VERSION"
    setEnvFromFlag "$ENV_FILE" BAAS_PROJECT_ID          "$OPT_BAAS_PROJECT_ID"
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_URL         "$OPT_LOGS_PUSH_URL"
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_USER        "$OPT_LOGS_PUSH_USER"
    setEnvFromFlag "$ENV_FILE" OC_LOGS_PUSH_PASSWORD    "$OPT_LOGS_PUSH_PASSWORD"

    promptForRequired
    warnBaasHostProblem
}

# .env holds BAAS_TOKEN and the push credentials. On every install and
# upgrade run, before anything is written to it, it is made the file of the
# user running the installer (root: preflight) and mode 0600 — an operator's
# 0644 copy, or one owned by another user, used to keep its mode while the
# installer wrote BAAS_TOKEN into it. The notice names the old owner and
# mode, never a value. Returns 1 when that could not be done.
secureEnvFile() {
    [ -f "$ENV_FILE" ] || return 0
    sefState="$(dirIdsMode "$ENV_FILE")"
    if [ -z "$sefState" ]; then
        warn "could not read the owner and mode of $ENV_FILE"
        return 1
    fi
    read -r sefUid _ sefMode sefOwner sefGroup << EOF
$sefState
EOF
    sefWant="$(id -u)"
    sefWantName="$(id -un 2> /dev/null || echo "uid $sefWant")"
    if [ "$sefUid" = "$sefWant" ] && [ "$((0$sefMode))" -eq "$((0600))" ]; then
        return 0
    fi
    sefWas="$(printf '%s:%s %04o' "$sefOwner" "$sefGroup" "$((0$sefMode))")"
    if [ "$DRY_RUN" -eq 1 ]; then
        [ "$sefUid" = "$sefWant" ] \
            || echo "    ${C_YELLOW}dry-run${C_RESET} chown $sefWant $ENV_FILE (owned by $sefOwner)" >&2
        echo "    ${C_YELLOW}dry-run${C_RESET} chmod 600 $ENV_FILE (now $sefWas)" >&2
        return 0
    fi
    if [ "$sefUid" != "$sefWant" ]; then
        chown "$sefWant" "$ENV_FILE" || return 1
    fi
    chmod 600 "$ENV_FILE" || return 1
    warn "$ENV_FILE was $sefWas — now owned by $sefWantName, mode 0600: it holds BAAS_TOKEN, nobody else may read it"
    return 0
}

# A BAAS_HOST already in .env that the runtime refuses (baasHostProblem),
# read as the launchers read it (sourced, then trimmed): said by name, never
# the value.
warnBaasHostProblem() {
    wbhProblem=""
    if loadEffectiveEnvValue BAAS_HOST; then
        wbhValue="$(trimSpace "$EEV_VALUE")"
        EEV_VALUE=""
        [ -z "$wbhValue" ] || wbhProblem="$(baasHostProblem "$wbhValue")"
        wbhValue=""
    fi
    if [ -n "$wbhProblem" ]; then
        warn "BAAS_HOST in $ENV_FILE $wbhProblem — the config watcher and prefix-monitor cannot use it; set the plain origin there (its value is not shown)"
    fi
    return 0
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
        pfrHow=""
        if [ "$key" = BAAS_TOKEN ]; then pfrHow=secret; fi
        val="$(promptValue "$key is required$hint — enter value" "$pfrHow")" || val=""
        if [ "$key" = BAAS_HOST ] && [ -n "$val" ]; then
            val="$(trimSpace "$val")"
            pfrProblem="$(baasHostProblem "$val")"
            if [ -n "$pfrProblem" ]; then
                warn "BAAS_HOST $pfrProblem — not set (its value is not shown)"
                val=""
            fi
        fi
        if [ -n "$val" ]; then
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
    # -m is for certs itself; its parent is the install directory.
    # shellcheck disable=SC2174
    mkdir -p -m 0700 "$certsDir"
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

    # Its own mktemp: "$tmp.rest" was a name anyone who saw $tmp appear in
    # /tmp could create first, as a symlink root would then write through.
    rest="$(mktemp)"
    if [ -f "$f" ]; then
        awk '/^# BEGIN opencache-managed/{skip=1} skip==0{print} /^# END opencache-managed/{skip=0}' "$f" > "$rest"
    fi
    cat "$rest" "$tmp" > "$f"
    rm -f "$tmp" "$rest"

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

    # Its own mktemp: "$tmp.rest" was a name anyone who saw $tmp appear in
    # /tmp could create first, as a symlink root would then write through.
    rest="$(mktemp)"
    if [ -f "$f" ]; then
        awk '/^# BEGIN opencache-managed/{skip=1} skip==0{print} /^# END opencache-managed/{skip=0}' "$f" > "$rest"
    fi
    cat "$rest" "$tmp" > "$f"
    rm -f "$tmp" "$rest"

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

# ── Time sync (NTP) ──────────────────────────────────────────────────────────
# TLS validity, cache freshness/age math and every log and metric timestamp
# ride on the wall clock, and nothing else in the stack keeps it right. Base
# ntpd is used — it ships with FreeBSD, so there is no package to fetch — with
# the stock /etc/ntp.conf (FreeBSD pool, modify/query refused).
#
# Deliberately conservative on a host someone else already set up:
#   * a chronyd or openntpd the hosting provider enabled is LEFT IN CHARGE —
#     two daemons disciplining one clock fight each other;
#   * an existing /etc/ntp.conf is never rewritten (a provider may point it at
#     their own servers); one is written only when the file is missing;
#   * a running ntpd is never restarted.
#
# ntpd_sync_on_start=YES makes rc.d/ntpd pass -g, so a clock that is far off
# at boot is STEPPED once instead of ntpd refusing to correct it.

# Sets CLOCK_DAEMON (ntpd|chronyd|openntpd|none), CLOCK_SYNCED
# (yes|no|unknown) and CLOCK_OFFSET_MS (empty when not reported; positive =
# local clock behind). Read-only. Same logic as scripts/health-check.sh.
readClockState() {
    CLOCK_DAEMON=none; CLOCK_SYNCED=unknown; CLOCK_OFFSET_MS=""

    if pgrep -x chronyd > /dev/null 2>&1; then
        CLOCK_DAEMON=chronyd
        rec="$(chronyc -c tracking 2> /dev/null | head -1)"
        [ -n "$rec" ] || return 0
        if printf '%s\n' "$rec" | awk -F, '$14 == "Not synchronised" || $3 + 0 == 0 { exit 0 } { exit 1 }'; then
            CLOCK_SYNCED=no
        else
            CLOCK_SYNCED=yes
            CLOCK_OFFSET_MS="$(printf '%s\n' "$rec" | awk -F, '{ printf "%.3f", $5 * 1000 }')"
        fi
        return 0
    fi

    # base ntpd and OpenNTPD share the process name.
    if pgrep -x ntpd > /dev/null 2>&1; then
        CLOCK_DAEMON=ntpd
        rv="$(ntpq -c rv 2> /dev/null || true)"
        stratum="$(printf '%s\n' "$rv" | tr ',' '\n' | sed -n 's/^[[:space:]]*stratum=\([0-9][0-9]*\).*/\1/p' | head -1)"
        if [ -n "$stratum" ]; then
            if [ "$stratum" -ge 16 ] || printf '%s\n' "$rv" | grep -qE 'leap_alarm|sync_unspec'; then
                CLOCK_SYNCED=no
            else
                CLOCK_SYNCED=yes
                CLOCK_OFFSET_MS="$(printf '%s\n' "$rv" | tr ',' '\n' | sed -n 's/^[[:space:]]*offset=\([-+0-9.][0-9.]*\).*/\1/p' | head -1)"
            fi
            return 0
        fi
        if st="$(ntpctl -s status 2> /dev/null)"; then
            CLOCK_DAEMON=openntpd
            case "$st" in
                *"clock synced"*) CLOCK_SYNCED=yes ;;
                *"clock unsynced"*) CLOCK_SYNCED=no ;;
            esac
        fi
        return 0
    fi

    # No daemon: the kernel's own discipline state (code 5 = TIME_ERROR).
    if command -v ntptime > /dev/null 2>&1; then
        case "$(ntptime 2> /dev/null || true)" in
            *"returns code 5"*) CLOCK_SYNCED=no ;;
            *"returns code "[0-4]*) CLOCK_SYNCED=yes ;;
        esac
    fi
}

# rc.conf enable knob for a daemon, normalised to YES or empty.
rcEnabled() {
    case "$(sysrc -n "${1}_enable" 2> /dev/null)" in
        [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee] | [Oo][Nn] | 1) echo YES ;;
    esac
}

describeClock() {
    case "$CLOCK_SYNCED" in
        yes) echo "synchronised ($CLOCK_DAEMON${CLOCK_OFFSET_MS:+, offset ${CLOCK_OFFSET_MS} ms})" ;;
        no) echo "NOT synchronised ($CLOCK_DAEMON)" ;;
        *) echo "sync state unreadable ($CLOCK_DAEMON)" ;;
    esac
}

configureNtp() {
    step "Time sync (NTP)"

    if [ "$SKIP_NTP" -eq 1 ]; then
        info "skipped (--skip-ntp)"
        return 0
    fi

    other=""
    [ -n "$(rcEnabled chronyd)" ] && other="chronyd"
    [ -n "$(rcEnabled openntpd)" ] && other="${other:+$other, }openntpd"
    if [ -n "$other" ]; then
        info "$other is enabled in rc.conf — leaving time sync to it (base ntpd not enabled)"
        if [ -n "$(rcEnabled ntpd)" ]; then
            warn "ntpd_enable=YES as well — two daemons will fight over the clock. Keep one: sysrc ntpd_enable=NO && service ntpd stop"
        fi
    else
        if [ ! -x /usr/sbin/ntpd ]; then
            warn "/usr/sbin/ntpd is missing (world built WITHOUT_NTP?) — NOT configuring time sync. Install and enable net/chrony instead."
            return 0
        fi

        if [ ! -f /etc/ntp.conf ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    ${C_YELLOW}dry-run${C_RESET} write /etc/ntp.conf (FreeBSD default: pool 0.freebsd.pool.ntp.org)" >&2
            else
                cat > /etc/ntp.conf <<- 'EOF'
				# Written by install-freebsd.sh because /etc/ntp.conf was missing.
				# Mirrors the FreeBSD default; edit freely — it is never overwritten.
				tos minclock 3 maxclock 6
				pool 0.freebsd.pool.ntp.org iburst
				restrict default limited kod nomodify notrap noquery nopeer
				restrict source  limited kod nomodify notrap noquery
				restrict 127.0.0.1
				restrict ::1
				leapfile "/var/db/ntpd.leap-seconds.list"
				EOF
                ok "/etc/ntp.conf was missing — wrote the FreeBSD default"
            fi
        else
            info "/etc/ntp.conf present — left as is"
        fi

        run sysrc -q ntpd_enable=YES > /dev/null
        run sysrc -q ntpd_sync_on_start=YES > /dev/null
        ok "ntpd enabled in rc.conf (ntpd_sync_on_start=YES)"

        if service ntpd status > /dev/null 2>&1; then
            ok "ntpd already running — not restarted"
        else
            info "starting ntpd (a clock that is far off is stepped once)"
            svc start ntpd
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: would wait up to 60s for the clock to synchronise"
        return 0
    fi

    # ntpd reports unsynchronised until its first clock update — with iburst
    # against the pool that is typically 10-40s. Not fatal either way: the
    # node serves regardless, and health-check.sh / prefix-monitor keep
    # watching.
    i=0
    while :; do
        readClockState
        [ "$CLOCK_SYNCED" = "yes" ] && break
        [ "$i" -ge 60 ] && break
        sleep 5; i=$((i + 5))
    done
    if [ "$CLOCK_SYNCED" = "yes" ]; then
        ok "clock $(describeClock)"
    else
        warn "clock $(describeClock) after ${i}s — normal right after ntpd starts; re-check with scripts/health-check.sh. If it persists, check that outbound UDP 123 is not filtered upstream: ntpq -p"
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
    # $1 = username, $2 = home dir, $3 = file holding candidate keys. Sets
    # AKU_KEYS to the number of those keys the user now has.
    user="$1"; home="$2"; keysFile="$3"
    added=0; present=0
    sshDir="$home/.ssh"; auth="$sshDir/authorized_keys"
    # -m is for .ssh itself; its parent is the home directory.
    # shellcheck disable=SC2174
    mkdir -p -m 0700 "$sshDir"; chmod 700 "$sshDir"
    [ -f "$auth" ] || (umask 077; touch "$auth")
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
    AKU_KEYS=$((added + present))
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

    AKU_KEYS=0
    appendKeysToUser root /root "$keysFile"
    # A variable, not a "$keysFile.count" file: that name was one anyone who
    # saw $keysFile appear in /tmp could create first, as a symlink.
    rootKeys="$AKU_KEYS"

    # The user who invoked the installer via sudo/doas, when resolvable.
    invoker="${SUDO_USER:-${DOAS_USER:-}}"
    if [ -n "$invoker" ] && [ "$invoker" != "root" ]; then
        invokerHome="$(getent passwd "$invoker" | cut -d: -f6)"
        if [ -n "$invokerHome" ] && [ -d "$invokerHome" ]; then
            appendKeysToUser "$invoker" "$invokerHome" "$keysFile"
        fi
    fi
    rm -f "$keysFile"

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
# The GeoLite2 databases come from the OpenCache mirror through the BaaS API
# (scripts/geoip-update.sh, with the node's own BAAS_* credentials); a node
# never talks to MaxMind and holds no MaxMind credentials. The mirror refreshes
# daily at 05:00 UTC, so the cron runs daily at 06:MM — MM fixed per PoP from
# POP_ID so the fleet does not fetch in the same minute. FreeBSD cron has no
# `~` random field, hence the computed minute. The updater is version-gated by
# the mirror's manifest: an unchanged mirror costs one request.
#
# OC_GEOIP_CONF / OC_GEOIP_CRON override the paths of the retired
# geoipupdate files (as in scripts/health-check.sh); OC_GEOIP_UPDATE_CRON the
# new cron file.
geoipCronPath() { echo "${OC_GEOIP_UPDATE_CRON:-/usr/local/etc/cron.d/opencache-geoip}"; }

geoipCronMinute() {
    gcmSeed="$(envValue "$ENV_FILE" POP_ID)"
    [ -n "$gcmSeed" ] || gcmSeed="$(hostname 2> /dev/null || echo opencache)"
    echo $(( $(printf '%s' "$gcmSeed" | cksum | awk '{print $1}') % 60 ))
}

renderGeoipCron() {
    printf '%s\n' \
        '# OpenCache — refresh the GeoLite2 databases from the OpenCache mirror (BaaS API), daily.' \
        '# The mirror updates at 05:00 UTC; the minute is fixed per PoP. Version-gated: an' \
        '# unchanged mirror costs one manifest request. Log: /var/log/opencache/geoip-update.log' \
        "${1:?minute} 6 * * * root ${2:?install dir}/scripts/geoip-update.sh --quiet > /dev/null 2>&1"
}

# Retire the per-node geoipupdate setup: its package, its weekly cron and
# GeoIP.conf, which held the MaxMind license key. Idempotent; runs on every
# install and upgrade.
removeLegacyGeoipupdate() {
    legacyConf="${OC_GEOIP_CONF:-/usr/local/etc/GeoIP.conf}"
    legacyCron="${OC_GEOIP_CRON:-/usr/local/etc/cron.d/opencache-geoipupdate}"

    if pkg info -e geoipupdate > /dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            run pkg delete -y geoipupdate
        elif pkg delete -y geoipupdate > /dev/null 2>&1; then
            ok "removed the retired geoipupdate package"
        else
            warn "could not remove the geoipupdate package — remove it by hand: pkg delete -y geoipupdate"
        fi
    fi
    # After the pkg delete: pkg keeps a GeoIP.conf that differs from its sample.
    for f in "$legacyCron" "$legacyConf"; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        run rm -f "$f"
        [ "$DRY_RUN" -eq 1 ] || ok "removed $f (retired geoipupdate setup)"
    done
}

configureGeoip() {
    step "GeoIP"

    removeLegacyGeoipupdate
    # Read by nothing any more: GeoIP rides on BAAS_HOST/BAAS_TOKEN.
    if [ -n "${GEOIP_ACCOUNT_ID:-}${GEOIP_LICENSE_KEY:-}" ]; then
        info "GEOIP_ACCOUNT_ID / GEOIP_LICENSE_KEY in the environment are ignored (GeoIP comes from the OpenCache mirror via the BaaS API)"
    fi
    if [ -n "$(envValue "$ENV_FILE" GEOIP_ACCOUNT_ID)$(envValue "$ENV_FILE" GEOIP_LICENSE_KEY)" ]; then
        info "GEOIP_ACCOUNT_ID / GEOIP_LICENSE_KEY in $ENV_FILE are no longer used (GeoIP comes from the OpenCache mirror) — they can be removed"
    fi

    # /usr/local/share/GeoIP and its /usr/share/GeoIP symlink: installNginx.
    geoipScript="$INSTALL_DIR/scripts/geoip-update.sh"
    geoipCron="$(geoipCronPath)"
    geoipMinute="$(geoipCronMinute)"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write $geoipCron (daily 06:$(printf '%02d' "$geoipMinute"), $geoipScript --quiet)"
        echo "    ${C_YELLOW}dry-run${C_RESET} run $geoipScript (fetches only editions that changed on the mirror)"
        return 0
    fi

    mkdir -p "$(dirname "$geoipCron")"
    geoipTmp="$(mktemp "$geoipCron.XXXXXX")" || die "could not create a temp file for $geoipCron"
    if ! renderGeoipCron "$geoipMinute" "$INSTALL_DIR" > "$geoipTmp" \
        || ! chmod 644 "$geoipTmp" \
        || ! mv -f "$geoipTmp" "$geoipCron"; then
        rm -f "$geoipTmp"
        die "could not write $geoipCron"
    fi
    ok "daily GeoIP update cron at 06:$(printf '%02d' "$geoipMinute") ($geoipCron)"

    if [ ! -f "$geoipScript" ]; then
        warn "$geoipScript is missing from the bundle — nginx uses the GeoIP fallback config"
        return 0
    fi
    [ -x "$geoipScript" ] || warn "$geoipScript is not executable — the cron cannot run it"

    # A failure (BaaS unreachable, BAAS_* not set yet) is not fatal: nginx
    # starts on the GeoIP fallback config and the cron retries daily.
    info "fetching GeoLite2 databases from the OpenCache mirror"
    if /bin/sh "$geoipScript" --quiet < /dev/null; then
        ok "GeoIP databases up to date in /usr/local/share/GeoIP"
    else
        warn "GeoIP update failed — nginx uses the fallback config until it succeeds (see /var/log/opencache/geoip-update.log; retry: $geoipScript --force)"
    fi
}

# ── Access-log cleanup ───────────────────────────────────────────────────────
# nginx writes one access log per property per UTC hour and never rotates it;
# scripts/access-log-cleanup.sh, run every minute, deletes each file once
# Alloy has shipped it (by Alloy's saved positions) — or LOG_ROTATE_KEEP hours
# after its hour ended when the shipping marker says nothing ships — and
# deletes finished files oldest first when the log filesystem drops under 10%
# free. Runs are serialised by lockf in the script. newsyslog rotates its log
# (BN). OC_ACCESS_LOG_CLEANUP_CRON overrides the cron file path (tests).
accessLogCronPath() { echo "${OC_ACCESS_LOG_CLEANUP_CRON:-/usr/local/etc/cron.d/opencache-access-logs}"; }

renderAccessLogCron() {
    printf '%s\n' \
        '# OpenCache — delete the per-property access logs once Alloy shipped them (or' \
        '# LOG_ROTATE_KEEP hours after their hour when nothing ships); keep the log disk' \
        '# above the free-space floor. State: /var/db/opencache/access-logs-state.json' \
        "* * * * * root /bin/sh ${1:?install dir}/scripts/access-log-cleanup.sh >> /var/log/opencache/access-log-cleanup.log 2>&1"
}

configureAccessLogCleanup() {
    step "Access-log cleanup"

    alcScript="$INSTALL_DIR/scripts/access-log-cleanup.sh"
    alcCron="$(accessLogCronPath)"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write $alcCron (every minute, $alcScript)"
        return 0
    fi

    mkdir -p "$(dirname "$alcCron")"
    alcTmp="$(mktemp "$alcCron.XXXXXX")" || die "could not create a temp file for $alcCron"
    if ! renderAccessLogCron "$INSTALL_DIR" > "$alcTmp" \
        || ! chmod 644 "$alcTmp" \
        || ! mv -f "$alcTmp" "$alcCron"; then
        rm -f "$alcTmp"
        die "could not write $alcCron"
    fi
    ok "access-log cleanup cron every minute ($alcCron; log /var/log/opencache/access-log-cleanup.log)"

    [ -f "$alcScript" ] \
        || warn "$alcScript is missing from the bundle — access logs are never deleted and will fill the disk"
}

# The shipping marker the access-log cleanup reads: `yes` while Alloy ships
# (the Alloy launcher writes it at every start), anything else = nothing
# ships, so access logs are kept LOG_ROTATE_KEEP hours instead of waiting for
# Alloy to read them. Written `no` here when Alloy is not enabled at all.
logShippingMarkerPath() { echo "${OC_LOG_SHIPPING_MARKER:-/var/db/opencache/log-shipping}"; }

markLogShippingOff() {
    lsmFile="$(logShippingMarkerPath)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} write 'no' to $lsmFile" >&2
        return 0
    fi
    if mkdir -p "$(dirname "$lsmFile")" && printf 'no\n' > "$lsmFile"; then
        info "log shipping marker $lsmFile: no (access logs kept LOG_ROTATE_KEEP hours)"
    else
        warn "could not write $lsmFile — the access-log cleanup may wait for an Alloy that never runs"
    fi
}

# ── Hostname ─────────────────────────────────────────────────────────────────
# The host's hostname follows nodeConfig.serverName, which the config watcher
# writes as SERVER_NAME to env/.env.prefix-monitor. It is the node's identity
# downstream: Alloy stamps it as the `instance` label on every log line and
# metric (read once, at Alloy start) and nginx exposes it as $hostname (re-read
# on reload/restart). Both the running hostname and rc.conf's are set, so a
# reboot keeps it. Never fatal: a jail that may not set its own hostname only
# warns. --skip-hostname opts out.

# Prints SERVER_NAME from an env file WITHOUT sourcing it: the last assignment
# wins, as it would when sourced, minus one pair of surrounding quotes (the
# watcher quotes shell-significant values; a valid hostname is always bare).
serverNameFromEnv() {
    [ -f "${1:-}" ] || return 0
    snfValue="$(grep '^SERVER_NAME=' "$1" 2> /dev/null | tail -n 1 | sed 's/^SERVER_NAME=//' || true)"
    case "$snfValue" in
        \"*\" | \'*\') snfValue="${snfValue#?}"; snfValue="${snfValue%?}" ;;
    esac
    printf '%s' "$snfValue"
}

# RFC 1123 host name: 1..253 characters, dot-separated labels of 1..63
# letters, digits and hyphens, none starting or ending with a hyphen. No
# trailing dot. Letters are spelled out: a bracket range is locale-dependent.
validHostname() {
    vhName="${1:-}"
    [ "${#vhName}" -ge 1 ] && [ "${#vhName}" -le 253 ] || return 1
    case "$vhName" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-]* | \
        .* | *. | *..* | -* | *- | *.-* | *-.*)
            return 1 ;;
    esac
    vhRest="$vhName"
    while :; do
        vhLabel="${vhRest%%.*}"
        [ "${#vhLabel}" -le 63 ] || return 1
        [ "$vhLabel" != "$vhRest" ] || return 0
        vhRest="${vhRest#*.}"
    done
}

syncHostname() {
    if [ "$SKIP_HOSTNAME" -eq 1 ]; then
        info "hostname sync skipped (--skip-hostname)"
        return 0
    fi

    shEnvFile="$INSTALL_DIR/env/.env.prefix-monitor"
    shName="$(serverNameFromEnv "$shEnvFile" || true)"
    if [ -z "$shName" ]; then
        info "hostname not managed: no nodeConfig.serverName in $shEnvFile yet — the next --upgrade syncs it"
        return 0
    fi
    shCur="$(hostname 2> /dev/null || true)"
    if ! validHostname "$shName"; then
        warn "hostname: nodeConfig.serverName '$shName' is not a valid hostname — left as ${shCur:-(empty)}"
        return 0
    fi

    shInSync=1
    if [ "$shCur" != "$shName" ]; then
        shInSync=0
        shOut=""
        if [ "$DRY_RUN" -eq 1 ]; then
            run hostname "$shName"
        elif shOut="$(run hostname "$shName" 2>&1)" \
            && [ "$(hostname 2> /dev/null || true)" = "$shName" ]; then
            ok "hostname: ${shCur:-(empty)} -> $shName (nodeConfig.serverName)"
            HOSTNAME_CHANGED=1
        else
            shOut="$(printf '%s\n' "$shOut" | head -n 1)"
            shCur="$(hostname 2> /dev/null || true)"
            warn "hostname: could not set the running hostname to $shName${shOut:+ ($shOut)} — still ${shCur:-(empty)} (in a jail, the host sets it)"
        fi
        shOut=""
    fi

    if ! command -v sysrc > /dev/null 2>&1; then
        warn "hostname: sysrc not found — rc.conf not updated, $shName does not survive a reboot"
        return 0
    fi
    shRc="$(sysrc -n hostname 2> /dev/null || true)"
    if [ "$shRc" != "$shName" ]; then
        shInSync=0
        if [ "$DRY_RUN" -eq 1 ]; then
            run sysrc -q hostname="$shName" > /dev/null
        elif run sysrc -q hostname="$shName" > /dev/null \
            && [ "$(sysrc -n hostname 2> /dev/null || true)" = "$shName" ]; then
            ok "hostname: rc.conf hostname=$shName (kept across reboots)"
        else
            warn "hostname: could not persist $shName in rc.conf — the next boot may revert it; set it by hand: sysrc hostname=$shName"
        fi
    fi

    if [ "$shInSync" -eq 1 ]; then
        ok "hostname already matches nodeConfig.serverName ($shName)"
    fi
    return 0
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
    # Re-adds the content-class aliases at boot from the list the watcher
    # writes (/var/db/opencache/class-addresses.list); a no-op without one.
    # The aliases themselves never go into rc.conf.
    run sysrc -q opencache_addresses_enable=YES > /dev/null
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
        markLogShippingOff
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
    # mktemp: 0600 at a name nobody can create first — the fixed
    # opencache-svc.<pid>.log could be planted as a symlink for root to write
    # through. Without one the output is not kept.
    if ! svcLog="$(mktemp "${TMPDIR:-/tmp}/opencache-svc.XXXXXX" 2> /dev/null)"; then
        warn "could not create a temp file for the output of service $name $action — it is not shown"
        service "$name" "$action" < /dev/null > /dev/null 2>&1 \
            || warn "service $name $action FAILED"
        return 0
    fi
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
        syncHostname
        info "skipped (--no-deploy)"
        info "start later with: service opencache_bird start; service opencache_watcher start; …"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        syncHostname
        echo "    ${C_YELLOW}dry-run${C_RESET} start class addresses, bird, watcher (initial config generation), nginx, monitor, exporter, alloy"
        return 0
    fi

    # ORDER IS LOAD-BEARING. The watcher's first cycle produces BOTH the
    # initial config set (nginx wants it before first start) AND the
    # nodeConfig-derived env files — env/.env.bird in particular, without
    # which opencache_bird renders an EMPTY bird.conf (envsubst substitutes
    # blanks) and BIRD exits on a parse error. Starting bird before the
    # watcher is exactly the first-deploy bug this ordering fixes.
    #
    # RESTART, not start: on a re-run the watcher may already be running, and
    # it keeps the .env (BAAS_*, POP_ID) and the code it started with — it
    # retries a failing BaaS instead of exiting. rc.subr's restart ignores a
    # failed stop, so on a fresh install this is a plain start.
    svc restart opencache_watcher
    info "waiting for the first generated config set (up to 180s)…"
    i=0
    while [ "$i" -lt 180 ]; do
        [ -n "$(find "$INSTALL_DIR/nginx/generated" -maxdepth 1 -name '*.conf' 2> /dev/null | head -1)" ] && break
        i=$((i + 5)); sleep 5
    done
    if [ "$i" -ge 180 ]; then
        warn "no generated configs after 180s — check: tail -50 /var/log/opencache/watcher.log"
        warn "(BAAS_HOST/BAAS_TOKEN/BAAS_VERSION/POP_ID wrong or unreachable is the usual cause)"
        warn "fix $ENV_FILE, then: service opencache_watcher restart"
    else
        ok "config set generated after ${i}s"
    fi

    # The watcher's first cycle has just written SERVER_NAME; nginx and Alloy
    # read the hostname when they start, so it must be right before they do.
    syncHostname

    # Before bird and nginx, like at boot. Idempotent: it only adds listed
    # class aliases that are missing (the watcher's first cycle has usually
    # added them already); without a list it does nothing.
    svc start opencache_addresses

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

    readClockState
    if [ "$CLOCK_SYNCED" = "yes" ]; then
        ok "clock $(describeClock)"
    elif [ "$SKIP_NTP" -eq 1 ] && [ "$CLOCK_DAEMON" = "none" ]; then
        warn "no time daemon running (--skip-ntp) — the clock is not being kept in sync"
    else
        warn "clock $(describeClock) — re-check with scripts/health-check.sh"
    fi
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
    # An upgrade writes nothing to .env, so a failure only warns.
    secureEnvFile \
        || warn "could not make $ENV_FILE private (owner $(id -un 2> /dev/null || id -u), mode 0600) — it holds BAAS_TOKEN; fix it by hand"
    warnBaasHostProblem

    ALLOY_INPUTS_HASH_BEFORE="$(alloyInputsHash)"

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
    configureNtp
    scanCacheDisks
    configureSsh
    configurePf
    # .env (BAAS_*) is the existing install's; rc.d is fresh from installServices.
    configureGeoip
    configureAccessLogCleanup
    syncHostname

    step "Restarting services"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    ${C_YELLOW}dry-run${C_RESET} start class addresses; restart watcher/monitor/exporter/birdwatcher; re-check /var/log and /var/run once the old watcher is gone; nginx restart-or-reload; alloy if its config or launcher changed, or the hostname did"
    else
        # Only adds listed class aliases that are missing; never removes one.
        svc start opencache_addresses
        svc restart opencache_watcher
        # Again, now that the OLD watcher is gone: until this restart it ran the
        # pre-#203 code, and any regeneration since installNginx's repair (a
        # KVS change, or a failing staged nginx -t retried every cycle) handed
        # /var/log and /var/run back to nginx. The new watcher never does.
        repairRootOwnedDirs
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

        # A hostname changed by syncHostname needs nothing extra for nginx:
        # every branch below (reload included) re-reads it for $hostname.
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

        if [ "$ALLOY_INPUTS_HASH_BEFORE" != "$(alloyInputsHash)" ]; then
            info "config.alloy or the alloy launcher changed — restarting alloy"
            svc restart opencache_alloy
        elif [ "$HOSTNAME_CHANGED" -eq 1 ]; then
            info "hostname changed — restarting alloy so its instance label picks up the new hostname"
            svc restart opencache_alloy
        else
            info "alloy unchanged (config.alloy, launcher, env-defaults helper) — not restarted (a restart costs a log catch-up window)"
        fi

        # Log shipping targets the ClickHouse warehouse; a pre-migration .env
        # only has the retired GCLOUD_HOSTED_LOGS_* keys, and without the new
        # ones the alloy launcher idles (no logs OR metrics ship). The fleet /
        # per-PoP env defaults count too.
        loadEffectiveEnvValue OC_LOGS_PUSH_URL; pushUrl="$EEV_VALUE"
        loadEffectiveEnvValue OC_LOGS_PUSH_PASSWORD; pushPassword="$EEV_VALUE"
        EEV_VALUE=""
        if [ -z "$pushUrl" ] || [ -z "$pushPassword" ]; then
            warn "OC_LOGS_PUSH_URL / OC_LOGS_PUSH_PASSWORD not set in $ENV_FILE or the fleet/per-PoP env defaults — log/metric shipping is DISABLED"
            warn "set them (ClickHouse warehouse ingest credentials) in $ENV_FILE or the fleet/per-PoP env defaults; the config watcher restarts Alloy within a minute"
            [ -f "$INSTALL_DIR/env/.env.defaults" ] \
                || info "(env/.env.defaults is not written yet — the config watcher writes the fleet/per-PoP defaults on its next cycle)"
        fi
        unset pushUrl pushPassword
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
    # Everything this run creates gets a known mode, whatever the operator's
    # umask: under 002 env/ (whose files root launchers read) and the other
    # directories came out group-writable, under 077 /etc/nginx/html, the
    # GeoIP and log directories came out root-only. 022 is also the umask the
    # services this run starts inherit, the one they get at boot. Secrets are
    # created private regardless (.env, certs/, nginx/generated/ — see
    # seedEnv, setEnvKv, ensureNodeLocalDirs); the bundle keeps the archive's
    # modes (tar -xpf, then rename). Set here, not at the top level, so
    # sourcing the script (OPENCACHE_INSTALL_LIB=1) leaves the caller's umask.
    umask 022
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
    configureNtp
    scanCacheDisks
    configureSsh
    configurePf
    installAlloy
    installNginxExporter
    installBirdwatcher
    installServices
    # After seedEnv (the updater authenticates with BAAS_HOST/BAAS_TOKEN) and
    # installServices (rc.d geoiptoggle, /var/log/opencache); before the first
    # nginx start, whose start_precmd picks geoip.conf or the fallback.
    configureGeoip
    # After installServices (/var/log/opencache, the shipping marker).
    configureAccessLogCleanup
    deployServices
    verifyInstall
    summary
}

# Sourceable for testing: `OPENCACHE_INSTALL_LIB=1 . install-freebsd.sh` loads
# the helpers without running an install.
#
# `{ main; exit; }`, never a bare `main`: run from the installed copy
# (/opt/opencache/packaging/install-freebsd.sh --upgrade), fetchBundle
# replaces this very file. Up to pfoundation/opencache#232 it was overwritten
# in place, and once main returned the shell read on from its old byte offset
# into the NEW file and ran whatever it found there. It is now renamed into
# place, so this shell keeps reading the old file; the braces stay as the
# second line of defence. The whole compound command is parsed before it
# runs, so the shell exits (with main's status) without reading any further.
[ "${OPENCACHE_INSTALL_LIB:-0}" = "1" ] || { main; exit; }
