# PAYDAY 2 Music Importer

PAYDAY 2 Music Importer 1.0 is a free, open-source Windows mod. Its release version stays at 1.0 until 2.0 release. It adds an in-game menu for importing YouTube videos as PAYDAY 2 menu music. A PowerShell helper downloads and converts the audio, then creates a BeardLib music mod in `PAYDAY 2\assets\mod_overrides`.

## Requirements

- PAYDAY 2 for Windows 10 or later
- Steam, required for the restart button
- SuperBLT
- BeardLib, so PAYDAY 2 can load the generated `MenuMusic` module
- Internet access to download the standalone Chromium browser the first time you open the YouTube picker
- Internet access for YouTube and first-run tool setup

The helper uses yt-dlp, Deno, and FFmpeg. It installs them under `%LOCALAPPDATA%\PD2MusicImporter\tools` and does not change the system `PATH`. yt-dlp is downloaded from its GitHub release with its published SHA-256 checksum checked. Deno is downloaded from its upstream GitHub release. FFmpeg is downloaded from the Windows build provider linked by the FFmpeg project, with the published SHA-256 checksum checked.

## Install

1. Install and launch PAYDAY 2 with SuperBLT and BeardLib at least once.
2. Copy the `PaydayMusicImporter` folder into `PAYDAY 2\mods\`, so `mod.txt` is at `PAYDAY 2\mods\PaydayMusicImporter\mod.txt`.
3. Run `Start-Helper.cmd` from that folder. Keep its console window open while using the importer. The first run downloads the helper tools and may take a few minutes.
4. Start PAYDAY 2 and open **Options → PAYDAY 2 Music Importer**.
5. Choose **Open YouTube picker** to open standalone Chromium on YouTube with the bundled picker extension already loaded. No manual extension installation is needed. Selecting a video page automatically queues its audio, uses the YouTube video title as the track name, and returns Chromium to YouTube home so you can choose another video. The helper installs queued videos one at a time.
6. Or click the URL field and press **Ctrl+V**, enter a track name, then choose **Queue download** for a manual import.
7. Choose **Importer status** in game or watch the helper window. The **Restart PAYDAY 2** button closes the game, waits 5 seconds, then relaunches it through Steam. Save any active progress first.
8. Select the new menu music in the game's music selection menu.

The helper downloads an unbranded Chromium build from the [official Chromium snapshot storage](https://www.chromium.org/getting-involved/download-chromium/) the first time you open the picker. The browser files and separate YouTube profile are stored under `%LOCALAPPDATA%\PD2MusicImporter`; your installed Chrome profile is not changed. The bundled extension is passed to Chromium on every picker launch, so it is automatically loaded for the importer. A loopback-only helper bridge receives video selections, with a DevTools watcher as a fallback. The downloaded Chromium snapshot does not update itself; the mod does not bundle Chromium binaries.

The helper does not require administrator privileges. If it cannot find the game, it opens a folder picker; select the PAYDAY 2 install folder that contains `assets`.

## Supported links and behavior

- Standard YouTube video links from `youtube.com`, `music.youtube.com`, or `youtu.be` are accepted. Playlist links are limited to the linked video.
- Each request creates a separate folder and a unique music ID. Existing mods are not overwritten.
- Picker imports use yt-dlp's video title metadata for the generated folder and in-game track name, even if the browser only supplied a generic YouTube video ID. Manual imports keep the name entered in the menu.
- The restart button asks the helper to close `PAYDAY2.exe`, waits up to 20 seconds for it to exit (then force closes it if needed), waits 5 seconds, and starts Steam's PAYDAY 2 RunGame link (App ID `218620`). It will not launch another copy if the game cannot be closed.
- The bundled Chromium extension watches YouTube video page selections, reads the page title, sends the page URL and title to the local helper, and returns the tab to `youtube.com`. The DevTools watcher is a fallback for full-page navigations.
- The importer does not handle private, deleted, members-only, or otherwise inaccessible videos, and does not supply account cookies.
- New override music is loaded when PAYDAY 2 starts, so restart after each completed import or use the in-game restart button.

## Troubleshooting

- **Helper not detected:** run `Start-Helper.cmd` and leave its window open.
- **Invalid game folder:** select the PAYDAY 2 folder itself, not its `assets` or `mod_overrides` subfolder.
- **A video fails:** confirm it is playable without account access, then check the PowerShell window for yt-dlp's error.
- **Track does not appear:** confirm BeardLib is installed and enabled, verify the folder exists under `assets\mod_overrides`, then restart the game.
- **Windows blocks script startup:** use `Start-Helper.cmd`; it starts the bundled script with a process-scoped execution policy and does not change the machine policy.

## Queue interface

The game mod writes one JSON request file per track to `PaydayMusicImporter\ipc\requests\<id>.json` with `id`, `url`, `name`, and `createdEpoch` fields. The bundled extension posts to a loopback-only bridge in `PickerBridge.ps1`, which adds selections to the same request queue. The helper also watches Chromium DevTools targets as a fallback. It claims requests by moving them into `ipc\processing`, then writes status JSON to `ipc\status\<id>.json` and `ipc\status\latest.json`. Status contains `id`, `name`, `state`, `percent`, `message`, and `updatedEpoch`. `ipc\status\helper.json` is a heartbeat used by the in-game status page.

## Third-party input helper

The bundled `lib\InlineInput` source comes from [perry519/InlineInput](https://github.com/perry519/InlineInput) and is distributed under its included MIT license. It provides the in-game text fields and clipboard paste support.

## License

PAYDAY 2 Music Importer source is released under the MIT License in `LICENSE`. The bundled InlineInput library keeps its own included MIT copyright and license notice. Chromium and the audio download/conversion tools are fetched from their upstream sources and are not included in this mod package.
