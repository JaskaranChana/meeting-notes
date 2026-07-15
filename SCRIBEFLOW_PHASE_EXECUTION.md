# Scribeflow Phase Execution

This is the durable handoff for the current product-quality pass. Each completed
phase was implemented against the existing architecture rather than adding a
parallel system.

## Phase 1 - Reliable, Source-Backed Core

Status: complete.

- Added persisted source references and claim-level confidence.
- Added proof inspectors throughout meeting intelligence.
- Preserved user-edited action state and reminder metadata during regeneration.
- Kept personal captures out of meeting-only accountability extraction.

## Phase 2 - Calendar Workflow

Status: complete.

- Moved EventKit reads off the main UI path.
- Refreshes on app activation and calendar-store changes.
- Links notes to events with an identifier plus title/time fallback.
- Keeps the interactive month, week, and agenda experience responsive.

## Phase 3 - Action Reminders

Status: complete.

- Persists reminder identity and scheduled time with each commitment.
- Supports schedule, reschedule, cancel, complete, and skip flows.
- Routes notification taps directly to the owning meeting.
- Cleans reminders when meetings or user data are removed.

## Phase 4 - User-Controlled Recovery

Status: complete for local storage.

- Added protected automatic snapshots with bounded history.
- Runs archive encoding and audio reads away from the main UI path.
- Validates imports and stages restores with rollback protection.
- Supports full and notes-only portable backups.

CloudKit activation remains an external Apple provisioning task. The app does
not claim live iCloud backup while that capability is unavailable.

## Phase 5 - Investor And Release Readiness

Status: complete for app-controlled work.

- Added on-device usage impact using real library data.
- Added a focused four-page investor presentation.
- Added one-tap presentation entry points from Today and Settings.
- Updated the source map and investor walkthrough documentation.

## Remaining External Gates

- Apple Developer CloudKit container, provisioning profile, and production schema.
- Production transcription provider URL, authentication, monitoring, and quotas.
- Signed TestFlight delivery credentials and requested device-level smoke automation.
- Legal review of the repository terms template before public distribution.

## End-To-End Refinement Pass

### Production Services

Status: complete for the client foundation.

- Added HTTPS runtime configuration and backend-issued token enforcement.
- Streams multipart recording uploads without loading the full file into memory.
- Keeps Apple Speech as the zero-configuration fallback.
- Persists failed transcription jobs and safely recovers them after relaunch.

### Account Lifecycle

Status: complete for current account modes.

- Local workspaces open without an account; app unlock is an explicit user choice.
- Enabled sessions use one Keychain-backed boundary.
- Removed the duplicate local password database and its legacy screens.
- Distinguishes local, social-identity, development, and backend sessions.
- Rechecks Apple authorization and blocks partial account deletion failures.
- Full deletion clears notes, recordings, reminders, queues, backups, diagnostics,
  integrations, Spotlight, widget data, and identity metadata.

### Cloud Continuity

Status: complete for user-controlled backup; not live sync.

- The private-backup foundation is present but remains unavailable until the
  signed target has the CloudKit entitlement and production container.
- Added SHA-256 integrity verification and remote-change conflict protection.
- Refreshes when the iCloud account changes and supports idempotent deletion.
- Still requires the Apple container, provisioning profile, and deployed schema.

### Release Operations

Status: complete for repository-controlled work.

- Added a protected, bounded local MetricKit archive.
- Added App Health checks and user-controlled diagnostics export/clear.
- Added GitHub Actions Debug tests plus Debug and Release compilation with cancellation and timeout controls.

### Inclusive Product

Status: client foundation complete; device validation remains.

- Added core and InfoPlist String Catalogs with type-safe navigation strings.
- Converted new display surfaces to Dynamic Type text styles.
- Metric strips stack at accessibility sizes instead of clipping or shrinking.
- VoiceOver, Voice Control, larger text, contrast, and localization validation
  remain release-device checks before publishing accessibility claims.

### Focused AI Notes And Speaker Intelligence

Status: complete for the client and on-device model path.

- Added a selectable brief focus and purpose-specific AI instructions.
- Added a ranked `What matters` layer for fast comprehension.
- Feeds numbered, speaker-tagged transcript evidence to Apple Intelligence.
- Stores source-backed per-speaker contributions without trusting model-made identities.
- Preserves backend diarization segments, provider metadata, and timestamps on save.
- Normalizes common provider labels and keeps every speaker name editable.
- Separates detected voice labels from calendar attendees and explains confidence.
- Cancels stale AI generations so the latest focus or speaker correction wins.

Enhanced local transcription can use FluidAudio diarization to produce ordered
speaker turns on device. Apple Speech remains one mixed track when diarization is
unavailable, and every detected label can be renamed, merged, or corrected for
an individual transcript turn.

## Trust, Performance, And Release Refinement

Status: app-controlled implementation and compile verification complete; device
validation remains a separate release step.

### Grounded Intelligence

- Ask retrieves raw note and transcript chunks before generation.
- The generated answer may cite only validated source IDs from that retrieval.
- The Sources card displays only evidence actually used by accepted answer bullets.
- Source proof persists exact, partial, or contextual match strength.
- Negation mismatches cannot become supporting evidence.
- Generated claims and actions pass through semantic deduplication.

### Scalable Daily Use

- Persisted derived intelligence is versioned and no longer rebuilt wholesale
  before the first screen appears.
- Older rows migrate gradually with yields between meetings.
- Recall reuses a revision-cached raw-source index between questions.
- Persistence avoids rewriting an identical library snapshot.

### Speaker And Accessibility Review

- A whole speaker label can still be renamed across the transcript.
- Any individual transcript turn can now be reassigned to an existing or new speaker.
- Primary transcript, language, settings, and tab controls use larger hit regions.
- Meeting tabs scroll at large Dynamic Type sizes instead of clipping.
- Ready-state fallback notices announce through VoiceOver.

### Production Focus And Truth

- Release builds use one canonical Today hero.
- Investor presentation, sample reset, and hero experiments remain Debug tools.
- Webhook URLs require HTTPS and are stored in Keychain; preferences retain metadata only.
- The unimplemented Live Activity capability flag was removed.
- Privacy and README language now describe local-first defaults and explicit boundaries.
- Settings links to a dedicated terms document rather than the source-code licence.

## Reliability And Speech Recovery Pass

Status: implementation and compile verification complete; real-device speech
quality remains a release validation step.

### Launch And Persistence

- Legacy or incomplete intelligence repair now begins after first paint and
  yields between meetings.
- Curated seed commitments remain intact during deferred migration.
- Pending library edits flush immediately when the app leaves the foreground,
  closing the normal save debounce window before suspension.

### User-Guided Speaker Separation

- Capture keeps automatic voice detection as the default.
- Users who know the room can select an exact count from one to six voices.
- The hint travels through persisted processing jobs and configures FluidAudio's
  clustering constraint instead of existing only in the interface.

### Recording Transcript Recovery

- Every saved recording can create or improve its transcript.
- Recovery requests persist before processing and resume after relaunch.
- Local processing remains the default; a configured backend is used only after
  the existing explicit consent setting is enabled.
- Transcript lines retain recording provenance, so an improved transcript
  replaces that recording's earlier contribution without duplicating unrelated text.

### Verification Checkpoint

- Latest Debug iOS Simulator build succeeded on July 15, 2026 after the final
  strict-concurrency and imported-audio integration fixes.
- Latest Release iOS Simulator build succeeded on July 14, 2026.
- Both builds used fresh DerivedData and code signing disabled for compile verification.
- Tests and screenshots were intentionally not run for this checkpoint.

## Final Stabilization Pass - 15 July 2026

Status: repository-controlled implementation complete; device certification
and signed service configuration remain external release gates.

- Retention choices now delete expired transcripts and recording files, not
  merely update descriptive UI.
- App Lock relocks after backgrounding, while Debug builds continue to open
  directly for development.
- Every accepted generated claim must be supported by one source excerpt;
  unrelated snippets can no longer combine into false evidence.
- Live audio delivery is lock-free on the render callback, recognition rotation
  is serialized, and Save queues secured audio before waiting for final captions.
- Imported audio is preflighted off the main actor, appears immediately as
  processing, and uses the enhanced retryable transcription pipeline.
- First-use speech models respect power, heat, and storage constraints and fall
  back automatically.
- Persistence uses a compact content digest, refreshes known-good recovery data,
  and protects meetings, recordings, queues, analytics, and backups at rest.
- Full JSON backups are bounded before audio allocation; private iCloud backup
  is notes-only.
- Deleting all user data now clears pending processing audio, queues, and local
  notifications as well as visible meetings.
- Root dock visibility follows each tab's real navigation path instead of a
  fragile shared counter. Week calendar navigation now moves by week and reports
  week-specific counts.
- Incomplete Live Activity and Now Playing status code was removed until a real
  Widget extension and device-certified controls exist.
- App icon files retain the same opaque artwork without an App Store-invalid
  alpha channel.
