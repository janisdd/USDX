Added a Lua playlist module that exposes the playlist manager to scripts. It returns playlist data as Lua tables (including items and metadata), supports getting/setting the current playlist, and provides functions to add/delete playlists, add/delete items, reload, and save. The new module is registered during Lua initialization so it can be required and used via the Usdx namespace.
Added a `CompanionPlaylistName` string setting read/written from `config.ini` under the `Companion` section (no UI exposure).
Added a `CompanionCommPort` integer setting read/written from `config.ini` under the `Companion` section (no UI exposure).
The main program entry point is located in `src/ultrastardx.dpr`.
In `src/base/UCompanionServer.pas`, added a function to find a playlist index by name, a function to ensure a playlist exists, and a function to try parsing a song request.
Added a `CompanionEnabled` integer setting read/written from `config.ini` under the `Companion` section (no UI exposure), defaulting to 0 (disabled).

example config.ini:
```
[Companion]
CompanionEnabled = 1
CompanionCommPort = 3001
CompanionPlaylistName = CompanionPlaylist
```