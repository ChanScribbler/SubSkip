# **SUBSKIP.LUA — README**
*(Designed to be clear for everyone, from complete beginners to experienced developers)*
99% vibe coded

This document is written to be accessible for everyone. If you consider yourself technical, you will find the “Advanced” section useful.

---

## WHAT THIS DOES

Subskip.lua is a small add-on for the mpv video player and many video players built on mpv.
When it is turned on, mpv will only play the parts of a video with subtitles.

---

## WHO IT’S FOR

This was designed with language learning in mind, inspired by [this video](https://www.youtube.com/watch?v=DRXeM07TVww) by Lamont from [Days and Words](https://www.youtube.com/@daysandwords). Go follow his advice if you're learning a language! I guess this tool might have other uses as well but I cant think of any.

---

## WHAT IS MPV?

mpv is a video player.

It plays video files, just like VLC or Windows Media Player.

The difference is that mpv is very customizable, allowing you to write your own code to change how it plays videos. This file is one of those add-ons. You don't need to know how to code in order to use this feature, don't worry.

If mpv (or an mpv-based player) is installed, you can either:

- drag a video onto the mpv icon

- right click a video file and open it with mpv (or your player built on top of mpv)

And then press play and watch

If normal mpv is a bit too minimalist for your taste, there are plenty normal-looking video players out there that use mpv internally. I don't use any of them but my informants claim some of them are quite pleasant to use.

**Recommended options:**
I have not used any of these and know nothing about them. This is purely AI generated advice so tell me if anything here is wrong or if I'm eggregiously leaving out a good option.

**macOS:**

- IINA

A normal Mac video player that uses mpv internally.

**Linux:**

- Celluloid

A simple video player that uses mpv directly.

**Windows:**

- mpv.net

A standard Windows video player built on mpv.

No matter which of these you use, this script is installed in mpv’s normal “scripts” folder because these apps automatically read mpv’s script folder

Once the file is in the correct place and the player is restarted, your video player will know what to do.

---

## EASY SETUP
*Ask an AI like Gemini or GPT for help if you get stuck.*

1. Download the file `subskip.lua`
2. Put it in mpv’s “scripts” folder.

 The folder is probably here: 
 
 - Linux / macOS: `~/.config/mpv/scripts/` which is equivalent to `/Users/YOURUSERNAME/.config/mpv/scripts/`
   - `.config` is a "hidden" file so you may have to type `Cmd+Shift+.` (`⇧⌘.`) in order to see it from within your home folder (`~` or `/Users/YOURUSERNAME`) which you can jump to by typing `⇧⌘H` in the Finder application.
 - Windows: `%APPDATA%\mpv\scripts\`
 
 So the final location should look like:
 
 `~/.config/mpv/scripts/subskip.lua`
 
 or (on windows)
 
 `%APPDATA%\mpv\scripts\subskip.lua`

3. Restart mpv.

That’s it. The script should now be available.

---

## HOW TO USE IT (SIMPLE)

Once the script is loaded, you can:

- Press **;** (semicolon) to toggle skipping ON or OFF.
- Press **E** to export the video using ffmpeg, producing a video containing only the dialogue sections.
- Press **e** to export only the audio using ffmpeg, producing an audio file containing only the dialogue sections.
  - Exporting requires ffmpeg to be installed. If not found, mpv will display an on-screen message to install it or configure `ffmpeg_path` in `subskip.conf`.
  - By default, exporting will also create a cropped subtitle file perfectly synced to the new media.

Now whenever there is no subtitle, mpv will skip forward to the beginning of the next one

An on-screen message should confirm the state (ON or OFF).

---

## ADVANCED

These options are optional. Feel free to ignore this section if you don't know what it's talking about.

### 1. Start with skipping already turned ON

You can launch mpv so that the script begins enabled automatically.

Use this command in your terminal emulator's command-line:

```
mpv --script-opts=subskip-enabled=yes video.mkv
```

Legacy syntax also works:

```
mpv --script-opts=subskip/enabled=yes video.mkv
```

### 2. Configuration options

You can create a settings file if you want to change defaults.
Create this file:

(on mac/linux)

```
~/.config/mpv/script-opts/subskip.conf
```

(on windows)

```
%APPDATA%\mpv\scripts\subskip.conf
```

Options you can set:

```
enabled=no
buffer=0.1
keybinding=;
ffmpeg_path=ffmpeg
export_video_key=E
export_audio_key=e
crop_srt=yes
```

- **enabled** Set to `yes` to start every video with subskip enabled.
- **buffer** Adds extra time before and after each subtitle (in seconds).
Example: `0.1` adds 0.1 seconds.
- **keybinding** Which key toggles the feature on/off.
Default: `;`
- **ffmpeg_path** The path to the ffmpeg executable if it's not in your system PATH.
Default: `ffmpeg`
- **export_video_key** Generates a dialogue-only cut of the video using ffmpeg.
Default: `E`
- **export_audio_key** Generates a dialogue-only cut of the audio using ffmpeg.
Default: `e`
- **crop_srt** Set to `no` to disable generating a cropped SRT file alongside the exported media.
Default: `yes`

---

## TROUBLESHOOTING / FAQ

**Q: “It doesn’t skip anything.”**

**A:**

- Make sure subtitles are turned on and selected.
- If no subtitles are found, the script cannot work.

**Q: “I pressed ; but nothing happened.”**

**A:**

- The script is not loaded or the keybinding was changed.
- Check that the file is in the correct folder.

**Q: “It feels slow with embedded subtitles.”**

**A:**
Embedded subtitles are slower because mpv has to scan them. External `.srt` files work faster.

---

## A FEW TECHNICAL DETAILS

- The script uses the active subtitle track (`sid`) and automatically updates if you switch subtitle tracks.
- External `.srt` files are preferred for accuracy. Embedded subtitles use a slower fallback scan.

---

## LICENSE

MIT License
