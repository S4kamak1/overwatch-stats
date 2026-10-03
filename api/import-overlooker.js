const crypto = require("crypto");

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DEFAULT_PLAYER = "S4kamak1";

const HERO_ROLES = {
  ana: "support", baptiste: "support", brigitte: "support",
  illari: "support", juno: "support", kiriko: "support",
  lifeweaver: "support", lucio: "support", mercy: "support",
  moira: "support", zenyatta: "support",
  dva: "tank", doomfist: "tank", hazard: "tank", domina: "tank",
  junker_queen: "tank", mauga: "tank", orisa: "tank", ramattra: "tank",
  reinhardt: "tank", roadhog: "tank", sigma: "tank", winston: "tank",
  wrecking_ball: "tank", zarya: "tank",
  ashe: "damage", bastion: "damage", cassidy: "damage", echo: "damage",
  emre: "damage", freja: "damage", genji: "damage", hanzo: "damage",
  junkrat: "damage", mei: "damage", pharah: "damage", reaper: "damage",
  sojourn: "damage", soldier_76: "damage", sombra: "damage",
  symmetra: "damage", torbjorn: "damage", tracer: "damage",
  venture: "damage", widowmaker: "damage"
};

function send(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

function tokenMatches(actual, expected) {
  if (!actual || !expected) return false;
  const a = Buffer.from(actual);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function decodeEntities(value) {
  return String(value)
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}

function visibleTokens(html) {
  const stripped = html
    .replace(/<script\b[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript\b[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/[^>]+>/g, "\n")
    .replace(/<[^>]+>/g, " ");

  return decodeEntities(stripped)
    .split(/\n+/)
    .map((part) => part.replace(/\s+/g, " ").trim())
    .filter(Boolean);
}

function parseNumber(value) {
  const n = Number(String(value).replace(/,/g, "").trim());
  if (!Number.isFinite(n)) throw new Error(`Invalid numeric value: ${value}`);
  return n;
}

function parseDuration(value) {
  const match = String(value || "").trim().match(/^(\d{1,2}):(\d{2})$/);
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

function uniq(values) {
  return [...new Set(values.filter(Boolean))];
}

function detectPlayerHeroes(html, player) {
  const playerPos = html.toLowerCase().indexOf(player.toLowerCase());
  if (playerPos < 0) return [];

  const occurrences = [];
  const regex = /\/perks\/([a-z0-9_-]+)\//gi;
  let match;
  while ((match = regex.exec(html))) {
    const offset = match.index - playerPos;
    if (Math.abs(offset) <= 700) {
      occurrences.push({ hero: match[1].toLowerCase(), distance: Math.abs(offset), offset });
    }
  }
  occurrences.sort((a, b) => a.distance - b.distance || a.offset - b.offset);
  return uniq(occurrences.map((item) => item.hero));
}

function extractMatchId(body) {
  const direct = String(body.match_id || "").trim();
  if (UUID_RE.test(direct)) return direct;

  const shareUrl = String(body.share_url || "").trim();
  const match = shareUrl.match(/^https:\/\/overlooker\.app\/matches\/([0-9a-f-]{36})\/?(?:[?#].*)?$/i);
  if (match && UUID_RE.test(match[1])) return match[1];
  return null;
}

function parseMatch(matchId, sourceUrl, html, player) {
  const titleMatch = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (!titleMatch) throw new Error("Match title not found");

  const title = decodeEntities(titleMatch[1]).replace(/\s+/g, " ").trim();
  const parts = title.split("—").map((part) => part.trim());
  const map = parts[0] || null;
  const upperTitle = title.toUpperCase();
  const result = upperTitle.includes("VICTORY")
    ? "win"
    : upperTitle.includes("DEFEAT")
      ? "loss"
      : (upperTitle.includes("DRAW") || upperTitle.includes("TIE"))
        ? "draw"
        : "unknown";

  const tokens = visibleTokens(html);
  const playerIndex = tokens.findIndex((token) => token.toLowerCase() === player.toLowerCase());
  if (playerIndex < 0 || playerIndex + 6 >= tokens.length) {
    throw new Error(`Player row not found for ${player}`);
  }

  const row = tokens.slice(playerIndex, playerIndex + 7);
  const stats = {
    eliminations: parseNumber(row[1]),
    assists: parseNumber(row[2]),
    deaths: parseNumber(row[3]),
    damage: parseNumber(row[4]),
    healing: parseNumber(row[5]),
    mitigation: parseNumber(row[6])
  };

  const mapIndex = tokens.findIndex((token) => map && token.toLowerCase() === map.toLowerCase());
  const mode = mapIndex >= 0 && tokens[mapIndex + 1] ? tokens[mapIndex + 1].toLowerCase() : null;
  const side = mapIndex >= 0 && tokens[mapIndex + 2] ? tokens[mapIndex + 2].toLowerCase() : null;
  const duration = mapIndex >= 0 && tokens[mapIndex + 3] ? tokens[mapIndex + 3] : null;
  const durationSeconds = parseDuration(duration);

  const heroes = detectPlayerHeroes(html, player);
  const primaryHero = heroes[0] || null;
  const role = HERO_ROLES[primaryHero] || null;
  const kda = stats.deaths ? Number(((stats.eliminations + stats.assists) / stats.deaths).toFixed(2)) : null;

  const per10 = {};
  if (durationSeconds) {
    for (const key of ["eliminations", "assists", "deaths", "damage", "healing", "mitigation"]) {
      per10[key] = Number((stats[key] * 600 / durationSeconds).toFixed(2));
    }
  }

  return {
    match_id: matchId,
    source: "overlooker-share",
    source_url: sourceUrl,
    imported_at: new Date().toISOString(),
    player,
    result,
    map,
    mode,
    side,
    duration,
    duration_seconds: durationSeconds,
    role,
    primary_hero: primaryHero,
    heroes,
    hero_detection: "nearest_perk_assets_to_player_row",
    stats,
    kda,
    per_10_minutes: per10
  };
}

async function githubRequest(path, options = {}) {
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error("GITHUB_TOKEN is not configured");
  const response = await fetch(`https://api.github.com${path}`, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "overwatch-overlooker-import",
      ...(options.headers || {})
    }
  });
  if (!response.ok) {
    const text = await response.text();
    const error = new Error(`GitHub ${response.status}: ${text}`);
    error.status = response.status;
    throw error;
  }
  if (response.status === 204) return null;
  return response.json();
}

async function putJsonFile(path, value, message) {
  const repo = process.env.GITHUB_REPO || "S4kamak1/overwatch-stats";
  const branch = process.env.GITHUB_BRANCH || "main";
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  const apiPath = `/repos/${repo}/contents/${encodedPath}`;

  let sha = null;
  try {
    const current = await githubRequest(`${apiPath}?ref=${encodeURIComponent(branch)}`);
    sha = current && current.sha ? current.sha : null;
  } catch (error) {
    if (error.status !== 404) throw error;
  }

  const body = {
    message,
    branch,
    content: Buffer.from(JSON.stringify(value, null, 2) + "\n", "utf8").toString("base64")
  };
  if (sha) body.sha = sha;

  return githubRequest(apiPath, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
}

module.exports = async function handler(req, res) {
  if (req.method === "OPTIONS") {
    res.statusCode = 204;
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    return res.end();
  }

  if (req.method !== "POST") return send(res, 405, { ok: false, error: "method_not_allowed" });

  const expected = process.env.OW_INGEST_TOKEN;
  const auth = String(req.headers.authorization || "");
  const actual = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!tokenMatches(actual, expected)) return send(res, 401, { ok: false, error: "unauthorized" });

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch { body = null; }
  }
  if (!body || typeof body !== "object") return send(res, 400, { ok: false, error: "invalid_json" });

  const matchId = extractMatchId(body);
  if (!matchId) return send(res, 400, { ok: false, error: "invalid_match_id_or_share_url" });

  const player = String(body.player || DEFAULT_PLAYER).trim();
  if (!/^[^\r\n]{1,40}$/.test(player)) return send(res, 400, { ok: false, error: "invalid_player" });

  const sourceUrl = `https://overlooker.app/matches/${matchId}`;

  try {
    const upstream = await fetch(sourceUrl, {
      method: "GET",
      redirect: "follow",
      headers: {
        Accept: "text/html,application/xhtml+xml",
        "User-Agent": "OWStatsShareImporter/1.1"
      }
    });
    if (!upstream.ok) return send(res, 502, { ok: false, error: "overlooker_fetch_failed", status: upstream.status });

    const html = await upstream.text();
    const match = parseMatch(matchId, sourceUrl, html, player);
    await putJsonFile(`data/matches/${matchId}.json`, match, `Import OverLooker match ${matchId}`);

    return send(res, 200, { ok: true, stored: "match", match });
  } catch (error) {
    console.error(error);
    return send(res, 500, { ok: false, error: "import_failed", message: String(error && error.message || error) });
  }
};
