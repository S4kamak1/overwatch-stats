import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

MATCH_DIR = Path("data/matches")
OUT = Path("data/analysis/live_matches.json")


def load_matches():
    if not MATCH_DIR.exists():
        return []
    rows = []
    for path in sorted(MATCH_DIR.glob("*.json")):
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(row, dict):
            row["_file"] = path.name
            rows.append(row)
    return rows


def normalize_result(value):
    if not isinstance(value, str):
        return "unknown"
    value = value.lower()
    if value in {"win", "victory", "won"}:
        return "win"
    if value in {"loss", "defeat", "lost"}:
        return "loss"
    if value in {"draw", "tie"}:
        return "draw"
    return "unknown"


def normalize_match_type(value):
    if not isinstance(value, str):
        return "unknown"
    value = value.strip().lower()
    if not value:
        return "unknown"
    if any(token in value for token in ("competitive", "ranked", "comp")):
        return "competitive"
    if any(token in value for token in ("quickplay", "quick_play", "quick play", "unranked", "casual", "quick")):
        return "unranked"
    return "unknown"


def main():
    matches = load_matches()
    results = Counter(normalize_result(m.get("result")) for m in matches)
    match_types = Counter(
        normalize_match_type(m.get("match_type") or m.get("game_type"))
        for m in matches
    )
    heroes = Counter()
    roles = Counter()
    for match in matches:
        hero = match.get("primary_hero") or match.get("hero")
        role = match.get("role") or match.get("primary_role")
        if isinstance(hero, str) and hero:
            heroes[hero.lower()] += 1
        if isinstance(role, str) and role:
            roles[role.lower()] += 1

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "matches": len(matches),
        "results": dict(results),
        "match_types": dict(match_types),
        "heroes": dict(heroes.most_common()),
        "roles": dict(roles.most_common()),
        "latest": matches[-20:],
        "note": "match_type separates competitive and unranked when available; unknown values are not guessed from queue_type.",
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Matches analyzed: {len(matches)}")
    print(f"Wrote: {OUT}")


if __name__ == "__main__":
    main()
