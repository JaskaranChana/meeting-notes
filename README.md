<div align="center">

<img src="docs/social.png" width="860" alt="Scribeflow — meetings, remembered, entirely on your device"/>

<br/>

Hit record — or just type. Scribeflow listens, then hands you a clean recap: what was **decided**, who **owns** what, and by **when**. It remembers across every meeting, so you can ask your whole history a question and get a cited answer. All on your iPhone — nothing ever leaves the device.

![iOS](https://img.shields.io/badge/iOS-26-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Observation-FA7343?logo=swift&logoColor=white)
![AI](https://img.shields.io/badge/AI-on--device-1F8A70)
![Privacy](https://img.shields.io/badge/data-stays%20local-2E7D71)
![License](https://img.shields.io/badge/license-All%20rights%20reserved-lightgrey)

<br/>

<img src="docs/flow.gif" width="300" alt="Record → Recap → Today → Ask"/>

<sub><b>Record → recap → today's plan → ask anything.</b> The whole loop, on device.</sub>

</div>

---

## ✨ How it works

<table border="0">
<tr>
<td width="25%" align="center"><img src="docs/framed/capture.png" width="190" alt="Capture"/></td>
<td width="25%" align="center"><img src="docs/framed/recap.png" width="190" alt="Recap"/></td>
<td width="25%" align="center"><img src="docs/framed/home.png" width="190" alt="Today"/></td>
<td width="25%" align="center"><img src="docs/framed/ask.png" width="190" alt="Ask"/></td>
</tr>
<tr>
<td align="center"><b>1 · Capture</b><br/><sub>Hit record or type. Live transcription — no bot joining your call.</sub></td>
<td align="center"><b>2 · Auto recap</b><br/><sub>Synopsis, decisions, owned action items, risks — scored.</sub></td>
<td align="center"><b>3 · Today</b><br/><sub>Open to a briefing of exactly what needs you, worst-first.</sub></td>
<td align="center"><b>4 · Ask</b><br/><sub>"What did we decide with Meridian?" — answered, with sources.</sub></td>
</tr>
</table>

<div align="center">
<img src="docs/capture.gif" width="280" alt="From a live meeting to a clean recap"/>

<sub><b>Talk through the meeting → a clean, owned recap.</b></sub>
</div>

---

## Why it's different

Most meeting tools record to the cloud and hand you a transcript. Scribeflow is built around **memory and follow-through**, locally:

- 🧠 **It reads what you wrote** — pulls out the *decision*, the *action*, and *who owns it* (`I'll…` → **You**, `we'll…` → **Team**, `Maya will…` → **Maya**, `owner: Dana` → **Dana**). Not a keyword dump.
- 🗓️ **Real deadlines** — free-text hints like "Friday" or "eod" resolve to actual dates, so *overdue* and *due-soon* are judged by time, not guesses.
- 🔁 **It remembers across meetings** — ask your whole history a question, with cited sources.
- ⚡ **It tells you what matters now** — a ranked briefing, not a wall of numbers.
- 🔒 **Private by design** — recordings, transcripts, and notes never leave the device.

---

## 🌗 One app, two moods

Every surface is built on adaptive tokens — it's beautiful in light and dark, and switches instantly.

<div align="center">
<img src="docs/theme.gif" width="300" alt="Light and dark"/>
</div>

<table border="0">
<tr>
<td width="50%" align="center"><img src="docs/framed/recap.png" width="220" alt="Recap light"/><br/><sub>Recap · Light</sub></td>
<td width="50%" align="center"><img src="docs/framed/recap_dark.png" width="220" alt="Recap dark"/><br/><sub>Recap · Dark</sub></td>
</tr>
</table>

---

## Highlights

| | |
|---|---|
| **Live capture + transcription** | Record on-device (`SFSpeechRecognizer`) or just type. |
| **Smart Notes** | Decisions & actions with owners and due hints, extracted live as you write. |
| **Meeting Copilot** | During a call, recalls open promises with the same people and flags decisions/actions as they're spoken. |
| **Ask your library** | Retrieval-augmented Q&A across every meeting, with citations and follow-up suggestions. |
| **Real commitments** | Overdue / due-soon judged by resolved dates; floats urgent work to the top. |
| **Push to Reminders** | Send any action item to Apple Reminders with its due date. |
| **One-tap recap** | Share a clean Markdown digest — synopsis · decisions · actions · risks · people. |

---

## The screens

<table border="0">
<tr>
<td width="33%" align="center"><img src="docs/framed/home.png" width="210" alt="Today"/><br/><sub><b>Today</b> — your ranked briefing</sub></td>
<td width="33%" align="center"><img src="docs/framed/library.png" width="210" alt="Library"/><br/><sub><b>Library</b> — searchable, filtered</sub></td>
<td width="33%" align="center"><img src="docs/framed/ask.png" width="210" alt="Ask"/><br/><sub><b>Ask</b> — grounded, cited answers</sub></td>
</tr>
</table>

---

## Tech

- **SwiftUI** · iOS 26 / Xcode 26 · the Observation framework (`@Observable`)
- **Apple Intelligence** (`FoundationModels`) for note transformation & Q&A, with a deterministic on-device fallback
- **Speech** (`SFSpeechRecognizer`) + `AVAudioEngine` for live capture
- Local JSON persistence — debounced, off-main writes with a backup/recovery path
- **Swift Testing** — extraction, due-date, and Copilot logic (34 tests, green)

## Build & run

```bash
open Scribeflow.xcodeproj
# Select an iOS 26 simulator (e.g. iPhone 16 Pro) and ⌘R
```

Explore with sample data (dev only — loads into a fresh install):

```
-SCRIBEFLOW_USE_SEED_DATA
```

## Tests

```bash
xcodebuild test \
  -project Scribeflow.xcodeproj -scheme Scribeflow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Privacy

Recordings, transcripts, and notes stay on the device — nothing is uploaded to a Scribeflow server. Speech recognition runs on-device wherever supported; calendar access is optional and used only to pre-fill meeting context. Full policy: **[scribeflow privacy](https://jaskaranchana.github.io/meeting-notes/PRIVACY)**.

## License

© 2026 Jaskaran Singh. **All rights reserved.** Source published for viewing only — see [LICENSE](LICENSE). Not licensed for reuse or redistribution without written permission.

<div align="center">
<sub>Built by Jaskaran Singh · SwiftUI · on-device AI · made to be remembered.</sub>
</div>
