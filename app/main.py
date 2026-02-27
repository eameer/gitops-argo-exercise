"""Minimal HTTP server — used as the sample application for the GitOps exercise."""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        start = time.time()

        if self.path == "/health":
            status = 200
            body = b"ok"
        else:
            status = 200
            body = b"Hello from sample-app!"

        self.send_response(status)
        self.end_headers()
        self.wfile.write(body)

        duration_ms = round((time.time() - start) * 1000, 2)
        print(json.dumps({
            "method": self.command,
            "path": self.path,
            "status": status,
            "duration_ms": duration_ms,
            "client": self.address_string(),
        }), flush=True)

    def log_message(self, format, *args):  # noqa: A002
        pass  # handled in do_GET


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    server = HTTPServer(("", port), Handler)
    print(json.dumps({"event": "startup", "port": port}), flush=True)
    server.serve_forever()
