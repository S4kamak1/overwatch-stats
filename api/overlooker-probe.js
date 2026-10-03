const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function send(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body, null, 2));
}

function uniq(values) {
  return [...new Set(values.filter(Boolean))];
}

function extractAll(text, regex, limit = 30) {
  const out = [];
  let match;
  while ((match = regex.exec(text)) && out.length < limit) {
    out.push(match[1] || match[0]);
  }
  return out;
}

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    return send(res, 405, { ok: false, error: "method_not_allowed" });
  }

  const matchId = String(req.query && req.query.id || "").trim();
  if (!UUID_RE.test(matchId)) {
    return send(res, 400, { ok: false, error: "invalid_match_id" });
  }

  const url = `https://overlooker.app/matches/${matchId}`;

  try {
    const response = await fetch(url, {
      method: "GET",
      redirect: "follow",
      headers: {
        "Accept": "text/html,application/xhtml+xml",
        "User-Agent": "OWStatsShareProbe/1.0"
      }
    });

    const html = await response.text();
    const title = (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || null;
    const scriptSrcs = uniq(extractAll(html, /<script[^>]+src=["']([^"']+)["'][^>]*>/gi, 40));
    const scriptIds = uniq(extractAll(html, /<script[^>]+id=["']([^"']+)["'][^>]*>/gi, 20));
    const jsonScriptTypes = extractAll(html, /<script[^>]+type=["']application\/json["'][^>]*>/gi, 20).length;
    const nextData = /id=["']__NEXT_DATA__["']/i.test(html);
    const svelteData = /__svelte|sveltekit/i.test(html);

    const lower = html.toLowerCase();
    const markers = {
      victory: lower.includes("victory"),
      watchpoint_gibraltar: lower.includes("watchpoint: gibraltar") || lower.includes("watchpoint%3a%20gibraltar"),
      s4kamak1: lower.includes("s4kamak1"),
      illari: lower.includes("illari"),
      match_id: lower.includes(matchId.toLowerCase())
    };

    return send(res, 200, {
      ok: true,
      match_id: matchId,
      upstream: {
        status: response.status,
        final_url: response.url,
        content_type: response.headers.get("content-type"),
        content_length: html.length,
        title
      },
      page_signals: {
        next_data: nextData,
        svelte_or_sveltekit: svelteData,
        application_json_scripts: jsonScriptTypes,
        script_ids: scriptIds,
        script_srcs: scriptSrcs
      },
      markers,
      note: "This endpoint returns structural diagnostics only and does not store the OverLooker page body."
    });
  } catch (error) {
    return send(res, 502, {
      ok: false,
      error: "upstream_fetch_failed",
      message: String(error && error.message || error)
    });
  }
};
