import json
import os
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 32145
RAW_OUT = Path("data/live/overwolf-events.jsonl")
MATCH_DIR = Path("data/matches")
LOG_FILE = Path("data/live/bridge.log")
SYNC_INTERVAL_SECONDS = 10

def log(message):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat()
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")

def run_git(*args):
    return subprocess.run(
        ["git", *args],
        cwd=Path(__file__).resolve().parent,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

def sync_matches_once():
    MATCH_DIR.mkdir(parents=True, exist_ok=True)
    add = run_git("add", "data/matches")
    if add.returncode != 0:
        log(f"git add failed: {add.stderr.strip()}")
        return
    diff = run_git("diff", "--cached", "--quiet")
    if diff.returncode == 0:
        return
    commit = run_git(
        "-c", "user.name=ow-live-collector",
        "-c", "user.email=ow-live-collector@users.noreply.github.com",
        "commit", "-m", "Add live Overwatch match",
    )
    if commit.returncode != 0:
        log(f"git commit failed: {commit.stderr.strip()}")
        return
    for attempt in range(1, 4):
        push = run_git("push", "origin", "HEAD:main")
        if push.returncode == 0:
            log("Normalized match data pushed to GitHub.")
            return
        log(f"git push attempt {attempt} failed: {push.stderr.strip()}")
        fetch = run_git("fetch", "origin", "main")
        if fetch.returncode != 0:
            log(f"git fetch failed: {fetch.stderr.strip()}")
            return
        rebase = run_git("rebase", "-X", "theirs", "origin/main")
        if rebase.returncode != 0:
            run_git("rebase", "--abort")
            log(f"git rebase failed: {rebase.stderr.strip()}")
            return

def sync_loop():
    while True:
        try:
            sync_matches_once()
        except Exception as exc:
            log(f"sync loop error: {exc}")
        time.sleep(SYNC_INTERVAL_SECONDS)

class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({
                "ok": True,
                "time": datetime.now(timezone.utc).isoformat(),
                "raw_log": str(RAW_OUT),
                "match_dir": str(MATCH_DIR),
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

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
        RAW_OUT.parent.mkdir(parents=True, exist_ok=True)
        with RAW_OUT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    os.chdir(root)
    MATCH_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=sync_loop, daemon=True).start()
    log(f"Listening on http://{HOST}:{PORT}")
    log(f"Raw events: {RAW_OUT}")
    log("Only data/matches is eligible for automatic GitHub sync.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
