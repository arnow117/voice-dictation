#!/usr/bin/env python3
"""Explicit local-only HTTP fixture for URLSessionModelFileDownloader integration tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys


FULL = b"model\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        cases = {
            "/resume": (206, {"Content-Range": "bytes 2-5/6", "Content-Length": "4"}, b"del\n"),
            "/restart": (200, {"Content-Length": "6"}, FULL),
            "/bad-range": (206, {"Content-Range": "bytes 1-5/6", "Content-Length": "5"}, b"xxxxx"),
            "/overlong": (200, {}, b"model\n!"),
            "/range-416": (416, {}, b""),
        }
        status, headers, body = cases.get(self.path, (404, {"Content-Length": "0"}, b""))
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def main():
    port_file = Path(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port_file.write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
