#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Gate-40 client driver for the fractalsql-mariadb-mcp direct-TLS mode.

Driven by build_test.sh's gate_40_mcp_https (and the matching PowerShell
gate): the gate itself generates the throwaway self-signed cert/key (via
the openssl CLI) and skips the whole gate if openssl isn't on PATH; this
driver only ever sees the resulting PEM paths.

Deliberately narrow in scope. The MCP HTTP transport's own behavior
(sessions, auth, framing, refusal shapes, concurrency) is the plaintext
transport's contract; this driver proves the FIVE things that are
specific to the TLS mode and untested anywhere else:
  1. fail-fast misconfiguration: TLS enabled with no cert/key, with a
     cert that doesn't load, with a key that doesn't parse, and with a
     valid cert paired with a NON-MATCHING valid key -- all four exit
     nonzero immediately, never falling back to plaintext or hanging.
  2. the listening port actually speaks TLS, not plaintext HTTP (a bare
     HTTP request against it gets no valid HTTP response).
  3. the full authenticated JSON-RPC round trip works over TLS.
  4. the Bearer-token check still applies underneath TLS (TLS is
     additive, never a substitute for the token).
  5. the session lifecycle still works over TLS: initialize mints a
     Mcp-Session-Id, and DELETE closes it.

It also pins the TWO HTTP-transport invariants that the TLS path
shares, because this is the only HTTP client driver in the tree:
  6. one request, one reply, one close -- the 200 says
     "Connection: close", so a client that pools connections does not
     hand the next request to a socket the server has already shut.
  7. a path the server does not serve is TERMINAL -- the 404 is the
     whole answer. The request must not continue into the dispatch, so
     a wrong path can never produce a second response and can never
     run the tool.

MariaDB shape, not a copy: this server's TLS mode is selected by
environment (FSQL_MCP_HTTP_TLS + FSQL_MCP_TLS_CERT / FSQL_MCP_TLS_KEY)
rather than by a --https flag, and the HTTP transport is enabled with
--http PORT. The engine's version tool is fractalsql_get_version.

Input (environment, all required unless noted):
  MCP_SERVER_EXE       the fractalsql-mariadb-mcp binary just built
  MCP_SERVER_CWD       the server process's working directory (its
                       stderr JSON log lands here as mcp_https_server.log)
  MCP_HTTPS_PORT       a free localhost port, distinct from every other
                       gate's port (the harness's own 133xx range)
  MCP_HTTPS_CERT       PEM cert path (the gate's throwaway self-signed one)
  MCP_HTTPS_KEY        PEM key path

The engine's own connection details come from the standard MARIADB_*
variables, exactly as the MCP server itself reads them
(EngineConfig::fromEnv) -- the harness exports those for its scratch
cluster before spawning this driver.

Exits 0 on all-pass, 1 otherwise; prints PASS/FAIL lines the gates
relabel."""

from __future__ import annotations

import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import time

_failures = 0


def check(label: str, cond: bool) -> bool:
    global _failures
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        _failures += 1
    return bool(cond)


def https_conn(port: int, timeout: float = 15.0) -> http.client.HTTPSConnection:
    # The throwaway cert is self-signed for 127.0.0.1; this driver only
    # ever talks to the server it just spawned, so disabling verification
    # is the correct choice here (there is no CA to verify against) and
    # not a stand-in for a real deployment's trust posture.
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return http.client.HTTPSConnection("127.0.0.1", port, timeout=timeout, context=ctx)


def https_req(port, method, path, body=None, token=None, session=None, timeout=15.0):
    headers = {}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    if session is not None:
        headers["Mcp-Session-Id"] = session
    try:
        conn = https_conn(port, timeout=timeout)
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", "replace")
        hdrs = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, hdrs, data
    except Exception:
        return None, {}, ""


def https_raw_exchange(port, method, path, body=None, token=None, session=None,
                       timeout=15.0, _retry=True):
    """Send one request and read the connection to EOF, returning the raw
    bytes. Used to prove how MANY responses a request produced: a normal
    client helper reads one response and closes, which cannot tell "the
    server sent a 404 and nothing else" apart from "the server sent a 404
    and then a second response that the client never looked at"."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    payload = (body or "").encode("utf-8")
    head = f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if token is not None:
        head += f"Authorization: Bearer {token}\r\n"
    if session is not None:
        head += f"Mcp-Session-Id: {session}\r\n"
    head += f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n"
    chunks = []
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as raw:
        with ctx.wrap_socket(raw, server_hostname="127.0.0.1") as sock:
            sock.sendall(head.encode("utf-8") + payload)
            while True:
                try:
                    data = sock.recv(65536)
                except (socket.timeout, ssl.SSLError, OSError):
                    break
                if not data:
                    break
                chunks.append(data)
    if not chunks and _retry:
        # The server writes its reply and closes without reading the
        # request body, so the close is an RST and the client's kernel may
        # drop the reply it had already buffered. The data itself is
        # delivered before the reset (same connection, in order, and the
        # client is already blocked in recv), so this is rare -- but a
        # lost reply must not read as "the server said nothing". Retry
        # once before reporting an empty exchange.
        return https_raw_exchange(port, method, path, body=body, token=token,
                                  session=session, timeout=timeout, _retry=False)
    return b"".join(chunks)


def plaintext_probe(port: int, timeout: float = 3.0) -> bool:
    """True if a bare HTTP request against the port gets back something
    that looks like an HTTP response -- i.e. the port is NOT TLS-only."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
            sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
            data = sock.recv(256)
        return data.startswith(b"HTTP/1.")
    except Exception:
        return False


def cli_run(mcp_exe, cwd, extra_args, env, timeout=30):
    return subprocess.run([mcp_exe] + extra_args, capture_output=True, text=True,
                          cwd=cwd, env=env, timeout=timeout, input="")


def main() -> int:  # noqa: ANN201
    mcp_exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ["MCP_SERVER_CWD"]
    port = int(os.environ["MCP_HTTPS_PORT"])
    cert = os.environ["MCP_HTTPS_CERT"]
    key = os.environ["MCP_HTTPS_KEY"]
    base_env = dict(os.environ)
    token = "g40-https-tok"

    # TLS is selected by the environment, not by a flag. FSQL_MCP_HTTP_TLS
    # is read by the server as "true"; the cert/key come from
    # FSQL_MCP_TLS_CERT / FSQL_MCP_TLS_KEY.
    #
    # The server's own env vars are set HERE, not inherited: this driver's
    # inputs (MCP_HTTPS_CERT / MCP_HTTPS_KEY) are named differently from
    # the server's (FSQL_MCP_TLS_CERT / FSQL_MCP_TLS_KEY), so without
    # this translation the server starts with TLS enabled and NO cert
    # or key at all -- it fails the "TLS requires cert and key" check
    # and exits 2, which every fail-fast case below would then read as
    # a pass for entirely the wrong reason, and the real-server case
    # would never come up at all.
    common_env = dict(base_env, FSQL_MCP_AUTH_TOKEN=token, FSQL_MCP_HTTP_PORT=str(port),
                      FSQL_MCP_BIND="127.0.0.1", FSQL_MCP_HTTP_PATH="/mcp",
                      FSQL_MCP_HTTP_TLS="true",
                      FSQL_MCP_TLS_CERT=cert, FSQL_MCP_TLS_KEY=key)

    # 1a. fail-fast: TLS enabled with no cert/key configured at all.
    no_tls_env = dict(common_env)
    no_tls_env.pop("FSQL_MCP_TLS_CERT", None)
    no_tls_env.pop("FSQL_MCP_TLS_KEY", None)
    r = cli_run(mcp_exe, cwd, ["--http", str(port)], no_tls_env)
    check("TLS with no cert/key configured exits nonzero immediately "
          "(never silently serves plaintext)",
          r.returncode != 0 and ("cert" in r.stderr.lower() or "key" in r.stderr.lower()))

    # 1b. fail-fast: a cert file that doesn't exist/load.
    r = cli_run(mcp_exe, cwd, ["--http", str(port)],
                dict(common_env, FSQL_MCP_TLS_CERT=os.path.join(cwd, "mcp_https_no_such_cert.pem"),
                     FSQL_MCP_TLS_KEY=key))
    check("TLS with an unloadable cert file exits nonzero (TLS init "
          "failure, not a hang or a crash)", r.returncode != 0)

    # 1c. fail-fast: a valid cert paired with a KEY file that isn't a real
    # key at all. This isolates the private-key load failure from 1b's
    # cert-load failure -- two distinct paths through the TLS context
    # setup, and the operator's remedy for each is different.
    bad_key = os.path.join(cwd, "mcp_https_garbage_key.pem")
    with open(bad_key, "w", encoding="utf-8") as fh:
        fh.write("-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----\n")
    r = cli_run(mcp_exe, cwd, ["--http", str(port)],
                dict(common_env, FSQL_MCP_TLS_CERT=cert, FSQL_MCP_TLS_KEY=bad_key))
    check("TLS with a cert that loads but a key file that doesn't "
          "parse exits nonzero", r.returncode != 0)

    # 1d. fail-fast: a valid cert paired with a valid key that just
    # doesn't belong to it. Both files load fine individually -- they
    # simply don't match each other. Without an explicit key/cert match
    # check this surfaces much later, as a handshake failure on every
    # single connection, which is indistinguishable from a broken
    # client. A second throwaway self-signed pair, same minimal-config
    # recipe the gate uses for the first.
    cert2 = os.path.join(cwd, "mcp_https_cert2.pem")
    key2 = os.path.join(cwd, "mcp_https_key2.pem")
    cnf2 = os.path.join(cwd, "mcp_https_openssl2.cnf")
    with open(cnf2, "w", encoding="utf-8") as fh:
        fh.write("[req]\ndistinguished_name = dn\nprompt = no\n[dn]\n")
    genrc = subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=127.0.0.1", "-config", cnf2, "-keyout", key2, "-out", cert2],
        capture_output=True, text=True)
    if genrc.returncode == 0:
        r = cli_run(mcp_exe, cwd, ["--http", str(port)],
                    dict(common_env, FSQL_MCP_TLS_CERT=cert, FSQL_MCP_TLS_KEY=key2))
        check("TLS with a valid cert and a valid but NON-MATCHING key "
              "exits nonzero (cert/key mismatch, not a load failure)",
              r.returncode != 0)
    else:
        check("TLS with a valid cert and a valid but NON-MATCHING key "
              "exits nonzero (skipped: couldn't generate the second "
              "throwaway cert/key pair)", True)

    # 2-5. the real server: TLS-only listening, auth still enforced, and a
    # full authenticated JSON-RPC round trip over the direct-TLS transport.
    log_path = os.path.join(cwd, "mcp_https_server.log")
    log = open(log_path, "w", encoding="utf-8")
    proc = None
    try:
        proc = subprocess.Popen(
            [mcp_exe, "--http", str(port)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            cwd=cwd, env=common_env, text=True)
        proc.stdin.close()

        up = False
        for _ in range(100):
            s, _, _ = https_req(port, "GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        if not check("TLS: the transport comes up and GET /healthz "
                     "answers over TLS unauthenticated", up):
            print("---- server log tail ----")
            log.flush()
            print(open(log_path, encoding="utf-8").read()[-2000:])
            return 1

        check("TLS: a bare plaintext HTTP request against the port "
              "gets no valid HTTP response (TLS-only, not dual-stack)",
              not plaintext_probe(port))

        s, _, b = https_req(port, "POST", "/mcp", body='{"jsonrpc":"2.0"}')
        check("TLS does not bypass the Bearer-token check "
              "(unauthenticated POST still 401)", s == 401)

        init_params = {"protocolVersion": "2025-06-18",
                       "clientInfo": {"name": "gate40", "version": "0"}}
        s, h, b = https_req(port, "POST", "/mcp", token=token, body=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": init_params}))
        minted = h.get("mcp-session-id")
        check("TLS: initialize over TLS answers 200 and mints a session",
              s == 200 and bool(minted))

        # The server writes one reply and then closes the connection, but
        # HTTP/1.1 defaults to KEEP-ALIVE. A client that pools
        # connections (httpx, requests.Session, urllib3 -- all standard
        # for this transport) reads the reply, sees no "Connection:
        # close", and returns the socket to the pool. The next request
        # goes to a socket the server has already shut and the client
        # sees a reset on an otherwise healthy server. Every other
        # response the transport writes says "Connection: close"; the
        # 200 carrying the JSON-RPC body did not.
        check("TLS: the 200 reply says 'Connection: close' (the server "
              "closes after one reply, so a pooled client must not "
              "reuse the socket)",
              h.get("connection", "").lower() == "close")

        # A path the server does not serve is TERMINAL: the 404 IS the
        # answer. If the 404 were written and the request then carried
        # on into the auth check and the dispatch, an authenticated
        # POST would get a 404 AND a second response (the tool's own
        # result) on the same connection -- two HTTP responses, and the
        # tool really ran. A client that reads one response per
        # connection is then left holding the stale second response in
        # its socket buffer, and the next request on a pooled socket
        # parses that as its own. Read the connection to EOF so the
        # count of responses is actually observed.
        raw = https_raw_exchange(
            port, "POST", "/not-the-mcp-path", token=token, session=minted,
            body=json.dumps({"jsonrpc": "2.0", "id": 99,
                             "method": "tools/call",
                             "params": {"name": "fractalsql_get_version",
                                        "arguments": {}}}))
        text = raw.decode("utf-8", "replace")
        check("TLS: an authenticated POST to a path the server does not "
              "serve gets exactly ONE response (the 404)",
              text.count("HTTP/1.1 ") == 1 and " 404 " in text)
        check("TLS: that wrong-path POST does NOT run the tool (no "
              "JSON-RPC result follows the 404)",
              '"result"' not in text and '"jsonrpc"' not in text)

        s, _, b = https_req(port, "POST", "/mcp", token=token, session=minted,
                            body=json.dumps({"jsonrpc": "2.0", "id": 2,
                                            "method": "tools/call",
                                            "params": {"name": "fractalsql_get_version",
                                                       "arguments": {}}}))
        edition = None
        if s == 200 and b.startswith("{"):
            try:
                edition = (json.loads(b).get("result") or {}) \
                    .get("structuredContent", {}).get("edition")
            except Exception:
                edition = None
        check("TLS: a full authenticated tools/call round-trips the "
              "same engine over TLS", s == 200 and edition == "Community")

        s, _, _ = https_req(port, "DELETE", "/mcp", token=token, session=minted)
        check("TLS: DELETE closes the TLS session cleanly (200)", s == 200)

        proc.terminate()
        try:
            rc = proc.wait(timeout=25)
        except Exception:
            proc.kill()
            rc = proc.wait(timeout=10)
        if os.name != "nt":
            check("TLS: the transport drains and exits cleanly on "
                  "termination", rc == 0)
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:
                pass
        log.close()

    return 1 if _failures else 0


if __name__ == "__main__":
    try:
        code = main()
    except SystemExit as exc:
        code = int(exc.code or 0)
    print(f"gate40-client: {'ALL GREEN' if code == 0 else 'FAILED'}; "
          f"{_failures} failure(s)")
    sys.exit(code)
