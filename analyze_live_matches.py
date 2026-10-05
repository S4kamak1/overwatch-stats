import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

MATCH_DIR = Path("data/matches")
OUT = Path("data/analysis/live_matches.json")
STAT_KEYS = ("eliminations", "assists", "deaths", "damage", "healing", "mitigation")


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
    # Check unranked first because the word "unranked" contains "ranked".
    if any(token in value for token in ("quickplay", "quick_play", "quick play", "unranked", "casual", "quick")):
        return "unranked"
    if any(token in value for token in ("competitive", "ranked", "comp")):
        return "competitive"
    return "unknown"


def primary_hero(match):
    value = match.get("primary_hero") or match.get("hero")
    if isinstance(value, str) and value.strip():
        return value.strip().lower()
    return "unknown"


def duration_seconds(match):
    value = match.get("duration_seconds")
    if isinstance(value, (int, float)) and value > 0:
        return float(value)

    value = match.get("duration_ms")
    if isinstance(value, (int, float)) and value > 0:
        return float(value) / 1000.0

    value = match.get("duration")
    if isinstance(value, str) and ":" in value:
        try:
            parts = [float(part) for part in value.split(":")]
            if len(parts) == 2:
                return parts[0] * 60 + parts[1]
            if len(parts) == 3:
                return parts[0] * 3600 + parts[1] * 60 + parts[2]
        except ValueError:
            pass
    return 0.0


def number(value):
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def summarize_performance(matches):
    total_duration = 0.0
    totals = {key: 0.0 for key in STAT_KEYS}
    usable_games = 0

    for match in matches:
        duration = duration_seconds(match)
        if duration <= 0:
            continue
        stats = match.get("stats")
        if not isinstance(stats, dict):
            continue

        usable_games += 1
        total_duration += duration
        for key in STAT_KEYS:
            totals[key] += number(stats.get(key))

    if total_duration <= 0:
        return {
            "games": len(matches),
            "games_with_stats": 0,
            "duration_seconds": 0,
            "totals": {key: 0 for key in STAT_KEYS},
            "per_10_minutes": {},
            "kda": None,
        }

    per_10 = {
        key: round(value * 600.0 / total_duration, 2)
        for key, value in totals.items()
    }
    deaths = totals["deaths"]
    kda = round((totals["eliminations"] + totals["assists"]) / deaths, 2) if deaths > 0 else None

    def tidy(value):
        rounded = round(value, 2)
        return int(rounded) if rounded.is_integer() else rounded

    return {
        "games": len(matches),
        "games_with_stats": usable_games,
        "duration_seconds": round(total_duration, 2),
        "totals": {key: tidy(value) for key, value in totals.items()},
        "per_10_minutes": per_10,
        "kda": kda,
    }


def compare_wins_and_losses(matches):
    wins = [match for match in matches if normalize_result(match.get("result")) == "win"]
    losses = [match for match in matches if normalize_result(match.get("result")) == "loss"]
    win_summary = summarize_performance(wins)
    loss_summary = summarize_performance(losses)

    win_per_10 = win_summary.get("per_10_minutes", {})
    loss_per_10 = loss_summary.get("per_10_minutes", {})
    differential = {}
    if win_per_10 and loss_per_10:
        differential = {
            key: round(win_per_10.get(key, 0) - loss_per_10.get(key, 0), 2)
            for key in STAT_KEYS
        }

    return {
        "wins": win_summary,
        "losses": loss_summary,
        "win_minus_loss_per_10_minutes": differential,
    }


def build_win_loss_comparison(matches):
    result = {}
    for scope_name, scoped_matches in (
        ("all", matches),
        (
            "competitive",
            [
                match
                for match in matches
                if normalize_match_type(match.get("match_type") or match.get("game_type")) == "competitive"
            ],
        ),
    ):
        result[scope_name] = compare_wins_and_losses(scoped_matches)
    return result


def build_hero_win_loss_comparison(matches):
    scopes = {
        "all": matches,
        "competitive": [
            match
            for match in matches
            if normalize_match_type(match.get("match_type") or match.get("game_type")) == "competitive"
        ],
    }
    output = {}

    for scope_name, scoped_matches in scopes.items():
        grouped = {}
        for match in scoped_matches:
            hero = primary_hero(match)
            if hero == "unknown":
                continue
            grouped.setdefault(hero, []).append(match)

        hero_rows = {}
        ordered_heroes = sorted(grouped, key=lambda hero: (-len(grouped[hero]), hero))
        for hero in ordered_heroes:
            hero_matches = grouped[hero]
            result_counts = Counter(normalize_result(match.get("result")) for match in hero_matches)
            wins = result_counts.get("win", 0)
            losses = result_counts.get("loss", 0)
            decided = wins + losses
            hero_rows[hero] = {
                "games": len(hero_matches),
                "results": dict(result_counts),
                "decided_winrate_percent": round(wins * 100.0 / decided, 1) if decided else None,
                "overall": summarize_performance(hero_matches),
                **compare_wins_and_losses(hero_matches),
            }

        output[scope_name] = hero_rows

    return output


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
        hero = primary_hero(match)
        role = match.get("role") or match.get("primary_role")
        if hero != "unknown":
            heroes[hero] += 1
        if isinstance(role, str) and role:
            roles[role.lower()] += 1

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "matches": len(matches),
        "results": dict(results),
        "match_types": dict(match_types),
        "heroes": dict(heroes.most_common()),
        "roles": dict(roles.most_common()),
        "win_loss_comparison": build_win_loss_comparison(matches),
        "hero_win_loss_comparison": build_hero_win_loss_comparison(matches),
        "latest": matches[-20:],
        "note": (
            "match_type separates competitive and unranked when available; unknown values are not guessed from queue_type. "
            "win/loss comparisons use duration-weighted per-10-minute rates; win_minus_loss_per_10_minutes is positive when the metric is higher in wins. "
            "hero_win_loss_comparison groups matches by primary hero, and decided_winrate_percent excludes draws and unknown results."
        ),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Matches analyzed: {len(matches)}")
    print(f"Wrote: {OUT}")


if __name__ == "__main__":
    main()
