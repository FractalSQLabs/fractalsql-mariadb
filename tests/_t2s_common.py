"""tests/_t2s_common.py: shared helpers for the fractal_text_to_sql
test suite (test_text_to_sql_*.py, test_scout.py, test_vectorizer.py).

Deliberately much thinner than fractalsql-postgresql's own
_t2s_common.py: MariaDB's reasoning config is a handful of FRACTALSQL_*
process environment variables read once by
fractalsql_cognition.c/fractalsql_textsql.c's ensure_env_config(), NOT
a postgres-style GUC. There is no ALTER SYSTEM SET + pg_reload_conf()
+ reconnect equivalent. Once mariadbd has started (see build_test.sh
and the install-test.yml jobs, which export FRACTALSQL_REASONING_PLUGIN
/ HTTP_URL / HTTP_EMBED_URL / HTTP_ALLOW_PLAINTEXT into mariadbd's own
environment before launch), the reasoning plugin path and endpoint URL
for the rest of that server's lifetime are fixed. A test that needs a
DIFFERENT canned reply per case (test_text_to_sql_fuzz.py) works around
this by keeping the URL constant and swapping what a long-lived local
mock server RETURNS instead -- see MutableMockLLMServer below and
_mock_llm_server.py's MockLLMServer/MockEmbedServer for the one-shot
variants that don't need this.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)


def get_dsn_kwargs():
    """Connection kwargs for mariadb.connect(), from FRACTALSQL_* env
    vars with the same defaults build_test.sh's own MARIADB[] client
    array uses (unix socket, root, no password, fractalsql_bt db)."""
    return {
        "user": os.environ.get("FRACTALSQL_USER", "root"),
        "password": os.environ.get("FRACTALSQL_PASSWORD", ""),
        "host": os.environ.get("FRACTALSQL_HOST", "127.0.0.1"),
        "port": int(os.environ.get("FRACTALSQL_PORT", "3306")),
        "database": os.environ.get("FRACTALSQL_DB", "fractalsql_bt"),
    }


def connect_or_skip():
    kwargs = get_dsn_kwargs()
    try:
        conn = mariadb.connect(**kwargs)
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"SKIP: no DB reachable at {kwargs['host']}:{kwargs['port']}: {e}")
        return None


def get_reasoning_plugin_path():
    return os.environ.get(
        "FRACTALSQL_REASONING_PLUGIN",
        "/usr/lib/mysql/plugin/fractalsql-reasoning-http.so")


def to_str(v):
    """MariaDB Connector/Python returns some TEXT/LONGTEXT UDF results
    as bytes rather than str (the wire protocol doesn't distinguish
    TEXT from BLOB by column type alone) -- decode defensively at every
    call site that compares/searches a UDF's string result, rather
    than relying on the connector's charset auto-detection. Passes
    None and already-str values through unchanged."""
    if isinstance(v, (bytes, bytearray)):
        return v.decode("utf-8", errors="replace")
    return v


def call_proc(cur, sql, params=()):
    """CALL a stored procedure with OUT-param SELECT-back semantics --
    MariaDB's mariadb-connector-python returns OUT-param results as a
    trailing result set (or via cur.callproc()'s own mechanism
    depending on driver version); this repo's procedures follow
    build_test.sh's own proven CALL-then-SELECT-@var pattern instead
    of relying on driver-specific OUT-param handling, which is the
    same pattern every gate in build_test.sh already uses and keeps
    this test suite consistent with the shell-based gates."""
    cur.execute(sql, params)


def reasoning_available():
    """True if FRACTALSQL_REASONING_PLUGIN names a file that exists on
    THIS machine. Only meaningful when the test runs on the same host
    as mariadbd (true for every CI job in this repo -- build_test.sh's
    containers and the install-test.yml jobs all run the Python test
    client and mariadbd in the same container/host)."""
    return os.path.isfile(get_reasoning_plugin_path())


class MutableMockLLMServer:
    """Like _mock_llm_server.py's MockLLMServer, but BINDS TO A FIXED
    PORT (not an OS-assigned one) and lets the caller change the
    canned reply AFTER the server is already running, via set_content().

    Needed because mariadbd's FRACTALSQL_HTTP_URL is fixed at process
    start -- a test can't point it at a fresh server per test case the
    way postgres's configure_reasoning()+reconnect() can. Instead, one
    server is started ONCE (before or alongside mariadbd, at the SAME
    port FRACTALSQL_HTTP_URL already names), and each test case calls
    set_content() to change what the NEXT request gets back.
    """

    def __init__(self, port, content=""):
        self.port = port
        self._content = content
        self._embed_body = {"data": [{"embedding": [0.1, 0.2, 0.3]}]}
        self._lock = threading.Lock()
        self._httpd = None
        self._thread = None

    def set_content(self, content):
        """Set the NEXT chat-completions reply (fractal_reason /
        fractal_t2s_generate / fractal_t2s_review)."""
        with self._lock:
            self._content = content

    def set_embed_vector(self, vector):
        """Set the NEXT embeddings reply to a well-formed
        {"data":[{"embedding": vector}]} body (fractal_embed / the
        vectorizer)."""
        with self._lock:
            self._embed_body = {"data": [{"embedding": vector}]}

    def set_embed_body(self, body):
        """Set the NEXT embeddings reply to an arbitrary raw dict --
        for testing how fractal_embed()/the vectorizer handle a
        malformed response (e.g. missing the "data" key)."""
        with self._lock:
            self._embed_body = body

    def __enter__(self):
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                self.rfile.read(length)
                with outer._lock:
                    content = outer._content
                    embed_body = outer._embed_body
                if "embed" in self.path:
                    body = json.dumps(embed_body).encode("utf-8")
                else:
                    body = json.dumps(
                        {"choices": [{"message": {"role": "assistant", "content": content}}]}
                    ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._httpd = HTTPServer(("127.0.0.1", self.port), Handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc):
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
        return False
