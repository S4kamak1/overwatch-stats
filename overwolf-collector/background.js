const requestedFeatures = ["game_info", "match_info", "kill", "death", "assist"];

const sessionId = (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);
const diagnostic = {
  event_counts: {},
  schema_by_event: {},
  enabled_features: [],
  snapshot_reason: null
};

function shape(value, depth = 0) {
  if (depth >= 4) return typeof value;
  if (Array.isArray(value)) {
    return value.length ? [shape(value[0], depth + 1)] : [];
  }
  if (value && typeof value === "object") {
    const out = {};
    Object.keys(value).sort().forEach(key => {
      out[key] = shape(value[key], depth + 1);
    });
    return out;
  }
  return value === null ? "null" : typeof value;
}

function bump(name, sample) {
  diagnostic.event_counts[name] = (diagnostic.event_counts[name] || 0) + 1;
  if (!diagnostic.schema_by_event[name]) {
    diagnostic.schema_by_event[name] = shape(sample);
  }
}

function eventNames(payload) {
  const list = Array.isArray(payload) ? payload :
    (payload && Array.isArray(payload.events) ? payload.events : [payload]);

  const names = [];
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const name = item.name || item.event || item.type || item.feature || "unknown_event";
    names.push(String(name));
  }
  return names;
}

function cloudConfig() {
  return {
    endpoint: (localStorage.getItem("ow_cloud_endpoint") || "").trim(),
    token: (localStorage.getItem("ow_cloud_token") || "").trim()
  };
}

function openSettings() {
  if (!overwolf.windows || !overwolf.windows.obtainDeclaredWindow) return;
  overwolf.windows.obtainDeclaredWindow("settings", result => {
    if (!result || !result.window) return;
    overwolf.windows.restore(result.window.id, () => {});
  });
}

async function postDiagnostic(reason) {
  const { endpoint, token } = cloudConfig();
  if (!endpoint || !token) {
    openSettings();
    return;
  }

  diagnostic.snapshot_reason = reason;

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`
      },
      body: JSON.stringify({
        kind: "diagnostic_snapshot",
        received_at: new Date().toISOString(),
        session_id: sessionId,
        diagnostic
      })
    });

    if (!response.ok) {
      console.warn("Cloud diagnostic failed:", response.status);
    }
  } catch (error) {
    console.warn("Cloud endpoint unavailable:", error);
  }
}

function inspectEvents(payload) {
  const list = Array.isArray(payload) ? payload :
    (payload && Array.isArray(payload.events) ? payload.events : [payload]);

  let ended = false;
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const name = String(item.name || item.event || item.type || "unknown_event");
    bump(`event:${name}`, item);
    const lowered = name.toLowerCase();
    if (
      lowered.includes("match_end") ||
      lowered.includes("match_ended") ||
      lowered.includes("match_outcome")
    ) {
      ended = true;
    }
  }

  if (ended) {
    setTimeout(() => postDiagnostic("match_end"), 3000);
  }
}

function inspectInfo(info) {
  if (!info || typeof info !== "object") return;
  const feature = String(info.feature || info.name || "unknown_info");
  bump(`info:${feature}`, info);
}

function registerFeatures() {
  overwolf.games.events.setRequiredFeatures(requestedFeatures, result => {
    bump("feature_registration", result);
    diagnostic.enabled_features = (result && result.supportedFeatures) || [];
    if (!result.success) {
      console.error("Feature registration failed:", result.error);
    }
  });
}

overwolf.games.events.onNewEvents.addListener(events => {
  inspectEvents(events);
});

overwolf.games.events.onInfoUpdates2.addListener(info => {
  inspectInfo(info);
});

overwolf.games.events.onError.addListener(error => {
  bump("gep_error", error);
});

overwolf.games.onGameInfoUpdated.addListener(update => {
  bump("game_info_updated", update);
});

if (!cloudConfig().endpoint || !cloudConfig().token) {
  setTimeout(openSettings, 500);
}

registerFeatures();

// Backup: if the exact match-end event name changes, still emit one privacy-safe
// schema snapshot occasionally while OW2 is running.
setInterval(() => postDiagnostic("periodic_backup"), 10 * 60 * 1000);
