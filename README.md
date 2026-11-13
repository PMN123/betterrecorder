# BetterRecorder

A native Mac app for screen recording and audio-only meeting assistance. Record a screen or window with system audio and an optional microphone, or transcribe a meeting locally and send text into an existing Codex chat. Screen recording requires macOS 15 or later; Meeting mode requires macOS 26 or later.

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

## Audio-only Meeting mode

1. Open **Meeting mode**. Keep the Mac connected to power for local transcription.
2. Choose **Mac audio**, **Microphone**, or both, and select a microphone if needed.
3. Click **Choose Mac audio** and select a screen in the macOS sharing picker. The stream supplies audio; this mode saves no video or audio recording.
4. Search for and select an existing local **Codex chat**. No new chat is created, and its model and conversation history are preserved.
5. Click **Start meeting & send transcript**. BetterRecorder opens that chat in Codex and displays a local live transcript. The microphone can be muted and unmuted during the session.
6. Click **Stop meeting** to stop capture, finish transcription, and queue remaining text. **Open transcript** reveals the saved local text.

Transcription uses Apple's on-device English (United States) SpeechAnalyzer model. The model may download on first use; speech recognition itself runs locally. Recognition can omit or mishear words. Live partial text appears immediately, while only finalized speech is forwarded, labeled with timestamps and its source. Use headphones when capturing both Mac audio and microphone to reduce duplicate speaker audio.

Finalized text is batched roughly every 10 seconds. The [installed Codex CLI](https://learn.chatgpt.com/docs/cli/reference) uses your existing **ChatGPT sign-in**, so no API key is needed. Normal Codex usage limits apply. Keep the selected chat open: the desktop checks externally queued messages approximately every 10 seconds. A chat already working drains the queue after its current turn, and a paused chat needs you to resume it. **Queued** means Codex accepted the text into its queue; it does not mean an answer has finished.

The selected destination is fixed for a session. Transcript text is framed as quoted meeting content, rather than instructions to execute commands or send messages. Only text goes to the selected chat; raw audio stays on the Mac. Completed text is saved under `~/Documents/BetterRecorder Meetings/<session>/transcript.txt`, in a private folder. On connection uncertainty, forwarding pauses and the full transcript remains there; check the chat before manually retrying to avoid duplicates. Responses to text already queued may arrive after you stop the meeting.

## macOS permissions

Use the system picker to choose what BetterRecorder may capture. If macOS asks, allow screen and system-audio recording. If capture is blocked, check **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen the app if macOS requests it.

Microphone access is requested only when you start with **Microphone** enabled. If access was denied, enable BetterRecorder under **System Settings → Privacy & Security → Microphone**.

Protected streaming video and some apps may block capture or produce silent/black sections. Selecting a window can limit captured audio to its application; select a screen for general Mac output. Playback volume and the source app’s mute controls affect what is available to record.

## Build locally

This folder is the complete source. It has no external package dependencies.

Clone the repository, then build with Xcode 26 or later and Swift 6 installed:

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

Run the meeting routing and transcript batching checks without opening or sending to a real chat:

```sh
./Support/tests/run-meeting.sh
```

Local SpeechAnalyzer has also been exercised with generated speech, including progressive results, final results, and finalization. These checks do not assert perfect transcription accuracy or prove that a particular live chat processed a batch.
