# Scribeflow Source Map

Use this as the first stop when finding code. The Xcode navigator mirrors these
groups; physical file moves should be done in smaller follow-up refactors.

## App

- `ScribeflowApp.swift` - app entry, optional app lock, splash, app commands.
- `ContentView.swift` - root tabs, floating dock, sheets, deep links, toasts.
- `NotificationRouter.swift` - notification presentation and meeting deep-link routing.

## Core

- `Models.swift` - meeting, transcript, action, auth, and product domain models.
- `MeetingPurpose.swift` - purpose classification and conservative extraction policy.
- `MeetingStore.swift` - protected persistence/recovery, retention enforcement, meeting mutations, grounded intelligence, and export.
- `AppCore.swift` - shared app services, calendar/reminder helpers, Spotlight, utilities.
- `ProductionServices.swift` - runtime backend configuration, streamed transcription, and durable retries.
- `ReleaseOperations.swift` - readiness checks, bounded MetricKit archive, and support export.
- `Localization.swift` - type-safe access to core localized navigation and actions.

## Design System

- `DesignTokens.swift` - palette, layout metrics, typography, dock, reusable chrome.
- `SharedViews.swift` - shared cards, rows, digest rendering, generic UI pieces.
- `Skeleton.swift` - loading skeletons and shimmer affordances.
- `AIIntelligenceStatus.swift` - compact model/status UI.

## Features

- `TodayView.swift` - home briefing, investor demo banner, daily plan, upcoming meeting cards.
- `UsageImpactView.swift` - private, on-device capture and follow-through metrics.
- `InvestorPresentationView.swift` - live-data investor walkthrough and product proof.
- `MeetingPrep.swift` - source-backed event matching, relationship context, and the before-you-join brief.
- `MeetingCalendarView.swift` - interactive month/week calendar and day agenda.
- `MeetingsView.swift` - library list and meeting browsing.
- `ActionItemsView.swift` - task inbox and reminders flow.
- `WorkspaceViews.swift` - Ask/recall workspace assistant.

## Meeting Detail

- `MeetingDetailView.swift` - recap/detail surface, trust summary, recording transcript recovery, and pushed detail routes.
- `MeetingIntelligence.swift` - purpose-aware extraction, speaker normalization, people-count confidence, and scoring helpers.
- `SourceProof.swift` - claim confidence, source references, and proof inspector UI.
- `MeetingSavedSheet.swift` - post-save confirmation.
- `LiveMeetingCoordinator.swift` - live meeting capture context and in-call intelligence.
- `MeetingProcessingCoordinator.swift` - durable post-save queue, resource-aware enhanced transcription, background resume, and ready notifications.

## Capture And Audio

- `CaptureView.swift` - capture modes and note creation.
- `VoiceNoteInput.swift` - inline voice-note control.
- `VoiceRecorderView.swift` - full recorder UI.
- `VoiceRecorderViewModel.swift` - recorder UI state and coordination.
- `VoiceRecordingService.swift` - audio recording service.
- `SpeechRecognitionPipeline.swift` - live SpeechTranscriber/legacy Speech pipeline and contextual vocabulary.
- `LocalSpeakerDiarization.swift` - temporary audio writer, constrained on-device speaker separation, and transcript alignment.
- `VoiceRecordingModels.swift` - recording models, protected file storage, and off-main audio import preflight.
- `AudioPlaybackControls.swift` - playback UI.
- `AudioSessionManager.swift` - AVAudioSession setup.
- `RecordingCompliance.swift` - recording limitation and compliance text.
- `RecordingPrivacyView.swift` - recording privacy surface.

## Authentication

- `AuthModels.swift` - auth domain types.
- `AuthService.swift` - auth session store and sign-in flows.
- `AuthKeychainStore.swift` - secure token/session persistence.
- `AuthViews.swift` - active Keychain/device/Apple sign-in and lock UI.
- `DeviceAuthService.swift` - device/biometric auth service.
- `GoogleSignInService.swift` - Google sign-in integration shim.

## Settings And Data Controls

- `SettingsView.swift` - app preferences, investor demo mode, demo data, diagnostics links.
- `DataControlsView.swift` - data export, backup, iCloud backup, restore preview, recording cleanup controls.
- `BackupArchiveService.swift` - off-main backup encoding, bounded full exports, protected snapshots, and restore staging.
- `DataManagementModels.swift` - storage/backup models and CloudKit backup foundation.
- `ProductCapabilityModels.swift` - capability/status models.
- `AudioDiagnostics.swift` - microphone/audio diagnostics.

## Library And Recall

- `LibraryViews.swift` - folders, filters, library chrome.
- `LibrarySnapshot.swift` - precomputed library filtering/search snapshot.
- `RecallEngine.swift` - action checks and recall intelligence.
- `RecallView.swift` - recall UI.

## Resources

- `Assets.xcassets` - icons, brand mark, colors.
- `PrivacyInfo.xcprivacy` - Apple privacy manifest.
- `Localizable.xcstrings` - core navigation and action String Catalog.
- `InfoPlist.xcstrings` - localized permission and display-name copy.
- `Info.plist` - bundle metadata and permitted meeting-processing background task.
- `Scribeflow.entitlements` - CloudKit entitlement template; wire it only after the Apple Developer profile supports iCloud.

## Repo Docs

- `PRIVACY.md` - public privacy disclosure and user-controlled data boundaries.
- `TERMS.md` - public terms template; obtain legal review before App Store release.
- `INVESTOR_READINESS.md` - demo path, product proof, release checks, and next investor polish.
- `SCRIBEFLOW_PHASE_EXECUTION.md` - completed phase record and external launch gates.
- `PRODUCTION_CONFIGURATION.md` - backend, identity, CloudKit, privacy, and CI contracts.

## Large Files To Split Later

- `TodayView.swift` - split hero, agenda, inbox, and sample-data/onboarding cards.
- `MeetingDetailView.swift` - split detail routes and repeated cards by tab/section.
- `MeetingStore.swift` - split persistence, sample data, AI processing, export, and mutation APIs.
- `Models.swift` - split domain model families after storage compatibility is stable.
