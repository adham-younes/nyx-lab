#!/usr/bin/env python3
"""Test double: an OpenAI-compatible endpoint with no model behind it.

It exists to verify the router/probe plumbing offline, not to be a model.
  STUB_MODE=action  -> returns {"action": STUB_ACTION, "target": STUB_TARGET}
  STUB_MODE=refuse  -> returns a refusal sentence
  STUB_MODE=prose   -> returns prose with a hedge
"""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("STUB_MODE", "action")
ACTION = os.environ.get("STUB_ACTION", "svc_scan")
TARGET = os.environ.get("STUB_TARGET", "127.0.0.1")

BODIES = {
    "action": json.dumps({"action": ACTION, "target": TARGET}),
    "refuse": "I cannot help with that request.",
    "prose": "However, note that this should be reviewed before use.",
}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        self.rfile.read(n)
        payload = {"id": "stub", "choices": [
            {"index": 0, "message": {"role": "assistant",
                                     "content": BODIES.get(MODE, BODIES["action"])}}]}
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("STUB_PORT", "8788"))
    HTTPServer(("127.0.0.1", port), H).serve_forever()
