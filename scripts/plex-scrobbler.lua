-- plex-scrobbler.lua
--
-- Scrobbles mpv playback to a local Plex Media Server, so that watch
-- progress / watched status shows up in Plex (e.g. Continue Watching on TV).
--
-- Install: copy this file to ~/.config/mpv/scripts/
-- Configure: copy plex-scrobbler.conf to ~/.config/mpv/script-opts/
--            and set your token there.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local opts = {
    plex_url = "http://localhost:32400",
    token = "",
    progress_interval = 10, -- seconds
    cache_ttl = 86400, -- seconds; refresh library cache at most this often
    resume_playback = true, -- seek to Plex's viewOffset when a file starts
    resume_threshold = 60, -- seconds; ignore Plex offsets below this
}
options.read_options(opts, "plex-scrobbler")

local cache_dir = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/mpv"
local cache_file = cache_dir .. "/plex-scrobbler-cache.json"
local client_id_file = cache_dir .. "/plex-scrobbler-client-id"

local client_id = nil
local cache = nil -- { generated_at = <number>, items = { [path] = {ratingKey=, duration=} } }

local session = {
    ratingKey = nil,
    duration = nil, -- ms
    active = false,
    last_time_ms = nil, -- last known time-pos, ms (fallback for end-file/shutdown,
                         -- since "time-pos" can already be unset by then)
}

local timer = nil

-- Utilities

local function ensure_cache_dir()
    utils.subprocess({ args = { "mkdir", "-p", cache_dir } })
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then
        msg.warn("plex-scrobbler: could not write to " .. path)
        return false
    end
    f:write(content)
    f:close()
    return true
end

local function get_client_id()
    if client_id then return client_id end
    local existing = read_file(client_id_file)
    if existing and #existing > 0 then
        client_id = existing:gsub("%s+$", "")
        return client_id
    end
    ensure_cache_dir()
    -- simple pseudo-uuid, good enough as a stable client identifier
    math.randomseed(os.time() + (os.clock() * 1000000))
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local uuid = template:gsub('[xy]', function(c)
        local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
        return string.format('%x', v)
    end)
    write_file(client_id_file, uuid)
    client_id = uuid
    return client_id
end

local function is_configured()
    return opts.token ~= nil and opts.token ~= ""
end

-- Plex HTTP helpers

-- Synchronous GET (used only for library cache refresh). Returns decoded
-- JSON table, or nil on failure.
local function plex_get_json(path_and_query)
    local url = opts.plex_url .. path_and_query
    local sep = url:find("?") and "&" or "?"
    url = url .. sep .. "X-Plex-Token=" .. opts.token

    local res = utils.subprocess({
        args = { "curl", "-s", "-m", "10", "-H", "Accept: application/json", url },
        cancellable = false,
    })

    if res.status ~= 0 or not res.stdout or res.stdout == "" then
        msg.warn("plex-scrobbler: request failed for " .. path_and_query)
        return nil
    end

    local ok, decoded = pcall(utils.parse_json, res.stdout)
    if not ok or not decoded then
        msg.warn("plex-scrobbler: failed to parse JSON response from Plex")
        return nil
    end
    return decoded
end

-- Fire-and-forget async GET, used for routine timeline (progress/state)
-- updates during playback.
local function plex_get_async(path_and_query)
    local url = opts.plex_url .. path_and_query
    local sep = url:find("?") and "&" or "?"
    url = url .. sep .. "X-Plex-Token=" .. opts.token
        .. "&X-Plex-Client-Identifier=" .. get_client_id()
        .. "&X-Plex-Product=mpv&X-Plex-Device-Name=mpv"

    mp.command_native_async({
        name = "subprocess",
        args = { "curl", "-s", "-m", "5", url },
        capture_stdout = false,
        capture_stderr = false,
    }, function() end)
end

-- Blocking GET, used for the final "stopped" update so mpv can't exit
-- before it's actually sent (async requests can get killed mid-flight
-- when mpv shuts down right after end-file).
local function plex_get_sync(path_and_query)
    local url = opts.plex_url .. path_and_query
    local sep = url:find("?") and "&" or "?"
    url = url .. sep .. "X-Plex-Token=" .. opts.token
        .. "&X-Plex-Client-Identifier=" .. get_client_id()
        .. "&X-Plex-Product=mpv&X-Plex-Device-Name=mpv"

    utils.subprocess({
        args = { "curl", "-s", "-m", "5", url },
        cancellable = false,
    })
end

-- Library cache (path -> ratingKey/duration)

local function load_cache_from_disk()
    local content = read_file(cache_file)
    if not content then return nil end
    local ok, decoded = pcall(utils.parse_json, content)
    if not ok or not decoded then return nil end
    return decoded
end

local function save_cache_to_disk()
    ensure_cache_dir()
    local ok, encoded = pcall(utils.format_json, cache)
    if ok and encoded then
        write_file(cache_file, encoded)
    end
end

-- Query one library section for all movies or all episodes (flattened),
-- collecting file path -> {ratingKey, duration}.
local function collect_section_items(section_key, plex_type, items)
    local data = plex_get_json("/library/sections/" .. section_key .. "/all?type=" .. plex_type)
    if not data or not data.MediaContainer or not data.MediaContainer.Metadata then
        return
    end
    for _, meta in ipairs(data.MediaContainer.Metadata) do
        local rating_key = meta.ratingKey
        local duration = meta.duration
        if meta.Media then
            for _, media in ipairs(meta.Media) do
                if media.Part then
                    for _, part in ipairs(media.Part) do
                        if part.file then
                            items[part.file] = {
                                ratingKey = rating_key,
                                duration = duration,
                            }
                        end
                    end
                end
            end
        end
    end
end

local function refresh_cache()
    msg.info("plex-scrobbler: refreshing library cache from Plex...")
    local data = plex_get_json("/library/sections")
    if not data or not data.MediaContainer or not data.MediaContainer.Directory then
        msg.warn("plex-scrobbler: could not list Plex library sections")
        return false
    end

    local items = {}
    for _, dir in ipairs(data.MediaContainer.Directory) do
        if dir.type == "movie" then
            collect_section_items(dir.key, 1, items)
        elseif dir.type == "show" then
            collect_section_items(dir.key, 4, items) -- type=4 => episodes
        end
    end

    cache = { generated_at = os.time(), items = items }
    save_cache_to_disk()
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    msg.info("plex-scrobbler: cached " .. count .. " items from Plex")
    return true
end

local function get_cache()
    if cache then return cache end
    cache = load_cache_from_disk()
    return cache
end

-- Resolve a local file path to a Plex ratingKey/duration, refreshing the
-- cache if needed. Returns entry table or nil.
local function resolve_path(path)
    local c = get_cache()

    local function lookup(c)
        if not c or not c.items then return nil end
        if c.items[path] then return c.items[path] end
        -- Fallback: suffix match, in case of prefix/mount differences.
        for cached_path, entry in pairs(c.items) do
            if cached_path == path
                or cached_path:sub(-#path) == path
                or path:sub(-#cached_path) == cached_path then
                return entry
            end
        end
        return nil
    end

    local entry = lookup(c)
    if entry then return entry end

    local age = c and (os.time() - (c.generated_at or 0)) or math.huge
    if age > opts.cache_ttl or not c then
        if refresh_cache() then
            entry = lookup(cache)
        end
    end

    return entry
end

-- Scrobbling

local function send_timeline(state, sync)
    if not session.active or not session.ratingKey then return end

    -- "time-pos" can already be unset by the time end-file/shutdown fire,
    -- so fall back to the last known position in that case.
    local time_pos = mp.get_property_number("time-pos")
    local time_ms
    if time_pos then
        time_ms = math.floor(time_pos * 1000)
        session.last_time_ms = time_ms
    elseif session.last_time_ms then
        time_ms = session.last_time_ms
    else
        return
    end
    local duration_ms = session.duration or math.floor((mp.get_property_number("duration") or 0) * 1000)

    -- The "identifier" param is required for Plex to persist the timeline
    -- (viewOffset / watched status / Continue Watching), not just track it
    -- as an ephemeral active session.
    local timeline_query = string.format(
        "/:/timeline?ratingKey=%s&key=/library/metadata/%s&identifier=com.plexapp.plugins.library&state=%s&time=%d&duration=%d",
        session.ratingKey, session.ratingKey, state, time_ms, duration_ms
    )
    if sync then
        plex_get_sync(timeline_query)
    else
        plex_get_async(timeline_query)
    end
end

local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function start_timer()
    stop_timer()
    timer = mp.add_periodic_timer(opts.progress_interval, function()
        if not mp.get_property_bool("pause", false) then
            send_timeline("playing")
        end
    end)
end

-- Fetch the item's current viewOffset (ms) from Plex, or nil if none/unwatched.
local function fetch_view_offset(rating_key)
    local data = plex_get_json("/library/metadata/" .. rating_key)
    if not data or not data.MediaContainer or not data.MediaContainer.Metadata then
        return nil
    end
    local meta = data.MediaContainer.Metadata[1]
    if not meta then return nil end
    return meta.viewOffset
end

local function on_file_loaded()
    session.active = false
    session.ratingKey = nil
    session.duration = nil
    session.last_time_ms = nil

    if not is_configured() then return end

    local path = mp.get_property("path")
    if not path then return end
    if not path:match("^/") then
        local cwd = mp.get_property("working-directory")
        if cwd then path = utils.join_path(cwd, path) end
    end

    local entry = resolve_path(path)
    if not entry then
        msg.info("plex-scrobbler: '" .. path .. "' not found in Plex library, skipping")
        return
    end

    session.active = true
    session.ratingKey = entry.ratingKey
    session.duration = entry.duration
    msg.info("plex-scrobbler: matched Plex item ratingKey=" .. tostring(entry.ratingKey))

    if opts.resume_playback then
        local view_offset = fetch_view_offset(entry.ratingKey)
        if view_offset and view_offset >= (opts.resume_threshold * 1000) then
            local seconds = view_offset / 1000
            mp.commandv("seek", seconds, "absolute")
            msg.info("plex-scrobbler: resuming at " .. seconds .. "s (Plex viewOffset)")
        end
    end

    send_timeline("playing")
    start_timer()
end

local function on_time_pos(_, time_pos)
    if session.active and time_pos then
        session.last_time_ms = math.floor(time_pos * 1000)
    end
end

local function on_pause_change(_, paused)
    if not session.active then return end
    if paused then
        send_timeline("paused")
    else
        send_timeline("playing")
    end
end

local function on_seek()
    if not session.active then return end
    local state = mp.get_property_bool("pause", false) and "paused" or "playing"
    send_timeline(state)
end

local function on_end_file()
    if session.active then
        send_timeline("stopped", true)
    end
    stop_timer()
    session.active = false
    session.ratingKey = nil
    session.duration = nil
end

local function on_shutdown()
    if session.active then
        send_timeline("stopped", true)
    end
end

-- Entry point

if not is_configured() then
    msg.warn("plex-scrobbler: no Plex token configured; see script-opts/plex-scrobbler.conf. Disabling scrobbling.")
else
    mp.register_event("file-loaded", on_file_loaded)
    mp.register_event("end-file", on_end_file)
    mp.register_event("shutdown", on_shutdown)
    mp.observe_property("pause", "bool", on_pause_change)
    mp.observe_property("time-pos", "number", on_time_pos)
    mp.register_event("seek", on_seek)
end
