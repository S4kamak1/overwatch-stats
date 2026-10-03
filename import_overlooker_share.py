import html as html_lib
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

DEFAULT_MATCH_ID = "52b337bf-c871-48d9-b8c6-67c035826ebf"
PLAYER = os.environ.get("OVERLOOKER_PLAYER", "S4kamak1")

HERO_ROLES = {
    "ana": "support", "baptiste": "support", "brigitte": "support",
    "illari": "support", "juno": "support", "kiriko": "support",
    "lifeweaver": "support", "lucio": "support", "mercy": "support",
    "moira": "support", "zenyatta": "support",
    "dva": "tank", "doomfist": "tank", "hazard": "tank",
    "junker_queen": "tank", "mauga": "tank", "orisa": "tank",
    "ramattra": "tank", "reinhardt": "tank", "roadhog": "tank",
    "sigma": "tank", "winston": "tank", "wrecking_ball": "tank",
    "zarya": "tank",
}


class VisibleTextParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = 0
        self.tokens = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() in {"script", "style", "noscript"}:
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag.lower() in {"script", "style", "noscript"} and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if self.hidden:
            return
        text = re.sub(r"\s+", " ", data).strip()
        if text:
            self.tokens.append(text)


def parse_number(value):
    return int(str(value).replace(",", "").strip())


def parse_duration(value):
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", str(value).strip())
    if not match:
        return None
    return int(match.group(1)) * 60 + int(match.group(2))


def uniq(items):
    out = []
    seen = set()
    for item in items:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


def fetch_match_html(match_id):
    url = f"https://overlooker.app/matches/{match_id}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "OWStatsShareImporter/1.0",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        if response.status != 200:
            raise RuntimeError(f"OverLooker returned HTTP {response.status}")
        return url, response.read().decode("utf-8", errors="replace")


def parse_match(match_id, source_url, raw_html):
    title_match = re.search(r"<title[^>]*>([\s\S]*?)</title>", raw_html, re.I)
    if not title_match:
        raise RuntimeError("Match title not found")

    title = html_lib.unescape(title_match.group(1)).strip()
    title_parts = [part.strip() for part in title.split("—")]
    map_name = title_parts[0] if title_parts else None

    upper_title = title.upper()
    if "VICTORY" in upper_title:
        result = "win"
    elif "DEFEAT" in upper_title:
        result = "loss"
    elif "DRAW" in upper_title or "TIE" in upper_title:
        result = "draw"
    else:
        result = "unknown"

    parser = VisibleTextParser()
    parser.feed(raw_html)
    tokens = parser.tokens

    player_index = next(
        (i for i, token in enumerate(tokens) if token.lower() == PLAYER.lower()),
        None,
    )
    if player_index is None or player_index + 6 >= len(tokens):
        raise RuntimeError(f"Player row not found for {PLAYER}")

    row = tokens[player_index : player_index + 7]
    stats = {
        "eliminations": parse_number(row[1]),
        "assists": parse_number(row[2]),
        "deaths": parse_number(row[3]),
        "damage": parse_number(row[4]),
        "healing": parse_number(row[5]),
        "mitigation": parse_number(row[6]),
    }

    map_index = next(
        (i for i, token in enumerate(tokens) if map_name and token.lower() == map_name.lower()),
        None,
    )
    mode = side = duration_text = None
    if map_index is not None:
        if map_index + 1 < len(tokens):
            mode = tokens[map_index + 1].lower()
        if map_index + 2 < len(tokens):
            side = tokens[map_index + 2].lower()
        if map_index + 3 < len(tokens):
            duration_text = tokens[map_index + 3]

    hero_slugs = uniq(
        [slug.lower() for slug in re.findall(r"/perks/([a-z0-9_-]+)/", raw_html, re.I)]
        + [slug.lower() for slug in re.findall(r"/heroes?/([a-z0-9_-]+)(?:[/.])", raw_html, re.I)]
    )
    hero_slugs = [slug for slug in hero_slugs if slug not in {"icons", "role"}]
    primary_hero = hero_slugs[0] if hero_slugs else None
    role = HERO_ROLES.get(primary_hero)

    deaths = stats["deaths"]
    kda = round((stats["eliminations"] + stats["assists"]) / deaths, 2) if deaths else None

    duration_seconds = parse_duration(duration_text) if duration_text else None
    per_10 = {}
    if duration_seconds:
        for key in ("eliminations", "assists", "deaths", "damage", "healing", "mitigation"):
            per_10[key] = round(stats[key] * 600 / duration_seconds, 2)

    return {
        "match_id": match_id,
        "source": "overlooker-share",
        "source_url": source_url,
        "imported_at": datetime.now(timezone.utc).isoformat(),
        "player": PLAYER,
        "result": result,
        "map": map_name,
        "mode": mode,
        "side": side,
        "duration": duration_text,
        "duration_seconds": duration_seconds,
        "role": role,
        "primary_hero": primary_hero,
        "heroes": hero_slugs,
        "stats": stats,
        "kda": kda,
        "per_10_minutes": per_10,
    }


def main():
    match_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MATCH_ID
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", match_id):
        raise SystemExit("Invalid match id")

    source_url, raw_html = fetch_match_html(match_id)
    match = parse_match(match_id, source_url, raw_html)

    out = Path("data/matches") / f"{match_id}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(match, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(match, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
