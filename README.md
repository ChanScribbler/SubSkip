# **SUBSKIP.LUA — README**  
*(Designed to be clear for everyone, from complete beginners to experienced developers)*

This document is written so anyone can understand it, no matter their background. It includes simple, step-by-step setup instructions for beginners, and it also contains advanced options for power users. If you consider yourself technical, you will find the “Advanced” section useful. If you're not technical (and maybe already nervous), it is not important!

---

## WHAT THIS DOES

Subskip.lua is a small add-on for the mpv video player, and most video players that are built on mpv.  
When it is turned on, mpv will only play the parts of a video where subtitles are visible.  
Whenever there is a gap with no subtitles, the video automatically jumps forward to the next subtitle.

---

## WHO IT’S FOR

This script is for people who want:  
- Faster watching with no silent gaps  
- A study tool for subtitles and dialogue  
- A way to skip to spoken parts automatically  
- A more efficient way to review content  

It was designed with language learning in mind, inspired by Lamont from [Days and Words](https://www.youtube.com/@daysandwords) (specifically [this video](https://www.youtube.com/watch?v=DRXeM07TVww)). Go follow his advice if you're learning a language!

---

## WHAT IS MPV?

mpv is a video player.  
It plays video files, just like VLC or Windows Media Player.  
The difference is that mpv is very good at playing video, and it allows small add-ons (called “scripts”) to change how playback works. This file is one of those add-ons.

You do NOT need to:  
- use a command line  
- type commands  
- understand how mpv works internally  

If mpv (or an mpv-based player) is installed, you can just:  
- double-click a video file  
- drag a video onto the player  
- press play and watch  

This script does not replace your video player. It only adds an optional behavior to it.

If mpv is a bit too minimalist for your taste, there's good news: You do not have to use mpv directly.  
There are normal-looking video players that use mpv internally. They behave like regular apps, with menus and settings, but still support mpv scripts like this one.

**Recommended options:**

**macOS:**  
- IINA  
  A normal Mac video player that uses mpv internally.

**Linux:**  
- Celluloid  
  A simple video player that uses mpv directly.

**Windows:**  
- mpv.net  
  A standard Windows video player built on mpv.

No matter which of these you use:  
- This script is installed in mpv’s normal “scripts” folder  
- You do not install it inside IINA, Celluloid, or mpv.net  
- Those apps automatically read mpv’s script folder  

Once the file is in the correct place and the player is restarted, your video player will know what to do.  
You do not need to understand anything beyond that.

---

## EASY SETUP (FOR BEGINNERS)
Ask an AI bot like Gemini for help if you're not sure how to do this.

1. Download the file `subskip.lua`  
2. Put it in mpv’s “scripts” folder.  

   If you are on a typical system, the folder is here:  
   - Linux / macOS: `~/.config/mpv/scripts/`  
   - Windows: `%APPDATA%\mpv\scripts\`

   So the final location should look like:  
   `~/.config/mpv/scripts/subskip.lua`

3. Restart mpv.  

That’s it. The script is now available.

---

## HOW TO USE IT (SIMPLE)

Once the script is loaded, you turn it on and off using a key:  

- Press **;** (semicolon)  
  This toggles subtitle skipping ON or OFF.
- Press **B** to create and "invisible" subtitle track (e.g. no subtitles) but still allows skipping (since this program needs subtitles in order to know when to skip!)
  - This *might* require you to restart mpv in order to access it!

When skipping is enabled:  
- mpv will only play during subtitle intervals.  
- Whenever subtitles disappear, mpv jumps forward to the next subtitle.  
- An on-screen message confirms the state (ON or OFF).

---

## ADVANCED

These options are optional. Beginners can ignore this section.

### 1. Start with skipping already turned ON

You can launch mpv so that the script begins enabled automatically.  
Use this command:

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

```
~/.config/mpv/script-opts/subskip.conf
```

Options you can set:

```
enabled=no
buffer=0.1
keybinding=;
blank_key=B
```

- **enabled**  
  Set to `yes` to start already enabled.  
- **buffer**  
  Adds extra time before and after each subtitle (in seconds).  
  Example: `0.1` adds 0.1 seconds.  
- **keybinding**  
  Which key toggles skipping.  
  Default: `;`  
- **blank_key**  
  Generates a blank subtitle track (explained below).  
  Default: `B`

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