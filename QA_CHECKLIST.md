# Scribeflow QA Checklist

## Automated smoke pass
Run the project build-for-testing step:

```bash
xcodebuild -project /Users/jaskaransingh/Projects/codes/Scribeflow/Scribeflow.xcodeproj \
  -scheme Scribeflow \
  -destination 'generic/platform=iOS Simulator' \
  build-for-testing
```

Run unit tests:

```bash
xcodebuild -project /Users/jaskaransingh/Projects/codes/Scribeflow/Scribeflow.xcodeproj \
  -scheme Scribeflow \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ScribeflowTests \
  test
```

Run a Release compile without signing:

```bash
xcodebuild -project /Users/jaskaransingh/Projects/codes/Scribeflow/Scribeflow.xcodeproj \
  -scheme Scribeflow \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the screenshot smoke pass if the local simulator is healthy:

```bash
/Users/jaskaransingh/Projects/codes/Scribeflow/scripts/qa_smoke.sh
```

Expected smoke screens:
- Home
- Library
- Quick note
- Meeting detail
- Live capture
- Workspace assistant
- Folder detail
- Phone call

Artifacts are saved in `/Users/jaskaransingh/Projects/codes/Scribeflow/qa-artifacts`.

## Real iPhone checks

### Authentication
- Fresh install the app.
- Complete onboarding and confirm the login screen appears before the app workspace.
- Try empty fields, invalid email, and a weak password; confirm inline errors appear.
- Sign up with a valid email and strong password such as `Secure123`.
- Confirm the app opens after the loading state completes.
- Background and reopen the app; confirm it locks and offers Face ID or Touch ID when available.
- Use the password path if biometrics are unavailable or cancelled.
- Open Settings and confirm the signed-in email appears.
- Tap `Log out`, cancel once, then confirm logout; verify the app returns to authentication.

### Quick note
- Open `Quick note` from Home.
- Enter a title, objective, and short bullets.
- Save.
- Confirm the note appears in Library.
- Open the saved note and confirm rewritten content feels polished.

### Live capture
- Open `Start live`.
- Confirm speech and microphone permission prompts appear the first time.
- Confirm `Start listening` changes state after permission is granted.
- Speak several sentences.
- Confirm transcript lines appear.
- Add manual bullets while speech capture is active.
- Save and confirm the final note is enhanced.

### Voice notes
- Open `Voice note` from Today.
- Confirm microphone and speech permission states are clear.
- Record at least 30 seconds.
- Pause, resume, stop, and save.
- Confirm the recording appears in Library under the Voice filter.
- Play and pause the latest recording directly from the Library row.
- Open the note detail view.
- Play/pause the audio recording.
- Rename, share, and delete a recording.
- Attach a second voice note from the note detail screen.
- Confirm transcript text is searchable from Library.
- Search for a transcript phrase and confirm the matching snippet appears in the result row.
- Start recording, background the app or trigger an audio interruption, and confirm recording pauses cleanly.

### Phone call note
- Start a real call or FaceTime call.
- Open Scribeflow.
- Confirm the Home call card appears.
- Open `Call note`.
- Confirm the mode chooser is fully visible.
- Test `Take notes only`.
- Confirm manual notes save correctly.

### Phone call mic assist
- During a call, choose `Try mic assist`.
- Test once on speakerphone.
- Test once with AirPods.
- Confirm the permission flow is clear.
- Confirm the app never starts listening without explicit user action.
- Confirm the live transcript section updates if speech capture is available.
- Confirm the app stays usable even if transcript capture fails.

### Provider call panel
- Open the phone call workflow.
- Confirm the app clearly says it cannot record cellular, FaceTime, WhatsApp, or third-party app calls.
- In Debug, confirm the sandbox provider can simulate a call.
- In Release, confirm an unconfigured provider cannot start a fake real call.
- Confirm mute, speaker, timer, end-call, and provider notes behave correctly in sandbox.

### Recording privacy
- Open Settings.
- Open `Recording privacy`.
- Confirm voice note storage, transcription, phone call limits, and no-tracking copy are clear.
- Confirm the built app contains `PrivacyInfo.xcprivacy`.
- Open `Storage & backup`.
- Confirm total storage, audio storage, and recording file sizes render.
- Export a full backup and a notes-only backup; confirm both JSON files are created.
- Restore a backup on a test install and confirm notes plus recordings appear.
- Move the large-file slider and confirm the large-audio count updates.
- Delete audio over the selected size and confirm notes/transcripts remain.
- Delete audio older than 30 days on test data and confirm notes/transcripts remain.
- Delete one large recording and confirm the note remains but audio is removed.
- Use `Delete all my data` on a test install and confirm notes, transcripts, recordings, and fuel data are cleared.
- Open `Account & sync` and confirm account, cloud sync, AI summary, speaker detection, and backup statuses are accurate.

### Meeting intelligence
- Open a note with transcript or voice recording.
- Confirm `Meeting intelligence` appears above the digest.
- Confirm smart summary, decisions, action items, open questions, follow-ups, and speaker read render when present.
- Confirm structured action items show owner, due hint, and source when available.
- Confirm transcript lines with `Name: text` show separate speakers.
- Open Share > Transcript > Speakers.
- Rename a speaker and confirm every matching transcript line updates.
- Confirm the screen states that real acoustic diarization requires a transcription backend.

### Library and folders
- Open Library.
- Switch between `Meetings` and `Folders`.
- Search for a meeting.
- Open one folder.
- Run folder chat using a recipe chip.
- Confirm an answer appears.

### Workspace assistant
- Open `Ask workspace`.
- Run at least one recipe.
- Ask a custom question.
- Confirm the answer renders and feels grounded in meetings.

## Known limits
- iOS does not allow a normal app to directly record the other side of a standard phone call.
- FaceTime plus AirPods can limit what microphone input third-party apps receive.
- Simulator is useful for UI validation, but real call audio behavior must be checked on-device.
- Real two-sided call recording requires a compliant provider backend, consent workflow, server-side recording, and updated privacy disclosures.
