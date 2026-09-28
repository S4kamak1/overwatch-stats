import json
import time
import urllib.parse
import urllib.request
from urllib.error import HTTPError, URLError
from datetime import datetime, timezone
from pathlib import Path


# =========================
# Settings
# =========================

PLAYER = "S4kamak1-1198"
BASE = "https://overfast-api.tekrop.fr"

PLATFORM = "pc"
GAMEMODE = "competitive"

USER_AGENT = "S4kamak1-OW-Stats/2.0"

# OverFast serves stale player data while refreshing it in the background.
# Its stale API response is short-lived, so wait long enough for the worker
# to refresh the Blizzard profile before doing the second pass.
REFRESH_WAIT_SECONDS = 70


# =========================
# HTTP
# =========================

def fetch_json(url, *, cache_control=None):
    print(f"GET {url}")

    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
    }

    if cache_control:
        headers["Cache-Control"] = cache_control

    req = urllib.request.Request(
        url,
        headers=headers,
    )

    try:
        with urllib.request.urlopen(
            req,
            timeout=45,
        ) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            body = response.read().decode(charset)

            response_headers = {
                key.lower(): value
                for key, value in response.headers.items()
            }

            print(f"HTTP {response.status}")

            age = response_headers.get("age")
            cache_ttl = response_headers.get("x-cache-ttl")
            cache_header = response_headers.get("cache-control")

            if age is not None:
                print(f"Age: {age}")
            if cache_ttl is not None:
                print(f"X-Cache-TTL: {cache_ttl}")
            if cache_header is not None:
                print(f"Cache-Control: {cache_header}")

            return json.loads(body), response_headers

    except HTTPError as e:
        try:
            body = e.read().decode(
                "utf-8",
                errors="replace",
            )
        except Exception:
            body = "<unable to read response body>"

        raise RuntimeError(
            "\n"
            "HTTP request failed\n"
            f"Status: {e.code}\n"
            f"URL: {url}\n"
            f"Response:\n{body}"
        ) from e

    except URLError as e:
        raise RuntimeError(
            "\n"
            "Network request failed\n"
            f"URL: {url}\n"
            f"Reason: {e.reason}"
        ) from e

    except json.JSONDecodeError as e:
        raise RuntimeError(
            "\n"
            "Invalid JSON response\n"
            f"URL: {url}\n"
            f"Error: {e}"
        ) from e


def read_json(path):
    if not path.exists():
        return None

    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"WARNING: Could not read {path}: {e}")
        return None


def add_cache_buster(url):
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}_ts={time.time_ns()}"


# =========================
# Player resolution
# =========================

def search_player():
    query = urllib.parse.urlencode({
        "name": PLAYER,
        "limit": 20,
    })

    search_url = f"{BASE}/players?{query}"

    print()
    print("=== Searching player ===")

    search, _ = fetch_json(search_url)
    results = search.get("results", [])

    print(f"Search returned {len(results)} result(s)")

    if not results:
        raise RuntimeError(
            "\n"
            f"No OverFast player found for: {PLAYER}\n"
            "Possible causes:\n"
            "- BattleTag is incorrect\n"
            "- Blizzard search has not indexed the player yet\n"
            "- The BattleTag capitalization is different\n"
            "- Blizzard/OverFast is temporarily unable to resolve the player"
        )

    for index, player in enumerate(results):
        print(
            f"[{index}] "
            f"name={player.get('name')} "
            f"player_id={player.get('player_id')} "
            f"is_public={player.get('is_public')} "
            f"last_updated_at={player.get('last_updated_at')}"
        )

    for player in results:
        if player.get("player_id") == PLAYER:
            print()
            print("Exact BattleTag/player_id match found.")
            return player, search

    for player in results:
        player_id = player.get("player_id")

        if (
            isinstance(player_id, str)
            and player_id.lower() == PLAYER.lower()
        ):
            print()
            print("Case-insensitive BattleTag/player_id match found.")
            return player, search

    expected_name = PLAYER.rsplit("-", 1)[0]

    name_matches = [
        player
        for player in results
        if player.get("name", "").lower() == expected_name.lower()
    ]

    if len(name_matches) == 1:
        print()
        print("One matching username found. Using that result.")
        return name_matches[0], search

    raise RuntimeError(
        "\n"
        f"Player search returned candidates, "
        f"but none exactly matched {PLAYER}.\n"
        "Check the candidate list above in the GitHub Actions log."
    )


# =========================
# OverFast player fetch
# =========================

def build_player_urls(player_id):
    encoded_player_id = urllib.parse.quote(
        player_id,
        safe="-|%",
    )

    summary_url = (
        f"{BASE}/players/"
        f"{encoded_player_id}/summary"
    )

    stats_query = urllib.parse.urlencode({
        "gamemode": GAMEMODE,
        "platform": PLATFORM,
    })

    stats_url = (
        f"{BASE}/players/"
        f"{encoded_player_id}/stats/summary"
        f"?{stats_query}"
    )

    return summary_url, stats_url


def fetch_player_data(summary_url, stats_url, *, bust_cache=False):
    if bust_cache:
        summary_url = add_cache_buster(summary_url)
        stats_url = add_cache_buster(stats_url)

    print()
    print("=== Fetching summary ===")
    summary, summary_headers = fetch_json(
        summary_url,
        cache_control="no-cache" if bust_cache else None,
    )

    print()
    print("=== Fetching competitive stats ===")
    stats, stats_headers = fetch_json(
        stats_url,
        cache_control="no-cache" if bust_cache else None,
    )

    return summary, stats, {
        "summary": summary_headers,
        "stats": stats_headers,
    }


def games_played(snapshot):
    try:
        return int(snapshot["stats"]["general"]["games_played"])
    except (KeyError, TypeError, ValueError):
        return None


def should_retry(previous, first_result):
    if previous is None:
        return False

    previous_games = games_played(previous)
    current_games = games_played(first_result)

    if previous_games is None or current_games is None:
        return False

    # If the cumulative total has not advanced, the first response may be
    # OverFast's stale-while-revalidate response. A second pass after the
    # short stale window gives its background worker time to refresh Blizzard.
    return current_games <= previous_games


# =========================
# Main
# =========================

def main():
    now = datetime.now(timezone.utc)

    print("===================================")
    print("Overwatch Stats Collector")
    print("===================================")
    print(f"Requested player: {PLAYER}")
    print(f"Platform: {PLATFORM}")
    print(f"Gamemode: {GAMEMODE}")

    data_dir = Path("data")
    history_dir = data_dir / "history"
    latest_file = data_dir / "latest.json"

    previous = read_json(latest_file)

    resolved, search_response = search_player()

    player_id = resolved.get("player_id")
    blizzard_id = resolved.get("blizzard_id")
    is_public = resolved.get("is_public")

    if not player_id:
        raise RuntimeError("Search result did not contain player_id")

    print()
    print("=== Resolved player ===")
    print(f"Name: {resolved.get('name')}")
    print(f"Player ID: {player_id}")
    print(f"Public profile: {is_public}")
    print(f"Search last_updated_at: {resolved.get('last_updated_at')}")

    if is_public is False:
        print()
        print(
            "WARNING: Blizzard reports that "
            "this career profile is private."
        )

    summary_url, stats_url = build_player_urls(player_id)

    summary, stats, response_headers = fetch_player_data(
        summary_url,
        stats_url,
    )

    first_result = {
        "stats": stats,
    }

    refresh_retry_used = False

    if should_retry(previous, first_result):
        previous_games = games_played(previous)
        current_games = games_played(first_result)

        print()
        print("===================================")
        print("POSSIBLE STALE OVERFAST RESPONSE")
        print("===================================")
        print(f"Previous games: {previous_games}")
        print(f"First-pass games: {current_games}")
        print(
            "Waiting for OverFast background refresh "
            f"({REFRESH_WAIT_SECONDS}s)..."
        )

        time.sleep(REFRESH_WAIT_SECONDS)

        print()
        print("=== Refresh retry ===")

        retry_summary, retry_stats, retry_headers = fetch_player_data(
            summary_url,
            stats_url,
            bust_cache=True,
        )

        retry_games = None
        try:
            retry_games = int(
                retry_stats["general"]["games_played"]
            )
        except (KeyError, TypeError, ValueError):
            pass

        print(f"Retry games: {retry_games}")

        summary = retry_summary
        stats = retry_stats
        response_headers = retry_headers
        refresh_retry_used = True

    result = {
        "requested_player": PLAYER,
        "resolved_player_id": player_id,
        "blizzard_id": blizzard_id,
        "player_name": resolved.get("name"),
        "is_public": is_public,
        "platform": PLATFORM,
        "gamemode": GAMEMODE,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "refresh_retry_used": refresh_retry_used,
        "overfast_response_headers": response_headers,
        "resolved_player": resolved,
        "summary": summary,
        "stats": stats,
    }

    data_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    history_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    with latest_file.open(
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(
            result,
            f,
            ensure_ascii=False,
            indent=2,
        )
        f.write("\n")

    history_file = (
        history_dir
        / f"{now.strftime('%Y-%m-%d')}.json"
    )

    with history_file.open(
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(
            result,
            f,
            ensure_ascii=False,
            indent=2,
        )
        f.write("\n")

    with (
        data_dir / "player_search.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(
            search_response,
            f,
            ensure_ascii=False,
            indent=2,
        )
        f.write("\n")

    print()
    print("===================================")
    print("SUCCESS")
    print("===================================")
    print(f"Latest: {latest_file}")
    print(f"History: {history_file}")
    print(f"Refresh retry used: {refresh_retry_used}")
    print(f"Final games played: {games_played(result)}")


if __name__ == "__main__":
    main()
