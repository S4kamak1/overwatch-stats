import json
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ASSET_URL = "https://overlooker.app/assets/match-BpMa0pko.js"
OUT = Path("data/overlooker-bundle-probe.json")


def uniq(values):
    out = []
    seen = set()
    for value in values:
        if value and value not in seen:
            seen.add(value)
            out.append(value)
    return out


request = urllib.request.Request(
    ASSET_URL,
    headers={
        "User-Agent": "OWStatsBundleProbe/1.0",
        "Accept": "application/javascript,text/javascript,*/*",
    },
)

with urllib.request.urlopen(request, timeout=20) as response:
    text = response.read().decode("utf-8", errors="replace")
    status = response.status
    content_type = response.headers.get("Content-Type")

# Extract only short public-code string literals that look related to routing,
# loading, sharing or match access. Do not commit the bundle itself.
strings = []
for match in re.finditer(r'(["\'])(.{1,180}?)\1', text):
    value = match.group(2)
    lower = value.lower()
    if any(token in lower for token in (
        "match", "share", "public", "private", "api", "graphql",
        "supabase", "fetch", "loader", "mcp", "auth"
    )):
        if "data:" not in lower and "base64" not in lower:
            strings.append(value)

strings = uniq(strings)[:250]

absolute_urls = uniq(
    re.findall(r"https://[^\"'`<>\\\s]{1,240}", text, re.I)
)[:100]

path_hints = uniq(
    re.findall(
        r"[\"'`](/[^\"'`]{0,160}(?:match|share|api|auth|public|private)[^\"'`]{0,120})[\"'`]",
        text,
        re.I,
    )
)[:100]

identifier_hints = uniq(
    re.findall(
        r"\b([A-Za-z_$][A-Za-z0-9_$]{1,50}(?:match|share|public|private|auth|loader|fetch)[A-Za-z0-9_$]{0,50})\b",
        text,
        re.I,
    )
)[:120]

result = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "asset_url": ASSET_URL,
    "upstream": {
        "status": status,
        "content_type": content_type,
        "content_length": len(text),
    },
    "route_or_string_hints": strings,
    "absolute_urls": absolute_urls,
    "path_hints": path_hints,
    "identifier_hints": identifier_hints,
    "signals": {
        "contains_fetch": "fetch(" in text,
        "contains_graphql": "graphql" in text.lower(),
        "contains_supabase": "supabase" in text.lower(),
        "contains_share": "share" in text.lower(),
        "contains_public": "public" in text.lower(),
        "contains_private": "private" in text.lower(),
        "contains_mcp": "mcp" in text.lower(),
    },
    "privacy_note": "Only short route/string/identifier hints from a public JS bundle are stored; the bundle body is not committed.",
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
