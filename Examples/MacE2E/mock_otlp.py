"""A stand-in for Zharp's OTLP endpoint: answers 200 and saves each body (gunzipped) to bodies/."""
import gzip
import http.server
import os
import sys
import time

OUT = sys.argv[1] if len(sys.argv) > 1 else "bodies"
os.makedirs(OUT, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.headers.get("Content-Encoding") == "gzip" or body[:2] == b"\x1f\x8b":
            body = gzip.decompress(body)
        name = "%s-%d.bin" % (self.path.strip("/").replace("/", "_"), time.time_ns())
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(body)
        print("POST", self.path, len(body), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", "0")
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", 4318), Handler).serve_forever()
