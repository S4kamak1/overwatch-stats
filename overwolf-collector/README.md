# Overwatch 2 live collector

This folder is a minimal Overwolf development app for collecting Overwatch 2
Game Events Provider data.

## Local test

1. Install Overwolf.
2. Start `start_live_collector.bat` from the repository root.
3. In Overwolf's developer options, load this `overwolf-collector` folder as an unpacked extension.
4. Start Overwatch 2 and play one competitive match.
5. Keep the bridge window open.
6. After the match, run:

```
python inspect_live_events.py
```

Raw events are written to:

```
data/live/overwolf-events.jsonl
```

A compact diagnostic is written to:

```
data/live/event-diagnostic.json
```

The next implementation step uses that real payload shape to produce one
normalized JSON record per match.
