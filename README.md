# 🎵 Bitsongs

A fully functional iOS music player that streams real music from the internet.

> SwiftUI frontend + Python Flask backend — search any song, stream it, control from lock screen.

## 📁 Project Structure

```
Bitsongs/
├── Bitsongs/                    # iOS App (SwiftUI)
│   ├── BitsongApp.swift         # App entry point
│   ├── Info.plist               # App configuration
│   ├── Models/
│   │   └── Song.swift           # Song data model
│   ├── ViewModels/
│   │   └── MusicPlayerViewModel.swift  # Player logic & state
│   ├── Views/
│   │   ├── MusicPlayerView.swift       # Main player screen
│   │   └── Components/
│   │       ├── AlbumArtView.swift      # Album artwork (remote)
│   │       ├── PlaybackControlsView.swift  # Play/pause/seek
│   │       ├── SearchBarView.swift     # Search + results list
│   │       ├── UpNextView.swift        # Queue (collapsible)
│   │       └── DynamicBackgroundView.swift  # Animated gradient BG
│   ├── Services/
│   │   └── NetworkService.swift        # API client for server
│   ├── Utilities/
│   │   ├── ColorExtractor.swift        # Extract colors from artwork
│   │   ├── HapticManager.swift         # Haptic feedback
│   │   └── ToneGenerator.swift         # (legacy) Demo tones
│   ├── Assets.xcassets/
│   └── Preview Content/
│
├── Bitsongs.xcodeproj/          # Xcode project
│
├── Server/                      # Backend (Python Flask)
│   ├── app.py                   # Main server (API + streaming)
│   ├── requirements.txt         # Python dependencies
│   ├── Dockerfile               # Docker support
│   └── docker-compose.yml       # Docker Compose config
│
├── .gitignore
└── README.md
```

## ⚡ Features

- 🔍 **Search** any song or artist (iTunes API)
- 📈 **Trending** charts on launch
- 🎧 **Real audio streaming** via YouTube
- ▶️ **Full controls** — play, pause, next, previous, seek
- 🖼️ **Album artwork** with dynamic color theming
- 🔒 **Background playback** — works with screen off
- 📱 **Lock screen controls** — play/pause/skip from lock screen
- 📋 **Queue** — see all upcoming songs
- 📝 **Lyrics** support (via LRCLIB)
- 🫨 **Haptic feedback** on controls

## 🚀 Setup

### Prerequisites

- **Xcode 15+** (macOS)
- **Python 3.9+**
- **yt-dlp** — `pip install yt-dlp`
- **ffmpeg** — `brew install ffmpeg`

### 1. Setup Server

```bash
cd Server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python app.py
```

Server starts on `http://0.0.0.0:499`

### 2. Configure iOS App

Edit `Bitsongs/Services/NetworkService.swift`:

```swift
// For Simulator:
@Published var baseURL: String = "http://127.0.0.1:499"

// For physical iPhone (use your Mac's IP):
@Published var baseURL: String = "http://192.168.x.x:499"
```

Find your Mac's IP: `ifconfig | grep "inet " | grep -v 127.0.0.1`

### 3. Build & Run

1. Open `Bitsongs.xcodeproj` in Xcode
2. Select target device (simulator or iPhone via USB)
3. **⌘R** to build and run
4. First time on iPhone: **Settings → General → VPN & Device Management → Trust**

## 🏗️ Architecture

```
iPhone App ──HTTP──▶ Flask Server ──▶ iTunes API (search/metadata)
    │                    │
    │                    └──▶ yt-dlp (audio stream from YouTube)
    │                    │
    │                    └──▶ LRCLIB (lyrics)
    │
    └── AVPlayer (streams audio)
    └── MPNowPlayingInfoCenter (lock screen)
    └── MPRemoteCommandCenter (lock screen controls)
```

## 📄 API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/mobile/health` | GET | Server health check |
| `/api/mobile/search?q=` | GET | Search songs |
| `/api/mobile/chart` | GET | Trending songs |
| `/api/mobile/play?id=&artist=&title=` | GET | Get stream URL |
| `/api/mobile/stream_proxy?url=` | GET | Proxy audio stream |
| `/api/mobile/lyrics?artist=&title=` | GET | Get lyrics |
| `/api/mobile/recommend?artist_id=` | GET | Recommendations |

## 📝 License

Personal project — for personal use only.
