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
Version:        2.0.9
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
%{libexecdir}/fractalsqld
%{_unitdir}/fractalsqld.service
%{sharedir}/install_udf.sql
%{sharedir}/install_agents.sql
%dir %attr(0750,fractalsql,fractalsql) %{confdir}

%changelog
* Tue Sep 23 2026 FractalSQLabs - 2.0.7-1
- v2.0.7: 10 new v2.0.25-core analytics/vector primitives as UDFs
  (change-point detection, periodogram, SimHash state fingerprint,
  streaming cycle detection, TDA persistence, k-subset allocation,
  Lp distance, int8/binary quantization, Hamming distance), agent
  loop-detection rewrite over real state fingerprints, JSON_VALUE
  boolean-contract fix in shipped procedures.
* Sun Aug 30 2026 FractalSQLabs - 2.0.0-1
- Full v2.0.0: Discovery/Vector/Cognition/Text-to-SQL/Vectorizer/
  Agency/Enterprise-activation tiers. Single generic package (no
  per-major split -- the UDF ABI is stable across the whole 10.6-12.3
  compat range), Apache-2.0, no LuaJIT.
* Sat Apr 18 2026 FractalSQLabs - 1.0.0-1
- Initial Factory-standardized release for MariaDB 10.6 / 10.11 / 11.4.
