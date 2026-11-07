%global         plugindir %{_libdir}/mysql/plugin
%global         sharedir  %{_datadir}/fractalsql-mariadb
%global         libexecdir %{_libexecdir}/fractalsql
%global         confdir   %{_sysconfdir}/fractalsql

# Reference-only spec: scripts/package.sh (fpm-based, generic
# mariadb-server dependency, no per-major fan-in -- the UDF ABI is
# stable across MariaDB 10.6/10.11/11.4 LTS/12.3 LTS) is the
# actual build/package path used by CI (release.yml, install-test.yml)
# and documented in scripts/package.sh's own header. This file is kept
# for maintainers who prefer a native `rpmbuild` flow instead of fpm --
# it is not exercised by any workflow in this repo. It packages the
# same pair fpm does: fractalsql.so (GPL-2.0-only shim, loaded by
# mariadbd) and fractalsqld (Apache-2.0 daemon, its own process).
# Shipping the shim without the daemon isn't an option: nothing would
# run the UDF bodies the shim forwards calls to.

Name:           fractalsql-mariadb
Version:        2.0.12
Release:        1%{?dist}
Summary:        FractalSQL UDF for MariaDB (10.6 / 10.11 / 11.4 LTS / 12.3 LTS)

License:        GPL-2.0-only AND Apache-2.0 AND MIT AND LicenseRef-PublicDomain
URL:            https://github.com/FractalSQLabs/fractalsql-mariadb
Source0:        fractalsql-mariadb-%{version}.tar.gz

BuildRequires:  gcc, make, MariaDB-devel
Requires:       mariadb-server
Requires:       libcurl.so.4()(64bit)
Requires:       libcrypto.so.3()(64bit)
Requires(post): shadow-utils, systemd, openssl
Requires(preun): systemd
%{?systemd_requires}

%description
fractalsql-mariadb registers the fractal_search() UDF, a Stochastic
Fractal Search optimizer that returns JSON top-k matches for a query
vector against an inline corpus, plus the full Discovery/Vector/
Cognition/Text-to-SQL/Agency/Enterprise-activation tier surface (see
docs/features.md). Pure-C vendored core, no LuaJIT runtime dependency.
mariadbd loads only a thin shim (fractalsql.so); every UDF body runs in
the separate fractalsqld daemon this package also installs and
services via systemd. The bundled fractalsql-reasoning-http.so plugin
(Cognition/Text-to-SQL/Vectorizer/Agency tiers), loaded by the daemon,
dynamically links libcurl at runtime.

%prep
%setup -q

%build
# Both binaries are produced out-of-band by build.sh on a Docker
# builder (glibc-pinned per PROFILE, see build.sh's own header); this
# spec just stages the already-built pair.
test -f dist/amd64/fractalsql.so
test -f dist/amd64/fractalsqld

%install
install -Dm0755 dist/amd64/fractalsql.so \
    %{buildroot}%{plugindir}/fractalsql.so
install -Dm0755 dist/amd64/fractalsqld \
    %{buildroot}%{libexecdir}/fractalsqld
install -Dm0755 include/linux-x86_64/fractalsql-reasoning-http.so \
    %{buildroot}%{plugindir}/fractalsql-reasoning-http.so
install -Dm0644 include/linux-x86_64/fractalsql-reasoning-http.so.sig \
    %{buildroot}%{plugindir}/fractalsql-reasoning-http.so.sig
install -Dm0644 sql/install_udf.sql \
    %{buildroot}%{sharedir}/install_udf.sql
install -Dm0644 sql/install_agents.sql \
    %{buildroot}%{sharedir}/install_agents.sql
install -Dm0644 packaging/systemd/fractalsqld.service \
    %{buildroot}%{_unitdir}/fractalsqld.service
install -d -m 0750 %{buildroot}%{confdir}

%pre
getent group fractalsql >/dev/null || groupadd --system fractalsql
getent passwd fractalsql >/dev/null || \
    useradd --system --gid fractalsql --no-create-home \
        --shell /sbin/nologin --comment "FractalSQL daemon" fractalsql
exit 0

%post
# Same provisioning as packaging/scripts/postinst.sh (the fpm hook for
# the .deb/.rpm fpm itself builds); kept in sync by hand since this
# spec is a separate, unexercised build path.
getent passwd mysql >/dev/null 2>&1 && usermod -aG fractalsql mysql || true
chown fractalsql:fractalsql %{confdir}
KEY=%{confdir}/hmac.key
if [ ! -f "$KEY" ]; then
    oldumask=$(umask); umask 077
    openssl rand -hex 32 > "$KEY"
    umask "$oldumask"
    chown fractalsql:fractalsql "$KEY"; chmod 0640 "$KEY"
fi
MYSQL_UID="$(id -u mysql 2>/dev/null || echo 0)"
if [ ! -f %{confdir}/fractalsqld.conf ]; then
    cat > %{confdir}/fractalsqld.conf <<CONF
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = $KEY
allowed_uids = ${MYSQL_UID}
CONF
    chown fractalsql:fractalsql %{confdir}/fractalsqld.conf
    chmod 0640 %{confdir}/fractalsqld.conf
fi
if [ ! -f %{confdir}/fractalsql.conf ]; then
    cat > %{confdir}/fractalsql.conf <<CONF
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = $KEY
CONF
    chown root:mysql %{confdir}/fractalsql.conf 2>/dev/null || chown root:root %{confdir}/fractalsql.conf
    chmod 0640 %{confdir}/fractalsql.conf
fi
%systemd_post fractalsqld.service
systemctl enable --now fractalsqld.service >/dev/null 2>&1 || true

%preun
%systemd_preun fractalsqld.service

%postun
%systemd_postun_with_restart fractalsqld.service

%files
%license LICENSE LICENSES/*
%doc THIRD-PARTY-NOTICES.md GPL-SOURCE-OFFER.txt
%{plugindir}/fractalsql.so
%{plugindir}/fractalsql-reasoning-http.so
%{plugindir}/fractalsql-reasoning-http.so.sig
%{libexecdir}/fractalsqld
%{_unitdir}/fractalsqld.service
%{sharedir}/install_udf.sql
%{sharedir}/install_agents.sql
%dir %attr(0750,fractalsql,fractalsql) %{confdir}

%changelog
* Sat Nov 07 2026 FractalSQLabs - 2.0.12-1
- Safety: the reasoning plugin is now signed. It ships with a detached
  Ed25519 signature (.sig) beside it and loads only when that file is
  present and valid; a missing signature is refused unless
  FSQL_REASONING_REQUIRE_SIGNATURE=0 is set, and a wrong one is always
  refused. The enterprise library signature requirement is unchanged.
- Removed FRACTALSQL_REASONING_ALLOW_UNVERIFIED and
  FRACTALSQL_REASONING_PLUGIN_SHA256; use
  FSQL_REASONING_REQUIRE_SIGNATURE=0 to load an unsigned plugin.
- Packaging: the plugin's .sig is installed beside the plugin, and the
  Windows installer now includes the reasoning plugin.

* Wed Oct 21 2026 FractalSQLabs - 2.0.11-1
- Text-to-SQL: fractal_sql_agent and the MCP text-to-SQL tool take a
  required p_auto_execute argument. FALSE generates and validates the
  statement and returns it without running it; TRUE runs it under the
  caller's privileges. NULL is treated as FALSE. Existing calls to the
  procedure need the extra argument.
- Safety: a reasoning plugin is verified (signature or pinned digest)
  before it is loaded; generated SELECT/INSERT/UPDATE statements are
  checked against a list of functions they may not call; the text of an
  agent's question can be hashed or masked before it is written to an
  audit entry.
- Work limits: calls that can run for a long time are bounded by the
  size of the job requested, with defaults suited to a shared server;
  an oversized request returns a clear error. Geometry functions refuse
  non-finite coordinates and degenerate input, and the periodogram uses
  an FFT for long series.
- Audit ledger: the chain, CSV mirror and head files are owner-only; a
  signed head file makes truncation detectable and fractal_ledger_verify
  names the specific failure; a session can lock the destructive ledger
  operations; the daemon refuses a configuration file other users can
  read.
- MCP: authentication with a deployment token or a per-client token
  policy file; the registered tool surface is pinned by committed lock
  files; both the handshake and the stateless request styles are
  supported; new conformance and fuzz tests and Windows ASan/UBSan
  build scripts; the MCP documentation is rewritten with a full settings
  reference.
- Documentation and packaging: the support matrix lists Linux amd64 and
  arm64 separately; the Docker image, install scripts and bundled core
  libraries are refreshed.
- MCP: the SIGHUP handler now only raises a flag and the auth-token
  reload happens on the request path (the reload is file I/O plus
  allocation, neither of which is async-signal-safe); the HTTP
  transport serves one request per connection instead of holding a
  keep-alive loop; the shutdown flag is an atomic, closing a genuine
  data race against the per-connection threads; command-line parsing,
  the connection setup, and the version-skew check are split into
  their own units; coverage builds use atomic profile updates so the
  thread-per-connection transport cannot corrupt its own counters.
- Test coverage: new assertions inside the existing gates (composite
  foreign keys with ON UPDATE/ON DELETE actions in the schema
  context, the non-keyword/INSERT/empty-candidate branches of the
  text-to-SQL allowlist, schema context against a table-less
  database, the vectorizer's argument-validation and failed-queue
  paths, and the reasoning tier's argument-count and input-size
  caps), new standalone probe suites for the MCP vector, database, and
  concurrency layers, a deterministically slow reasoning plugin so the
  shutdown-drain path is exercised with a request genuinely in flight,
  and a sanitizer runtime that refused to start in the host process is
  now reported as a skip rather than an extension failure.
- Benchmarks: the connection target is validated before the driver is
  asked to connect, so a malformed host or database name cannot
  silently redirect a run at another server.
- Shim: a failure with an empty message is replaced by a generic
  one -- MariaDB renders an empty error buffer as a NULL result with
  no explanation at all -- and the per-call error buffers are zeroed
  on entry.
- Cognition: the string-duplication helper rejects a null output
  pointer instead of dereferencing it.
- Build and install scripts: the Docker build rejects an unrecognized
  argument and an unhandled architecture instead of continuing; the
  Linux install script pins its downloads to https in one auditable
  place; the Windows install script's wizard is split into single-step
  functions and its release download asserts an https scheme.
* Mon Oct 12 2026 FractalSQLabs - 2.0.10-1
- Pin darwin-asan/ubsan/tsan CI jobs to mariadb lts.
- Add vcpkg binary caching to Windows CI jobs.
* Wed Oct 07 2026 FractalSQLabs - 2.0.9-1
- 10 new analytics and vector functions: change-point detection,
  periodogram, state fingerprinting, cycle detection, TDA persistence
  diagrams, subset optimization, L_p distance, and int8/binary vector
  quantization with Hamming-distance matching.
- ctid-based id resolution for table-backed agents, so row references
  survive table rewrites; the trajectory and cross-modal agents are
  unchanged.
- Agents: 16 engines updated; new fractal_agent_detect_loop (SimHash,
  streaming cycle detection and DFA) and a metric argument for
  fractal_agent_outlier_intercept.
- Two new vertical demos (biotech-genomics, agentic-edge-swarm); the
  quant-finance and cybersecurity demos exercise the new analytics
  functions.
- Full-API benchmark functions; refreshed docs across the api-* pages,
  features, composition-guide, starter-kits and the demo README.
- Refreshed vendored core artifacts, build-test assertions and CI
  workflow tests for the easy_install assets.
