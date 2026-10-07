#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Conformance for fsqlctl, the standalone CLI. It talks to a real fractalsqld
# over the socket with no MariaDB and no shim. Checks the daemon's answers and
# the client's refusals, and confirms the CLI includes no shim, daemon, or
# core header.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
work=${CLI_WORK:-${TMPDIR:-/tmp}/fsqlctl_test.$$}
fsqlctl="$here/build/fsqlctl"
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

[ -x "$fsqlctl" ] || { echo "fsqlctl not built: run make all"; exit 1; }
rm -rf "$work"; mkdir -p "$work"
trap 'kill "$daemon_pid" 2>/dev/null; rm -rf "$work"' EXIT

openssl rand -hex 32 > "$work/hmac.key" && chmod 600 "$work/hmac.key"
cat > "$work/fractalsqld.conf" <<CONF
socket_path = $work/fsqld.sock
hmac_key_file = $work/hmac.key
allowed_uids = $(id -u)
CONF
# The conf file may carry plaintext provider secrets (reasoning_token,
# enterprise_ledger_key), so it is gated like the key file: startup and
# every reload both refuse a world/groups-readable conf.
chmod 600 "$work/fractalsqld.conf"

echo "== fsqlctl against a live fractalsqld (no MariaDB)"
"$here/build/fractalsqld" -c "$work/fractalsqld.conf" </dev/null >"$work/fsqld.log" 2>&1 &
daemon_pid=$!
i=0
while [ ! -S "$work/fsqld.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
export FSQLCTL_SOCKET="$work/fsqld.sock" FSQLCTL_KEY="$work/hmac.key"

out=$("$fsqlctl" ping 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "pong: protocol 2" ] && ok "ping answers with protocol 2" || bad "ping: rc=$rc out=$out"

out=$("$fsqlctl" version 2>&1); rc=$?
case "$out" in *"protocol 2"*) [ $rc -eq 0 ] && ok "version reports the daemon and protocol" || bad "version rc=$rc" ;;
    *) bad "version: $out" ;; esac

out=$("$fsqlctl" check 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "ping: ok" && ok "check: key, socket and ping all ok" || bad "check rc=$rc: $out"

out=$("$fsqlctl" call fractal_vector_dims '[1,2,3]' 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "3" ] && ok "call fractal_vector_dims returns 3" || bad "call dims: rc=$rc out=$out"

out=$("$fsqlctl" call fractal_vector_norm '[3,4]' 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "5" ] && ok "call fractal_vector_norm (REAL result) returns 5" || bad "call norm: rc=$rc out=$out"

out=$("$fsqlctl" call fractal_version 2>&1); rc=$?
[ $rc -eq 0 ] && [ -n "$out" ] && ok "call fractal_version (STRING result) returns text" || bad "call version: rc=$rc out=$out"

out=$("$fsqlctl" call fractal_vector_dims NULL 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "NULL" ] && ok "NULL argument yields a NULL result" || bad "call NULL: rc=$rc out=$out"

out=$("$fsqlctl" call no_such_function x 2>&1); rc=$?
[ $rc -eq 4 ] && ok "unknown function exits 4 without contacting the daemon" || bad "unknown fn: rc=$rc out=$out"

out=$("$fsqlctl" call fractal_vector_norm 'i:notanumber' 2>&1); rc=$?
[ $rc -eq 2 ] && ok "a bad integer argument exits 2" || bad "bad int: rc=$rc out=$out"

cp "$work/hmac.key" "$work/wrong.key"
openssl rand -hex 32 > "$work/wrong.key"
out=$(FSQLCTL_KEY="$work/wrong.key" "$fsqlctl" ping 2>&1); rc=$?
[ $rc -eq 3 ] && ok "wrong key is refused (exit 3)" || bad "wrong key: rc=$rc out=$out"

out=$(FSQLCTL_SOCKET="$work/absent.sock" "$fsqlctl" ping 2>&1); rc=$?
[ $rc -eq 1 ] && ok "absent socket exits 1" || bad "absent socket: rc=$rc out=$out"

printf 'not-hex\n' > "$work/bad.key"
out=$(FSQLCTL_KEY="$work/bad.key" "$fsqlctl" ping 2>&1); rc=$?
[ $rc -eq 1 ] && ok "malformed key file exits 1" || bad "bad key: rc=$rc out=$out"

chmod 644 "$work/hmac.key"
out=$("$fsqlctl" check 2>&1); rc=$?
case "$out" in *"readable by group or others"*) [ $rc -eq 0 ] && ok "check warns about a world-readable key file" || bad "check warn rc=$rc" ;;
    *) bad "check did not warn about mode 644" ;; esac
chmod 600 "$work/hmac.key"

echo "== hot reload: all-or-nothing config re-read"
cp "$work/fractalsqld.conf" "$work/fractalsqld.conf.bak"
# Pointing socket_path at a different path must be REFUSED (the shim reads
# socket_path once at mariadbd boot, so applying it live would strand every
# running client); the running config is then untouched.
sed 's|^socket_path = .*|socket_path = '"$work"'/other.sock|' "$work/fractalsqld.conf.bak" > "$work/fractalsqld.conf"
out=$("$fsqlctl" reload 2>&1); rc=$?
case "$out" in *"restart"*) [ $rc -eq 1 ] && ok "a changed socket_path is refused (exit 1) and the daemon keeps running" || bad "socket_path refusal rc=$rc: $out" ;;
    *) bad "socket_path reload not refused: rc=$rc out=$out" ;; esac

# An unrelated change (a fresh identical copy, i.e. no semantic change) reloads cleanly.
cp "$work/fractalsqld.conf.bak" "$work/fractalsqld.conf"
out=$("$fsqlctl" reload 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "reloaded: configuration swapped in" ] && ok "reload swaps the config in and answers" || bad "reload: rc=$rc out=$out"

# And the daemon still serves calls after both reloads.
out=$("$fsqlctl" call fractal_vector_dims '[1,2,3]' 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "3" ] && ok "calls still work after the reloads" || bad "post-reload call: rc=$rc out=$out"

echo "== hot reload: provider settings push live (no restart, no LLM)"
# fractalsqld.conf is now the preferred provider source (the boot
# environment is the fallback), and every provider key reloads live: the
# pushed value reaches the consumer on the tier's NEXT call, with no
# restart. fractal_t2s_config reflects the daemon's live text-to-sql
# config, so these probes need no dlopen and no LLM.
cp "$work/fractalsqld.conf.bak" "$work/fractalsqld.conf"
printf 'reasoning_plugin = %s/absent-fsql-plugin.so\nt2s_max_attempts = 5\nt2s_allowed_statements = select_insert_update\n' "$work" >> "$work/fractalsqld.conf"
chmod 600 "$work/fractalsqld.conf"
out=$("$fsqlctl" reload 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "reloaded: configuration swapped in" ] \
    && ok "reload accepts live provider keys" || bad "provider reload: rc=$rc out=$out"
out=$("$fsqlctl" call fractal_t2s_config 2>&1); rc=$?
case "$out" in *'"max_attempts":5'*) case "$out" in
    *select_insert_update*) ok "reloaded provider values reflect in the live daemon (t2s_config)" ;;
    *) bad "t2s_config shows the reloaded attempts but not the reloaded allowlist: $out" ;; esac ;;
    *) bad "t2s_config does not reflect the reloaded values: rc=$rc out=$out" ;; esac
# The reasoning tier re-loads its plugin from the pushed path on the next
# call and reports the failure to the daemon's log (errors on this runtime
# path cannot use the init-message channel).
out=$("$fsqlctl" call fractal_reason 'i:7' 's:probe' 2>&1); rc=$?
[ $rc -ne 0 ] && ok "fractal_reason fails as expected with an unloadable plugin path" \
    || bad "fractal_reason unexpectedly succeeded: $out"
tried=no
for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q "failed to load reasoning plugin" "$work/fsqld.log" 2>/dev/null && { tried=yes; break; }
    sleep 0.1
done
[ "$tried" = yes ] && ok "fractal_reason attempted a plugin load from the reloaded path (daemon log)" \
    || bad "the daemon log shows no reasoning-plugin load attempt after the reload"

# Removing the keys reverts the tiers to the boot-env fallback on the next
# call -- the environment here never carried the plugin or the overrides,
# so t2s_max_attempts returns to its default 2 and "select".
sed '/^reasoning_plugin/d;/^t2s_max_attempts/d;/^t2s_allowed_statements/d' \
    "$work/fractalsqld.conf" > "$work/fractalsqld.conf.new"
mv "$work/fractalsqld.conf.new" "$work/fractalsqld.conf"
chmod 600 "$work/fractalsqld.conf"
out=$("$fsqlctl" reload 2>&1); rc=$?
[ $rc -eq 0 ] && ok "reload with the provider keys removed" || bad "removal reload: rc=$rc out=$out"
out=$("$fsqlctl" call fractal_t2s_config 2>&1); rc=$?
case "$out" in *'"max_attempts":2'*) case "$out" in
    *select_insert_update*) bad "the allowlist did not revert after key removal: $out" ;;
    *) ok "removed keys revert to the boot-env fallback (defaults) live" ;;
esac ;;
    *) bad "t2s_config did not revert after key removal: rc=$rc out=$out" ;; esac
cp "$work/fractalsqld.conf.bak" "$work/fractalsqld.conf"

# The conf file carries provider secrets, so it is gated like the key
# file: a world-readable conf refuses the reload.
chmod 644 "$work/fractalsqld.conf"
out=$("$fsqlctl" reload 2>&1); rc=$?
case "$out" in *"permissions"*) [ $rc -eq 1 ] && ok "a world-readable conf file refuses the reload" || bad "644 conf refusal rc=$rc: $out" ;;
    *) bad "644 conf reload not refused: rc=$rc out=$out" ;; esac
chmod 600 "$work/fractalsqld.conf"

# Provider values are validated loudly on a reload (a deliberate file
# edit): the reload itself is refused with the generic CLI reply, and the
# named key + its expected range land in the daemon's log.
cp "$work/fractalsqld.conf.bak" "$work/fractalsqld.conf"
printf 't2s_max_attempts = 11\n' >> "$work/fractalsqld.conf"
chmod 600 "$work/fractalsqld.conf"
logmark=$(wc -c < "$work/fsqld.log" 2>/dev/null || echo 0)
out=$("$fsqlctl" reload 2>&1); rc=$?
case "$out" in *"provider settings rejected"*) [ $rc -eq 1 ] && ok "t2s_max_attempts out of range refuses the reload" || bad "range refusal rc=$rc: $out" ;;
    *) bad "t2s_max_attempts=11 not refused: rc=$rc out=$out" ;; esac
tail -c +"$(( logmark + 1 ))" "$work/fsqld.log" 2>/dev/null \
    | grep -q 'provider key t2s_max_attempts: must be an integer in \[1,10\] (got 11)' \
    && ok "the refusal names the key and its range in the daemon's log" \
    || bad "the range refusal did not name the key in the daemon's log"
cp "$work/fractalsqld.conf.bak" "$work/fractalsqld.conf"
chmod 600 "$work/fractalsqld.conf"

echo "== independence: the CLI includes no shim, daemon, or core header"
if grep -n '#include' "$here/cli/fsqlctl.c" | grep -E 'fsq_protocol|fsq_sha256|fractalsql|\.\./' >/dev/null; then
    bad "fsqlctl.c includes a project header"
else
    ok "fsqlctl.c includes only system and OpenSSL headers, plus its generated table"
fi

echo "== $pass passed, $fail failed"
[ $fail -eq 0 ]
