#!/bin/bash
#
# scripts/enterprise/anchor-ledger.sh — external anchoring for the
# enterprise decision-audit ledger (fractalsql_ledger).
#
# What this closes: fractal_ledger_verify() proves nothing in the
# MIDDLE of the chain was altered or removed (every row's entry_hash
# recomputes from its own blob/mac and matches the next row's
# prev_hash). It cannot prove nothing was TRUNCATED off the very END --
# there's nothing after the last row to notice its absence. That needs
# an anchor outside this database: a record of "the chain's tip was X
# as of this time," written somewhere the database's own admin can't
# quietly rewrite. This script produces that record; you decide where
# it lives (see the PUBLISH step below).
#
# Usage (as a cron job, one line per chain you want anchored):
#   */15 * * * * MARIADB_HOST=... MARIADB_DATABASE=... /path/to/anchor-ledger.sh 1 >> /var/log/fractalsql/anchor.log
#   */15 * * * * MARIADB_HOST=... MARIADB_DATABASE=... /path/to/anchor-ledger.sh 2 >> /var/log/fractalsql/anchor.log
#
# Argument: the ledger `kind` to anchor -- 1 = QTL (fractal_ledger_flush),
# 2 = the general decision-audit chain (fractal_audit_log). Anchor
# whichever your audit scope covers; most CISO reviews want both.
#
# Connection: the mariadb client picks up MARIADB_HOST / MARIADB_PORT /
# MARIADB_TCP_PORT / MARIADB_USER / MARIADB_PWD from the environment the
# same way mariadb-dump does; override MARIADB_CLIENT below if the
# binary is named `mysql` on your box. The tip is read through the
# CONNECT-engine mirror table (sql/install_enterprise_connect.sql); on a
# deployment without the CONNECT plugin, point SQL_TIP at an equivalent
# SELECT over the ledger CSV's columns -- same fields, same result.
#
# Verifying an anchor later: an anchor record is only useful if you can
# re-derive it. Given an anchored (kind, id, entry_hash), confirm the
# LIVE table still has a row at that id, for that kind, with that exact
# entry_hash:
#   SELECT entry_hash_hex = '<anchored hex>'
#   FROM fractalsql_ledger WHERE kind = <kind> AND id = <anchored id>;
# 0 or no row = the row was altered, or the chain was rewound past
# it -- either way, tampering after the anchor was taken.

set -euo pipefail

KIND="${1:?usage: anchor-ledger.sh <kind> (1=QTL, 2=decision-audit)}"
MARIADB_CLIENT="${MARIADB_CLIENT:-mariadb}"

# The tip only -- O(1), no full chain walk needed to anchor (that's
# what fractal_ledger_verify() is for, on your own audit cadence).
if ! ROW="$("${MARIADB_CLIENT}" --batch --skip-column-names --raw \
    -e "SELECT id, entry_hash_hex, updated FROM fractalsql_ledger \
        WHERE kind = ${KIND} ORDER BY id DESC LIMIT 1;")"; then
    echo "anchor-ledger: could not read fractalsql_ledger (is the CONNECT mirror installed? see sql/install_enterprise_connect.sql)" >&2
    exit 1
fi

if [[ -z "${ROW}" ]]; then
    echo "anchor-ledger: no rows for kind=${KIND} yet -- nothing to anchor" >&2
    exit 0
fi

IFS=$'\t' read -r ID ENTRY_HASH UPDATED_EPOCH <<< "${ROW}"
ANCHORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD="anchor kind=${KIND} id=${ID} entry_hash=${ENTRY_HASH} row_updated=${UPDATED_EPOCH} anchored_at=${ANCHORED_AT}"

# --- PUBLISH: pick (or combine) whichever of these match your actual
# compliance posture. The point is that this record ends up somewhere
# the MariaDB admin's own credentials can't retroactively edit --
# stdout alone (the default) does NOT satisfy that; redirect it
# yourself (see the crontab line above) or uncomment a sink below.

echo "${RECORD}"

# SIEM via syslog (logger ships to whatever your syslog daemon forwards
# to -- most SIEMs ingest this natively):
# logger -t fractalsql-ledger-anchor "${RECORD}"

# Object-lock storage (S3 Object Lock / WORM-mode bucket -- requires
# the bucket already have Object Lock enabled; a normal bucket does NOT
# give you this guarantee):
# echo "${RECORD}" | aws s3 cp - "s3://your-anchor-bucket/fractalsql/kind-${KIND}/${ANCHORED_AT}.txt"

# Email (any MTA on the box; a compliance mailbox nobody with DB access
# can also purge is the point):
# echo "${RECORD}" | mail -s "FractalSQL ledger anchor (kind=${KIND})" compliance@example.com