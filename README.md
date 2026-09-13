# mpv-plex-scrobbler

An mpv Lua script that scrobbles playback to a local Plex Media Server, so
progress and watched status sync back to Plex (e.g. Continue Watching shows
up correctly when you later watch on the TV app).

## How it works

- When mpv loads a file, the script looks up the file's path in a local
  cache mapping Plex library file paths to `ratingKey`s.
- On a cache miss, it queries your Plex server's library sections (movies
  and TV episodes) and rebuilds the cache.
- Once a match is found, the script sends Plex `/:/timeline` updates
  (the same API real Plex clients use) on play, pause, stop, and every
  10 seconds during playback.
- If Plex has a saved resume position (`viewOffset`) for the matched item
  above `resume_threshold` seconds, mpv seeks there automatically when the
  file starts (set `resume_playback=no` to disable).
- If a file isn't found in your Plex library, it's silently skipped.

This assumes mpv is running on the same machine (or sees the same
filesystem paths) as your Plex server, since matching is done by exact/
suffix file path comparison.

## Installation

1. Copy `scripts/plex-scrobbler.lua` to `~/.config/mpv/scripts/`
2. Copy `script-opts/plex-scrobbler.conf` to `~/.config/mpv/script-opts/`
3. Edit the copied `plex-scrobbler.conf` and set your Plex token (see below)

## Getting a Plex token

1. Open Plex Web in your browser and log in.
2. Open your browser's developer tools (F12, or Ctrl+Shift+I) and go to the
   **Network** tab.
3. Play any item, or just navigate around the library, so requests start
   showing up.
4. Click on any request to `localhost:32400` (or your Plex server) and look
   at its request headers/query string for `X-Plex-Token`. Copy its value.

Or see Plex's own instructions: [Context: "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/"]

Paste it into `plex-scrobbler.conf` as `token=...`.

## Debugging

Run mpv with debug-level logging for this script to see path matching,
cache refreshes, and every request sent to Plex:

```
mpv --msg-level=plex_scrobbler=debug /path/to/file.mkv
```

## Notes

- Requires `curl` to be installed and on `PATH`.
- Set `plex_url` in the config if your server isn't at
  `http://localhost:32400`.
- The library cache (`~/.cache/mpv/plex-scrobbler-cache.json`) is
  automatically refreshed whenever it's older than `cache_ttl` (default:
  1 day) or a played file isn't found in it — so newly added media is
  picked up automatically without any manual action. Delete the cache
  file yourself to force an immediate full rescan sooner than that.
