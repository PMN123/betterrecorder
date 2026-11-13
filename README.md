# BetterRecorder

A native Mac app that records a screen or window together with system audio and an optional microphone. No audio driver, account, or network service is needed. Requires macOS 15 or later.

Built with SwiftUI and Apple's [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), using the native screen-sharing picker and a synchronized H.264/AAC MP4 writer.

## Open and record

Open `~/Applications/BetterRecorder.app` from Finder or Spotlight.

1. Click **Choose screen or window** and select your source in the Mac sharing picker. Choose a full screen to capture audio across apps.
2. Leave **System audio** enabled. Optionally enable **Microphone** and choose the built-in mic, a connected headset/USB input, or the system default. Choose 30 or 60 fps, cursor visibility, and whether to use the three-second countdown.
3. Click **Start recording**.
4. While recording, click the small **Mute / Unmute** microphone button whenever you want. The screen and system audio continue recording. The same controls are available in the menu-bar menu.
5. Click **Stop & save recording** in the app or its menu-bar menu. Wait for **Recording saved**, then use the play or folder button.

Recordings are H.264 MP4 files saved under `~/Movies/BetterRecorder` by default. **Change…** selects a different folder, remembered between launches. Video keeps its source proportions, up to a 3840-pixel long edge. The microphone is off until enabled. When both sound sources are enabled, they are mixed into one audio track.

The app keeps running in the menu bar after its window closes. Quitting during a recording finishes saving before exiting. Command-Shift-R starts or stops while BetterRecorder is the active app; it is not a global shortcut.

Command-Shift-M mutes or unmutes the microphone while BetterRecorder is the active app. Choose input devices before starting; switching devices requires a new recording.

## macOS permissions

Use the system picker to choose what BetterRecorder may capture. If macOS asks, allow screen and system-audio recording. If capture is blocked, check **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen the app if macOS requests it.

Microphone access is requested only when you start with **Microphone** enabled. If access was denied, enable BetterRecorder under **System Settings → Privacy & Security → Microphone**.

Protected streaming video and some apps may block capture or produce silent/black sections. Selecting a window can limit captured audio to its application; select a screen for general Mac output. Playback volume and the source app’s mute controls affect what is available to record.

## Build locally

This folder is the complete source. It has no external package dependencies.

Clone the repository, then build with Xcode 16.2 or later and Swift 6 installed:

```sh
git clone https://github.com/PMN123/betterrecorder.git
cd betterrecorder
./build-app.sh --install
open "$HOME/Applications/BetterRecorder.app"
```

The build script creates `dist/BetterRecorder.app`, signs it locally, and installs it into your user Applications folder when passed `--install`. Quit the installed app before rebuilding it. This local signature is for this Mac; the app has not been notarized for distribution.

Regenerate its icon if needed:

```sh
swift Support/make-icon.swift /tmp/BetterRecorder.iconset
iconutil -c icns /tmp/BetterRecorder.iconset -o Support/AppIcon.icns
```

## Verification

Tested locally on macOS 26.6.2 with a real display capture: a saved 3840 × 2160 H.264 video contained 48 kHz stereo AAC system audio, including a generated 440 Hz test tone. A second recording with system audio disabled contained only video. Countdown cancellation produced no recording, and quitting during capture finalized a playable MP4. Test recordings are not included in this repository.

Permission-dependent screen, system audio, and microphone capture require a real interactive Mac session.

Run the media regression checks without screen or microphone access:

```sh
./Support/tests/run.sh
```

These encode and decode generated audio/video to verify mixed 44.1/48 kHz inputs, live microphone mute and resume, uninterrupted system audio, a single mixed audio track, static-screen duration, empty captures, and cancellation. Temporary test media is removed afterward.
