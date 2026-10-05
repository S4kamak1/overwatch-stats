import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

MATCH_DIR = Path("data/matches")
OUT = Path("data/analysis/live_matches.json")
STAT_KEYS = ("eliminations", "assists", "deaths", "damage", "healing", "mitigation")
RECENT_WINDOWS = (5, 10, 20)


def parse_timestamp(value):
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def match_timestamp(match):
    for key in ("captured_at", "cloud_received_at", "imported_at", "ended_at", "started_at"):
        dt = parse_timestamp(match.get(key))
        if dt is not None:
            return dt
    return datetime.min.replace(tzinfo=timezone.utc)


def load_matches():
    if not MATCH_DIR.exists():
        return []
    rows = []
    for path in MATCH_DIR.glob("*.json"):
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(row, dict):
            row["_file"] = path.name
            rows.append(row)
    rows.sort(key=lambda row: (match_timestamp(row), row.get("_file", "")))
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


def clean_label(value, fallback="unknown"):
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


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


def summarize_results(matches):
    counts = Counter(normalize_result(match.get("result")) for match in matches)
    wins = counts.get("win", 0)
    losses = counts.get("loss", 0)
    decided = wins + losses
    return {
        "games": len(matches),
        "results": dict(counts),
        "decided_winrate_percent": round(wins * 100.0 / decided, 1) if decided else None,
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


def competitive_matches(matches):
    return [
        match
        for match in matches
        if normalize_match_type(match.get("match_type") or match.get("game_type")) == "competitive"
    ]


def build_win_loss_comparison(matches):
    return {
        "all": compare_wins_and_losses(matches),
        "competitive": compare_wins_and_losses(competitive_matches(matches)),
    }


def build_group_breakdown(matches, key_func):
    grouped = {}
    for match in matches:
        key = key_func(match)
        if key == "unknown":
            continue
        grouped.setdefault(key, []).append(match)

    rows = {}
    ordered = sorted(grouped, key=lambda key: (-len(grouped[key]), key.lower()))
    for key in ordered:
        group_matches = grouped[key]
        rows[key] = {
            **summarize_results(group_matches),
            "overall": summarize_performance(group_matches),
            **compare_wins_and_losses(group_matches),
        }
    return rows


def build_scoped_breakdown(matches, key_func):
    return {
        "all": build_group_breakdown(matches, key_func),
        "competitive": build_group_breakdown(competitive_matches(matches), key_func),
    }


def build_hero_map_breakdown(matches):
    output = {}
    for scope_name, scoped_matches in (
        ("all", matches),
        ("competitive", competitive_matches(matches)),
    ):
        grouped = {}
        for match in scoped_matches:
            hero = primary_hero(match)
            map_name = clean_label(match.get("map"))
            if hero == "unknown" or map_name == "unknown":
                continue
            grouped.setdefault(hero, {}).setdefault(map_name, []).append(match)

        hero_rows = {}
        for hero in sorted(grouped, key=lambda h: (-sum(len(v) for v in grouped[h].values()), h)):
            map_rows = {}
            for map_name in sorted(grouped[hero], key=lambda m: (-len(grouped[hero][m]), m.lower())):
                group_matches = grouped[hero][map_name]
                map_rows[map_name] = {
                    **summarize_results(group_matches),
                    "overall": summarize_performance(group_matches),
                    **compare_wins_and_losses(group_matches),
                }
            hero_rows[hero] = map_rows
        output[scope_name] = hero_rows
    return output


def build_recent_form(matches):
    comp = competitive_matches(matches)
    output = {}
    for window in RECENT_WINDOWS:
        recent = comp[-window:]
        output[str(window)] = {
            **summarize_results(recent),
            "overall": summarize_performance(recent),
            **compare_wins_and_losses(recent),
            "match_ids": [match.get("match_id") for match in recent if match.get("match_id")],
        }
    return output


def build_data_quality(matches):
    return {
        "total_matches": len(matches),
        "unknown_result": sum(normalize_result(match.get("result")) == "unknown" for match in matches),
        "unknown_match_type": sum(
            normalize_match_type(match.get("match_type") or match.get("game_type")) == "unknown"
            for match in matches
        ),
        "unknown_hero": sum(primary_hero(match) == "unknown" for match in matches),
        "unknown_map": sum(clean_label(match.get("map")) == "unknown" for match in matches),
        "missing_or_zero_duration": sum(duration_seconds(match) <= 0 for match in matches),
        "missing_stats": sum(not isinstance(match.get("stats"), dict) for match in matches),
    }


def main():
    matches = load_matches()
    results = Counter(normalize_result(m.get("result")) for m in matches)
    match_types = Counter(
        normalize_match_type(m.get("match_type") or m.get("game_type"))
        for m in matches
    )
    heroes = Counter()
    roles = Counter()
    maps = Counter()
    modes = Counter()

    for match in matches:
        hero = primary_hero(match)
        role = clean_label(match.get("role") or match.get("primary_role"))
        map_name = clean_label(match.get("map"))
        mode_name = clean_label(match.get("mode"))

        if hero != "unknown":
            heroes[hero] += 1
        if role != "unknown":
            roles[role.lower()] += 1
        if map_name != "unknown":
            maps[map_name] += 1
        if mode_name != "unknown":
            modes[mode_name] += 1

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "matches": len(matches),
        "results": dict(results),
        "match_types": dict(match_types),
        "heroes": dict(heroes.most_common()),
        "roles": dict(roles.most_common()),
        "maps": dict(maps.most_common()),
        "modes": dict(modes.most_common()),
        "data_quality": build_data_quality(matches),
        "win_loss_comparison": build_win_loss_comparison(matches),
        "hero_win_loss_comparison": build_scoped_breakdown(matches, primary_hero),
        "map_win_loss_comparison": build_scoped_breakdown(matches, lambda match: clean_label(match.get("map"))),
        "mode_win_loss_comparison": build_scoped_breakdown(matches, lambda match: clean_label(match.get("mode"))),
        "hero_map_comparison": build_hero_map_breakdown(matches),
        "recent_competitive_form": build_recent_form(matches),
        "latest": matches[-20:],
        "note": (
            "Matches are sorted chronologically using captured_at/cloud_received_at/imported_at before recent-form analysis. "
            "match_type separates competitive and unranked when available; unknown values are not guessed from queue_type. "
            "All performance comparisons use duration-weighted per-10-minute rates. "
            "Hero, map, mode, hero-by-map, recent competitive form, and data-quality summaries are regenerated automatically whenever a match is added."
        ),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Matches analyzed: {len(matches)}")
    print(f"Wrote: {OUT}")


if __name__ == "__main__":
    main()
