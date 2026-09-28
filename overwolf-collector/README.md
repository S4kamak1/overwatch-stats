# Overwatch 2 cloud collector

This collector sends privacy-safe diagnostics directly from Overwolf to an HTTPS
cloud endpoint. The GitHub repository no longer needs to be cloned onto the gaming PC.

## PC requirements

- Overwolf
- the packaged `overwolf-collector` extension only

Python, Git, `local_bridge.py`, and the full repository are not required for cloud mode.

## First-time setup

1. Deploy this repository to Vercel.
2. Configure the Vercel environment variables:
   - `OW_INGEST_TOKEN`: a long random secret
   - `GITHUB_TOKEN`: a fine-grained GitHub token with Contents read/write for only this repository
   - `GITHUB_REPO`: `S4kamak1/overwatch-stats`
   - `GITHUB_BRANCH`: `main`
3. Download the packaged Overwolf collector from the GitHub Actions artifact.
4. Load the collector once as an unpacked/development Overwolf extension.
5. The settings window opens automatically. Enter:
   - `https://<your-vercel-project>/api/ingest`
   - the same `OW_INGEST_TOKEN`
6. Press the connection-test button.

## Privacy

During the initial mapping stage, raw Overwatch event values are not uploaded.
The collector sends only event names, counts, and key/type structure. The cloud endpoint
stores that as `data/cloud-diagnostic.json`.

After the first real match is mapped, the collector can be upgraded to send one
normalized match JSON at match end. The same endpoint already supports
`kind: normalized_match` and stores those records under `data/matches/`.

## Automation

Once configured, OW2 launch starts the collector through Overwolf. No game restart,
local Python process, Git clone, or manual upload is needed.


## Important Overwolf development requirement

Overwolf currently requires a developer-whitelisted account to load unpacked or
unreleased apps. This custom collector should only be tested when the Overwolf
account is already authorized for development. The cloud ingest endpoint can
remain in place regardless of which approved/public match collector is used.
