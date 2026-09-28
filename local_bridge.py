import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 32145
OUT = Path("data/live/overwolf-events.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self._headers()
        self.end_headers()

    def do_POST(self):
        if self.path != "/event":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception as exc:
            self.send_error(400, str(exc))
            return

        payload.setdefault(
            "bridge_received_at",
            datetime.now(timezone.utc).isoformat(),
        )

        OUT.parent.mkdir(parents=True, exist_ok=True)
        with OUT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")

        self.send_response(204)
        self._headers()
        self.end_headers()

    def _headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    print(f"Listening on http://{HOST}:{PORT}")
    print(f"Writing events to {OUT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
