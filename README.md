# Spotify Lyrics Menu Bar

A tiny native macOS menu bar app that shows time-synced lyrics for the song currently playing in the Spotify desktop app.

This Swift/AppKit port runs as a normal `.app`, so users do not need Python, pip, or a virtualenv.

Inspired by Nadia Lovely's original Python project: https://github.com/nadialvy/spotify-lyrics-menubar

## Requirements

- macOS
- Spotify desktop app

## Install

1. Download `SpotifyLyricsMenuBar.dmg` from the latest GitHub Release.
2. Open the DMG.
3. Drag `SpotifyLyricsMenuBar.app` to Applications.
4. Launch it from Applications.

On first launch, macOS may ask for Automation permission so the app can read the current Spotify track and playback position.

Note: until release builds are signed and notarized with an Apple Developer ID certificate, macOS may show an "unidentified developer" warning after download.

## Development

Build the app locally:

```bash
make app
```

Run the local build:

```bash
make run
```

Build a local DMG:

```bash
make dmg
```

The GitHub Actions release workflow builds and uploads `SpotifyLyricsMenuBar.dmg` automatically when you push a version tag like `v1.0.0`.

## How It Works

- Reads the current track, artist, and playback position from Spotify via AppleScript.
- Fetches synced lyrics from lrclib.net.
- Falls back to plain lyrics with estimated timing when synced lyrics are unavailable.
- Updates the menu bar title as the song progresses.
