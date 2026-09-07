#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat-completions AND embeddings mock, for
build_test.sh's reasoning-tier gates (fractal_reason/fractal_embed/
fractal_text_to_sql/fractal_sql_agent/the vectorizer/the Agency tier)
without a real LLM endpoint.

Routes on the request PATH (anything containing "embed" -> embeddings
shape, everything else -> chat-completions shape) so ONE process backs
both FRACTALSQL_HTTP_URL and FRACTALSQL_HTTP_EMBED_URL in the same gate
run -- fractalsql-reasoning-http doesn't care about the path itself (it
POSTs wherever it's configured), this just lets one mock instance serve
both roles.

CHAT_REPLY is a fenced ```sql block on purpose, not plain text: it has
to work for BOTH consumers, and the mock has no way to tell which one
is calling (RESPONSE_MODE is an env var read by fractalsql-reasoning-
http.so itself, invisible in the HTTP request) --
  * fractal_reason (plain chat mode) returns whatever content it gets
    verbatim, fence markers and all -- harmless for a smoke check.
  * fractal_text_to_sql/fractal_sql_agent's GENERATE step (RESPONSE_
    MODE=code) extracts exactly the fenced block's contents -- needs to
    BE a real, allowlist-passing SELECT for those gates to reach their
    EXPLAIN-equivalent PREPARE check.
Rejection-path testing (a candidate that FAILS the allowlist) is done
by calling fractal_t2s_check_allowlist() directly with a hand-picked
adversarial string instead of trying to make an LLM misbehave on
demand, deterministic, and already covers that logic thoroughly
without needing a second mock reply mode.

Serves a fixed chat reply plus an embeddings route that this repo's
Vectorizer/fractal_embed gates
need (the reasoning-VFS-ABI test fixtures prove the plugin-ABI path
directly; this HTTP mock covers the real dlopen/curl/HTTP path -- see
build_test.sh's reasoning-gates header comment for the split).

Usage: python3 mock_llm.py [port]   (default port 18080)

Not for production use -- no auth, no TLS, one canned reply per mode.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CHAT_REPLY = "```sql\nSELECT 1\n```"
EMBED_VECTOR = [0.1, 0.2, 0.3]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)

        if "embed" in self.path:
            body = json.dumps(
                {"data": [{"embedding": EMBED_VECTOR}]}
            ).encode("utf-8")
        else:
            body = json.dumps(
                {"choices": [{"message": {"role": "assistant", "content": CHAT_REPLY}}]}
            ).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # keep CI logs quiet


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
