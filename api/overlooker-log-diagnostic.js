const crypto = require("crypto");

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

async function githubRequest(path, options = {}) {
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error("GITHUB_TOKEN is not configured");
  const response = await fetch(`https://api.github.com${path}`, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "overwatch-overlooker-log-diagnostic",
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

function sanitizeDiagnostic(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;

  const files = Array.isArray(value.files) ? value.files.slice(0, 30).map((file) => ({
    name: String(file && file.name || "").slice(0, 120),
    size_bytes: Number(file && file.size_bytes || 0),
    modified_utc: String(file && file.modified_utc || "").slice(0, 80),
    lines_scanned: Number(file && file.lines_scanned || 0),
    uuid_count: Number(file && file.uuid_count || 0),
    unique_uuid_hashes: Array.isArray(file && file.unique_uuid_hashes)
      ? file.unique_uuid_hashes.slice(0, 50).map((x) => String(x).slice(0, 24))
      : [],
    keyword_counts: file && typeof file.keyword_counts === "object" ? file.keyword_counts : {},
    url_routes: Array.isArray(file && file.url_routes)
      ? file.url_routes.slice(0, 80).map((x) => String(x).slice(0, 240))
      : [],
    json_key_sets: Array.isArray(file && file.json_key_sets)
      ? file.json_key_sets.slice(0, 40).map((set) => Array.isArray(set) ? set.slice(0, 40).map((x) => String(x).slice(0, 80)) : [])
      : []
  })) : [];

  return {
    generated_at: String(value.generated_at || "").slice(0, 80),
    log_root_exists: Boolean(value.log_root_exists),
    files
  };
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
  const diagnostic = sanitizeDiagnostic(body && body.diagnostic);
  if (!diagnostic) return send(res, 400, { ok: false, error: "invalid_diagnostic" });

  const stored = {
    source: "overlooker-local-log-probe",
    server_received_at: new Date().toISOString(),
    diagnostic,
    privacy_note: "No raw OverLooker log lines, battletags, UUID values, query strings, tokens, or file contents are accepted or stored."
  };

  try {
    await putJsonFile(
      "data/overlooker-log-diagnostic.json",
      stored,
      "Update privacy-safe OverLooker log diagnostic"
    );
    return send(res, 200, { ok: true, stored: "overlooker_log_diagnostic" });
  } catch (error) {
    console.error(error);
    return send(res, 500, { ok: false, error: "storage_failed" });
  }
};
