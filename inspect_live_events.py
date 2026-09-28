import json
from collections import Counter
from pathlib import Path

SOURCE = Path("data/live/overwolf-events.jsonl")
OUT = Path("data/live/event-diagnostic.json")


def event_name(item):
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
    samples = {}

    for row in rows:
        for name in event_name(row):
            counts[name] += 1
            samples.setdefault(name, row)

    result = {
        "source": str(SOURCE),
        "records": len(rows),
        "event_counts": dict(counts.most_common()),
        "sample_by_event": samples,
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
