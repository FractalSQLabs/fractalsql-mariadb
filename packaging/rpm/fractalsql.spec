%global         plugindir %{_libdir}/mysql/plugin
%global         sharedir  %{_datadir}/fractalsql-mariadb

# Reference-only spec: scripts/package.sh (fpm-based, generic
# mariadb-server dependency, no per-major fan-in -- the UDF ABI is
# stable across MariaDB 10.6/10.11/11.4 LTS/12.3 LTS) is the
# actual build/package path used by CI (release.yml, install-test.yml)
# and documented in scripts/package.sh's own header. This file is kept
# for maintainers who prefer a native `rpmbuild` flow instead of fpm --
# it is not exercised by any workflow in this repo.

Name:           fractalsql-mariadb
Version:        2.0.3
Release:        1%{?dist}
Summary:        Stochastic Fractal Search UDF for MariaDB (10.6 / 10.11 / 11.4 LTS / 12.3 LTS)

License:        Apache-2.0
URL:            https://github.com/FractalSQLabs/fractalsql-mariadb
Source0:        fractalsql-mariadb-%{version}.tar.gz

BuildRequires:  gcc, make, MariaDB-devel
Requires:       mariadb-server
Requires:       libcurl.so.4()(64bit)

%description
fractalsql-mariadb registers the fractal_search() UDF, a Stochastic
Fractal Search optimizer that returns JSON top-k matches for a query
vector against an inline corpus, plus the full Discovery/Vector/
Cognition/Text-to-SQL/Agency/Enterprise-activation tier surface (see
docs/features.md). Pure-C vendored core, no LuaJIT runtime dependency.
The bundled fractalsql-reasoning-http.so plugin (Cognition/Text-to-SQL/
Vectorizer/Agency tiers) dynamically links libcurl at runtime.

%prep
%setup -q

%build
# The .so is produced out-of-band by build.sh on a Docker builder
# (glibc-pinned per PROFILE, see build.sh's own header); this spec
# just stages the already-built artifact.
test -f dist/amd64/fractalsql.so

%install
install -Dm0755 dist/amd64/fractalsql.so \
    %{buildroot}%{plugindir}/fractalsql.so
install -Dm0755 include/linux-x86_64/fractalsql-reasoning-http.so \
    %{buildroot}%{plugindir}/fractalsql-reasoning-http.so
install -Dm0644 sql/install_udf.sql \
    %{buildroot}%{sharedir}/install_udf.sql
install -Dm0644 sql/install_agents.sql \
    %{buildroot}%{sharedir}/install_agents.sql

%files
%license LICENSE
%doc THIRD-PARTY-NOTICES.md
%{plugindir}/fractalsql.so
%{plugindir}/fractalsql-reasoning-http.so
%{sharedir}/install_udf.sql
%{sharedir}/install_agents.sql

%changelog
* Sun Aug 30 2026 FractalSQLabs <ops@fractalsqlabs.io> - 2.0.0-1
- Full v2.0.0 port: Discovery/Vector/Cognition/Text-to-SQL/Vectorizer/
  Agency/Enterprise-activation tiers. Single generic package (no
  per-major split -- the UDF ABI is stable across the whole 10.6-12.3
  compat range), Apache-2.0, no LuaJIT.
* Sat Apr 18 2026 FractalSQLabs <ops@fractalsqlabs.io> - 1.0.0-1
- Initial Factory-standardized release for MariaDB 10.6 / 10.11 / 11.4.
