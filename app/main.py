"""Minimal HTTP server — used as the sample application for the GitOps exercise."""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Hello from sample-app!")

    def log_message(self, format, *args):  # noqa: A002
        pass  # Suppress default access logs; use structured logging in production


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    server = HTTPServer(("", port), Handler)
    print(f"Listening on port {port}")
    server.serve_forever()
