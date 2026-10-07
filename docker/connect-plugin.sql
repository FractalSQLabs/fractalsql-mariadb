-- Demo image only: loads the MariaDB CONNECT storage engine (package
-- mariadb-plugin-connect) so sql/install_enterprise_connect.sql can create
-- its read-only CSV mirror table.
INSTALL SONAME 'ha_connect';
