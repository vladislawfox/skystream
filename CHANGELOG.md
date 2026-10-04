# Changelogs - v2.8.1

### ✨ *New Features & Enhancements*

#### 🧩 Stremio Add-ons & Nuvio (thanks to [Skywave22](https://github.com/Skywave22))
- **Official-style Quick Install and a working Discover tab** – Quick Install lists the two official add-ons (Cinemeta and OpenSubtitles v3). Discover gains search, pull-to-refresh and a retry state, skips broken entries, folds duplicates, and sends add-ons that need configuring to their setup page.
- **Faster link fetching** – Every stream add-on is asked in parallel, each within its own time budget, so one slow or dead add-on no longer holds up the rest, and slow scraping add-ons such as the CNCVerse bridge get long enough to answer.
- **Add-on health badges** – The Manage tab shows whether each installed add-on is working and how fast it answers.
- **Search and provider chips** – Filter the Stremio sources sheet by add-on, provider, quality or label, and search your installed add-ons.
- **Clearer stream rows** – Rows read "Add-on · Provider", with the resolution always shown.
- **Nuvio link fixes** – Embedded stream objects, file names with spaces, `#` or `+`, and scraper ids with special characters no longer break link fetching.

#### 🎬 Player & Playback
- **Smoother seeking** – Quick repeated seeks (arrow keys, D-pad, gamepad shoulder buttons, double-taps) are merged: the first goes at once and the final position follows the moment you stop, instead of a full rebuffer for every press.
- **The seek bar follows your seek at once** – The scrubber and the clock move to where you sent playback straight away, instead of waiting for the stream to get there.
- **Clearer source status** – Sources that are not a video, or that cannot seek, are labelled in the Sources list, and resuming prefers a source that can seek.
- **Half the memory for the network buffer** – libVLC's read-ahead buffer was being allocated twice; the buffer size you choose is now the memory it uses.

#### 💬 Subtitles
- **Subtitle search in the player panel** – Online subtitle search opens as a page inside the player's side panel.
- **Subtitle files drawn by SkyStream** – SRT, WebVTT (including HLS subtitle playlists) and SSA/ASS files are drawn over the video by the app, so Zoom and Stretch no longer push lines off screen, and files that need the source's headers now load.
- **The right file from season packs** – When a provider sends a whole season as one archive, the episode being watched, in the language asked for, is picked instead of the first file in it.
- **Automatic subtitle language** – Auto picks a subtitle in your preferred language from the video's own tracks, however the source names the language.
- **Embedded subtitles with Zoom and Stretch** – Subtitles inside the video stay on screen whichever fit is chosen.

#### 📺 TV & Navigation
- **D-pad text entry** – Text fields no longer steal D-pad directions, so TV keyboards keep all four arrows for picking letters.
- **Back exits from Home** – Back on the home screen now leaves the app instead of doing nothing.
- **Focus rings follow the input** – Focus highlights show when you use a keyboard, remote or gamepad, and stay out of the way on touch.
- **Clear of the bottom bar** – Lists on every screen, settings pages and bookmarks included, scroll clear of the floating bottom navigation.

#### ⚙️ Settings & Extensions
- **Extensions update on launch** – SkyStream plugins, Nuvio scrapers and Stremio add-ons are checked on every launch; followed collections add the repositories they newly list, and what changed is summed up in at most three toasts.
- **TMDB API key check** – A pasted key is cleaned of spaces and invisible characters, pasting TMDB's v4 read token instead of the key is explained, and a network problem is no longer reported as a wrong key.
- **External player** – The chosen default player is honoured end to end, including request headers on Android.

---

### 🐞 *Bug Fixes & System Stability*
- 🛠️ **Fixed: resuming could open to a black screen reading "LIVE"** – Happened when a different source was picked while the resume was still opening.
- 🛠️ **Fixed: some HLS episodes read 27:46:39** – The seek bar, the next-episode card and the end of the episode now use the video's real length.
- 🛠️ **Fixed: "Reconnecting…" after seeking** – A slow refill after a seek is no longer taken for a dead connection, and the recovery step re-issues your seek instead of jumping back to where you were.
- 🛠️ **Fixed: the buffered band on the seek bar** – It no longer vanishes or jumps after a seek, and shows what is really buffered after seeking back.
- 🛠️ **Fixed: Discover stayed empty for hours after a single network error.**
- 🛠️ **Fixed: slow stream add-ons timed out mid-scrape.**


### ⚙️ Improvements
- 🚀 The Riverpod lint rules now run as a reliable CI gate.
- 🚀 Various performance improvements and stability fixes across the app.
