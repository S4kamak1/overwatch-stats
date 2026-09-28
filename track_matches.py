import json
import sys
from datetime import datetime, timezone
from pathlib import Path

FIELDS = ("eliminations", "assists", "deaths", "damage", "healing")


def load(path):
    p = Path(path)
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def save(path, obj):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def num(value):
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return value
    return 0


def delta_value(current, previous, key):
    return num((current or {}).get(key)) - num((previous or {}).get(key))


def metric_block(previous, current):
    previous = previous or {}
    current = current or {}

    previous_total = previous.get("total") or {}
    current_total = current.get("total") or {}

    seconds = delta_value(current, previous, "time_played")

    total = {
        key: num(current_total.get(key)) - num(previous_total.get(key))
        for key in FIELDS
    }

    deaths = total["deaths"]
    kda = None
    if deaths > 0:
        kda = round((total["eliminations"] + total["assists"]) / deaths, 2)

    per_10_minutes = {}
    if seconds > 0:
        per_10_minutes = {
            key: round(value * 600 / seconds, 2)
            for key, value in total.items()
        }

    return {
        "games_played": delta_value(current, previous, "games_played"),
        "games_won": delta_value(current, previous, "games_won"),
        "games_lost": delta_value(current, previous, "games_lost"),
        "time_played": seconds,
        "total": total,
        "kda": kda,
        "per_10_minutes": per_10_minutes,
    }


def get_season(snapshot):
    try:
        return snapshot["summary"]["competitive"]["pc"]["season"]
    except (KeyError, TypeError):
        return None


def classify_result(games, wins, losses):
    if games == 1:
        if wins == 1 and losses == 0:
            return "win"
        if losses == 1 and wins == 0:
            return "loss"
        if wins == 0 and losses == 0:
            return "draw_or_unknown"
        return "unknown"

    if games > 1:
        if wins == games and losses == 0:
            return "all_wins"
        if losses == games and wins == 0:
            return "all_losses"
        return "mixed"

    return "no_game"


def changed(block):
    if block["games_played"] != 0:
        return True
    if block["games_won"] != 0 or block["games_lost"] != 0:
        return True
    if block["time_played"] != 0:
        return True
    return any(value != 0 for value in block["total"].values())


def make_event(previous, current):
    previous_stats = previous.get("stats") or {}
    current_stats = current.get("stats") or {}

    general = metric_block(
        previous_stats.get("general"),
        current_stats.get("general"),
    )

    old_season = get_season(previous)
    new_season = get_season(current)

    reset = (
        (
            old_season is not None
            and new_season is not None
            and old_season != new_season
        )
        or general["games_played"] < 0
        or general["games_won"] < 0
        or general["games_lost"] < 0
    )

    if reset:
        status = "reset"
    elif general["games_played"] == 0:
        status = "no_change"
    elif general["games_played"] == 1:
        status = "single_game"
    else:
        status = "multi_game"

    roles = {}
    previous_roles = previous_stats.get("roles") or {}
    current_roles = current_stats.get("roles") or {}

    for name in sorted(set(previous_roles) | set(current_roles)):
        block = metric_block(
            previous_roles.get(name),
            current_roles.get(name),
        )
        if changed(block):
            roles[name] = block

    heroes = {}
    previous_heroes = previous_stats.get("heroes") or {}
    current_heroes = current_stats.get("heroes") or {}

    changed_heroes = []
    for name in set(previous_heroes) | set(current_heroes):
        block = metric_block(
            previous_heroes.get(name),
            current_heroes.get(name),
        )
        if changed(block):
            changed_heroes.append((name, block))

    changed_heroes.sort(
        key=lambda item: item[1]["time_played"],
        reverse=True,
    )

    for name, block in changed_heroes:
        heroes[name] = block

    primary_role = max(
        roles,
        key=lambda name: roles[name]["time_played"],
        default=None,
    )
    primary_hero = max(
        heroes,
        key=lambda name: heroes[name]["time_played"],
        default=None,
    )

    previous_general = previous_stats.get("general") or {}
    current_general = current_stats.get("general") or {}

    event_id = (
        f"s{old_season}-{new_season}:"
        f"g{num(previous_general.get('games_played'))}"
        f"-{num(current_general.get('games_played'))}:"
        f"w{num(previous_general.get('games_won'))}"
        f"-{num(current_general.get('games_won'))}:"
        f"l{num(previous_general.get('games_lost'))}"
        f"-{num(current_general.get('games_lost'))}"
    )

    heroes_used = []
    total_seconds = general["time_played"]

    for name, block in changed_heroes:
        if block["time_played"] <= 0:
            continue

        share_percent = None
        if total_seconds > 0:
            share_percent = round(
                block["time_played"] / total_seconds * 100,
                1,
            )

        heroes_used.append(
            {
                "hero": name,
                "time_played": block["time_played"],
                "share_percent": share_percent,
            }
        )

    return {
        "event_id": event_id,
        "from_fetched_at": previous.get("fetched_at"),
        "to_fetched_at": current.get("fetched_at"),
        "season_from": old_season,
        "season_to": new_season,
        "status": status,
        "result": classify_result(
            general["games_played"],
            general["games_won"],
            general["games_lost"],
        ),
        "primary_role": primary_role,
        "primary_hero": primary_hero,
        "heroes_used": heroes_used,
        "general": general,
        "roles": roles,
        "heroes": heroes,
    }


def read_events(folder):
    folder = Path(folder)
    if not folder.exists():
        return []

    events = []

    for path in sorted(folder.glob("*.jsonl")):
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line:
                    events.append(json.loads(line))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"WARNING: Could not read {path}: {exc}")

    return events


def average(values):
    usable = [
        value
        for value in values
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    ]

    if not usable:
        return None

    return round(sum(usable) / len(usable), 2)


def summarize_result(events, wanted_result):
    selected = [
        event
        for event in events
        if event.get("status") == "single_game"
        and event.get("result") == wanted_result
    ]

    if not selected:
        return {
            "games": 0,
            "average": {},
        }

    return {
        "games": len(selected),
        "average": {
            "duration_seconds": average([
                event["general"].get("time_played")
                for event in selected
            ]),
            **{
                field: average([
                    event["general"]["total"].get(field)
                    for event in selected
                ])
                for field in FIELDS
            },
            "kda": average([
                event["general"].get("kda")
                for event in selected
            ]),
            "per_10_minutes": {
                field: average([
                    event["general"]
                    .get("per_10_minutes", {})
                    .get(field)
                    for event in selected
                ])
                for field in FIELDS
            },
        },
    }


def aggregate(events, current):
    single_games = [
        event
        for event in events
        if event.get("status") == "single_game"
        and event.get("result") in ("win", "loss")
    ]

    hero_stats = {}
    role_stats = {}

    for event in single_games:
        outcome = event["result"]

        for name, destination in (
            (event.get("primary_hero"), hero_stats),
            (event.get("primary_role"), role_stats),
        ):
            if not name:
                continue

            bucket = destination.setdefault(
                name,
                {
                    "games": 0,
                    "wins": 0,
                    "losses": 0,
                },
            )

            bucket["games"] += 1
            if outcome == "win":
                bucket["wins"] += 1
            else:
                bucket["losses"] += 1

    for collection in (hero_stats, role_stats):
        for bucket in collection.values():
            bucket["winrate"] = round(
                bucket["wins"] / bucket["games"] * 100,
                2,
            )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "current_season": get_season(current),
        "single_games_tracked": len(single_games),
        "wins": summarize_result(events, "win"),
        "losses": summarize_result(events, "loss"),
        "primary_heroes": hero_stats,
        "primary_roles": role_stats,
        "notes": [
            "Single-game records are inferred from differences between cumulative OverFast snapshots.",
            "Only intervals with exactly one new competitive game are used for direct win/loss averages.",
            "Intervals with multiple games are preserved but excluded from single-game averages.",
            "Primary hero is inferred from the largest increase in hero time played during the interval.",
        ],
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "Usage: python track_matches.py PREVIOUS CURRENT"
        )

    previous = load(sys.argv[1])
    current = load(sys.argv[2])

    if not current:
        raise SystemExit("Current snapshot not found")

    events_dir = Path("data/events")
    events = read_events(events_dir)

    if previous:
        event = make_event(previous, current)
        save("data/latest_delta.json", event)

        print()
        print("=== Match delta ===")
        print(f"Status: {event['status']}")
        print(f"Result: {event['result']}")
        print(
            "Games: "
            f"{event['general']['games_played']} "
            f"(W {event['general']['games_won']} / "
            f"L {event['general']['games_lost']})"
        )
        print(f"Primary role: {event['primary_role']}")
        print(f"Primary hero: {event['primary_hero']}")

        should_record = event["status"] in (
            "single_game",
            "multi_game",
            "reset",
        )

        already_recorded = any(
            old.get("event_id") == event["event_id"]
            for old in events
        )

        if should_record and not already_recorded:
            events_dir.mkdir(parents=True, exist_ok=True)

            month = datetime.now(timezone.utc).strftime("%Y-%m")
            path = events_dir / f"{month}.jsonl"

            with path.open("a", encoding="utf-8") as f:
                f.write(
                    json.dumps(
                        event,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                    + "\n"
                )

            events.append(event)
            print(f"Recorded event: {path}")
        elif already_recorded:
            print("Event already recorded.")
        else:
            print("No new competitive game detected.")

    else:
        save(
            "data/latest_delta.json",
            {
                "status": "baseline",
                "result": "no_game",
                "message": (
                    "Baseline snapshot created. "
                    "Tracking begins with the next detected competitive change."
                ),
            },
        )
        print("Baseline snapshot created.")

    save(
        "data/analysis/win_loss_summary.json",
        aggregate(events, current),
    )


if __name__ == "__main__":
    main()
