import json
import urllib.request
import urllib.parse
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

USER_AGENT = "S4kamak1-OW-Stats/1.0"


# =========================
# HTTP
# =========================

def fetch_json(url):
    print(f"GET {url}")

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(
            req,
            timeout=30,
        ) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            body = response.read().decode(charset)

            print(f"HTTP {response.status}")

            return json.loads(body)

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
            f"HTTP request failed\n"
            f"Status: {e.code}\n"
            f"URL: {url}\n"
            f"Response:\n{body}"
        ) from e

    except URLError as e:
        raise RuntimeError(
            "\n"
            f"Network request failed\n"
            f"URL: {url}\n"
            f"Reason: {e.reason}"
        ) from e

    except json.JSONDecodeError as e:
        raise RuntimeError(
            "\n"
            f"Invalid JSON response\n"
            f"URL: {url}\n"
            f"Error: {e}"
        ) from e


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

    search = fetch_json(search_url)

    results = search.get("results", [])

    print(
        f"Search returned "
        f"{len(results)} result(s)"
    )

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

    # Display candidates in Actions log
    for index, player in enumerate(results):
        print(
            f"[{index}] "
            f"name={player.get('name')} "
            f"player_id={player.get('player_id')} "
            f"blizzard_id={player.get('blizzard_id')} "
            f"is_public={player.get('is_public')}"
        )

    # First preference: exact player_id match
    for player in results:
        if player.get("player_id") == PLAYER:
            print()
            print("Exact BattleTag/player_id match found.")
            return player, search

    # Second preference:
    # exact match ignoring capitalization
    for player in results:
        player_id = player.get("player_id")

        if (
            isinstance(player_id, str)
            and player_id.lower() == PLAYER.lower()
        ):
            print()
            print(
                "Case-insensitive "
                "BattleTag/player_id match found."
            )
            return player, search

    # Third preference:
    # username portion match
    expected_name = PLAYER.rsplit("-", 1)[0]

    name_matches = [
        player
        for player in results
        if player.get("name", "").lower()
        == expected_name.lower()
    ]

    if len(name_matches) == 1:
        print()
        print(
            "One matching username found. "
            "Using that result."
        )
        return name_matches[0], search

    # Do NOT silently choose the wrong account.
    print()
    print(
        "Could not uniquely identify "
        "the requested BattleTag."
    )

    raise RuntimeError(
        "\n"
        f"Player search returned candidates, "
        f"but none exactly matched {PLAYER}.\n"
        "Check the candidate list above in the GitHub Actions log."
    )


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

    resolved, search_response = search_player()

    player_id = resolved.get("player_id")
    blizzard_id = resolved.get("blizzard_id")
    is_public = resolved.get("is_public")

    if not player_id:
        raise RuntimeError(
            "Search result did not contain player_id"
        )

    print()
    print("=== Resolved player ===")
    print(f"Name: {resolved.get('name')}")
    print(f"Player ID: {player_id}")
    print(f"Blizzard ID: {blizzard_id}")
    print(f"Public profile: {is_public}")

    if is_public is False:
        print()
        print(
            "WARNING: Blizzard reports that "
            "this career profile is private."
        )

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

    print()
    print("=== Fetching summary ===")
    summary = fetch_json(summary_url)

    print()
    print("=== Fetching competitive stats ===")
    stats = fetch_json(stats_url)

    result = {
        "requested_player": PLAYER,
        "resolved_player_id": player_id,
        "blizzard_id": blizzard_id,
        "player_name": resolved.get("name"),
        "is_public": is_public,
        "platform": PLATFORM,
        "gamemode": GAMEMODE,
        "fetched_at": now.isoformat(),
        "resolved_player": resolved,
        "summary": summary,
        "stats": stats,
    }

    data_dir = Path("data")
    history_dir = data_dir / "history"

    data_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    history_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    latest_file = data_dir / "latest.json"

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

    # Debug/search result also preserved
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

    print()
    print("===================================")
    print("SUCCESS")
    print("===================================")
    print(f"Latest: {latest_file}")
    print(f"History: {history_file}")


if __name__ == "__main__":
    main()
