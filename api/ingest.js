const crypto = require("crypto");

function json(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.end(JSON.stringify(body));
}

function tokenMatches(actual, expected) {
  if (!actual || !expected) return false;
  const a = Buffer.from(actual);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function safeFilePart(value) {
  return String(value || "")
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
}

async function githubRequest(path, options = {}) {
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error("GITHUB_TOKEN is not configured");

  const response = await fetch(`https://api.github.com${path}`, {
    ...options,
    headers: {
      "Accept": "application/vnd.github+json",
      "Authorization": `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "overwatch-cloud-ingest",
      ...(options.headers || {}),
    },
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
    content: Buffer.from(JSON.stringify(value, null, 2) + "\n", "utf8").toString("base64"),
  };
  if (sha) body.sha = sha;

  return githubRequest(apiPath, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
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

  if (req.method !== "POST") {
    return json(res, 405, { ok: false, error: "method_not_allowed" });
  }

  const expected = process.env.OW_INGEST_TOKEN;
  const auth = String(req.headers.authorization || "");
  const actual = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!tokenMatches(actual, expected)) {
    return json(res, 401, { ok: false, error: "unauthorized" });
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch { body = null; }
  }
  if (!body || typeof body !== "object") {
    return json(res, 400, { ok: false, error: "invalid_json" });
  }

  try {
    if (body.kind === "diagnostic_snapshot") {
      const diagnostic = {
        source: "overwolf-cloud",
        server_received_at: new Date().toISOString(),
        client_received_at: body.received_at || null,
        session_id: body.session_id || null,
        game_id: 10844,
        diagnostic: body.diagnostic || {},
        privacy_note: "Contains event names, counts and key/type shapes only; no raw game values.",
      };
      await putJsonFile(
        "data/cloud-diagnostic.json",
        diagnostic,
        "Update Overwatch cloud event diagnostic"
      );
      return json(res, 200, { ok: true, stored: "diagnostic" });
    }

    if (body.kind === "normalized_match") {
      const match = body.match;
      if (!match || typeof match !== "object") {
        return json(res, 400, { ok: false, error: "missing_match" });
      }
      const id = safeFilePart(match.match_id || match.id || body.received_at || Date.now());
      if (!id) return json(res, 400, { ok: false, error: "invalid_match_id" });

      const stored = {
        ...match,
        cloud_received_at: new Date().toISOString(),
        source: "overwolf-cloud",
      };
      await putJsonFile(
        `data/matches/${id}.json`,
        stored,
        `Add live Overwatch match ${id}`
      );
      return json(res, 200, { ok: true, stored: "match", id });
    }

    return json(res, 400, { ok: false, error: "unsupported_kind" });
  } catch (error) {
    console.error(error);
    return json(res, 500, { ok: false, error: "server_error" });
  }
};
