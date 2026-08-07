-- subskip.lua
-- Subtitle-driven temporal truncation script for mpv
-- with added blank (invisible) subtitle track generator
-- 99% vibe-code.

local mp      = require 'mp'
local options = require 'mp.options'
local utils   = require 'mp.utils'
local msg     = require 'mp.msg'

local opts = {
    enabled          = "no",
    buffer           = 0.1,
    keybinding       = ";",
    ffmpeg_path      = "ffmpeg",
    export_video_key = "E",
    export_audio_key = "e",
    crop_srt         = "yes",
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
local keybinding       = opts.keybinding
local export_video_key = opts.export_video_key
local export_audio_key = opts.export_audio_key

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


local function sec_to_time(sec)
    local total_sec = math.floor(sec)
    local h = math.floor(total_sec / 3600)
    local m = math.floor((total_sec % 3600) / 60)
    local s = total_sec % 60
    local ms = math.floor((sec - total_sec) * 1000 + 0.5)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
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
        elseif line:match("^%d+$") and not in_text_block then
            current_index = tonumber(line)
            line = file:read("*l")
        elseif current_index and not in_text_block and line:match(".*%s*-->%s*.*") then
            local start_str, end_str = line:match("(.*)%s*-->%s*(.*)")
            if start_str and end_str then
                start_str = start_str:gsub("%s*-*%s*$", "")
                end_str   = end_str:gsub("^%s+", ""):gsub("%s+$", "")
                
                local function to_seconds(t_str)
                    local h, m, sec, ms = t_str:match("(%d+):(%d+):(%d+),(%d+)")
                    if h and m and sec and ms then
                        return tonumber(h)*3600 + tonumber(m)*60 + tonumber(sec) + tonumber(ms)/1000
                    end
                    return 0
                end
                
                local start_sec = to_seconds(start_str)
                local end_sec = to_seconds(end_str)

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
                    start_sec = start_sec,
                    end_sec   = end_sec,
                    text      = full_text,
                })
                current_index = nil
            else
                line = file:read("*l")
            end
        else
            line = file:read("*l")
        end
    end

    file:close()
    return #subs > 0 and subs or nil
end

local function crop_srt_file(target_srt, segments, offset, output_srt, actual_durs)
    local target_subs = parse_srt_full(target_srt)
    if not target_subs then return end

    local new_subs = {}
    local cumulative_time = 0.0

    for i, seg in ipairs(segments) do
        local seg_start = seg.start
        local seg_end = seg.end_
        local seg_duration = actual_durs[i] or (seg_end - seg_start)

        for _, sub in ipairs(target_subs) do
            local shifted_sub_start = sub.start_sec + offset
            local shifted_sub_end = sub.end_sec + offset

            if not (shifted_sub_end <= seg_start or shifted_sub_start >= seg_end) then
                local clip_start = math.max(shifted_sub_start, seg_start)
                local clip_end = math.min(shifted_sub_end, seg_end)
                if clip_end - clip_start > 0 then
                    local new_start = clip_start - seg_start + cumulative_time
                    local new_end = clip_end - seg_start + cumulative_time
                    table.insert(new_subs, {start = new_start, end_ = new_end, text = sub.text})
                end
            end
        end
        cumulative_time = cumulative_time + seg_duration
    end

    if #new_subs == 0 then return end

    table.sort(new_subs, function(a, b) return a.start < b.start end)

    local f = io.open(output_srt, "w")
    if not f then return end

    for i, sub in ipairs(new_subs) do
        f:write(i .. "\n")
        f:write(sec_to_time(sub.start) .. " --> " .. sec_to_time(sub.end_) .. "\n")
        f:write(sub.text .. "\n\n")
    end
    f:close()
end

-- ────────────────────────────────────────────────────────────────────────────────
-- Export dialogue-only video
-- ────────────────────────────────────────────────────────────────────────────────

local function get_active_srt_path()
    local sid = mp.get_property_number("sid")
    if not sid or sid == 0 then return nil end
    local tracks = mp.get_property_native("track-list") or {}
    for _, t in ipairs(tracks) do
        if t.id == sid and t.type == "sub" then
            if t.external and t["external-filename"] then
                local video_path = mp.get_property("path") or ""
                local video_dir = utils.split_path(video_path)[1] or mp.get_property("working-directory") or "."
                return utils.join_path(video_dir, t["external-filename"])
            end
            break
        end
    end
    return nil
end

local function export_media(mode)
    local sid = mp.get_property_number("sid") or 0
    if sid == 0 then
        mp.osd_message("No subtitle track selected!")
        return
    end

    if #merged == 0 then
        update_merged()
        if #merged == 0 then
            mp.osd_message("No subtitles found for export!")
            return
        end
    end

    local ffmpeg = opts.ffmpeg_path or "ffmpeg"
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = {ffmpeg, "-version"}
    })

    if res.status ~= 0 then
        mp.osd_message("ffmpeg not found! Install it or set ffmpeg_path in subskip.conf", 5)
        return
    end

    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("No video loaded!")
        return
    end

    local dir, filename = utils.split_path(video_path)
    local stem = get_stem(filename)
    if not stem then stem = "output" end
    
    local ext = mode == "audio" and "_dialogue_only.m4a" or "_dialogue_only.mkv"
    local out_path = utils.join_path(dir, stem .. ext)
    local out_srt = utils.join_path(dir, stem .. ext:gsub("%.%w+$", ".srt"))
    
    mp.osd_message(mode == "audio" and "Cropping audio..." or "Cropping video...", 3)
    
    local active_srt_path = nil
    if opts.crop_srt == "yes" then
        active_srt_path = get_active_srt_path()
    end

    local delay = mp.get_property_number("sub-delay") or 0
    local shifted_segments = {}
    for _, iv in ipairs(merged) do
        table.insert(shifted_segments, {
            start = math.max(0, iv.start + delay),
            end_ = math.max(0, iv.end_ + delay)
        })
    end

    local temp_dir = os.tmpname()
    os.remove(temp_dir)
    local success, err = os.execute('mkdir "' .. temp_dir .. '"')
    if not success then
        temp_dir = utils.join_path(dir, ".subskip_tmp")
        os.execute('mkdir "' .. temp_dir .. '"')
    end

    local temp_files = {}
    local actual_durs = {}
    local current_segment = 1

    local function process_next_segment()
        if current_segment > #shifted_segments then
            local list_file = utils.join_path(temp_dir, 'concat_list.txt')
            local f = io.open(list_file, "w")
            for _, tf in ipairs(temp_files) do
                f:write(string.format("file '%s'\n", tf:gsub("'", "'\\''")))
            end
            f:close()

            mp.command_native_async({
                name = "subprocess",
                playback_only = false,
                args = {ffmpeg, "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", "-y", out_path}
            }, function(succ, result, e)
                for _, tf in ipairs(temp_files) do os.remove(tf) end
                os.remove(list_file)
                os.execute('rmdir "' .. temp_dir .. '"')

                if succ and result.status == 0 then
                    mp.osd_message("Export complete: " .. out_path, 5)
                    msg.info("Exported to " .. out_path)
                    
                    if active_srt_path then
                        crop_srt_file(active_srt_path, shifted_segments, delay, out_srt, actual_durs)
                        msg.info("Cropped SRT saved to " .. out_srt)
                    end
                else
                    mp.osd_message("Export failed! Check console for details.", 5)
                    msg.error("ffmpeg export failed.")
                end
            end)
            return
        end

        local iv = shifted_segments[current_segment]
        local dur = iv.end_ - iv.start
        
        if dur <= 0 then
            table.insert(actual_durs, 0)
            current_segment = current_segment + 1
            process_next_segment()
            return
        end

        local temp_file = utils.join_path(temp_dir, string.format("temp_%04d%s", current_segment, mode == "audio" and ".m4a" or ".mp4"))
        table.insert(temp_files, temp_file)
        
        local args = {ffmpeg, "-ss", tostring(iv.start), "-i", video_path, "-t", tostring(dur)}
        if mode == "video" then
            for _, v in ipairs({"-c:v", "libx264", "-preset", "ultrafast", "-crf", "23", "-c:a", "aac"}) do table.insert(args, v) end
        else
            for _, v in ipairs({"-vn", "-c:a", "aac"}) do table.insert(args, v) end
        end
        for _, v in ipairs({"-avoid_negative_ts", "make_zero", "-y", temp_file}) do table.insert(args, v) end

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = args
        }, function(succ, res, e)
            if succ and res.status == 0 then
                local probe_res = mp.command_native({
                    name = "subprocess",
                    capture_stdout = true,
                    args = {"ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", temp_file}
                })
                local actual_dur = dur
                if probe_res.status == 0 and probe_res.stdout then
                    local val = tonumber(probe_res.stdout)
                    if val then actual_dur = val end
                end
                table.insert(actual_durs, actual_dur)
            else
                table.insert(actual_durs, dur)
            end
            current_segment = current_segment + 1
            process_next_segment()
        end)
    end

    process_next_segment()
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
    
    local delay = mp.get_property_number("sub-delay") or 0
    local effective_pos = pos - delay

    local in_interval = false
    for _, iv in ipairs(merged) do
        if effective_pos >= iv.start and effective_pos <= iv.end_ then
            in_interval = true
            break
        end
    end
    if not in_interval then
        local next_start = nil
        for _, iv in ipairs(merged) do
            if iv.start > effective_pos then
                next_start = iv.start
                break
            end
        end
        if next_start then
            mp.set_property_number("time-pos", next_start + delay)
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
mp.add_key_binding(export_video_key, "export_dialogue_video", function() export_media("video") end, {repeatable = false})
mp.add_key_binding(export_audio_key, "export_dialogue_audio", function() export_media("audio") end, {repeatable = false})
