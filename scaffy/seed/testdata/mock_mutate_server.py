#!/usr/bin/env python3
"""Local stand-in for guerrilla's /v1/data/mutate endpoint, for repair-selftest.sh.

Exists so scaffy/seed/repair.sh can be exercised with ZERO egress and ZERO
credentials. The real endpoint is the only thing repair.sh talks to, so faking
it is enough to drive every branch of that script: the happy path, the E3
unknown_tag 422-then-retry wall, and a hard refusal.

MODE (env) selects the behaviour under test:
  happy        every mutation accepted (200)
  unknown_tag  command mutations are refused 422 {"error":"unknown_tag"} until
               the tag doc for EVERY tag they carry has been registered; tag
               mutations are always accepted. Proves the retry actually clears
               the wall rather than merely being attempted.
  refuse       every command mutation refused 500. Proves repair.sh reds
               instead of swallowing a failed write.

Every accepted mutation body is appended as one JSON line to $RECORD_FILE so
the test can assert WHAT was sent, not merely that something was.

GET /healthz is the readiness probe and is deliberately NOT the mutate path:
an earlier version had the test probe readiness by POSTing an empty-mutations
body, which the server then RECORDED, so every arm carried one phantom batch
and the shape assertions failed against a body the code under test never sent.
A readiness probe must not be indistinguishable from the traffic being measured.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("MODE", "happy")
RECORD_FILE = os.environ.get("RECORD_FILE", "/dev/null")
PORT = int(os.environ.get("PORT", "8766"))

registered_tags = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the test output readable

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True, "mode": MODE})
            return
        self._send(404, {"error": "not_found", "path": self.path})

    def do_POST(self):
        if self.path != "/v1/data/mutate/production":
            self._send(404, {"error": "not_found", "path": self.path})
            return

        if self.headers.get("Authorization", "") != "Bearer " + os.environ.get(
            "EXPECT_TOKEN", "test-token"
        ):
            self._send(401, {"error": "unauthorized"})
            return

        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            body = json.loads(raw)
        except json.JSONDecodeError as e:
            self._send(400, {"error": "bad_json", "detail": str(e)})
            return

        muts = body.get("mutations", [])
        if not muts:
            # repair.sh never sends this; refuse it rather than record it.
            self._send(400, {"error": "empty_mutations"})
            return

        created = muts[0].get("createOrReplace", {})
        doc_type = created.get("_type")

        if doc_type == "tag":
            registered_tags.add(created.get("_id"))
            self._record(body)
            self._send(200, {"ok": True, "registered": created.get("_id")})
            return

        # A command mutation.
        if MODE == "refuse":
            self._send(500, {"error": "server_exploded"})
            return

        if MODE == "unknown_tag":
            want = {t.get("tag") for t in created.get("tags", [])}
            missing = want - registered_tags
            if missing:
                self._send(
                    422,
                    {"error": "unknown_tag", "unknown_tag": sorted(missing)},
                )
                return

        self._record(body)
        self._send(200, {"ok": True, "id": created.get("_id")})

    def _record(self, body):
        with open(RECORD_FILE, "a") as fh:
            fh.write(json.dumps(body, sort_keys=True) + "\n")


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("mock mutate server on %d mode=%s\n" % (PORT, MODE))
    sys.stderr.flush()
    srv.serve_forever()
