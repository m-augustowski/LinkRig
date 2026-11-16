#!/usr/bin/env python3
"""Synthetic fixture only; no application payloads or request logging."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIZE = 8 * 1024 * 1024
PAYLOAD = bytes(i % 251 for i in range(SIZE))

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        if self.path != '/file':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(SIZE))
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(PAYLOAD)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, *_args):
        pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    print(f'Fixture: 127.0.0.1:{args.port}/file; {SIZE} bytes; SHA256 {hashlib.sha256(PAYLOAD).hexdigest()}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
