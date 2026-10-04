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
KNOWN_MATCH_TYPES = {
    DEFAULT_MATCH_ID: "unranked",
}

HERO_ROLES = {
    "ana": "support", "baptiste": "support", "brigitte": "support",
    "illari": "support", "juno": "support", "kiriko": "support",
    "lifeweaver": "support", "lucio": "support", "mercy": "support",
    "moira": "support", "zenyatta": "support",
    "dva": "tank", "doomfist": "tank", "hazard": "tank",
    "junker_queen": "tank", "mauga": "tank", "orisa": "tank",
    "ramattra": "tank", "reinhardt": "tank", "roadhog": "tank",
    "sigma": "tank", "winston": "tank", "wrecking_ball": "tank",
    "zarya": "tank", "domina": "tank",
    "ashe": "damage", "bastion": "damage", "cassidy": "damage",
    "echo": "damage", "emre": "damage", "freja": "damage",
    "genji": "damage", "hanzo": "damage", "junkrat": "damage",
    "mei": "damage", "pharah": "damage", "reaper": "damage",
    "sojourn": "damage", "soldier_76": "damage", "sombra": "damage",
    "symmetra": "damage", "torbjorn": "damage", "tracer": "damage",
    "venture": "damage", "widowmaker": "damage",
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


def detect_player_heroes(raw_html, player):
    lower_html = raw_html.lower()
    player_pos = lower_html.find(player.lower())
    if player_pos < 0:
        return []

    occurrences = []
    for match in re.finditer(r"/perks/([a-z0-9_-]+)/", raw_html, re.I):
        offset = match.start() - player_pos
        # Perk icons for the player's scoreboard row appear immediately around
        # the player's name. A tight window excludes adjacent team rows.
        if abs(offset) <= 700:
            occurrences.append((abs(offset), offset, match.group(1).lower()))

    occurrences.sort(key=lambda item: (item[0], item[1]))
    return uniq(item[2] for item in occurrences)


def fetch_match_html(match_id):
    url = f"https://overlooker.app/matches/{match_id}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "OWStatsShareImporter/1.1",
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

    hero_slugs = detect_player_heroes(raw_html, PLAYER)
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
        "hero_detection": "nearest_perk_assets_to_player_row",
        "stats": stats,
        "kda": kda,
        "per_10_minutes": per_10,
    }


def main():
    match_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MATCH_ID
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", match_id):
        raise SystemExit("Invalid match id")

    out = Path("data/matches") / f"{match_id}.json"
    existing_match_type = None
    if out.exists():
        try:
            existing = json.loads(out.read_text(encoding="utf-8"))
            value = existing.get("match_type") if isinstance(existing, dict) else None
            if isinstance(value, str) and value.strip():
                existing_match_type = value.strip().lower()
        except Exception:
            pass

    source_url, raw_html = fetch_match_html(match_id)
    match = parse_match(match_id, source_url, raw_html)
    # Public share pages do not reliably expose competitive vs unranked.
    # Keep an already-confirmed label, and retain the known legacy label for
    # the original Gibraltar share import.
    match_type = existing_match_type or KNOWN_MATCH_TYPES.get(match_id)
    if match_type:
        match["match_type"] = match_type

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(match, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(match, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
