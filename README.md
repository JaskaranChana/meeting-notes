<div align="center">

<img src="docs/social.png" width="860" alt="Scribeflow - meetings remembered with local-first privacy"/>

<br/>

### Hit record, start from calendar, or just type. Scribeflow turns rough notes into a clean, owned recap with inspectable sources and clear inference labels.

What was **decided**, who **owns** what, by **when**, what's still **open** — pulled from your words when Scribeflow can prove it was a meeting or call. Personal notes stay personal, without fake tasks or risks. Ask your whole history a question and get an answer grounded in cited source excerpts. Data stays local by default; exports, private iCloud backup, Apple services, configured webhooks, and optional remote transcription are explicit user-controlled boundaries.

<br/>

![iOS](https://img.shields.io/badge/iOS-26-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Observation-FA7343?logo=swift&logoColor=white)
![Apple Intelligence](https://img.shields.io/badge/Apple%20Intelligence-on--device-1F8A70?logo=apple&logoColor=white)
![Privacy](https://img.shields.io/badge/local--first-2E7D71)
![Build](https://img.shields.io/badge/build-green-3FB950)
![License](https://img.shields.io/badge/license-All%20rights%20reserved-lightgrey)

<br/>

<img src="docs/flow.gif" width="300" alt="Record → Recap → Today → Ask"/>

<sub><b>Record → recap → calendar + today → ask anything.</b> The whole loop, on device.</sub>

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
<td align="center"><b>1 · Capture</b><br/><sub>Hit record or type. Live transcription — no bot joins your call.</sub></td>
<td align="center"><b>2 · Understand</b><br/><sub>The model reads your notes and lays out the brief — by meeting type.</sub></td>
<td align="center"><b>3 · Plan</b><br/><sub>Calendar, Today, and Tasks show what needs you, without covering bottom actions.</sub></td>
<td align="center"><b>4 · Ask</b><br/><sub>"What did we decide with Meridian?" — answered, with sources.</sub></td>
</tr>
</table>

<div align="center">
<img src="docs/capture.gif" width="280" alt="From a live meeting to a clean recap"/>

<sub><b>Talk through the meeting → a clean, owned recap.</b></sub>
</div>

---

## 🧠 The AI that won't make things up

Scribeflow runs **Apple Intelligence on-device** (`FoundationModels`, guided generation) to turn rough, misspelled notes into a polished brief — after a conservative purpose check. It only extracts meeting signals when the capture has meeting proof:

> **Real notes in → a powerful, structured brief.**
> **Nonsense in →** *"This does not make sense. Please clarify."* — never invented meaning.

| Principle | What it means |
|---|---|
| 🚫 **Never invents** | Only what your notes actually support — no fabricated owners, dates, or decisions. |
| 🧭 **Purpose-aware** | Personal notes, journals, and solo voice notes do not get forced into decisions, action items, or risks. |
| 🪪 **Your words stay yours** | Granola-style: your bullets are the anchor (your text), the model adds context beneath in quieter ink. You always see what *you* wrote vs. what AI added. |
| ❓ **Flags, doesn't guess** | Anything ambiguous goes to a **Needs clarification** list instead of a confident guess. |
| 🧹 **Cleans, never loses** | Fixes spelling, removes repetition, keeps every important detail. |
| 📴 **Local-first, with a fallback** | Intelligence runs on device where available and degrades to a deterministic engine. Backend transcription is used only in builds explicitly configured for it. |

### The brief, anatomized

From a meeting or call, the model produces a presentation-ready layout:

```
Summary        ─ one sharp sentence
Decisions      ─ what was settled
Action items   ─ Owner · Deadline · Priority · why it matters
Open questions ─ what still needs an answer
Risks          ─ blockers and concerns
Key points     ─ the substance, distilled
Your notes     ─ your words, verbatim, expanded with AI context
```

For personal notes, Scribeflow keeps the shape lighter: cleaned notes, source text, and searchable context, without pretending there are owners, deadlines, decisions, or risks.

### It adapts to the purpose

The app first decides whether the capture is a personal note, meeting, or call. Then the model **auto-detects the meeting type** and tailors the layout — no setup:

| Lens | Adds sections like |
|---|---|
| 📈 **Sales** | Customer needs · Budget · Stakeholders |
| ⚖️ **Legal** | Exact language · Conditions · Deadlines |
| 🌱 **Coaching / 1:1** | Wins · Blockers · Looking ahead |
| 🧩 **Product** | Specs · Dependencies · Ship criteria |
| 🗣️ **Standup** | Done · In progress · Blocked |

Pick a lens to lock it, or let it choose.

---

## Why it's different

Most meeting tools record to the cloud and hand you a transcript. Scribeflow is built around **comprehension and follow-through**, locally:

- 🧭 **It knows when not to extract** — a personal thought, journal note, or solo voice memo stays a note; meeting sections only appear when there is evidence.
- 🧠 **It understands, not keyword-matches** — typos and shorthand become clean, owned items (`i'll snd the deck fryday` → **Send the deck · You · Friday**).
- ⏱️ **Action items that actually move** — every task carries an owner, a real deadline, a **priority**, and a one-line *why it matters*; Today and Tasks rank by it.
- 🗓️ **Real dates** — "Friday" or "eod" resolve to actual dates, so *overdue* and *due-soon* are judged by time, not guesses.
- 📅 **A real calendar surface** — month, week, and agenda modes combine saved notes, calendar events, and open loops in one place.
- 🔁 **It remembers across meetings** — ask your whole history, get a cited answer.
- 🧭 **It prepares the next conversation** — upcoming events carry forward related decisions, open promises, and unresolved questions with links to the exact source notes.
- 🔒 **Private by design** — recordings, transcripts, and notes stay on device by default; exports, private iCloud backup, and a configured transcription service are explicit user-controlled boundaries.

---

## 🌗 One app, two moods

Every surface is built on adaptive tokens — beautiful in light and dark, switches instantly.

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
| 🎙️ **Live capture + transcription** | Record on device, optionally guide the voice count, and rebuild a saved recording's transcript without a bot on the call. |
| 🧠 **On-device AI brief** | The model turns rough notes into summary · decisions · actions · questions · risks, typo-corrected. |
| 🧭 **Purpose-aware extraction** | Meeting intelligence runs for meetings and calls; personal captures stay lightweight and private. |
| 🪪 **Enhanced notes** | Your bullets, expanded with AI context — your words kept distinct from the model's. |
| 🎯 **Auto meeting lenses** | Detects sales / legal / coaching / product / standup and tailors the sections. |
| ✅ **Action items that move** | Owner · deadline · **priority** · *why* — surfaced until done. |
| 📅 **Interactive calendar** | Month, week, and agenda views with filters for notes, events, and open loops. |
| 🧭 **Before-you-join brief** | Matches an upcoming event to people and prior topics, then carries forward source-linked commitments and questions. |
| 🤖 **Live Copilot** | Mid-call, recalls open promises with the same people and flags decisions as they're spoken. |
| 🔎 **Ask your library** | Retrieval-augmented Q&A across every meeting, with citations and follow-ups. |
| 📤 **One-tap recap** | Share a clean Markdown digest — AI summary kept separate from your verbatim notes. |
| 🫧 **Liquid navigation** | Compact icon-only root dock, centered Today action, stable taps, and bottom-safe scrolling. |
| 🛡️ **Honest by default** | No invention; nonsense is called out; unclear points are flagged, not guessed. |

---

## The screens

<table border="0">
<tr>
<td width="33%" align="center"><img src="docs/framed/home.png" width="210" alt="Today"/><br/><sub><b>Today</b> — ranked by priority, personal-safe</sub></td>
<td width="33%" align="center"><img src="docs/framed/library.png" width="210" alt="Library"/><br/><sub><b>Library</b> — searchable, filtered</sub></td>
<td width="33%" align="center"><img src="docs/framed/ask.png" width="210" alt="Ask"/><br/><sub><b>Ask</b> — grounded, cited answers</sub></td>
</tr>
</table>

Also included in-app: an interactive Calendar tab with month, week, and agenda modes; a Tasks inbox for open loops; Settings controls for demo data, diagnostics, integrations, and privacy.

---

## Tech

- **SwiftUI** · iOS 26 / Xcode 26 · the Observation framework (`@Observable`)
- **Apple Intelligence** (`FoundationModels`) — `@Generable` guided generation for a structured, typo-tolerant brief; deterministic on-device engine as the fallback
- **Speech** (`SFSpeechRecognizer`) + `AVAudioEngine` for live capture
- **EventKit** — optional calendar context, calendar browsing, and Reminders export
- **UserNotifications** — local reminder scheduling for action follow-through
- Purpose classifier — conservative personal/meeting/call policy before extracting decisions, tasks, risks, or open loops
- SwiftUI liquid-style dock — icon-only tabs, centered Today action, and bottom clearance for scrollable screens
- Heavy extraction is **debounced off the keystroke path**, so typing stays smooth
- Local JSON persistence — debounced, off-main writes with a backup/recovery path
- Build is currently green for the app target; tests exist for extraction, distillation, due-date, Copilot, and schema-migration logic

## Build & run

```bash
open Scribeflow.xcodeproj
# Select an iOS 26 simulator (e.g. iPhone 16 Pro) and ⌘R
```

Command-line build check:

```bash
xcodebuild -project Scribeflow.xcodeproj \
  -scheme Scribeflow \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

> **Note:** the AI brief runs on Apple-Intelligence-capable devices (iPhone 15 Pro / 16, iOS 26+). On the Simulator and older devices it uses the deterministic on-device engine.

Explore with demo data from the app through onboarding, Home, Library, or Settings. For dev-only launch seeding:

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

Recordings, transcripts, and notes stay on the device by default. Speech recognition and the AI brief prefer on-device processing; calendar access is optional and used to pre-fill meeting context. User-triggered exports, private iCloud backup, Apple services, configured webhooks, and optional remote transcription are documented boundaries. Full policy: **[Scribeflow privacy](https://jaskaranchana.github.io/meeting-notes/PRIVACY)**.

## License

© 2026 Jaskaran Singh. **All rights reserved.** Source published for viewing only — see [LICENSE](LICENSE). Not licensed for reuse or redistribution without written permission.

<div align="center">
<sub>Built by Jaskaran Singh · SwiftUI · on-device AI · made to be remembered.</sub>
</div>
