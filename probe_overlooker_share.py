import json
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MATCH_ID = "52b337bf-c871-48d9-b8c6-67c035826ebf"
URL = f"https://overlooker.app/matches/{MATCH_ID}"
OUT = Path("data/overlooker-share-probe.json")


def uniq(items):
    seen = set()
    out = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


req = urllib.request.Request(
    URL,
    headers={
        "User-Agent": "OWStatsShareProbe/1.0",
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

# Look for likely data/API hints without storing the full page body.
absolute_urls = uniq(
    re.findall(r"https://[^\"'<>\\\s]+", html, re.I)
)[:100]
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
    },
    "markers": {
        "victory": "victory" in lower,
        "watchpoint_gibraltar": "watchpoint: gibraltar" in lower,
        "s4kamak1": "s4kamak1" in lower,
        "illari": "illari" in lower,
        "match_id": MATCH_ID.lower() in lower,
    },
    "network_hints": {
        "absolute_urls": api_hints,
        "path_hints": path_hints,
    },
    "privacy_note": "Stores structural/page hints only; full public match HTML is not committed.",
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
