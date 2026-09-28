import json
from collections import Counter
from pathlib import Path

SOURCE = Path("data/live/overwolf-events.jsonl")
OUT = Path("data/live/event-diagnostic.json")


def event_names(item):
    payload = item.get("payload")

    if isinstance(payload, dict):
        events = payload.get("events")
        if isinstance(events, list):
            names = []
            for event in events:
                if isinstance(event, dict):
                    name = (
                        event.get("name")
                        or event.get("event")
                        or event.get("type")
                    )
                    if name:
                        names.append(str(name))
            if names:
                return names

        for key in ("name", "event", "type", "feature"):
            value = payload.get(key)
            if value:
                return [str(value)]

    return [item.get("kind", "unknown")]


def shape(value, depth=0):
    if depth >= 4:
        return type(value).__name__

    if isinstance(value, dict):
        return {
            key: shape(child, depth + 1)
            for key, child in sorted(value.items())
        }

    if isinstance(value, list):
        if not value:
            return []
        return [shape(value[0], depth + 1)]

    return type(value).__name__


def main():
    if not SOURCE.exists():
        raise SystemExit(
            f"No live event log found: {SOURCE}\n"
            "Start start_live_collector.bat and play Overwatch 2 first."
        )

    rows = []

    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue

        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass

    counts = Counter()
    schemas = {}

    for row in rows:
        names = event_names(row)

        for name in names:
            counts[name] += 1
            schemas.setdefault(name, shape(row))

    result = {
        "source": str(SOURCE),
        "records": len(rows),
        "event_counts": dict(counts.most_common()),
        "schema_by_event": schemas,
        "note": (
            "Diagnostic contains key/type structure only. "
            "Raw event values stay local in data/live/."
        ),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Records: {len(rows)}")
    print(f"Diagnostic: {OUT}")
    print()
    for name, count in counts.most_common():
        print(f"{name}: {count}")


if __name__ == "__main__":
    main()
