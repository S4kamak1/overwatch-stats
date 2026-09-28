const BRIDGE_URL = "http://127.0.0.1:32145/event";

const requestedFeatures = [
  "game_info",
  "match_info",
  "kill",
  "death",
  "assist"
];

async function send(kind, payload) {
  try {
    await fetch(BRIDGE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        received_at: new Date().toISOString(),
        kind,
        payload
      })
    });
  } catch (error) {
    console.warn("Bridge unavailable:", error);
  }
}

function registerFeatures() {
  overwolf.games.events.setRequiredFeatures(
    requestedFeatures,
    result => {
      send("feature_registration", result);
      if (!result.success) {
        console.error("Feature registration failed:", result.error);
      }
    }
  );
}

overwolf.games.events.onNewEvents.addListener(events => {
  send("events", events);
});

overwolf.games.events.onInfoUpdates2.addListener(info => {
  send("info", info);
});

overwolf.games.events.onError.addListener(error => {
  send("error", error);
});

overwolf.games.onGameInfoUpdated.addListener(update => {
  send("game_info_updated", update);
});

registerFeatures();
