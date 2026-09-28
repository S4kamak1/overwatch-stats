import json
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PLAYER = "S4kamak1-1198"

BASE = "https://overfast-api.tekrop.fr"

SUMMARY_URL = f"{BASE}/players/{PLAYER}/summary"
STATS_URL = (
    f"{BASE}/players/{PLAYER}/stats/summary"
    "?gamemode=competitive&platform=pc"
)

def fetch_json(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "S4kamak1-OW-Stats/1.0"
        }
    )

    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def main():
    now = datetime.now(timezone.utc)

    summary = fetch_json(SUMMARY_URL)
    stats = fetch_json(STATS_URL)

    result = {
        "player": PLAYER,
        "platform": "pc",
        "gamemode": "competitive",
        "fetched_at": now.isoformat(),
        "summary": summary,
        "stats": stats,
    }

    data_dir = Path("data")
    history_dir = data_dir / "history"

    data_dir.mkdir(exist_ok=True)
    history_dir.mkdir(exist_ok=True)

    # 常に最新データ
    with open(
        data_dir / "latest.json",
        "w",
        encoding="utf-8"
    ) as f:
        json.dump(
            result,
            f,
            ensure_ascii=False,
            indent=2
        )

    # 1日単位の履歴
    history_file = (
        history_dir /
        f"{now.strftime('%Y-%m-%d')}.json"
    )

    with open(
        history_file,
        "w",
        encoding="utf-8"
    ) as f:
        json.dump(
            result,
            f,
            ensure_ascii=False,
            indent=2
        )


if __name__ == "__main__":
    main()
