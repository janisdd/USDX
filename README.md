# UltraStar Deluxe Fork

This is a fork of the original UltraStar Deluxe project.

It adds a (http) companion server to the game to communicate with a companion website.

The main changes were made in the `src/base/UCompanionServer.pas` file.

The companion server is a lightweight HTTP server that can receive JSON requests.
The server runs asynchronously and must not block the main thread.

Example config.ini (with default values):

```ini
[Companion]
CompanionEnabled = 1
CompanionCommPort = 3001
CompanionPlaylistName = CompanionPlaylist
```

- `CompanionEnabled` (integer) - 0 = disabled, 1 = enabled
- `CompanionCommPort` (integer) - the port the server will listen on
- `CompanionPlaylistName` (string) - the name of the playlist to use

The companion server can be used to add songs to the playlist and to select a song.

The server supports the following endpoints:
- `/setCompanionPlaylist` - set the companion playlist to the given songs
- `/addToCompanionPlaylist` - add the given songs to the companion playlist
- `/selectSong` - select the given song in the game (only in song select screen and when the song is in the current collection [when filtered or in playlist])


`setCompanionPlaylist` and `addToCompanionPlaylist` try to find the songs and only add them if they are found, not found songs are skipped.

The server returns a JSON response with the following format:
```json
{
  "ok": true|false,
  "error": "error message"
}
```

Example requests:

- `/setCompanionPlaylist`

```json
{
  "songs": [
    {
      "title": "Song Title",
      "artist": "Song Artist"
    }
  ]
}
```

- `/addToCompanionPlaylist`
```json
{
  "songs": [
    {
      "title": "Song Title",
      "artist": "Song Artist"
    }
  ]
}
```

- `/selectSong`
```json
{
  "title": "Song Title",
  "artist": "Song Artist"
}
```

The logLevel is now also exposed via the `config.ini` file.

```ini
[Log]
LogLevel = 20
```

- `LogLevel` (integer)
  - 50 = debug
  - 40 = info
  - 30 = status
  - 20 = warn (default)
  - 10 = error
  - 0 = critical
  - -1 = none

---

# UltraStar Deluxe

[![Build Status](https://github.com/UltraStar-Deluxe/USDX/actions/workflows/main.yml/badge.svg)](https://github.com/UltraStar-Deluxe/USDX/actions/workflows/main.yml)
[![License](https://img.shields.io/badge/license-GPLv2-blue.svg)](LICENSE)

Official Project Website: https://usdx.eu/

![UltraStar Deluxe Logo](https://github.com/UltraStar-Deluxe/USDX/blob/master/icons/ultrastardx-icon_256.png)


### 1. About
UltraStar Deluxe (USDX) is a free and open source karaoke game. It allows up to six players to sing along with music using microphones in order to score points, depending on the pitch of the voice and the rhythm of singing.
UltraStar Deluxe is a fork of the original UltraStar (developed by corvus5).
Many features have been added like party mode, theme support and support for more audio and video formats.
The improved stability and code quality of USDX enabled ports to Linux and Mac OS X.

### 2. Installation
Currently, the following installation channels are offered:
- installer (or portable version) for [the latest release](https://github.com/UltraStar-Deluxe/USDX/releases/latest)
- flatpak from [flathub](https://flathub.org/apps/eu.usdx.UltraStarDeluxe)
- Arch Linux [AUR](https://aur.archlinux.org/packages/ultrastardx-git)

### 3. Configuration
- To set additional song directories change your config.ini like this:
```ini
  [Directories]
  SongDir1=C:\Users\My\Music\MyUSDXSongs
  SongDir2=F:\EvenMoreUSDXSongs
  SongDir...=... (some more directories)
```
- To enable joypad support change config.ini `Joypad=Off` to `Joypad=On`
- To enable 2 or 3 player each on 2 screens, disable the full screen mode, extend your desktop horizontally and set the resolution to fill one screen. Then, in the config.ini set `Screens=2` and restart the game.
- The primary folder for songs on OS X is `$HOME/Music/UltraStar Deluxe`, which is created when UltraStar Deluxe is run for the first time.
- On OS X, by default the `config.ini` file is created in `$HOME/Library/Application Support/UltraStarDeluxe` when UltraStar Deluxe is run for the first time.
- When running in borderless fullscreen mode, the monitor it runs on can be configured by setting `Graphics.PositionX/Y` to an offset in pixels.
- If installed via the flatpak package, the primary song folder is `~/.var/app/eu.usdx.UltraStarDeluxe/.ultrastardx/songs/` and the config.ini is located in `~/.var/app/eu.usdx.UltraStarDeluxe/.ultrastardx/` by default. To configure additional song directories, they first need to be made accessible to the flatpak app using the command: `flatpak override eu.usdx.UltraStarDeluxe --filesystem=/your/new/songfolder` - Afterwards, the directory can be added to the config.ini file as usual.

### 4. Further documentation
The [wiki](https://github.com/UltraStar-Deluxe/USDX/wiki) contains more information on:
* [Command-line parameters](https://github.com/UltraStar-Deluxe/USDX/wiki/Command-Line-Parameters)
* [Controls](https://github.com/UltraStar-Deluxe/USDX/wiki/Controls)
* [Customization](https://github.com/UltraStar-Deluxe/USDX/wiki/Customization)

### 5. Compiling
There are two main ways to compile the game:

1. Lazarus IDE
2. `./autogen.sh && ./configure [--enable-debug] && make`

The executable will be `game/ultrastardx[.exe]`.

For extended information, dependencies, OS-specific notes and configure flags, see [COMPILING.md](COMPILING.md).

### 6. Making a release
See [RELEASING.md](RELEASING.md)

Other useful documents for maintainers: [pipeline info](PIPELINE.md).
