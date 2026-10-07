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
#   - No sysvar/`SET GLOBAL`-style config surface exists at all for
#     these settings. The preferred source for every reasoning setting
#     is fractalsqld.conf, the daemon's own config file (the file
#     fractalsqld -c names, e.g. /etc/fractalsql/fractalsqld.conf): the
#     wizard writes the 9 reasoning_* provider keys there
#     (reasoning_plugin, reasoning_url, reasoning_token,
#     reasoning_model, reasoning_allow_plaintext, embed_url,
#     embed_model, think, think_provider). Both daemon startup and
#     `fsqlctl reload` apply the conf (keys absent from it fall back to
#     the captured boot environment), so a wizard change is applied
#     live with `fsqlctl reload` where the daemon admits the client,
#     and takes the restart below otherwise. The env file/plist (the
#     /etc/fractalsql/fractalsqld.env EnvironmentFile on Linux, the
#     plist's EnvironmentVariables on macOS) keeps ONLY the env-only
#     knobs FSQL_REASONING_HTTP_TIMEOUT_MS /
#     FSQL_REASONING_HTTP_LOW_SPEED_SECS -- and stays the fallback
#     channel for any other FRACTALSQL_* keys an admin keeps, captured
#     once at daemon startup.
#   - Registration is two plain SQL
#     files (sql/install_udf.sql + sql/install_agents.sql), not
#     `CREATE EXTENSION` -- there's no catalog-version/staleness concept
#     to detect, since both scripts are unconditionally idempotent
#     (DROP ... IF EXISTS then CREATE). UDFs are also server-global, not
#     per-database.
#   - Verification functions are fractal_edition()/fractal_version()
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSQL_VERSION="@@FSQL_VERSION@@"
if [[ "${FSQL_VERSION}" == "@@FSQL_VERSION@@" ]]; then
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
usage() { sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

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
    if [[ -z "${MDB_CONFIG_BIN}" ]]; then
        # Debian/Ubuntu's mariadb-server package ships neither config
        # script (those come with libmariadb-dev), but MDB_CONFIG_BIN is
        # only used below as an anchor to locate the client sitting next
        # to it -- so fall back to whatever mariadb/mysql client is on
        # PATH (caught live in the Debian easy-install CI container).
        if command -v mariadb >/dev/null 2>&1; then
            MDB_CONFIG_BIN="$(dirname "$(command -v mariadb)")/mariadb_config"
        elif command -v mysql >/dev/null 2>&1; then
            MDB_CONFIG_BIN="$(dirname "$(command -v mysql)")/mysql_config"
        fi
    fi
    [[ -n "${MDB_CONFIG_BIN}" ]] || die "no mariadb_config/mysql_config or mariadb/mysql client found (checked PATH, MDB_BINDIR and common Homebrew paths). Set MDB_BINDIR to the bin/ directory of your MariaDB install."
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
    # Homebrew's MariaDB 12.x creates root@localhost with unix_socket
    # auth only (usable by the OS root user alone) plus a same-named,
    # all-privilege account for the invoking user. Debian/RHEL
    # mariadb-server likewise makes root@localhost unix_socket. So try
    # the invoking user's own account first, then -u root (installs
    # where root still has an empty native password, or running as
    # root), then sudo.
    if "${bin}" -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MDB_AS=("${bin}")
    elif "${bin}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
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
    # The reasoning core requires a canonical plugin path (the
    # configured value must equal its own realpath), and @@plugin_dir
    # runs through Homebrew's /opt/homebrew/opt/mariadb symlink on
    # macOS -- writing that symlinked form to the conf would be rejected
    # at load time ("reasoning plugin path is not canonical").
    # Resolve to the physical directory once, here.
    RESOLVED_PLUGIN_DIR="$(cd "${PLUGIN_DIR}" && pwd -P)" \
        || die "can't resolve plugin dir '${PLUGIN_DIR}' to a physical path"
    PLUGIN_DIR="${RESOLVED_PLUGIN_DIR}"
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
            curl -fsSL --proto '=https' "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            log "sudo apt-get install -y ${TMP_DIR}/${asset}"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo apt-get install -y "${TMP_DIR}/${asset}"
            ;;
        rhel)
            local asset="fractalsql-mariadb-${ARCH_DEB}.rpm"
            log "Downloading ${asset}..."
            curl -fsSL --proto '=https' "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
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
            curl -fsSL --proto '=https' "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
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
# Values here come from user input (a URL, a model name, a token). They
# land in the daemon's conf file (see below); ONLY the two env-only
# timeout knobs still land in the daemon's env mechanisms. Those
# mechanisms are still worth knowing about for the values they now carry:
# systemd's EnvironmentFile= needs no shell-style quoting (it splits each
# line on the first '=' and takes the rest literally, unlike a file a
# shell sources), so the env fallback path writes plain KEY=value lines.
# The darwin path shells out to PlistBuddy, which has its own simple
# whitespace-based command parser: a value containing a space, quote, or
# colon can confuse it. Fine for the numeric timeouts these variables
# normally hold; worth hardening if a value with those characters turns
# out to be common in practice.

# bash 3.2 -- macOS's stock shell -- has no associative arrays ("declare -A"
# fails outright there), so the wizard's config state is parallel indexed
# arrays, kept in insertion order by env_set_raw/conf_set. FSQL_ENV_* holds
# the env-only knobs (FSQL_REASONING_HTTP_TIMEOUT_MS /
# FSQL_REASONING_HTTP_LOW_SPEED_SECS -- the only things this wizard ever
# writes to the daemon's environment now); FSQL_CONF_* holds the 9
# reasoning_* provider keys written to the conf.
FSQL_ENV_KEYS=()
FSQL_ENV_VALUES=()
env_set() { env_set_raw "FRACTALSQL_$1" "$2"; }
env_set_raw() {
    local k="$1" i
    if [[ "${#FSQL_ENV_KEYS[@]}" -gt 0 ]]; then
        for i in "${!FSQL_ENV_KEYS[@]}"; do
            if [[ "${FSQL_ENV_KEYS[i]}" = "${k}" ]]; then
                FSQL_ENV_VALUES[i]="$2"
                return
            fi
        done
    fi
    FSQL_ENV_KEYS+=("${k}")
    FSQL_ENV_VALUES+=("$2")
}

# The 9 reasoning_* provider keys the daemon reads from fractalsqld.conf
# (its preferred source), in the order this wizard writes them.
FSQL_PROV_CONF_KEYS=(reasoning_plugin reasoning_url reasoning_token reasoning_model
    reasoning_allow_plaintext embed_url embed_model think think_provider)
FSQL_CONF_KEYS=()
FSQL_CONF_VALUES=()
conf_set() {  # insert-or-update, same parallel-array discipline as env_set_raw
    local k="$1" i
    if [[ "${#FSQL_CONF_KEYS[@]}" -gt 0 ]]; then
        for i in "${!FSQL_CONF_KEYS[@]}"; do
            if [[ "${FSQL_CONF_KEYS[i]}" = "${k}" ]]; then
                FSQL_CONF_VALUES[i]="$2"
                return
            fi
        done
    fi
    FSQL_CONF_KEYS+=("${k}")
    FSQL_CONF_VALUES+=("$2")
}
is_managed_prov_key() {  # is_managed_prov_key <conf-key> -> one of the 9 reasoning_* keys
    case "$1" in
        reasoning_plugin|reasoning_url|reasoning_token|reasoning_model|reasoning_allow_plaintext|embed_url|embed_model|think|think_provider) return 0 ;;
        *) return 1 ;;
    esac
}

# The 9 legacy FRACTALSQL_* names the wizard used to write into the
# daemon's environment (the env file/plist) before the conf became the
# preferred source. Leftovers from earlier runs get stripped by
# strip_legacy_env; an env entry with one of these names is treated as
# wizard-managed wherever the filter loops run.
is_legacy_env_key() {
    case "$1" in
        FRACTALSQL_REASONING_PLUGIN|FRACTALSQL_HTTP_URL|FRACTALSQL_HTTP_TOKEN|FRACTALSQL_HTTP_MODEL|FRACTALSQL_HTTP_ALLOW_PLAINTEXT|FRACTALSQL_HTTP_EMBED_URL|FRACTALSQL_HTTP_EMBED_MODEL|FRACTALSQL_HTTP_THINK|FRACTALSQL_HTTP_THINK_PROVIDER) return 0 ;;
        *) return 1 ;;
    esac
}
is_managed_env_key() {  # legacy names plus the env-only timeout knobs
    is_legacy_env_key "$1" && return 0
    case "$1" in
        FSQL_REASONING_HTTP_TIMEOUT_MS|FSQL_REASONING_HTTP_LOW_SPEED_SECS) return 0 ;;
        *) return 1 ;;
    esac
}

# Root-vs-sudo plumbing, once at file scope -- conf writes, env-file
# writes and daemon restarts all need it (this scaffolding used to be
# duplicated inside the old apply-env branch and uninstall_flow).
AS_ROOT=0
priv_init() {
    AS_ROOT=0
    if [[ "$(id -u)" -eq 0 ]]; then AS_ROOT=1; fi
}
priv() {  # priv <skip> <cmd...>: run directly when root, else via sudo
    local skip="$1"; shift
    if [[ "${skip}" -eq 1 ]]; then "$@"; else
        command -v sudo >/dev/null 2>&1 \
            || die "this needs root privileges but 'sudo' isn't installed and you're not root. Install sudo, or re-run as root."
        sudo "$@"
    fi
}

# --- Phase C, stage 1: the daemon's conf file --------------------------
# /etc/fractalsql/fractalsqld.conf. Identical on all three POSIX platforms
# -- the systemd unit, the launchd plist, and the no-systemd hand-launch
# path all hardcode it (fractalsqld -c).
FSQD_CONF="/etc/fractalsql/fractalsqld.conf"

require_fsqd_conf() {
    [[ -f "${FSQD_CONF}" ]] \
        || die "fractalsqld.conf not found; install the package or run scripts/macos/install.sh first (the daemon reads socket_path/hmac_key_file from it)"
}

trim() {  # trim <string> -> echoes it with leading/trailing whitespace (incl. CR) removed
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "${s}"
}

# parse_conf_field <file> <key> -> the first matching line's RHS, spaces
# before the value trimmed and CR tolerated, empty when absent. Load_config's
# own grammar is what this parses for: split on the first '=', '#' comments
# only at line start, values may contain '='.
parse_conf_field() {
    local file="$1" key="$2" line lhs
    [[ -f "${file}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="$(trim "${line}")"
        lhs="$(trim "${line%%=*}")"
        [[ "${lhs}" != "${key}" ]] && continue
        printf '%s\n' "$(trim "${line#*=}")"
        return 0
    done < "${file}"
}

_conf_read() {  # _conf_read -> conf content on stdout, elevating via priv only when readability forces it
    if [[ -r "${FSQD_CONF}" ]]; then
        cat "${FSQD_CONF}"
    else
        priv "${AS_ROOT}" cat "${FSQD_CONF}"
    fi
}

# _conf_install <new-file>: replace the conf's content, restoring the
# packaging owner+mode. The daemon refuses (startup AND reload) a conf
# readable by other users (mode & 0007 != 0), so 0640 is not optional, and
# the owner is put back the way packaging ships it: fractalsql:fractalsql
# on Linux, the invoking user on macOS.
_conf_install() {
    if [[ -r "${FSQD_CONF}" && -w "${FSQD_CONF}" ]]; then
        cat "$1" > "${FSQD_CONF}"   # in-place: the inode keeps its owner/mode
        chmod 0640 "${FSQD_CONF}"
        return 0
    fi
    priv "${AS_ROOT}" cp "$1" "${FSQD_CONF}"
    case "${OS_FAMILY}" in
        darwin)      priv "${AS_ROOT}" chown "$(id -un)" "${FSQD_CONF}" ;;
        debian|rhel) priv "${AS_ROOT}" chown fractalsql:fractalsql "${FSQD_CONF}" ;;
    esac
    priv "${AS_ROOT}" chmod 0640 "${FSQD_CONF}"
}

# Read-modify-write the 9 reasoning_* provider keys into the daemon's conf
# (the preferred source; applied by daemon startup and `fsqlctl reload`).
# Every line whose key is NOT a managed reasoning_* key -- comments,
# blanks, and the socket_path/hmac_key_file/allowed_uids plumbing -- is
# kept verbatim and in order; managed lines are replaced by fresh
# `key = value` appends (empty values are skipped: the daemon refuses an
# empty provider key by name). Skips the write entirely when nothing would
# change, so owner/mode are never touched without a reason. Never creates
# the conf: if it's absent, Phase C has nothing to work with.
write_conf_provider_keys() {
    require_fsqd_conf
    local tmp_cur tmp_new line lhs i
    tmp_cur="$(mktemp)" tmp_new="$(mktemp)"
    _conf_read > "${tmp_cur}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lhs="$(trim "${line%%=*}")"
        if is_managed_prov_key "${lhs}"; then continue; fi
        printf '%s\n' "${line}"
    done < "${tmp_cur}" > "${tmp_new}"
    if [[ "${#FSQL_CONF_KEYS[@]}" -gt 0 ]]; then
        for i in "${!FSQL_CONF_KEYS[@]}"; do
            [[ -n "${FSQL_CONF_VALUES[i]}" ]] || continue
            printf '%s = %s\n' "${FSQL_CONF_KEYS[i]}" "${FSQL_CONF_VALUES[i]}"
        done >> "${tmp_new}"
    fi
    if cmp -s "${tmp_cur}" "${tmp_new}"; then
        ok "${FSQD_CONF} already carries the planned reasoning_* keys."
    else
        _conf_install "${tmp_new}"
        ok "reasoning_* keys written to ${FSQD_CONF} (applied by daemon startup and fsqlctl reload)."
    fi
    rm -f "${tmp_cur}" "${tmp_new}"
}

# The uninstall-side counterpart: drop every managed reasoning_* key line
# from the conf, keeping the plumbing verbatim. Same write path, so the
# same owner+mode come back.
strip_conf_provider_keys() {
    [[ -f "${FSQD_CONF}" ]] || return 0
    local tmp_cur tmp_new line lhs removed=0
    tmp_cur="$(mktemp)" tmp_new="$(mktemp)"
    _conf_read > "${tmp_cur}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lhs="$(trim "${line%%=*}")"
        if is_managed_prov_key "${lhs}"; then
            removed=1
            continue
        fi
        printf '%s\n' "${line}"
    done < "${tmp_cur}" > "${tmp_new}"
    if [[ "${removed}" -eq 1 ]]; then
        _conf_install "${tmp_new}"
        ok "reasoning_* keys stripped from ${FSQD_CONF}."
    fi
    rm -f "${tmp_cur}" "${tmp_new}"
}

# Apply the just-written conf live with `fsqlctl reload`. Deliberately
# silent on the success path and returning 1 cleanly on every "not usable
# here" case, so the caller falls back to the restart machinery without
# noise: fsqlctl isn't shipped by any package, and the daemon admits
# peers by uid (the conf's allowed_uids vs SO_PEERCRED on Linux /
# getpeereid on macOS) -- on Debian/RHEL packaging the admitted account is
# mysql's, so the reload runs as mysql (which can read the 0640 key:
# postinst puts mysql in the fractalsql group), not as root.
try_fsqlctl_reload() {  # -> 0 reload succeeded, 1 unusable (caller restarts instead)
    local ctl=""
    if command -v fsqlctl >/dev/null 2>&1; then
        ctl="$(command -v fsqlctl)"
    elif [[ -x "${HERE}/../service/build/fsqlctl" ]]; then
        # A repo checkout can have an fsqlctl beside the daemon build.
        ctl="${HERE}/../service/build/fsqlctl"
    else
        return 1
    fi
    local tmp conf_body socket keyfile allowed
    tmp="$(mktemp)"
    conf_body="$(_conf_read 2>/dev/null)" || { rm -f "${tmp}"; return 1; }
    printf '%s\n' "${conf_body}" > "${tmp}"
    socket="$(parse_conf_field "${tmp}" socket_path)"
    keyfile="$(parse_conf_field "${tmp}" hmac_key_file)"
    allowed="$(parse_conf_field "${tmp}" allowed_uids)"
    rm -f "${tmp}"
    [[ -n "${socket}" && -n "${keyfile}" ]] || return 1
    # Admission precheck: never attempt what the daemon would refuse.
    local me need_uid found=1 uid must_drop=0
    me="$(id -u)"
    case "${OS_FAMILY}" in
        darwin)
            need_uid="${me}"
            ;;
        debian|rhel)
            need_uid="$(id -u mysql 2>/dev/null)" || true
            if [[ -z "${need_uid}" ]]; then return 1; fi
            if [[ "${me}" != "${need_uid}" ]]; then must_drop=1; fi
            ;;
        *) return 1 ;;
    esac
    for uid in ${allowed}; do
        [[ "${uid}" = "${need_uid}" ]] && found=0
    done
    [[ "${found}" -eq 0 ]] || return 1
    local out rc=0
    if [[ "${must_drop}" -eq 1 ]]; then
        out="$(priv "${AS_ROOT}" sudo -u mysql "${ctl}" -s "${socket}" -k "${keyfile}" reload 2>&1)" || rc=1
    else
        out="$("${ctl}" -s "${socket}" -k "${keyfile}" reload 2>&1)" || rc=1
    fi
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    warn "fsqlctl reload didn't take (${out%%$'\n'*}); falling back to a restart."
    return 1
}

have_systemd() { [[ -d /run/systemd/system ]]; }

# Writes the env-only FSQL_* timeout knobs to the daemon's environment
# mechanisms (the /etc/fractalsql/fractalsqld.env EnvironmentFile on
# Linux, the LaunchAgent's EnvironmentVariables dict on macOS) and
# restarts fractalsqld -- not mariadbd: fractal_reason/fractal_embed run
# in the daemon, so mariadbd and its active SQL connections are
# untouched. The provider settings themselves are already in the conf
# (write_conf_provider_keys) by the time this runs, and the restart picks
# them up at startup -- with no timeout knobs configured, no env file/
# plist keys are written at all and the relaunch runs purely from the
# conf. Prints the manual steps if the user declines.
apply_env_only_and_restart() {  # -> 0 restarted, 1 declined/failed
    if [[ "${DRY_RUN}" -eq 1 ]]; then log "(--dry-run: not actually writing or restarting)"; return 0; fi
    case "${OS_FAMILY}" in
        debian|rhel)
            # Both distros package fractalsqld as a systemd service (see
            # packaging/systemd/fractalsqld.service, which reads
            # /etc/fractalsql/fractalsqld.env via EnvironmentFile=) --
            # no distro-specific drop-in needed, unlike mariadb.service,
            # which this script does not touch at all anymore.
            # Read-modify-write, not the wholesale tee this path used to
            # do (which lost entries an admin had added to the env file
            # by hand): every wizard-managed name is filtered out, then
            # the pending timeout keys are appended.
            local envfile="/etc/fractalsql/fractalsqld.env"
            local tmp line lhs i
            tmp="$(mktemp)"
            {
                while IFS= read -r line || [[ -n "${line}" ]]; do
                    lhs="$(trim "${line%%=*}")"
                    if is_managed_env_key "${lhs}"; then continue; fi
                    printf '%s\n' "${line}"
                done < <(priv "${AS_ROOT}" cat "${envfile}" 2>/dev/null)
                if [[ "${#FSQL_ENV_KEYS[@]}" -gt 0 ]]; then
                    for i in "${!FSQL_ENV_KEYS[@]}"; do
                        [[ -n "${FSQL_ENV_VALUES[i]}" ]] || continue
                        printf '%s=%s\n' "${FSQL_ENV_KEYS[i]}" "${FSQL_ENV_VALUES[i]}"
                    done
                fi
            } > "${tmp}"
            if [[ -s "${tmp}" ]]; then
                # tee (not cp): truncates the existing file in place, so
                # its owner/mode survive; no chmod/chown on it -- systemd
                # reads it as root, and nothing gates on its permissions.
                priv "${AS_ROOT}" tee "${envfile}" >/dev/null < "${tmp}"
            else
                # An env file whose every line was wizard-managed and
                # which nothing replaces is removed, not left empty.
                [[ -f "${envfile}" ]] && priv "${AS_ROOT}" rm -f "${envfile}"
            fi
            rm -f "${tmp}"
            if have_systemd; then
                log "systemctl restart fractalsqld"
                if confirm "Restart fractalsqld now to apply it?"; then
                    priv "${AS_ROOT}" systemctl restart fractalsqld
                    ok "fractalsqld restarted with the new reasoning config."
                else
                    warn "Not restarted. The config won't take effect until you run: systemctl restart fractalsqld"
                    return 1
                fi
            else
                # No systemd to supervise it (a bare container, a
                # minimal distro, ...), so there is no unit to ask for
                # a restart -- find whatever fractalsqld is already
                # running (started by hand, same convention postinst.sh's
                # printed instructions describe) and relaunch it
                # ourselves, as the fractalsql user (fractalsqld refuses
                # to run as root -- see fractalsqld.c). The provider
                # settings come from the conf now, so the exported
                # environment holds at most the two env-only FSQL_* knobs
                # -- and nothing at all when none were configured.
                local fsqld_bin="/usr/libexec/fractalsql/fractalsqld"
                local fsqld_conf="${FSQD_CONF}"
                pgrep -f "${fsqld_bin} -c ${fsqld_conf}" >/dev/null 2>&1 \
                    || { warn "No systemd here, and fractalsqld isn't running, so there's nothing to restart. Start it by hand first (see service/README.md), then re-run this."; return 1; }
                log "No systemd: restarting fractalsqld by hand (same binary, same config)."
                if confirm "Restart fractalsqld now to apply it?"; then
                    priv "${AS_ROOT}" pkill -f "${fsqld_bin} -c ${fsqld_conf}"
                    for i in $(seq 1 50); do pgrep -f "${fsqld_bin} -c ${fsqld_conf}" >/dev/null 2>&1 || break; sleep 0.1; done
                    local env_args=()
                    if [[ "${#FSQL_ENV_KEYS[@]}" -gt 0 ]]; then
                        for i in "${!FSQL_ENV_KEYS[@]}"; do
                            [[ -n "${FSQL_ENV_VALUES[i]}" ]] || continue
                            env_args+=("${FSQL_ENV_KEYS[i]}=${FSQL_ENV_VALUES[i]}")
                        done
                    fi
                    # Redirected, not inherited: this whole script may
                    # itself be running inside a `... | tee logfile`
                    # pipeline (easy_install.sh's own callers do exactly
                    # that). A backgrounded fractalsqld with no explicit
                    # redirection inherits that pipe's write end, and
                    # since it's a server that never exits, the pipe's
                    # read end (tee) never sees EOF -- the whole
                    # pipeline hangs forever, not just this function.
                    # `disown` only drops job-control tracking; it does
                    # NOT close inherited file descriptors.
                    if [[ "${#env_args[@]}" -eq 0 ]]; then
                        if [[ "${AS_ROOT}" -eq 1 ]]; then
                            runuser -u fractalsql -- "${fsqld_bin}" -c "${fsqld_conf}" >/dev/null 2>&1 &
                        else
                            sudo -u fractalsql "${fsqld_bin}" -c "${fsqld_conf}" >/dev/null 2>&1 &
                        fi
                    else
                        if [[ "${AS_ROOT}" -eq 1 ]]; then
                            runuser -u fractalsql -- env "${env_args[@]}" "${fsqld_bin}" -c "${fsqld_conf}" >/dev/null 2>&1 &
                        else
                            sudo -u fractalsql env "${env_args[@]}" "${fsqld_bin}" -c "${fsqld_conf}" >/dev/null 2>&1 &
                        fi
                    fi
                    disown 2>/dev/null || true
                    for i in $(seq 1 50); do pgrep -f "${fsqld_bin} -c ${fsqld_conf}" >/dev/null 2>&1 && break; sleep 0.1; done
                    pgrep -f "${fsqld_bin} -c ${fsqld_conf}" >/dev/null 2>&1 \
                        || { warn "fractalsqld didn't come back up -- check its log."; return 1; }
                    ok "fractalsqld restarted with the new reasoning config."
                else
                    warn "Not restarted. The config won't take effect until fractalsqld is restarted with it."
                    return 1
                fi
            fi
            ;;
        darwin)
            local plist="${HOME}/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
            [[ -f "${plist}" ]] \
                || { warn "fractalsqld's LaunchAgent plist not found at ${plist}. Run scripts/macos/install.sh first."; return 1; }
            # Our own plist, fully under our control -- unlike editing
            # Homebrew's mariadb formula plist (which used to be this
            # function's darwin branch, and really did vary per
            # Homebrew version), so this is safe to automate.
            # PlistBuddy runs only when there are actually env keys to
            # write (the timeout knobs, offered on the ollama path) --
            # no wholesale Delete/Add when the conf change is all there
            # is. Each key is updated in place rather than deleting the
            # dict, so nothing an admin keeps is lost.
            local pending=0
            if [[ "${#FSQL_ENV_KEYS[@]}" -gt 0 ]]; then
                for i in "${!FSQL_ENV_KEYS[@]}"; do
                    [[ -n "${FSQL_ENV_VALUES[i]}" ]] && pending=1
                done
            fi
            if [[ "${pending}" -eq 1 ]]; then
                /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "${plist}" >/dev/null 2>&1 || true
                for i in "${!FSQL_ENV_KEYS[@]}"; do
                    [[ -n "${FSQL_ENV_VALUES[i]}" ]] || continue
                    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:${FSQL_ENV_KEYS[i]}" "${plist}" >/dev/null 2>&1 || true
                    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:${FSQL_ENV_KEYS[i]} string ${FSQL_ENV_VALUES[i]}" "${plist}"
                done
            fi
            log "launchctl kickstart -k gui/$(id -u)/com.fractalsqlabs.fractalsqld"
            if confirm "Restart fractalsqld now to apply it?"; then
                launchctl kickstart -k "gui/$(id -u)/com.fractalsqlabs.fractalsqld" >/dev/null 2>&1 \
                    || { launchctl unload "${plist}" >/dev/null 2>&1; launchctl load -w "${plist}"; }
                ok "fractalsqld restarted with the new reasoning config."
            else
                warn "Not restarted. The config won't take effect until fractalsqld reloads."
                return 1
            fi
            ;;
    esac
}

# Removes wizard-managed legacy FRACTALSQL_* entries from the daemon's
# env mechanisms (the /etc/fractalsql/fractalsqld.env EnvironmentFile on
# Linux, the LaunchAgent's EnvironmentVariables dict on macOS), leaving
# anything else an admin added. A file/dict this empties is removed
# rather than left behind empty.
strip_legacy_env() {
    case "${OS_FAMILY}" in
        debian|rhel)
            local envfile="/etc/fractalsql/fractalsqld.env"
            [[ -f "${envfile}" ]] || return 0
            local tmp line lhs kept=0
            tmp="$(mktemp)"
            while IFS= read -r line || [[ -n "${line}" ]]; do
                lhs="$(trim "${line%%=*}")"
                if is_legacy_env_key "${lhs}"; then continue; fi
                printf '%s\n' "${line}"
                kept=1
            done < <(priv "${AS_ROOT}" cat "${envfile}" 2>/dev/null) > "${tmp}"
            if [[ "${kept}" -eq 1 ]]; then
                priv "${AS_ROOT}" tee "${envfile}" >/dev/null < "${tmp}"
            else
                priv "${AS_ROOT}" rm -f "${envfile}"
            fi
            rm -f "${tmp}"
            ;;
        darwin)
            local plist="${HOME}/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
            [[ -f "${plist}" ]] || return 0
            local k removed=0 dict
            for k in FRACTALSQL_REASONING_PLUGIN FRACTALSQL_HTTP_URL FRACTALSQL_HTTP_TOKEN \
                     FRACTALSQL_HTTP_MODEL FRACTALSQL_HTTP_ALLOW_PLAINTEXT FRACTALSQL_HTTP_EMBED_URL \
                     FRACTALSQL_HTTP_EMBED_MODEL FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER; do
                if /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:${k}" "${plist}" >/dev/null 2>&1; then
                    removed=1
                    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:${k}" "${plist}" >/dev/null 2>&1 || true
                fi
            done
            if [[ "${removed}" -eq 1 ]]; then
                # An EnvironmentVariables dict this emptied is deleted too.
                dict="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables" "${plist}" 2>/dev/null || true)"
                [[ "${dict}" == *" = "* ]] \
                    || /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "${plist}" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# How many env knobs are configured right now (the wizard only ever puts
# the two FSQL_* timeout knobs in the env arrays).
env_pending_count() {
    local n=0 i
    if [[ "${#FSQL_ENV_KEYS[@]}" -gt 0 ]]; then
        for i in "${!FSQL_ENV_KEYS[@]}"; do
            [[ -n "${FSQL_ENV_VALUES[i]}" ]] && n=$((n+1))
        done
    fi
    printf '%s' "${n}"
}

# The one masking rule for Phase C's planned-settings print: the token
# (reasoning_token in the conf, FRACTALSQL_HTTP_TOKEN in env) shows ***.
print_masked() {  # print_masked <key> <value> -> indented KEY=value (*** for tokens)
    case "$1" in
        *HTTP_TOKEN*|reasoning_token)
            echo "  ${1}=***"
            ;;
        *)
            echo "  ${1}=${2}"
            ;;
    esac
}

print_apply_plan() {
    local i
    log "About to apply:"
    log "fractalsqld.conf reasoning_* keys (the preferred source: daemon startup and fsqlctl reload):"
    if [[ "${#FSQL_CONF_KEYS[@]}" -gt 0 ]]; then
        for i in "${!FSQL_CONF_KEYS[@]}"; do
            print_masked "${FSQL_CONF_KEYS[i]}" "${FSQL_CONF_VALUES[i]}"
        done
    else
        echo "  (nothing to write)"
    fi
    if [[ "$(env_pending_count)" -gt 0 ]]; then
        log "env fallback (fractalsqld.env EnvironmentFile / LaunchAgent plist), env-only timeout knobs:"
        for i in "${!FSQL_ENV_KEYS[@]}"; do
            [[ -n "${FSQL_ENV_VALUES[i]}" ]] || continue
            print_masked "${FSQL_ENV_KEYS[i]}" "${FSQL_ENV_VALUES[i]}"
        done
    fi
    echo "  (legacy FRACTALSQL_* entries in the env mechanisms, left over from earlier runs, will be stripped)"
}

# Phase C's single entry point -- ALL of it funnels through this:
#   1. print the plan (conf keys token-masked, timeout knobs shown), and
#   2. confirm; the wording is honest about what can happen,
#   3. write the conf's reasoning_* keys,
#   4. strip the legacy wizard env entries from the env mechanisms,
#   5. apply: `fsqlctl reload` when no timeout knobs were written AND the
#      daemon admits us; otherwise the per-OS restart -- env knobs are
#      captured at daemon startup only, so they force the restart.
apply_conf_and_apply() {  # -> 0 applied, 1 declined/failed
    require_fsqd_conf
    print_apply_plan
    confirm "Apply this configuration? This applies the conf-file change live with fsqlctl reload when possible, else restarts fractalsqld (the daemon fractal_reason/fractal_embed run in) -- not mariadbd: active SQL connections are undisturbed; an in-flight reasoning/embedding call on the daemon is dropped." \
        || { warn "Aborted. Nothing was changed."; return 1; }

    write_conf_provider_keys
    strip_legacy_env

    if [[ "$(env_pending_count)" -ne 0 ]]; then
        # Timeout knobs were written: they live in the captured process
        # environment, which only a startup refreshes -- reloading the
        # conf alone wouldn't pick them up.
        apply_env_only_and_restart
        return
    fi
    # Conf-only change: apply it live when the daemon will admit us.
    if try_fsqlctl_reload; then
        ok "fractalsqld reloaded the new reasoning config; no restart needed."
        return 0
    fi
    log "No fsqlctl reload available here -- falling back to a restart."
    apply_env_only_and_restart
}

# A cold-loading local model (for example, a large Ollama model pulled
# onto constrained hardware) can take minutes to produce its first
# answer, longer than the reasoning plugin's default HTTP timeout. These
# are the same values easy_install.ps1 applies on Windows, and they are
# env-only knobs: written to the env fallback channel (the daemon's
# env file/plist), not the conf -- and, since the daemon captures its
# environment at startup only, setting one forces the restart branch of
# apply_conf_and_apply.
offer_cold_start_timeout() {
    confirm "Local models can be slow to answer the first time while they load into memory or VRAM. Raise the reasoning HTTP timeout to handle that? It is applied with the fractalsqld restart below." \
        || return 0
    env_set_raw FSQL_REASONING_HTTP_TIMEOUT_MS 330000
    env_set_raw FSQL_REASONING_HTTP_LOW_SPEED_SECS 300
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
            # All 9 land as reasoning_* keys in the daemon's conf (the
            # preferred source, read by startup and fsqlctl reload) --
            # not the env. See the conf plumbing above.
            conf_set reasoning_plugin "${plugin_so}"
            conf_set reasoning_url "${HTTP_URL}"
            conf_set reasoning_allow_plaintext "1"
            conf_set reasoning_model "${HTTP_MODEL}"
            conf_set embed_url "${HTTP_EMBED_URL}"
            conf_set embed_model "${HTTP_EMBED_MODEL}"
            conf_set think "${HTTP_THINK}"
            conf_set think_provider "${HTTP_THINK_PROVIDER}"
            ;;
        openai-compatible)
            HTTP_URL="${HTTP_URL:-$(prompt "Chat completions URL" "")}"
            [[ -n "${HTTP_URL}" ]] || die "a URL is required for a cloud/OpenAI-compatible endpoint"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-4o-mini")}"
            [[ -n "${HTTP_TOKEN}" ]] || HTTP_TOKEN="$(prompt_secret "API token (masked, never logged)")"
            conf_set reasoning_plugin "${plugin_so}"
            conf_set reasoning_url "${HTTP_URL}"
            conf_set reasoning_token "${HTTP_TOKEN}"
            conf_set reasoning_model "${HTTP_MODEL}"
            if [[ "${HTTP_URL}" != https://* ]]; then
                warn "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            fi
            ;;
        skip)
            log "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
            ;;
        *) die "unknown --provider '${PROVIDER}' (expected ollama, openai-compatible, or skip)" ;;
    esac

    if [[ "${PROVIDER}" == "ollama" ]]; then
        offer_cold_start_timeout
    fi

    local applied=1
    if [[ "${PROVIDER}" != "skip" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            print_apply_plan
            log "(--dry-run: not actually applying)"
        else
            apply_conf_and_apply && applied=0 || applied=1
        fi
    fi

    log "Registering UDFs + agent procedures..."
    local already=0
    "${MDB_AS[@]}" -Nse "SELECT 1 FROM mysql.func WHERE name='fractal_edition';" 2>/dev/null | grep -q 1 && already=1
    if [[ "${already}" -eq 1 && "${FORCE_REINSTALL}" -ne 1 ]]; then
        confirm "fractal_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?" \
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
        ed="$("${MDB_AS[@]}" -Nse 'SELECT fractal_edition();')"
        ver="$("${MDB_AS[@]}" -Nse 'SELECT fractal_version();')"
        ok "fractal_edition() = ${ed}, fractal_version() = ${ver}"
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
            warn "Reasoning config wasn't applied (the reload/restart was declined or unavailable), so skipping the smoke test. fractal_reason() will use whatever config fractalsqld already has."
        fi
    fi

    printf "\n${G}You're set up.${Z} Where next:\n"
    cat <<'EOF'
  - docs/starter-kits.md: industry-specific runnable examples
  - docs/api-agency.md: the 16 built-in agents, full reference
  - docs/composition-guide.md: build your own agent
  - Re-run this script anytime to switch providers or models. It's
    safe: it writes the reasoning_* keys into fractalsqld.conf
    (e.g. /etc/fractalsql/fractalsqld.conf), applies that live with
    `fsqlctl reload` where the daemon admits it, and only ever touches
    fractalsqld (the daemon), not mariadbd.
  - The conf is the preferred source for every reasoning_* key: edit it
    by hand and run `fsqlctl reload` yourself for the same effect. The
    daemon's env file/plist keeps only the env-only timeout knobs this
    script may have set, plus any other FRACTALSQL_* keys you added by
    hand -- the fallback for keys the conf file doesn't set.
EOF
}

# --- --uninstall ---------------------------------------------------------
uninstall_flow() {
    log "This removes the reasoning_* conf keys from fractalsqld.conf and the wizard's FRACTALSQL_* env fallback entries, then restarts fractalsqld (mariadbd untouched)."
    if confirm "Remove them now?"; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually resetting)"
        else
            # The conf first (its reasoning_* keys) -- plumbing lines like
            # socket_path/hmac_key_file/allowed_uids stay; owner+mode go
            # back exactly the way packaging ships them.
            strip_conf_provider_keys
            # Then the wizard's env fallback entries (legacy FRACTALSQL_*
            # names and any empty-after-filter env file/plist dict) --
            # filter, not a whole-file Delete-All, so an admin's own
            # entries survive.
            strip_legacy_env
            case "${OS_FAMILY}" in
                debian|rhel)
                    if have_systemd; then
                        confirm "Restart fractalsqld now?" && { priv "${AS_ROOT}" systemctl restart fractalsqld; ok "fractalsqld restarted."; }
                    else
                        warn "No systemd found; strip the conf keys and restart fractalsqld yourself."
                    fi
                    ;;
                darwin)
                    local plist="${HOME}/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
                    if [[ -f "${plist}" ]]; then
                        confirm "Restart fractalsqld now?" && {
                            launchctl kickstart -k "gui/$(id -u)/com.fractalsqlabs.fractalsqld" >/dev/null 2>&1 \
                                || { launchctl unload "${plist}" >/dev/null 2>&1; launchctl load -w "${plist}"; }
                            ok "fractalsqld restarted."
                        }
                    fi
                    ;;
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
        darwin)
            echo "  To remove the files:"
            echo "    launchctl unload ~/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
            echo "    rm ${PLUGIN_DIR}/fractalsql.so ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
            echo "    sudo rm -rf /usr/local/libexec/fractalsql /etc/fractalsql ~/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
            ;;
    esac
}

# --- main ------------------------------------------------------------------
main() {
    detect_os
    detect_mariadb
    resolve_mdb_as
    priv_init
    log "Targeting MariaDB (plugin_dir ${PLUGIN_DIR})"

    if [[ "${UNINSTALL}" -eq 1 ]]; then
        uninstall_flow
        exit 0
    fi

    phase_b_install
    phase_c_wizard
}

main "$@"
