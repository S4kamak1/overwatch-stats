module.exports = async function handler(req, res) {
  res.statusCode = 200;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.end(JSON.stringify({
    ok: true,
    service: "overwatch-cloud-ingest",
    version: "2026-09-29-env-refresh-1",
    github_storage_configured: Boolean(process.env.GITHUB_TOKEN),
    ingest_auth_configured: Boolean(process.env.OW_INGEST_TOKEN),
    repository: process.env.GITHUB_REPO || "S4kamak1/overwatch-stats",
    branch: process.env.GITHUB_BRANCH || "main",
    time: new Date().toISOString()
  }));
};
