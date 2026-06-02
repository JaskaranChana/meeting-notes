# Scribeflow

**An on-device meeting-memory app for iOS.** Capture meetings live, and Scribeflow turns rough notes and speech into a clean, structured recap — decisions, action items with real owners and due dates, and answers across every meeting you've ever captured. No cloud, no account-on-a-server: it all runs on your device.

<p align="center">
  <img src="docs/home.png" alt="Scribeflow — cinematic briefing home" width="320">
</p>

## Why

Most meeting tools record to the cloud and hand you a transcript. Scribeflow is built around **memory and follow-through**, locally:

- It **reads what you wrote** and pulls out the *decision*, the *action*, and *who owns it* — not a keyword dump.
- It **remembers across meetings**, so you can ask your whole history a question.
- It surfaces **what actually needs you today**, ranked by real deadlines.

## Features

- **Live capture + transcription** — record and transcribe on-device (`SFSpeechRecognizer`), or just type.
- **Smart Notes** — as you write, Scribeflow extracts **Decisions** and **Actions** with owners (`I'll…` → *You*, `we'll…` → *Team*, `Maya will…` → *Maya*, `owner: Dana` → *Dana*) and due hints — live, on-device.
- **Meeting Copilot** — during a call, recalls open promises with the same people, flags decisions/actions as they're spoken, and suggests questions to raise.
- **Ask your library** — retrieval-augmented Q&A across every meeting, with cited sources and follow-up suggestions.
- **Real commitments** — free-text due hints ("Friday", "eod", "next week") resolve to **absolute deadlines**, so *overdue* and *due-soon* are judged by time, not keywords.
- **Cinematic briefing home** — a ranked "what needs you today" with urgency, plus follow-through stats.
- **One-tap recap** — share a clean Markdown digest (synopsis · decisions · actions · risks · people).
- **Private by design** — fully on-device; uses Apple Intelligence (`FoundationModels`) when available, with a local heuristic fallback.

## Tech

- **SwiftUI**, iOS 26 / Xcode 26, the Observation framework (`@Observable`).
- **Apple Intelligence** (`FoundationModels`) for note transformation and Q&A, with a deterministic on-device fallback.
- **Speech** (`SFSpeechRecognizer`) + `AVAudioEngine` for live capture.
- Local JSON persistence with debounced, off-main writes and a backup/recovery path.
- **Swift Testing** for the extraction, due-date, and Copilot logic.

## Build & run

```bash
open Scribeflow.xcodeproj
# Select an iOS 26 simulator (e.g. iPhone 16 Pro) and ⌘R
```

To explore with sample data (dev only — loads into a fresh install), pass the launch argument:

```
-SCRIBEFLOW_USE_SEED_DATA
```

## Tests

```bash
xcodebuild test \
  -project Scribeflow.xcodeproj -scheme Scribeflow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Covers note→intelligence extraction (`MeetingExtractionTests`), due-date resolution (`DueDateTests`), and Copilot recall (`MeetingCopilotTests`).

## Privacy

Recordings, transcripts, and notes stay on the device. Nothing is uploaded to a Scribeflow server. Calendar access is optional and used only to pre-fill meeting context.
