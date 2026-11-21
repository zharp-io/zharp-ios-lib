"""Saves every request the app sends (headers + body) to ./captured, answering 200."""
import http.server, json, os, time

os.makedirs("captured", exist_ok=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("captured/%d-GET%s.json" % (time.time_ns(), self.path.replace("/", "_")), "w") as f:
            json.dump({"path": self.path, "headers": dict(self.headers)}, f)
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Request-Id", "req-7")
        self.send_header("Set-Cookie", "sid=secret")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        name = "captured/%d-%s" % (time.time_ns(), self.path.strip("/").replace("/", "_"))
        with open(name + ".body", "wb") as f:
            f.write(body)
        with open(name + ".json", "w") as f:
            json.dump({"path": self.path, "headers": dict(self.headers)}, f)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", 4318), Handler).serve_forever()
