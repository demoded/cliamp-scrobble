local p = plugin.register({
    name = "cliamp-scrobble",
    type = "hook",
    permissions = { "keymap" },
})

local API_URL = "https://ws.audioscrobbler.com/2.0/"
local MIN_DURATION_SECS = 30
local MAX_BATCH_SIZE = 50

local function legacy_config(key)
    local ok, content = pcall(function()
        return cliamp.fs.read("/home/bd/.config/cliamp/config.toml")
    end)
    if not ok or not content then return nil end

    local in_section = false
    for line in string.gmatch(content, "[^\r\n]+") do
        local section = string.match(line, "^%s*%[([^%]]+)%]%s*$")
        if section then
            in_section = section == "plugins.lastfm-scrobbler"
        elseif in_section then
            local found_key, value = string.match(line, "^%s*([%w_%-]+)%s*=%s*(.-)%s*$")
            if found_key == key then
                value = string.gsub(value, '^"(.*)"$', "%1")
                return value
            end
        end
    end

    return nil
end

local function config_value(key)
    local value = p:config(key)
    if value ~= nil then return value end
    return legacy_config(key)
end

local function config_bool(key, default)
    local value = config_value(key)
    if value == nil then return default end
    if value == false or value == "false" or value == "0" then return false end
    return true
end

local CACHE_PATH = config_value("cache_path") or "/home/bd/.config/cliamp/lastfm-scrobbler-cache.json"

local api_key = config_value("api_key")
local api_secret = config_value("api_secret")
local session_key = config_value("session_key")
local threshold = tonumber(config_value("threshold")) or 0.5
local poll_secs = tonumber(config_value("poll_secs")) or 2
local enabled = config_bool("enabled", true)
local now_playing_enabled = config_bool("now_playing", false)

if threshold <= 0 then threshold = 0.5 end
if threshold > 1 then threshold = 1 end
if poll_secs < 1 then poll_secs = 1 end

local session = nil
local timer_id = nil
local lastfm_username = nil

local function color(text, hex)
    local r, g, b = string.match(hex, "^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return tostring(text) end

    return "\27[38;2;"
        .. tostring(tonumber(r, 16)) .. ";"
        .. tostring(tonumber(g, 16)) .. ";"
        .. tostring(tonumber(b, 16)) .. "m"
        .. tostring(text)
        .. "\27[0m"
end

local function lastfm_message(text, hex)
    return color("Last.fm", "#D92323") .. ": " .. color(text, hex)
end

local function message(text)
    if cliamp.message then
        cliamp.message(text, 3)
    end
end

local function log_warn(text)
    if cliamp.log and cliamp.log.warn then
        cliamp.log.warn(text)
    end
end

local function log_info(text)
    if cliamp.log and cliamp.log.info then
        cliamp.log.info(text)
    end
end

local function dump_table(v, depth)
    depth = depth or 0
    if depth > 4 then return "..." end
    if v == nil then return "nil" end
    local t = type(v)
    if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            table.insert(parts, tostring(k) .. "=" .. dump_table(val, depth + 1))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

local function trim(value)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

local function configured()
    return trim(api_key) ~= nil and trim(api_secret) ~= nil and trim(session_key) ~= nil
end

local function now()
    if os and os.time then return os.time() end
    return 0
end

local function lower(value)
    if value == nil then return "" end
    return string.lower(tostring(value))
end

local function sign(params)
    local keys = {}
    for key, _ in pairs(params) do
        if key ~= "format" and key ~= "callback" and key ~= "api_sig" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local payload = ""
    for _, key in ipairs(keys) do
        payload = payload .. key .. tostring(params[key])
    end

    return cliamp.crypto.md5(payload .. api_secret)
end

local function url_encode(value)
    value = tostring(value)
    value = value:gsub("\n", "\r\n")
    value = value:gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
    return value
end

local function form_encode(params)
    local parts = {}
    local keys = {}

    for key, _ in pairs(params) do
        table.insert(keys, key)
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        table.insert(parts, url_encode(key) .. "=" .. url_encode(params[key]))
    end

    return table.concat(parts, "&")
end

local function response_body(response, response2)
    if type(response2) == "string" then return response2 end
    if type(response) == "string" then return response end
    if type(response) ~= "table" then return nil end
    return response.body or response.Body or response.text or response.data or response[1]
end

local function response_status(response, response2)
    if type(response) == "number" then return response end
    if type(response2) == "number" then return response2 end
    if type(response) ~= "table" then return 200 end
    return response.status or response.Status or response.status_code or response.code or 200
end

local function parse_response(response, response2)
    local status = tonumber(response_status(response, response2)) or 200
    local body = response_body(response, response2)
    local decoded = nil

    if type(response) == "table" and (
        response.error
        or response.scrobbles
        or response.track
        or response.user
        or (response.status == "ok" and response.body == nil and response.text == nil and response.data == nil)
    ) then
        decoded = response
    end

    if decoded == nil and body and body ~= "" then
        local decode_ok, value = pcall(function()
            return cliamp.json.decode(body)
        end)
        if decode_ok then decoded = value end
    end

    if type(decoded) == "table" and decoded.error then
        local code = tonumber(decoded.error)
        local retry = code == 11 or code == 16
        return false, {
            retry = retry,
            code = code,
            message = decoded.message or ("Last.fm error " .. tostring(code)),
        }
    end

    if status < 200 or status >= 300 then
        local detail = "HTTP " .. tostring(status)
        if body and body ~= "" then
            detail = detail .. ": " .. string.sub(tostring(body), 1, 200)
        end
        return false, { retry = true, message = detail }
    end

    if decoded == nil then
        local detail = "empty or unparseable Last.fm response"
        if body and body ~= "" then
            detail = detail .. ": " .. string.sub(tostring(body), 1, 200)
        end
        return false, { retry = true, message = detail }
    end

    return true, decoded
end

local function lastfm_post_request(method, params, signed)
    params = params or {}
    params.method = method
    params.api_key = api_key
    params.format = "json"

    if signed then
        if not configured() then
            return false, { retry = false, message = "Last.fm credentials are not configured" }
        end
        params.sk = session_key
        params.api_sig = sign(params)
    elseif trim(api_key) == nil then
        return false, { retry = false, message = "Last.fm API key is not configured" }
    end

    local ok, response, response2 = pcall(function()
        return cliamp.http.post(API_URL, {
            body = form_encode(params),
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
        })
    end)

    if not ok then
        return false, { retry = true, message = tostring(response) }
    end

    return parse_response(response, response2)
end

local function lastfm_post(method, params)
    return lastfm_post_request(method, params, true)
end

local function lastfm_public(method, params)
    if trim(api_key) == nil then
        return false, { retry = false, message = "Last.fm API key is not configured" }
    end

    params = params or {}
    params.method = method
    params.api_key = api_key
    params.format = "json"

    local ok, response, response2 = pcall(function()
        return cliamp.http.get(API_URL .. "?" .. form_encode(params))
    end)

    if not ok then
        return false, { retry = true, message = tostring(response) }
    end

    return parse_response(response, response2)
end

local function username()
    if trim(lastfm_username) then return lastfm_username end

    local ok, result = lastfm_post("user.getInfo", {})
    if ok and type(result.user) == "table" and trim(result.user.name) then
        lastfm_username = trim(result.user.name)
        return lastfm_username
    end

    log_warn("Last.fm username lookup failed: " .. (result and result.message or "unknown error"))
    return nil
end

local function track_info(track)
    local user = username()
    if not user then
        return false, { message = "could not determine Last.fm username" }
    end

    return lastfm_public("track.getInfo", {
        artist = track.artist,
        track = track.title or track.track,
        username = user,
    })
end

local function track_userplaycount(track)
    local ok, result = track_info(track)
    if not ok or type(result.track) ~= "table" then return nil end
    return tonumber(result.track.userplaycount)
end

local function track_userloved(track)
    local ok, result = track_info(track)
    if not ok or type(result.track) ~= "table" then
        return nil, result or { message = "track.getInfo did not return a track object" }
    end

    local loved = result.track.userloved
    return loved == "1" or loved == 1 or loved == true, result
end

local function read_cache()
    if not cliamp.fs.exists(CACHE_PATH) then return {} end

    local ok, content = pcall(function()
        return cliamp.fs.read(CACHE_PATH)
    end)
    if not ok or not content or content == "" then return {} end

    local decode_ok, decoded = pcall(function()
        return cliamp.json.decode(content)
    end)
    if not decode_ok or type(decoded) ~= "table" then return {} end

    return decoded
end

local function write_cache(items)
    local ok, encoded = pcall(function()
        return cliamp.json.encode(items or {})
    end)
    if not ok then return end

    pcall(function()
        cliamp.fs.write(CACHE_PATH, encoded)
    end)
end

local function cache_scrobble(item)
    local items = read_cache()
    table.insert(items, item)
    write_cache(items)
end

local function scrobble_params(item, prefix)
    local params = {}
    local suffix = prefix or ""

    params["artist" .. suffix] = item.artist
    params["track" .. suffix] = item.track
    params["timestamp" .. suffix] = item.timestamp

    if trim(item.album) then
        params["album" .. suffix] = item.album
    end

    if item.duration and tonumber(item.duration) then
        params["duration" .. suffix] = tostring(math.floor(tonumber(item.duration)))
    end

    return params
end

local function now_playing_params(item)
    local params = {
        artist = item.artist,
        track = item.track,
    }

    if trim(item.album) then
        params.album = item.album
    end

    if item.duration and tonumber(item.duration) then
        params.duration = tostring(math.floor(tonumber(item.duration)))
    end

    return params
end

local function send_now_playing(item)
    if not item then return false end

    local ok, err = lastfm_post("track.updateNowPlaying", now_playing_params(item))
    if ok then
        log_info("Last.fm now playing " .. item.artist .. " - " .. item.track)
        return true
    end

    log_warn("Last.fm now playing failed: " .. (err and err.message or "unknown error"))
    return false
end

local function send_scrobble(item)
    local ok, result = lastfm_post("track.scrobble", scrobble_params(item))
    if not ok then return false, result end

    local attrs = result.scrobbles and result.scrobbles["@attr"]
    local accepted = attrs and tonumber(attrs.accepted) or nil
    local ignored = attrs and tonumber(attrs.ignored) or nil

    if accepted and accepted > 0 then
        return true, result
    end

    local ignored_message = nil
    if result.scrobbles and result.scrobbles.scrobble then
        local scrobble = result.scrobbles.scrobble
        if type(scrobble) == "table" and scrobble.ignoredMessage then
            local message_value = scrobble.ignoredMessage
            if type(message_value) == "table" then
                ignored_message = message_value["#text"] or message_value.text
                if message_value.code then
                    ignored_message = "code " .. tostring(message_value.code) .. ": " .. tostring(ignored_message or "")
                end
            else
                ignored_message = tostring(message_value)
            end
        end
    end

    return false, {
        retry = false,
        message = "Last.fm ignored scrobble"
            .. (accepted and (" accepted=" .. tostring(accepted)) or "")
            .. (ignored and (" ignored=" .. tostring(ignored)) or "")
            .. (ignored_message and (" (" .. ignored_message .. ")") or ""),
    }
end

local function retry_cached_scrobbles()
    local cached = read_cache()
    if #cached == 0 then return end

    local remaining = {}
    local params = {}
    local count = 0

    for _, item in ipairs(cached) do
        if count < MAX_BATCH_SIZE then
            local item_params = scrobble_params(item, "[" .. tostring(count) .. "]")
            for key, value in pairs(item_params) do
                params[key] = value
            end
            count = count + 1
        else
            table.insert(remaining, item)
        end
    end

    local ok, err = lastfm_post("track.scrobble", params)
    if ok then
        write_cache(remaining)
        if count > 0 then
            log_info("Last.fm retried " .. tostring(count) .. " cached scrobble(s)")
        end
    elseif err and err.retry then
        write_cache(cached)
    else
        log_warn("Dropping cached Last.fm scrobbles: " .. (err and err.message or "unknown error"))
        write_cache(remaining)
    end
end

local function scrobble_item(item, show_message)
    if not item then return false end

    retry_cached_scrobbles()

    local ok, err = send_scrobble(item)
    if ok then
        local count = track_userplaycount({
            artist = item.artist,
            title = item.track,
        })
        if show_message then
            if count then
                local noun = count == 1 and "scrobble" or "scrobbles"
                message(lastfm_message("scrobbled " .. item.artist .. " - " .. item.track .. " (" .. tostring(count) .. " " .. noun .. ")", "#00FF7F"))
            else
                message(lastfm_message("scrobbled " .. item.artist .. " - " .. item.track, "#00FF7F"))
            end
        end
        log_info("Last.fm scrobbled " .. item.artist .. " - " .. item.track)
        return true
    elseif err and err.retry then
        cache_scrobble(item)
        log_warn("Cached Last.fm scrobble: " .. (err.message or "retryable error"))
    else
        log_warn("Last.fm scrobble failed: " .. (err and err.message or "unknown error"))
    end

    return false
end

local function current_track()
    local track = {
        title = session and session.title or nil,
        artist = session and session.artist or nil,
        album = session and session.album or nil,
        duration = session and session.duration or nil,
    }

    if cliamp.track then
        local ok_title, title = pcall(function() return cliamp.track.title() end)
        local ok_artist, artist = pcall(function() return cliamp.track.artist() end)
        local ok_album, album = pcall(function() return cliamp.track.album() end)
        local ok_duration, duration = pcall(function() return cliamp.track.duration_secs() end)

        if ok_title and trim(title) then track.title = title end
        if ok_artist and trim(artist) then track.artist = artist end
        if ok_album and trim(album) then track.album = album end
        if ok_duration and tonumber(duration) then track.duration = tonumber(duration) end
    end

    track.title = trim(track.title)
    track.artist = trim(track.artist)
    track.album = trim(track.album)

    return track
end

local function dump_live_track()
    if not cliamp.track then return "{}" end
    local data = {}
    local fields = { "title", "artist", "album", "genre", "year", "track_number", "path", "is_stream", "duration_secs" }
    for _, fn_name in ipairs(fields) do
        if type(cliamp.track[fn_name]) == "function" then
            local ok, val = pcall(function() return cliamp.track[fn_name]() end)
            if ok then
                data[fn_name] = val
            else
                data[fn_name] = "<err: " .. tostring(val) .. ">"
            end
        end
    end
    return dump_table(data)
end

local function reset_session()
    if session then
        log_info("Last.fm session reset (was: " .. dump_table(session) .. ")")
    end
    session = nil
end

local valid_for_scrobble

local function session_item()
    if not session then return nil end
    return {
        artist = session.artist,
        track = session.title,
        album = session.album,
        duration = session.duration,
        timestamp = session.started_at,
    }
end

local function clean_track_metadata(artist, title)
    artist = trim(artist)
    title = trim(title)

    if not title then return artist, title end

    -- Check if title is in "Artist - Title" format
    local p_artist, p_title = string.match(title, "^%s*(.-)%s+%-+%s+(.+)%s*$")
    if p_artist and p_title and trim(p_artist) and trim(p_title) then
        p_artist = trim(p_artist)
        p_title = trim(p_title)

        if artist and lower(artist) == lower(p_artist) then
            -- Duplicate artist in title: e.g. artist="Ghostly Kisses", title="Ghostly Kisses - Fade from Me"
            title = p_title
        elseif not artist or artist == "" or artist == "YouTube" or artist == "YouTube Music" then
            artist = p_artist
            title = p_title
        else
            -- If title explicitly defines Artist - Title (e.g. uploader channel "Vinyl Great" vs song "Savage - Radio")
            artist = p_artist
            title = p_title
        end
    elseif artist and title then
        -- Check if title starts with artist name followed by separator like ': ' or ' - '
        local escaped_artist = string.gsub(artist, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        local stripped = string.match(title, "^" .. escaped_artist .. "%s*[:%-–—]%s*(.+)$")
        if stripped and trim(stripped) then
            title = trim(stripped)
        end
    end

    -- Remove common YouTube video suffixes (e.g. "(Lyrics Video)", "(Official Video)", etc.)
    local suffixes = {
        "%s*%(%s*[Ll]yric[s]?%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Ll]yric[s]?%s*[Vv]ideo%s*%]%s*$",
        "%s*%(%s*[Oo]fficial%s*[Mm]usic%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Oo]fficial%s*[Mm]usic%s*[Vv]ideo%s*%]%s*$",
        "%s*%(%s*[Oo]fficial%s*[Ll]yric[s]?%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Oo]fficial%s*[Ll]yric[s]?%s*[Vv]ideo%s*%]%s*$",
        "%s*%(%s*[Oo]fficial%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Oo]fficial%s*[Vv]ideo%s*%]%s*$",
        "%s*%(%s*[Oo]fficial%s*[Aa]udio%s*%)%s*$",
        "%s*%[%s*[Oo]fficial%s*[Aa]udio%s*%]%s*$",
        "%s*%(%s*[Mm]usic%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Mm]usic%s*[Vv]ideo%s*%]%s*$",
        "%s*%(%s*[Vv]ideo%s*[Cc]lip%s*%)%s*$",
        "%s*%[%s*[Vv]ideo%s*[Cc]lip%s*%]%s*$",
        "%s*%(%s*[Cc]lip%s*[Oo]fficiel%s*%)%s*$",
        "%s*%[%s*[Cc]lip%s*[Oo]fficiel%s*%]%s*$",
        "%s*%(%s*[Vv]isualizer%s*%)%s*$",
        "%s*%[%s*[Vv]isualizer%s*%]%s*$",
        "%s*%(%s*[Ll]yrics%s*%)%s*$",
        "%s*%[%s*[Ll]yrics%s*%]%s*$",
        "%s*%(%s*[Aa]udio%s*%)%s*$",
        "%s*%[%s*[Aa]udio%s*%]%s*$",
        "%s*%(%s*[Hh][Dd]%s*%)%s*$",
        "%s*%[%s*[Hh][Dd]%s*%]%s*$",
        "%s*%(%s*4[Kk]%s*%)%s*$",
        "%s*%[%s*4[Kk]%s*%]%s*$",
        "%s*%(%s*[Hh][Qq]%s*%)%s*$",
        "%s*%[%s*[Hh][Qq]%s*%]%s*$",
        "%s*%(%s*[Vv]ideo%s*%)%s*$",
        "%s*%[%s*[Vv]ideo%s*%]%s*$",
    }

    for _, pat in ipairs(suffixes) do
        title = string.gsub(title, pat, "")
    end

    title = trim(title)
    artist = trim(artist)

    return artist, title
end

local function is_current_session_track(track)
    if not session then return false end
    local art = trim(track.artist)
    local tit = trim(track.title or track.track)
    if art == trim(session.artist) and tit == trim(session.title) then
        return true
    end
    if session.raw_artist and session.raw_title and art == trim(session.raw_artist) and tit == trim(session.raw_title) then
        return true
    end
    local c_art, c_tit = clean_track_metadata(art, tit)
    return c_art == trim(session.artist) and c_tit == trim(session.title)
end

local poller_warned_no_session = false
local poller_warned_invalid = false

local function start_session(track)
    poller_warned_no_session = false
    poller_warned_invalid = false
    track = track or {}
    local live = current_track()
    local duration = tonumber(track.duration or track.duration_secs or live.duration or 0) or 0

    local raw_title = trim(track.title) or live.title
    local raw_artist = trim(track.artist) or live.artist
    local album = trim(track.album) or live.album

    local artist, title = clean_track_metadata(raw_artist, raw_title)

    session = {
        raw_title = raw_title,
        raw_artist = raw_artist,
        title = title,
        artist = artist,
        album = album,
        duration = duration,
        listened = 0,
        last_position = nil,
        last_checked = now(),
        started_at = now(),
        scrobbled = false,
        now_playing_sent = false,
    }

    if raw_title ~= title or raw_artist ~= artist then
        log_info("Last.fm cleaned track name: raw='" .. tostring(raw_artist) .. " - " .. tostring(raw_title) .. "' -> cleaned='" .. tostring(session.artist) .. " - " .. tostring(session.title) .. "'")
    end

    log_info("Last.fm track session initialized: track=" .. dump_table(track) .. ", live_track=" .. dump_live_track() .. ", session=" .. dump_table(session))

    if valid_for_scrobble(session) then
        log_info("Last.fm tracking " .. tostring(session.artist) .. " - " .. tostring(session.title) .. " (" .. tostring(math.floor(session.duration)) .. "s)")
    else
        log_warn("Last.fm ignoring track: artist='" .. tostring(session.artist or "") .. "', title='" .. tostring(session.title or "") .. "', duration=" .. tostring(session.duration or 0) .. "s (requires artist, title, duration > 30s)")
    end
end

function valid_for_scrobble(track)
    return trim(track.artist) ~= nil
        and trim(track.title) ~= nil
        and tonumber(track.duration or 0) ~= nil
        and tonumber(track.duration or 0) > MIN_DURATION_SECS
end

local function player_state()
    local ok, state = pcall(function()
        return cliamp.player.state()
    end)
    if not ok then return "" end
    return lower(state)
end

local function player_position()
    local ok, position = pcall(function()
        return cliamp.player.position()
    end)
    if not ok then return nil end
    return tonumber(position)
end

local function maybe_scrobble()
    if not enabled then return end

    local state = player_state()
    local position = player_position()
    local checked_at = now()

    if state ~= "playing" then
        if session then
            session.last_position = position
            session.last_checked = checked_at
            session.now_playing_sent = false
        end
        poller_warned_no_session = false
        return
    end

    if not session then
        if not poller_warned_no_session then
            log_warn("Last.fm poller active (playing) but session is nil (live_track=" .. dump_live_track() .. ")")
            poller_warned_no_session = true
        end
        return
    end

    if not valid_for_scrobble(session) then
        if not poller_warned_invalid then
            log_warn("Last.fm active session invalid for scrobble: session=" .. dump_table(session) .. ", live_track=" .. dump_live_track())
            poller_warned_invalid = true
        end
        return
    end

    if now_playing_enabled and not session.now_playing_sent then
        send_now_playing(session_item())
        session.now_playing_sent = true
    end

    if not position then
        session.last_position = position
        session.last_checked = checked_at
        return
    end

    if session.last_position then
        local delta = position - session.last_position
        if delta > 0 then
            local max_delta = poll_secs + 1
            if delta > max_delta then delta = max_delta end
            session.listened = session.listened + delta
        end
    end

    session.last_position = position
    session.last_checked = checked_at

    if session.scrobbled then return end

    if session.listened < (session.duration * threshold) then return end

    log_info("Last.fm scrobble threshold reached. Dumping session=" .. dump_table(session) .. ", session_item=" .. dump_table(session_item()))

    if scrobble_item(session_item(), true) then
        session.scrobbled = true
    else
        session.scrobbled = true
    end
end

local function love_current_track()
    local raw_track = current_track()
    local artist, title = clean_track_metadata(raw_track.artist, raw_track.title)
    if not artist or not title then
        message(lastfm_message("missing artist/title", "#FF991C"))
        return
    end

    local track = {
        artist = artist,
        title = title,
    }

    local loved, info_err = track_userloved(track)
    if loved == nil then
        local reason = info_err and info_err.message or "unknown error"
        message(lastfm_message("love toggle failed", "#FF991C"))
        log_warn("Last.fm love state lookup failed: " .. reason)
        return
    end

    local method = loved and "track.unlove" or "track.love"
    local ok, err = lastfm_post(method, {
        artist = track.artist,
        track = track.title,
    })

    if ok then
        if loved then
            message(lastfm_message("unloved " .. track.artist .. " - " .. track.title, "#FC8EAC"))
            log_info("Last.fm unloved " .. track.artist .. " - " .. track.title)
        else
            local forced_scrobble = false
            if is_current_session_track(track) and not session.scrobbled and valid_for_scrobble(session) then
                forced_scrobble = scrobble_item(session_item(), false)
                session.scrobbled = true
            end

            if forced_scrobble then
                local count = track_userplaycount(track)
                if count then
                    local noun = count == 1 and "scrobble" or "scrobbles"
                    message(lastfm_message("loved and scrobbled " .. track.artist .. " - " .. track.title .. " (" .. tostring(count) .. " " .. noun .. ")", "#00FF7F"))
                else
                    message(lastfm_message("loved and scrobbled " .. track.artist .. " - " .. track.title, "#00FF7F"))
                end
            else
                message(lastfm_message("loved " .. track.artist .. " - " .. track.title, "#00FF7F"))
            end
            log_info("Last.fm loved " .. track.artist .. " - " .. track.title)
        end
    else
        local reason = err and err.message or "unknown error"
        message(lastfm_message("love toggle failed", "#FF991C"))
        log_warn("Last.fm love toggle failed: " .. reason)
    end
end

local function toggle_scrobbling()
    enabled = not enabled
    if enabled then
        message(lastfm_message("scrobbling enabled", "#00FF7F"))
        log_info("Last.fm scrobbling enabled")
    else
        message(lastfm_message("scrobbling disabled", "#FC8EAC"))
        log_info("Last.fm scrobbling disabled")
    end
end

p:bind("*", "Love/unlove current track on Last.fm", love_current_track)
p:bind("&", "Toggle Last.fm scrobbling", toggle_scrobbling)

p:on("track.change", function(track)
    log_info("Last.fm track.change event fired: track=" .. dump_table(track) .. ", live_track=" .. dump_live_track())
    start_session(track or {})
end)

local last_logged_playback_state = nil

p:on("playback.state", function()
    local state = player_state()
    if state ~= last_logged_playback_state then
        log_info("Last.fm playback.state: " .. tostring(last_logged_playback_state or "nil") .. " -> " .. tostring(state) .. ", session=" .. dump_table(session))
        last_logged_playback_state = state
    end
    if state == "stopped" or state == "stop" then
        reset_session()
    end
end)

p:on("app.start", function()
    if configured() then
        log_info("Last.fm scrobbler loaded; threshold=" .. tostring(threshold) .. ", poll_secs=" .. tostring(poll_secs) .. ", now_playing=" .. tostring(now_playing_enabled))
    else
        log_warn("Last.fm scrobbler loaded without complete credentials")
    end

    retry_cached_scrobbles()
    if timer_id == nil then
        timer_id = cliamp.timer.every(poll_secs, maybe_scrobble)
    end
end)

p:on("app.quit", function()
    if timer_id ~= nil then
        cliamp.timer.cancel(timer_id)
        timer_id = nil
    end
end)
