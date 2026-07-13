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

## End-To-End Refinement Pass

### Production Services

Status: complete for the client foundation.

- Added HTTPS runtime configuration and backend-issued token enforcement.
- Streams multipart recording uploads without loading the full file into memory.
- Keeps Apple Speech as the zero-configuration fallback.
- Persists failed transcription jobs and safely recovers them after relaunch.

### Account Lifecycle

Status: complete for current account modes.

- Release now uses one Keychain-backed session boundary.
- Removed the duplicate local password database and its legacy screens.
- Distinguishes local, social-identity, development, and backend sessions.
- Rechecks Apple authorization and blocks partial account deletion failures.
- Full deletion clears notes, recordings, reminders, queues, backups, diagnostics,
  integrations, Spotlight, widget data, and identity metadata.

### Cloud Continuity

Status: complete for user-controlled backup; not live sync.

- Cloud capability is enabled by build configuration, not a source edit.
- Added SHA-256 integrity verification and remote-change conflict protection.
- Refreshes when the iCloud account changes and supports idempotent deletion.
- Still requires the Apple container, provisioning profile, and deployed schema.

### Release Operations

Status: complete for repository-controlled work.

- Added a protected, bounded local MetricKit archive.
- Added App Health checks and user-controlled diagnostics export/clear.
- Added build-only GitHub Actions compilation with cancellation and timeout controls.

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

Production-quality acoustic speaker separation still depends on the configured
transcription service returning ordered speaker segments. Apple Speech is shown
honestly as one mixed track rather than pretending to identify multiple voices.
