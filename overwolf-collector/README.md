# Overwatch 2 live collector

This is the local real-time layer for per-match Overwatch analysis.

## One-time setup

1. Install Overwolf.
2. Pull the latest version of this repository onto the gaming PC.
3. Load the `overwolf-collector` folder once as an unpacked/development extension in Overwolf.
4. Run `setup_live_collector.bat` once.
5. Confirm the bridge health check succeeds.

After that, Windows logon starts the bridge automatically. The Overwolf
extension is targeted to Overwatch 2 and is configured to launch with the game.

## Automated flow

Windows logon -> local bridge starts -> OW2 starts -> Overwolf events are
captured -> normalized match JSONs under `data/matches/` are automatically
committed and pushed -> GitHub Actions refreshes live analysis.

## Privacy

Raw Overwolf event data stays only under `data/live/` and is ignored by Git.
Only normalized per-match files under `data/matches/` are eligible for automatic
GitHub sync.

## Current remaining step

Transport, Windows autostart, Git sync and GitHub-side analysis are automated.
One real Overwatch match still needs to be observed once so the exact GEP payload
can be mapped into a stable one-match JSON schema. After that parser is added,
normal play is enough; no game restart or manual upload is required.
