import json
import re
import urllib.request
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

MATCH_ID = "52b337bf-c871-48d9-b8c6-67c035826ebf"
URL = f"https://overlooker.app/matches/{MATCH_ID}"
OUT = Path("data/overlooker-share-probe.json")
TARGET_PLAYER = "S4kamak1"
TARGET_HERO = "Illari"
TARGET_MAP = "Watchpoint: Gibraltar"


def uniq(items):
    seen = set()
    out = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


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


def context_after(tokens, needle, count):
    needle_lower = needle.lower()
    for i, token in enumerate(tokens):
        if token.lower() == needle_lower:
            return tokens[i : i + count]
    return []


def script_diagnostics(html):
    scripts = re.findall(r"<script([^>]*)>([\s\S]*?)</script>", html, re.I)
    result = []
    for attrs, body in scripts[:30]:
        src_match = re.search(r"\bsrc=[\"']([^\"']+)", attrs, re.I)
        id_match = re.search(r"\bid=[\"']([^\"']+)", attrs, re.I)
        type_match = re.search(r"\btype=[\"']([^\"']+)", attrs, re.I)
        keys = uniq(re.findall(r"[\"']([A-Za-z_][A-Za-z0-9_]{1,40})[\"']\s*:", body))[:40]
        result.append({
            "src": src_match.group(1) if src_match else None,
            "id": id_match.group(1) if id_match else None,
            "type": type_match.group(1) if type_match else None,
            "inline_length": 0 if src_match else len(body.strip()),
            "object_keys": keys,
        })
    return result


def nearby_hero_hints(raw_html, player):
    lower_html = raw_html.lower()
    pos = lower_html.find(player.lower())
    if pos < 0:
        return {"perk_occurrences": [], "hero_path_occurrences": []}

    start = max(0, pos - 2200)
    end = min(len(raw_html), pos + 2200)
    window = raw_html[start:end]
    rel_player = pos - start

    perk_occurrences = []
    for match in re.finditer(r"/perks/([a-z0-9_-]+)/", window, re.I):
        perk_occurrences.append({
            "hero": match.group(1).lower(),
            "offset": match.start() - rel_player,
        })

    hero_path_occurrences = []
    for match in re.finditer(
        r"/(?:heroes?|portraits|hero-portraits)/([a-z0-9_-]+)(?:[/.])",
        window,
        re.I,
    ):
        hero_path_occurrences.append({
            "hero": match.group(1).lower(),
            "offset": match.start() - rel_player,
        })

    perk_occurrences.sort(key=lambda item: abs(item["offset"]))
    hero_path_occurrences.sort(key=lambda item: abs(item["offset"]))

    return {
        "perk_occurrences": perk_occurrences[:12],
        "hero_path_occurrences": hero_path_occurrences[:12],
    }


req = urllib.request.Request(
    URL,
    headers={
        "User-Agent": "OWStatsShareProbe/1.3",
        "Accept": "text/html,application/xhtml+xml",
    },
)

with urllib.request.urlopen(req, timeout=20) as response:
    html = response.read().decode("utf-8", errors="replace")
    headers = dict(response.headers.items())
    status = response.status
    final_url = response.geturl()

lower = html.lower()
title_match = re.search(r"<title[^>]*>([\s\S]*?)</title>", html, re.I)
script_srcs = uniq(re.findall(r"<script[^>]+src=[\"']([^\"']+)[\"'][^>]*>", html, re.I))[:50]
script_ids = uniq(re.findall(r"<script[^>]+id=[\"']([^\"']+)[\"'][^>]*>", html, re.I))[:30]
json_scripts = re.findall(
    r"<script[^>]+type=[\"']application/json[\"'][^>]*>([\s\S]*?)</script>",
    html,
    re.I,
)

json_summaries = []
for raw in json_scripts[:20]:
    raw = raw.strip()
    summary = {"length": len(raw)}
    try:
        obj = json.loads(raw)
        summary["valid_json"] = True
        if isinstance(obj, dict):
            summary["top_level_keys"] = sorted(obj.keys())[:50]
        else:
            summary["top_level_type"] = type(obj).__name__
    except Exception:
        summary["valid_json"] = False
    json_summaries.append(summary)

parser = VisibleTextParser()
parser.feed(html)
visible_tokens = parser.tokens

target_player_context = context_after(visible_tokens, TARGET_PLAYER, 7)
target_hero_context = context_after(visible_tokens, TARGET_HERO, 10)
map_context = context_after(visible_tokens, TARGET_MAP, 5)
hero_hints = nearby_hero_hints(html, TARGET_PLAYER)

absolute_urls = uniq(re.findall(r"https://[^\"'<>\\\s]+", html, re.I))[:100]
api_hints = [
    url for url in absolute_urls
    if any(token in url.lower() for token in ("api", "match", "graphql", "supabase", "firebase"))
][:50]
path_hints = uniq(
    re.findall(r"[\"'](/[^\"']*(?:api|match|graphql)[^\"']*)[\"']", html, re.I)
)[:50]

result = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "match_id": MATCH_ID,
    "url": URL,
    "upstream": {
        "status": status,
        "final_url": final_url,
        "content_type": headers.get("Content-Type"),
        "content_length": len(html),
        "title": title_match.group(1).strip() if title_match else None,
    },
    "page_signals": {
        "next_data": "__NEXT_DATA__" in html,
        "svelte_or_sveltekit": bool(re.search(r"__svelte|sveltekit", html, re.I)),
        "react_root": bool(re.search(r"__next|react", html, re.I)),
        "application_json_scripts": len(json_scripts),
        "json_script_summaries": json_summaries,
        "script_ids": script_ids,
        "script_srcs": script_srcs,
        "script_diagnostics": script_diagnostics(html),
    },
    "markers": {
        "victory": "victory" in lower,
        "watchpoint_gibraltar": TARGET_MAP.lower() in lower,
        "s4kamak1": TARGET_PLAYER.lower() in lower,
        "illari": TARGET_HERO.lower() in lower,
        "match_id": MATCH_ID.lower() in lower,
    },
    "privacy_safe_context": {
        "target_player": target_player_context,
        "target_hero": target_hero_context,
        "map": map_context,
        "near_target_hero_hints": hero_hints,
    },
    "network_hints": {
        "absolute_urls": api_hints,
        "path_hints": path_hints,
    },
    "privacy_note": "Stores only the user's own short visible-text contexts, relative hero asset offsets, and structural/page hints; full public match HTML is not committed.",
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
