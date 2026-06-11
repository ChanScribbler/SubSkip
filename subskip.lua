-- subskip.lua
-- Subtitle-driven temporal truncation script for mpv
-- with added blank (invisible) subtitle track generator
-- 99% vibe-code.

local mp      = require 'mp'
local options = require 'mp.options'
local utils   = require 'mp.utils'
local msg     = require 'mp.msg'

local opts = {
    enabled    = "no",
    buffer     = 0.1,
    keybinding = ";",
    blank_key  = "B",
}
options.read_options(opts, "subskip")

-- Manual fallback for user's common syntax mistake: subskip/enabled=yes instead of subskip-enabled=yes
if opts.enabled == "no" then
    local all_script_opts = mp.get_property("script-opts") or ""
    if all_script_opts:match("subskip/enabled=yes") then
        opts.enabled = "yes"
        msg.verbose("subskip: Detected legacy script-opts syntax 'subskip/enabled=yes' — enabling as requested")
    end
end

-- using `state' rather than plain `enabled' so that when the CLI uses
-- a script-opt that sets `enabled', it is not permanently fixed to
-- that value. I.e. so you can always still enable/disable subskip.
local state = { enabled = (opts.enabled == "yes") }
local buffer      = tonumber(opts.buffer) or 0.1
local cache       = {}          -- sid → merged intervals
local merged      = {}          -- currently active merged intervals
local keybinding  = opts.keybinding
local blank_key   = opts.blank_key


-- ────────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────────────────────

local function get_stem(filename)
    if not filename then return nil end
    local basename = filename:match("[^/]+$") or filename
    return basename:match("^(.*)%.%a%a%.srt$")
        or basename:match("^(.*)%.srt$")
        or basename:match("^(.*)%..+$")
        or basename
end


-- ────────────────────────────────────────────────────────────────────────────────
-- Subtitle track selection
-- ────────────────────────────────────────────────────────────────────────────────

local function select_best_sub()
    local tracks = mp.get_property_native("track-list") or {}
    local video_stem = get_stem(mp.get_property("filename/no-ext") or "")

    local external_same_stem = {}
    local external_any       = {}
    local embedded_any       = {}

    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.codec:match("subrip") then
            local sub_filename = track["external-filename"]
            local sub_stem     = get_stem(sub_filename)
            local entry = {
                id       = track.id,
                lang     = track.lang or "und",
                stem     = sub_stem,
                filename = sub_filename,
                external = track.external,
            }

            if track.external then
                if sub_stem and video_stem and sub_stem == video_stem then
                    table.insert(external_same_stem, entry)
                else
                    table.insert(external_any, entry)
                end
            else
                table.insert(embedded_any, entry)
            end
        end
    end

    local function sort_prefer_en(a, b)
        if a.lang == "en" and b.lang ~= "en" then return true end
        if b.lang == "en" and a.lang ~= "en" then return false end
        return a.lang < b.lang
    end

    local candidates = external_same_stem
    if #candidates == 0 then candidates = external_any end
    if #candidates == 0 then candidates = embedded_any end

    if #candidates == 0 then
        msg.warn("subskip: No suitable subtitle tracks found")
        return false
    end

    table.sort(candidates, sort_prefer_en)
    local chosen = candidates[1]
    mp.set_property_number("sid", chosen.id)
    msg.verbose(("subskip: Selected sid=%d (lang=%s, external=%s)"):format(
        chosen.id, chosen.lang, tostring(chosen.external)))

    return true
end


-- ────────────────────────────────────────────────────────────────────────────────
-- SRT parsing
-- ────────────────────────────────────────────────────────────────────────────────

local function parse_srt(file_path)
    msg.verbose("subskip: Attempting to parse SRT file: " .. file_path)
    local file = io.open(file_path, "r")
    if not file then
        msg.warn("subskip: Failed to open SRT file: " .. file_path)
        return nil
    end

    local intervals = {}
    local line = file:read("*l")
    while line do
        line = line:gsub("\r", "")
        if line:match("^%d+$") then
            local time_line = file:read("*l")
            if time_line then
                time_line = time_line:gsub("\r", "")
                local start_str, end_str = time_line:match("(.*)%s*-->%s*(.*)")
                if start_str and end_str then
                    start_str = start_str:gsub("%s*-*%s*$", "")
                    end_str   = end_str:gsub("^%s+", ""):gsub("%s+$", "")
                    local function to_seconds(t_str)
                        local h, m, s, ms = t_str:match("(%d+):(%d+):(%d+),(%d+)")
                        if h and m and s and ms then
                            return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) + tonumber(ms)/1000
                        end
                        return nil
                    end
                    local start = to_seconds(start_str)
                    local end_  = to_seconds(end_str)
                    if start and end_ then
                        local text = ""
                        line = file:read("*l")
                        while line and line:match("%S") do
                            text = text .. line .. "\n"
                            line = file:read("*l")
                        end
                        if text:match("%S") then
                            table.insert(intervals, {start = start, end_ = end_})
                        end
                    end
                end
            end
        else
            line = file:read("*l")
        end
    end
    file:close()

    if #intervals == 0 then
        msg.warn("subskip: No valid intervals parsed from " .. file_path)
        return nil
    end

    msg.verbose(("subskip: Parsed %d intervals from %s"):format(#intervals, file_path))
    return intervals
end


local function parse_srt_full(file_path)
    local file = io.open(file_path, "r")
    if not file then return nil end

    local subs = {}
    local line = file:read("*l")
    local current_index = nil
    local in_text_block = false

    while line do
        line = (line or ""):gsub("\r", ""):gsub("\n", "")

        if line == "" then
            in_text_block = false
            line = file:read("*l")
            -- Removed "goto continue" - the loop will naturally iterate
        elseif line:match("^%d+$") and not in_text_block then
            current_index = tonumber(line)
            line = file:read("*l")
            -- Removed "goto continue"
        elseif current_index and not in_text_block and line:match(".*%s*-->%s*.*") then
            local start_str, end_str = line:match("(.*)%s*-->%s*(.*)")
            if start_str and end_str then
                start_str = start_str:gsub("%s*-*%s*$", "")
                end_str   = end_str:gsub("^%s+", ""):gsub("%s+$", "")
                local text_lines = {}
                line = file:read("*l")
                while line do
                    line = (line or ""):gsub("\r", ""):gsub("\n", "")
                    if line == "" or line:match("^%d+$") then
                        in_text_block = false
                        break
                    else
                        if line ~= "" then
                            table.insert(text_lines, line)
                        end
                        in_text_block = true
                        line = file:read("*l")
                    end
                end
                local full_text = table.concat(text_lines, "\n")
                table.insert(subs, {
                    index     = current_index or (#subs + 1),
                    start_str = start_str,
                    end_str   = end_str,
                    text      = full_text,
                })
                current_index = nil
                -- Removed "goto continue"
            else
                line = file:read("*l")
            end
        else
            line = file:read("*l")
        end
        -- Removed ::continue:: label
    end

    file:close()
    return #subs > 0 and subs or nil
end


local function write_blank_srt(subs, dst_path)
    local out = io.open(dst_path, "w")
    if not out then return false end

    local placeholder = "    "  -- four spaces — nonzero length, invisible

    for _, sub in ipairs(subs) do
        out:write(sub.index .. "\n")
        out:write(sub.start_str .. " --> " .. sub.end_str .. "\n")
        out:write(placeholder .. "\n")
        out:write("\n")
    end

    out:close()
    return true
end


-- ────────────────────────────────────────────────────────────────────────────────
-- Generate blank subtitle track
-- ────────────────────────────────────────────────────────────────────────────────

local function generate_blank()
    local sid = mp.get_property_number("sid")
    if not sid or sid == 0 then
        msg.info("subskip: No active subtitle track")
        return
    end

    local tracks = mp.get_property_native("track-list") or {}
    local track = nil
    for _, t in ipairs(tracks) do
        if t.id == sid and t.type == "sub" then
            track = t
            break
        end
    end

    if not track or not track.external or not track["external-filename"] then
        msg.info("subskip: Current subtitle is not an external .srt file")
        return
    end

    local video_path = mp.get_property("path") or ""
    local video_dir  = utils.split_path(video_path)[1] or mp.get_property("working-directory") or "."
    local src_path   = utils.join_path(video_dir, track["external-filename"])

    local subs = parse_srt_full(src_path)
    if not subs then
        msg.warn("subskip: Could not parse source SRT for blanking")
        return
    end

    local dir, basename = utils.split_path(src_path)
    local stem = get_stem(basename)
    local synth_lang = "xx"

    local new_basename = stem .. "." .. synth_lang .. ".srt"
    local dst_path = utils.join_path(dir, new_basename)
    local suffix = 0

    while io.open(dst_path, "r") do
        suffix = suffix + 1
        new_basename = stem .. "." .. synth_lang .. "-" .. suffix .. ".srt"
        dst_path = utils.join_path(dir, new_basename)
    end

    if write_blank_srt(subs, dst_path) then
        mp.commandv("sub-add", dst_path)
        mp.osd_message("Blank subtitle track created:\n" .. new_basename)
        msg.info("subskip: Generated blank track → " .. dst_path)
    else
        msg.warn("subskip: Failed to write blank SRT to " .. dst_path)
    end
end


-- ────────────────────────────────────────────────────────────────────────────────
-- Interval collection & merging
-- ────────────────────────────────────────────────────────────────────────────────

local function collect_intervals_fallback(sid)
    msg.verbose("subskip: Falling back to API collection for sid=" .. sid .. " (no filename)")
    local intervals = {}
    local was_paused = mp.get_property_bool("pause")
    local orig_pos = mp.get_property_number("time-pos") or 0
    local duration = mp.get_property_number("duration") or math.huge
    mp.set_property_bool("pause", true)
    mp.set_property_number("time-pos", 0)
    local seek_attempts = 0
    local max_seek_attempts = 100
    while seek_attempts < max_seek_attempts do
        local s = mp.get_property_number("sub-start")
        if s then break end
        mp.commandv("sub-seek", 1)
        seek_attempts = seek_attempts + 1
        local cur_pos = mp.get_property_number("time-pos") or 0
        if cur_pos >= duration then break end
    end
    if seek_attempts >= max_seek_attempts then
        msg.warn("subskip: Fallback failed to find first subtitle after " .. max_seek_attempts .. " sub-seeks for sid=" .. sid)
    end
    local last_pos = -1
    local iter_count = 0
    local max_iter = 100000
    while iter_count < max_iter do
        iter_count = iter_count + 1
        local cur_pos = mp.get_property_number("time-pos") or 0
        if cur_pos <= last_pos or cur_pos >= duration then break end
        local s = mp.get_property_number("sub-start")
        if not s then break end
        local e = mp.get_property_number("sub-end")
        local t = mp.get_property("sub-text") or ""
        if t:match("%S") then
            table.insert(intervals, {start = s, end_ = e or (s + 999)})
        end
        last_pos = cur_pos
        mp.commandv("sub-seek", 1)
    end
    mp.set_property_number("time-pos", orig_pos)
    mp.set_property_bool("pause", was_paused)
    if #intervals == 0 then
        msg.verbose("subskip: No valid intervals from fallback for sid=" .. sid)
        return nil
    end
    msg.verbose("subskip: Fallback found " .. #intervals .. " intervals for sid=" .. sid ..
                " (First: " .. intervals[1].start .. "s, Last: " .. intervals[#intervals].end_ .. "s)")
    return intervals
end


local function collect_intervals()
    local sid = mp.get_property_number("sid")
    if not sid or sid == 0 then
        msg.verbose("subskip: No active sid for collection")
        return false
    end
    if cache[sid] then
        merged = cache[sid]
        msg.verbose("subskip: Using cached intervals for sid=" .. sid .. " (#merged=" .. #merged .. ")")
        return #merged > 0
    end
    -- Get track details to check for filename
    local tracks = mp.get_property_native("track-list") or {}
    local track = nil
    for _, t in ipairs(tracks) do
        if t.id == sid and t.type == "sub" then
            track = t
            break
        end
    end
    if not track then
        msg.warn("subskip: No track details for sid=" .. sid)
        return false
    end
    local raw_intervals = nil
    if track.external and track["external-filename"] then
        -- Resolve full path: external-filename may be relative to video dir
        local video_path = mp.get_property("path") or ""
        local video_dir = utils.split_path(video_path)[1] or mp.get_property("working-directory") or "."
        local full_path = utils.join_path(video_dir, track["external-filename"])
        raw_intervals = parse_srt(full_path)
    end
    if not raw_intervals then
        -- Fallback for embedded or parse failure
        raw_intervals = collect_intervals_fallback(sid)
    end
    if not raw_intervals or #raw_intervals == 0 then
        cache[sid] = {}
        merged = {}
        return false
    end
    table.sort(raw_intervals, function(a, b) return a.start < b.start end)
    merged = {}
    local curr = {start = math.max(0, raw_intervals[1].start - buffer), end_ = raw_intervals[1].end_ + buffer}
    for i = 2, #raw_intervals do
        local nxt = {start = math.max(0, raw_intervals[i].start - buffer), end_ = raw_intervals[i].end_ + buffer}
        if curr.end_ >= nxt.start then
            curr.end_ = math.max(curr.end_, nxt.end_)
        else
            table.insert(merged, curr)
            curr = nxt
        end
    end
    table.insert(merged, curr)
    cache[sid] = merged
    return true
end


local function update_merged()
    local sid = mp.get_property_number("sid") or 0
    if sid == 0 then
        merged = {}
        return
    end
    if cache[sid] then
        merged = cache[sid]
    else
        collect_intervals() -- Sets merged and caches
    end
end


-- ────────────────────────────────────────────────────────────────────────────────
-- Playback skip logic
-- ────────────────────────────────────────────────────────────────────────────────

local function on_time_pos(_, pos)
    if not state.enabled or not pos or #merged == 0 then return end
    local duration = mp.get_property_number("duration") or 0
    if pos >= duration - 1 then return end
    local in_interval = false
    for _, iv in ipairs(merged) do
        if pos >= iv.start and pos <= iv.end_ then
            in_interval = true
            break
        end
    end
    if not in_interval then
        local next_start = nil
        for _, iv in ipairs(merged) do
            if iv.start > pos then
                next_start = iv.start
                break
            end
        end
        if next_start then
            mp.set_property_number("time-pos", next_start)
        end
    end
end


local function toggle()
    state.enabled = not state.enabled
    if not state.enabled then
        mp.osd_message("Subtitle Skip: OFF")
        return
    end
    update_merged()
    local attempted_select = false
    if #merged == 0 then
        attempted_select = select_best_sub()
        if attempted_select then
            update_merged()
        end
    end
    if #merged == 0 then
        msg.warn("subskip: No subtitles detected after all attempts" ..
                 (attempted_select and " (including track selection)" or ""))
        mp.osd_message("Subtitle Skip: No subtitles detected!")
        state.enabled = false
        return
    end
    mp.osd_message("Subtitle Skip: ON")
end


-- ────────────────────────────────────────────────────────────────────────────────
-- Observers and events
-- ────────────────────────────────────────────────────────────────────────────────

mp.observe_property("time-pos", "native", on_time_pos)
mp.observe_property("sid", "native", function() update_merged() end)
mp.observe_property("track-list", "native", function() cache = {} update_merged() end)
mp.register_event("file-loaded", function() cache = {} update_merged() end)
mp.add_key_binding(keybinding, "toggle_subskip", toggle, {repeatable = false})
mp.add_key_binding(blank_key, "generate_blank_sub", generate_blank, {repeatable = false})
