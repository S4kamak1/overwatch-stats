# Overwatch 2 live collector

This folder is a minimal Overwolf development app for collecting Overwatch 2
Game Events Provider data.

## Local test

1. Install Overwolf.
2. Update/clone this repository on the gaming PC.
3. Run `start_live_collector.bat` from the repository root.
4. In Overwolf's developer tools, load the `overwolf-collector` folder as an unpacked extension.
5. Start Overwatch 2 and play one competitive match.
6. Keep the bridge window open until the match has ended.
7. Run `inspect_live_events.bat`.

Raw events stay local in:

```
data/live/overwolf-events.jsonl
```

The privacy-safe diagnostic is written to:

```
data/live/event-diagnostic.json
```

`data/live/` is ignored by Git, so live event values are not uploaded to the
public repository.

Attach `event-diagnostic.json` to ChatGPT. Its event/key structure is enough
to build the next stage: one normalized JSON record per match.
