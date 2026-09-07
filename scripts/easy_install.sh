#!/bin/bash
#
# scripts/easy_install.sh
#
# The "easy button" for FractalSQL. One command gets you from a bare
# Linux or macOS box to a running install with reasoning configured.
#
# Usage (fresh machine, nothing installed yet):
#   curl -fsSL https://github.com/FractalSQLabs/fractalsql-mariadb/releases/latest/download/easy_install.sh | bash
#
# Usage (package already installed via apt/dnf/tarball yourself):
#   ./easy_install.sh              # detects it, skips straight to the wizard
#
# Flags (all optional. Anything you omit gets asked interactively):
#   --database <name>          target database for the agent stored
#                               procedures (UDFs are server-global, no
#                               database needed, but CREATE PROCEDURE
#                               requires one -- must already exist)
#   --provider ollama|openai-compatible|skip
#   --url <chat-completions-url>       --model <name>
#   --embed-url <url>                  --embed-model <name>
#   --token <token>            (prefer leaving this to the masked prompt)
#   --think <off|low|medium|high|...>  --think-provider <ollama|openai|...>
#   --yes                      pre-confirm every prompt (needed for CI/non-tty)
#   --no-install               don't offer to install a missing package
#   --dry-run                  print what would happen, change nothing
#   --force-reinstall          skip the "already registered" pause
#   --uninstall                reverse everything this script can set up
#   --version <X.Y.Z>          package version to install (default: this script's own)
#   -h, --help
#
# Env vars:
#   MDB_BINDIR                 same override build_test.sh/Makefile already use:
#                               when set and non-empty, use this bin dir directly
#                               (e.g. MDB_BINDIR=/opt/homebrew/opt/mariadb/bin)
#                               and skip auto-detection entirely.
#
# No telemetry. This script never reports usage, provider choice, or
# success/failure anywhere. That's deliberate, matching FractalSQL's own
# "sovereign reasoning" positioning: your infra choices stay yours.
#
# Design differences, all forced by MariaDB's own architecture (see
# docs/reasoning-setup.md):
#   - No per-major-version selector. One binary covers MariaDB
#     10.6/10.11/11.4/12.3 (the UDF ABI is stable across them, see
#     scripts/package.sh), and there's no Debian-style multi-cluster
#     concept -- normally exactly one mariadbd instance to target.
#   - No sysvar/`SET GLOBAL`-style config surface exists at all. Every
#     FRACTALSQL_* reasoning setting is a process environment variable
#     read once by mariadbd at startup, so applying any of them needs a
#     restart, not just a reload.
#   - Registration is two plain SQL
#     files (sql/install_udf.sql + sql/install_agents.sql), not
#     `CREATE EXTENSION` -- there's no catalog-version/staleness concept
#     to detect, since both scripts are unconditionally idempotent
#     (DROP ... IF EXISTS then CREATE). UDFs are also server-global, not
#     per-database.
#   - Verification functions are fractalsql_edition()/fractalsql_version()
#     (the fractalsql_ prefix; agent functions use fractal_ instead, see
#     sql/install_udf.sql).
#
# Runs fine piped from curl. Every prompt reads from /dev/tty directly,
# not stdin, since stdin is the pipe's source in `curl ... | bash`.

set -euo pipefail

# --- version -----------------------------------------------------------
# Stamped in by release.yml at build time (the placeholder below is
# replaced with the tag version before this file is uploaded as a release
# asset). Falls back to reading src/fractalsql.c directly when run from a
# repo checkout during development, so this script works untouched both
# as a release asset and as a dev/test tool.
FSQL_VERSION="@@FSQL_VERSION@@"
if [[ "${FSQL_VERSION}" == "@@FSQL_VERSION@@" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/../src/fractalsql.c" ]]; then
        FSQL_VERSION="$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' "${HERE}/../src/fractalsql.c")"
    fi
fi

REPO="FractalSQLabs/fractalsql-mariadb"

# --- output helpers ------------------------------------------------------
if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; Z="\033[0m"; else G=""; R=""; Y=""; B=""; Z=""; fi
log()  { printf "${B}==>${Z} %s\n" "$1"; }
ok()   { printf "  ${G}✓${Z} %s\n" "$1"; }
warn() { printf "  ${Y}!${Z} %s\n" "$1" >&2; }
err()  { printf "  ${R}✗${Z} %s\n" "$1" >&2; }
die()  { err "$1"; exit 1; }

# --- /dev/tty-aware prompting --------------------------------------------
YES=0
NO_INSTALL=0
DRY_RUN=0
FORCE_REINSTALL=0
UNINSTALL=0
INSTALL_VERSION="${FSQL_VERSION}"
DATABASE=""
PROVIDER=""
HTTP_URL=""
HTTP_MODEL=""
HTTP_TOKEN=""
HTTP_EMBED_URL=""
HTTP_EMBED_MODEL=""
HTTP_THINK=""
HTTP_THINK_PROVIDER=""

have_tty() { [[ -e /dev/tty ]]; }

confirm() {  # confirm "question" -> 0=yes 1=no
    local question="$1"
    [[ "${YES}" -eq 1 ]] && { ok "${question} -> yes (--yes)"; return 0; }
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --yes, or the specific flag for what you're trying to set."
    fi
    local reply
    read -r -p "${question} [Y/n] " reply < /dev/tty || true
    [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}

prompt() {  # prompt "question" "default" -> echoes the answer
    local question="$1" default="${2:-}" reply
    if ! have_tty; then
        [[ -n "${default}" ]] && { echo "${default}"; return; }
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass the corresponding flag."
    fi
    if [[ -n "${default}" ]]; then
        read -r -p "${question} [${default}]: " reply < /dev/tty || true
        echo "${reply:-${default}}"
    else
        read -r -p "${question}: " reply < /dev/tty || true
        echo "${reply}"
    fi
}

prompt_secret() {  # prompt_secret "question" -> echoes the answer, never displayed
    local question="$1" reply
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --token."
    fi
    read -r -s -p "${question}: " reply < /dev/tty || true
    echo >&2
    echo "${reply}"
}

# --- arg parsing -----------------------------------------------------------
usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database)          DATABASE="$2"; shift 2 ;;
        --provider)          PROVIDER="$2"; shift 2 ;;
        --url)                HTTP_URL="$2"; shift 2 ;;
        --model)            HTTP_MODEL="$2"; shift 2 ;;
        --token)            HTTP_TOKEN="$2"; shift 2 ;;
        --embed-url)     HTTP_EMBED_URL="$2"; shift 2 ;;
        --embed-model) HTTP_EMBED_MODEL="$2"; shift 2 ;;
        --think)              HTTP_THINK="$2"; shift 2 ;;
        --think-provider) HTTP_THINK_PROVIDER="$2"; shift 2 ;;
        --version)      INSTALL_VERSION="$2"; shift 2 ;;
        --yes)               YES=1; shift ;;
        --no-install)  NO_INSTALL=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --force-reinstall) FORCE_REINSTALL=1; shift ;;
        --uninstall)     UNINSTALL=1; shift ;;
        -h|--help)       usage ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

[[ -n "${INSTALL_VERSION}" ]] || die "could not determine a version to install. Pass --version X.Y.Z"

# --- OS detection -----------------------------------------------------
OS_FAMILY=""   # debian | rhel | darwin
PKG_MGR=""     # dnf | yum | zypper (only set when OS_FAMILY=rhel)
ARCH_UNAME="$(uname -m)"
case "${ARCH_UNAME}" in
    x86_64|amd64) ARCH_DEB="amd64"; ARCH_DARWIN="x86_64" ;;
    arm64|aarch64) ARCH_DEB="arm64"; ARCH_DARWIN="arm64" ;;
    *) die "unsupported architecture: ${ARCH_UNAME}" ;;
esac

detect_os() {
    case "$(uname -s)" in
        Darwin) OS_FAMILY="darwin" ;;
        Linux)
            # OS_FAMILY collapse: dnf/yum/
            # zypper all resolve to "rhel" here, since MariaDB Foundation's
            # own repo setup script (mariadb_repo_setup) targets all of
            # them identically -- the one real difference is the install
            # command itself (PKG_MGR below): zypper enforces signature
            # checks on local RPMs by default and needs --no-gpg-checks
            # for our unsigned package; dnf/yum don't.
            if command -v apt-get >/dev/null 2>&1; then OS_FAMILY="debian"
            elif command -v dnf >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="dnf"
            elif command -v yum >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="yum"
            elif command -v zypper >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="zypper"
            else
                die "unsupported Linux distro (need apt-get, dnf, yum, or zypper; Alpine isn't packaged yet)"
            fi
            ;;
        *) die "unsupported OS: $(uname -s). This script covers Linux and macOS. See easy_install.ps1 for Windows." ;;
    esac
}

# --- mariadb_config / plugin_dir plumbing -------------------------------
MDB_CONFIG_BIN=""
PLUGIN_DIR=""

detect_mariadb() {
    # Same override convention as build_test.sh/Makefile's own MDB_BINDIR:
    # when set and non-empty, trust it completely and skip auto-detection.
    local candidates=() c
    if [[ -n "${MDB_BINDIR:-}" ]]; then
        candidates+=("${MDB_BINDIR}/mariadb_config" "${MDB_BINDIR}/mysql_config")
    else
        command -v mariadb_config >/dev/null 2>&1 && candidates+=("$(command -v mariadb_config)")
        command -v mysql_config   >/dev/null 2>&1 && candidates+=("$(command -v mysql_config)")
        for c in /opt/homebrew/opt/mariadb/bin/mariadb_config \
                 /usr/local/opt/mariadb/bin/mariadb_config; do
            [[ -x "$c" ]] && candidates+=("$c")
        done
    fi
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] || continue
        MDB_CONFIG_BIN="$c"
        break
    done
    [[ -n "${MDB_CONFIG_BIN}" ]] || die "no mariadb_config/mysql_config found (checked PATH and common Homebrew paths). Set MDB_BINDIR to the bin/ directory of your MariaDB install."
    # mariadb_config/mysql_config only locates the mariadb/mysql client
    # binary below (via resolve_mdb_as), not the plugin directory.
    # `--plugindir` reports the client connector library's own plugin
    # path (for client-side auth plugins), which is a different
    # directory from the server's plugin_dir on Debian/Ubuntu -- CREATE
    # FUNCTION only looks in the server's. PLUGIN_DIR is set from a live
    # `SELECT @@plugin_dir` query instead, once resolve_mdb_as connects,
    # see main().
}

is_installed() {
    [[ -f "${PLUGIN_DIR}/fractalsql.so" ]] || [[ -f "${PLUGIN_DIR}/fractalsql.dylib" ]]
}

# --- mariadb client plumbing --------------------------------------------
# Uses the mariadb/mysql client next to MDB_CONFIG_BIN, not whatever
# happens to be on PATH.
#
# Connection: try the invoking user directly first (unix_socket auth,
# the default for root@localhost on a fresh Debian/RHEL mariadb-server
# install as well as Homebrew). Fall back to `sudo mariadb` (needed when
# the invoking user isn't the socket-authenticated account).
MDB_AS=()
resolve_mdb_as() {
    local bin; bin="$(dirname "${MDB_CONFIG_BIN}")/mariadb"
    [[ -x "${bin}" ]] || bin="$(dirname "${MDB_CONFIG_BIN}")/mysql"
    [[ -x "${bin}" ]] || die "mariadb/mysql client not found next to ${MDB_CONFIG_BIN}"
    if "${bin}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MDB_AS=("${bin}" -u root)
    elif command -v sudo >/dev/null 2>&1 && sudo "${bin}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MDB_AS=(sudo "${bin}" -u root)
    else
        die "can't connect to mariadbd as root, either directly or via 'sudo'. Check the server is running and that root@localhost uses unix_socket auth (the packaged default) or pass a working \$HOME/.my.cnf."
    fi
    # The one authoritative source for plugin_dir -- see detect_mariadb's
    # own comment for why mariadb_config --plugindir can't be trusted
    # for this.
    PLUGIN_DIR="$("${MDB_AS[@]}" -Nse 'SELECT @@plugin_dir;')"
    [[ -n "${PLUGIN_DIR}" ]] || die "SELECT @@plugin_dir returned nothing"
    PLUGIN_DIR="${PLUGIN_DIR%/}"
}

# --- Phase B: install the package (default-on) ------------------------
phase_b_install() {
    if is_installed; then return; fi
    if [[ "${NO_INSTALL}" -eq 1 ]]; then
        die "FractalSQL isn't installed in ${PLUGIN_DIR}. Grab the matching package from https://github.com/${REPO}/releases and install it, then re-run this script (or drop --no-install)."
    fi
    confirm "FractalSQL isn't installed yet. Install it now?" \
        || die "Nothing to do without installing the package first. Re-run without --no-install, or install it yourself from https://github.com/${REPO}/releases."

    local asset_base="https://github.com/${REPO}/releases/download/v${INSTALL_VERSION}"
    # Global, not local: an EXIT trap runs after set -e has already
    # unwound out of this function on a failing command below, at which
    # point a `local` variable here would no longer exist and `set -u`
    # would reject the trap's own reference to it as unbound.
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    case "${OS_FAMILY}" in
        debian)
            local asset="fractalsql-mariadb-${ARCH_DEB}.deb"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            log "sudo apt-get install -y ${TMP_DIR}/${asset}"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo apt-get install -y "${TMP_DIR}/${asset}"
            ;;
        rhel)
            local asset="fractalsql-mariadb-${ARCH_DEB}.rpm"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                # zypper enforces signature checks by default, even for a
                # locally-supplied file; dnf/yum don't.
                log "sudo zypper --non-interactive --no-gpg-checks install ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo zypper --non-interactive --no-gpg-checks install "${TMP_DIR}/${asset}"
            else
                log "sudo ${PKG_MGR} install -y ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo "${PKG_MGR}" install -y "${TMP_DIR}/${asset}"
            fi
            ;;
        darwin)
            local platform_tag="osx_${ARCH_DARWIN}"
            [[ "${ARCH_DARWIN}" == "x86_64" ]] && platform_tag="osx_amd64"
            [[ "${ARCH_DARWIN}" == "arm64" ]] && platform_tag="osx_arm64"
            local asset="fractalsql-mariadb-${platform_tag}.zip"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            (cd "${TMP_DIR}" && unzip -q "${asset}" -d extracted)
            log "Running the bundled install.sh (reused, not reimplemented)..."
            local mdb_bin; mdb_bin="$(dirname "${MDB_CONFIG_BIN}")/mariadb"
            [[ -x "${mdb_bin}" ]] || mdb_bin="$(dirname "${MDB_CONFIG_BIN}")/mysql"
            [[ "${DRY_RUN}" -eq 1 ]] || MARIADB_BIN="${mdb_bin}" "${TMP_DIR}/extracted/install.sh"
            ;;
    esac
    ok "Package installed."
}

# --- Phase C: the wizard -----------------------------------------------
# Doubles any single quote in a value before it goes inside a shell-quoted
# EnvironmentFile / launchctl / registry write. Values here come from user
# input (a URL, a model name, a token).
envq() { printf '%s' "${1//\'/\'\\\'\'}"; }

FSQL_ENV_KEYS=(FRACTALSQL_REASONING_PLUGIN FRACTALSQL_HTTP_URL FRACTALSQL_HTTP_TOKEN
    FRACTALSQL_HTTP_MODEL FRACTALSQL_HTTP_ALLOW_PLAINTEXT FRACTALSQL_HTTP_EMBED_URL
    FRACTALSQL_HTTP_EMBED_MODEL FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER)
declare -A FSQL_ENV_VALUES=()
env_set() { FSQL_ENV_VALUES["FRACTALSQL_$1"]="$2"; }

# Applies FSQL_ENV_VALUES to mariadbd's environment and restarts it, or
# prints the manual steps if the user declines / --dry-run. There is no
# reload path here at all (see this file's own header comment) --
# ALL of Phase C funnels through this.
have_systemd() { [[ -d /run/systemd/system ]]; }

# Debian/Ubuntu containers (Docker's own base images, this project's own
# docker/Dockerfile, and most CI test containers) run mariadbd directly,
# with no systemd PID 1 at all -- `systemctl restart mariadb` simply
# fails there, systemd unit or not. A real Debian/Ubuntu HOST install
# always has systemd, so that's still the first choice; this fallback
# mirrors install-test.yml's own debian-install job restart primitive
# (mariadbd --user=mysql &, then poll mariadb-admin ping) for the
# container case, rather than assuming systemd or giving up.
restart_mariadbd_direct() {
    local priv_fn="$1"
    "${priv_fn}" mariadb-admin -u root shutdown 2>/dev/null \
        || "${priv_fn}" pkill -TERM mariadbd 2>/dev/null || true
    for _ in $(seq 1 30); do
        mariadb-admin -u root ping >/dev/null 2>&1 || break
        sleep 1
    done
    # /etc/default/mariadb is normally sourced by the systemd unit
    # (EnvironmentFile=) or the sysvinit script -- NOT by mariadbd
    # itself. Since this fallback bypasses both, source it explicitly
    # before relaunching, or every FRACTALSQL_* value apply_env_and_
    # restart just wrote would silently never reach the new process.
    "${priv_fn}" bash -c '[ -f /etc/default/mariadb ] && set -a && . /etc/default/mariadb && set +a; mariadbd --user=mysql >/var/log/mysql/fractalsql-restart.log 2>&1 &' \
        || die "couldn't relaunch mariadbd directly (no systemd found, and this fallback also failed). Restart it yourself, however it was started."
    local i
    for i in $(seq 1 60); do
        mariadb-admin -u root ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "mariadbd didn't come back up within 60s of the direct restart."
}

apply_env_and_restart() {
    local envfile dropin_dir dropin restart_cmd
    local as_root=0; [[ "$(id -u)" -eq 0 ]] && as_root=1
    priv() {
        local skip="$1"; shift
        if [[ "${skip}" -eq 1 ]]; then "$@"; else
            command -v sudo >/dev/null 2>&1 \
                || die "this needs root privileges but 'sudo' isn't installed and you're not root. Install sudo, or re-run as root."
            sudo "$@"
        fi
    }
    priv_as_root() { priv "${as_root}" "$@"; }

    log "About to set (mariadbd environment):"
    local k
    for k in "${!FSQL_ENV_VALUES[@]}"; do
        if [[ "$k" == *HTTP_TOKEN* ]]; then
            echo "  ${k}=***"
        else
            echo "  ${k}=${FSQL_ENV_VALUES[$k]}"
        fi
    done
    confirm "Apply this configuration? This needs a mariadbd restart, which drops active connections -- there is no live reload for these." \
        || { warn "Aborted. Nothing was changed."; return 1; }

    case "${OS_FAMILY}" in
        debian)
            envfile="/etc/default/mariadb"
            if have_systemd; then
                restart_cmd="systemctl restart mariadb"
            else
                restart_cmd="mariadb-admin -u root shutdown && mariadbd --user=mysql &"
            fi
            [[ "${as_root}" -eq 1 ]] || restart_cmd="sudo ${restart_cmd}"
            if [[ "${DRY_RUN}" -eq 1 ]]; then log "(--dry-run: not actually writing or restarting)"; return 0; fi
            for k in "${FSQL_ENV_KEYS[@]}"; do
                priv "${as_root}" sed -i "/^${k}=/d" "${envfile}" 2>/dev/null || true
            done
            {
                for k in "${!FSQL_ENV_VALUES[@]}"; do
                    printf "%s='%s'\n" "${k}" "$(envq "${FSQL_ENV_VALUES[$k]}")"
                done
            } | priv "${as_root}" tee -a "${envfile}" >/dev/null
            log "${restart_cmd}"
            if confirm "Restart mariadbd now to apply it?"; then
                if have_systemd; then
                    priv "${as_root}" systemctl restart mariadb
                else
                    restart_mariadbd_direct priv_as_root
                fi
                ok "mariadbd restarted with the new reasoning config."
            else
                warn "Not restarted. The config won't take effect until you run: ${restart_cmd}"
                return 1
            fi
            ;;
        rhel)
            dropin_dir="/etc/systemd/system/mariadb.service.d"
            dropin="${dropin_dir}/fractalsql-env.conf"
            restart_cmd="systemctl restart mariadb"
            [[ "${as_root}" -eq 1 ]] || restart_cmd="sudo ${restart_cmd}"
            if [[ "${DRY_RUN}" -eq 1 ]]; then log "(--dry-run: not actually writing or restarting)"; return 0; fi
            priv "${as_root}" mkdir -p "${dropin_dir}"
            {
                echo "[Service]"
                for k in "${!FSQL_ENV_VALUES[@]}"; do
                    printf "Environment=%s=%s\n" "${k}" "${FSQL_ENV_VALUES[$k]}"
                done
            } | priv "${as_root}" tee "${dropin}" >/dev/null
            priv "${as_root}" systemctl daemon-reload
            log "${restart_cmd}"
            if confirm "Restart mariadbd now to apply it?"; then
                priv "${as_root}" systemctl restart mariadb
                ok "mariadbd restarted with the new reasoning config."
            else
                warn "Not restarted. The config won't take effect until you run: ${restart_cmd}"
                return 1
            fi
            ;;
        darwin)
            warn "macOS (launchd/brew services) needs this set by hand: edit the mariadb formula's plist environment (brew services --help / 'brew info mariadb') to add the FRACTALSQL_* variables printed above, then 'brew services restart mariadb'. Not automated here -- launchd plist edits vary per Homebrew version."
            return 1
            ;;
    esac
}

phase_c_wizard() {
    # UDFs (sql/install_udf.sql) are server-global (mysql.func), no
    # database needed. Agent procedures (sql/install_agents.sql) are
    # ordinary stored procedures, which do need one: running
    # install_agents.sql with no database selected fails with
    # "ERROR 1046: No database selected". docs/getting-started.md's own
    # manual instructions already assume a pre-existing `mydb`; this
    # asks for the same thing rather than inventing a default database
    # name no one asked for.
    DATABASE="${DATABASE:-$(prompt "Target database for the agent stored procedures (must already exist; UDFs themselves don't need one)" "")}"
    [[ -n "${DATABASE}" ]] || die "a target database is required to register the agent procedures. Pass --database <name>."
    "${MDB_AS[@]}" -Nse "SHOW DATABASES LIKE '$(printf '%s' "${DATABASE}" | sed "s/'/''/g")';" | grep -qx "${DATABASE}" \
        || die "database '${DATABASE}' doesn't exist. Create it first (CREATE DATABASE ${DATABASE};), then re-run with --database ${DATABASE}."
    MDB_AS+=(-D "${DATABASE}")

    if [[ -z "${PROVIDER}" ]]; then
        log "Reasoning provider:"
        echo "  1) Local Ollama"
        echo "  2) Cloud / OpenAI-compatible endpoint"
        echo "  3) Skip: search-only install, configure reasoning later"
        local choice; choice="$(prompt "Choice" "1")"
        case "${choice}" in
            1) PROVIDER="ollama" ;;
            2) PROVIDER="openai-compatible" ;;
            *) PROVIDER="skip" ;;
        esac
    fi

    local plugin_so="${PLUGIN_DIR}/fractalsql-reasoning-http.so"

    case "${PROVIDER}" in
        ollama)
            HTTP_URL="${HTTP_URL:-$(prompt "Ollama chat URL" "http://localhost:11434/v1/chat/completions")}"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-oss:20b")}"
            HTTP_EMBED_URL="${HTTP_EMBED_URL:-$(prompt "Ollama embeddings URL" "http://localhost:11434/v1/embeddings")}"
            HTTP_EMBED_MODEL="${HTTP_EMBED_MODEL:-$(prompt "Embedding model" "nomic-embed-text")}"
            HTTP_THINK="${HTTP_THINK:-off}"
            HTTP_THINK_PROVIDER="${HTTP_THINK_PROVIDER:-ollama}"
            env_set REASONING_PLUGIN "${plugin_so}"
            env_set HTTP_URL "${HTTP_URL}"
            env_set HTTP_ALLOW_PLAINTEXT "1"
            env_set HTTP_MODEL "${HTTP_MODEL}"
            env_set HTTP_EMBED_URL "${HTTP_EMBED_URL}"
            env_set HTTP_EMBED_MODEL "${HTTP_EMBED_MODEL}"
            env_set HTTP_THINK "${HTTP_THINK}"
            env_set HTTP_THINK_PROVIDER "${HTTP_THINK_PROVIDER}"
            ;;
        openai-compatible)
            HTTP_URL="${HTTP_URL:-$(prompt "Chat completions URL" "")}"
            [[ -n "${HTTP_URL}" ]] || die "a URL is required for a cloud/OpenAI-compatible endpoint"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-4o-mini")}"
            [[ -n "${HTTP_TOKEN}" ]] || HTTP_TOKEN="$(prompt_secret "API token (masked, never logged)")"
            env_set REASONING_PLUGIN "${plugin_so}"
            env_set HTTP_URL "${HTTP_URL}"
            env_set HTTP_TOKEN "${HTTP_TOKEN}"
            env_set HTTP_MODEL "${HTTP_MODEL}"
            if [[ "${HTTP_URL}" != https://* ]]; then
                warn "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            fi
            ;;
        skip)
            log "Skipping reasoning config. Search functions like fractal_search and fractal_explore work with no model."
            ;;
        *) die "unknown --provider '${PROVIDER}' (expected ollama, openai-compatible, or skip)" ;;
    esac

    local applied=1
    if [[ "${PROVIDER}" != "skip" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "About to set (mariadbd environment):"
            for k in "${!FSQL_ENV_VALUES[@]}"; do
                [[ "$k" == *HTTP_TOKEN* ]] && { echo "  ${k}=***"; continue; }
                echo "  ${k}=${FSQL_ENV_VALUES[$k]}"
            done
            log "(--dry-run: not actually applying)"
        else
            apply_env_and_restart && applied=0 || applied=1
        fi
    fi

    log "Registering UDFs + agent procedures..."
    local already=0
    "${MDB_AS[@]}" -Nse "SELECT 1 FROM mysql.func WHERE name='fractalsql_edition';" 2>/dev/null | grep -q 1 && already=1
    if [[ "${already}" -eq 1 && "${FORCE_REINSTALL}" -ne 1 ]]; then
        confirm "fractalsql_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?" \
            || die "Nothing to do. Re-run with --force-reinstall to skip this pause."
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "(--dry-run: not actually running sql/install_udf.sql or sql/install_agents.sql)"
    else
        HERE_SQL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sql"
        if [[ -f "${HERE_SQL}/install_udf.sql" ]]; then
            "${MDB_AS[@]}" < "${HERE_SQL}/install_udf.sql"
            "${MDB_AS[@]}" < "${HERE_SQL}/install_agents.sql"
        else
            die "sql/install_udf.sql not found next to this script and no repo checkout detected. Run this from an extracted release asset directory or a repo checkout."
        fi
        ok "UDFs + agent procedures registered."
    fi

    if [[ "${DRY_RUN}" -ne 1 ]]; then
        local ed ver
        ed="$("${MDB_AS[@]}" -Nse 'SELECT fractalsql_edition();')"
        ver="$("${MDB_AS[@]}" -Nse 'SELECT fractalsql_version();')"
        ok "fractalsql_edition() = ${ed}, fractalsql_version() = ${ver}"
        if [[ "${ver}" != "${INSTALL_VERSION}" ]]; then
            warn "That's not ${INSTALL_VERSION}, the version this script expected. The installed .so itself is out of date. Reinstall the current package from https://github.com/${REPO}/releases over this install to actually update the plugin file, then re-run this script."
        fi
        if [[ "${PROVIDER}" != "skip" && "${applied}" -eq 0 ]] \
            && confirm "Run a live reasoning smoke test (SELECT fractal_reason(CONNECTION_ID(), 'say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time."; then
            local reply; reply="$("${MDB_AS[@]}" -Nse "SELECT fractal_reason(CONNECTION_ID(), 'say ok');" 2>&1 || true)"
            echo "  ${reply}" | head -5
            if [[ "${reply}" == *ERROR* ]]; then
                warn "That failed. If it looks like a timeout on a slow/cold local model, see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            fi
        elif [[ "${PROVIDER}" != "skip" && "${applied}" -ne 0 ]]; then
            warn "Reasoning config wasn't applied (restart declined or unsupported on this OS), so skipping the smoke test. fractal_reason() will use whatever config mariadbd already has."
        fi
    fi

    printf "\n${G}You're set up.${Z} Where next:\n"
    cat <<'EOF'
  - docs/starter-kits.md: industry-specific runnable examples
  - docs/api-agency.md: the 16 built-in agents, full reference
  - docs/composition-guide.md: build your own agent
  - Re-run this script anytime to switch providers or models. It's
    safe, but every change needs a mariadbd restart to take effect.
EOF
}

# --- --uninstall ---------------------------------------------------------
uninstall_flow() {
    log "This will reset FRACTALSQL_* reasoning env vars and restart mariadbd."
    if confirm "Reset reasoning env vars now?"; then
        local as_root=0; [[ "$(id -u)" -eq 0 ]] && as_root=1
        priv() { local skip="$1"; shift; if [[ "${skip}" -eq 1 ]]; then "$@"; else sudo "$@"; fi; }
        priv_as_root() { priv "${as_root}" "$@"; }
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually resetting)"
        else
            case "${OS_FAMILY}" in
                debian)
                    for k in "${FSQL_ENV_KEYS[@]}"; do priv "${as_root}" sed -i "/^${k}=/d" /etc/default/mariadb 2>/dev/null || true; done
                    if confirm "Restart mariadbd now?"; then
                        if have_systemd; then priv "${as_root}" systemctl restart mariadb; else restart_mariadbd_direct priv_as_root; fi
                        ok "mariadbd restarted."
                    fi
                    ;;
                rhel)
                    priv "${as_root}" rm -f /etc/systemd/system/mariadb.service.d/fractalsql-env.conf
                    priv "${as_root}" systemctl daemon-reload
                    confirm "Restart mariadbd now?" && { priv "${as_root}" systemctl restart mariadb; ok "mariadbd restarted."; }
                    ;;
                darwin) warn "Remove the FRACTALSQL_* entries from mariadb's launchd plist by hand, then 'brew services restart mariadb'." ;;
            esac
        fi
    fi

    if confirm "Also drop the fractalsql UDFs and agent procedures (sql/install_udf.sql defines the exact DROP list)?"; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually dropping)"
        else
            "${MDB_AS[@]}" -Nse "SELECT CONCAT('DROP FUNCTION IF EXISTS ', name, ';') FROM mysql.func WHERE dl='fractalsql.so' OR dl='fractalsql.dylib';" \
                | "${MDB_AS[@]}"
            ok "UDFs dropped. Agent procedures (fractal_agent_*) aren't UDFs and aren't tracked in mysql.func -- drop them with: mariadb < sql/install_agents.sql's own DROP PROCEDURE list, or DROP them by hand."
        fi
    fi

    case "${OS_FAMILY}" in
        debian) echo "  To remove the package: sudo apt remove fractalsql-mariadb" ;;
        rhel)
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                echo "  To remove the package: sudo zypper remove fractalsql-mariadb"
            else
                echo "  To remove the package: sudo ${PKG_MGR} remove fractalsql-mariadb"
            fi
            ;;
        darwin) echo "  To remove the files: rm ${PLUGIN_DIR}/fractalsql.so ${PLUGIN_DIR}/fractalsql-reasoning-http.so" ;;
    esac
}

# --- main ------------------------------------------------------------------
main() {
    detect_os
    detect_mariadb
    resolve_mdb_as
    log "Targeting MariaDB (plugin_dir ${PLUGIN_DIR})"

    if [[ "${UNINSTALL}" -eq 1 ]]; then
        uninstall_flow
        exit 0
    fi

    phase_b_install
    phase_c_wizard
}

main "$@"
