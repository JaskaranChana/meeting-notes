# Scribeflow Source Map

Use this as the first stop when finding code. The Xcode navigator mirrors these
groups; physical file moves should be done in smaller follow-up refactors.

## App

- `ScribeflowApp.swift` - app entry, auth gate, splash, app commands.
- `ContentView.swift` - root tabs, floating dock, sheets, deep links, toasts.

## Core

- `Models.swift` - meeting, transcript, action, auth, and product domain models.
- `MeetingStore.swift` - local persistence, sample data, meeting mutations, export.
- `AppCore.swift` - shared app services, calendar/reminder helpers, Spotlight, utilities.

## Design System

- `DesignTokens.swift` - palette, layout metrics, typography, dock, reusable chrome.
- `SharedViews.swift` - shared cards, rows, digest rendering, generic UI pieces.
- `Skeleton.swift` - loading skeletons and shimmer affordances.
- `AIIntelligenceStatus.swift` - compact model/status UI.

## Features

- `TodayView.swift` - home briefing, daily plan, upcoming meeting cards.
- `MeetingCalendarView.swift` - interactive month/week calendar and day agenda.
- `MeetingsView.swift` - library list and meeting browsing.
- `ActionItemsView.swift` - task inbox and reminders flow.
- `WorkspaceViews.swift` - Ask/recall workspace assistant.

## Meeting Detail

- `MeetingDetailView.swift` - recap/detail surface and pushed detail routes.
- `MeetingIntelligence.swift` - deterministic intelligence extraction and scoring helpers.
- `MeetingSavedSheet.swift` - post-save confirmation.
- `LiveMeetingCoordinator.swift` - live meeting capture context and in-call intelligence.

## Capture And Audio

- `CaptureView.swift` - capture modes and note creation.
- `VoiceNoteInput.swift` - inline voice-note control.
- `VoiceRecorderView.swift` - full recorder UI.
- `VoiceRecorderViewModel.swift` - recorder UI state and coordination.
- `VoiceRecordingService.swift` - audio recording service.
- `VoiceRecordingModels.swift` - recording domain models.
- `AudioPlaybackControls.swift` - playback UI.
- `AudioSessionManager.swift` - AVAudioSession setup.
- `RecordingCompliance.swift` - recording limitation and compliance text.
- `RecordingPrivacyView.swift` - recording privacy surface.

## Authentication

- `AuthModels.swift` - auth domain types.
- `AuthService.swift` - auth session store and sign-in flows.
- `AuthKeychainStore.swift` - secure token/session persistence.
- `AuthViews.swift` - onboarding, sign-in, lock, and auth atmosphere.
- `DeviceAuthService.swift` - device/biometric auth service.
- `GoogleSignInService.swift` - Google sign-in integration shim.

## Settings And Data Controls

- `SettingsView.swift` - app preferences, demo data, diagnostics links.
- `DataControlsView.swift` - data export, backup, recording cleanup controls.
- `DataManagementModels.swift` - storage/backup models.
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

## Large Files To Split Later

- `TodayView.swift` - split hero, agenda, inbox, and sample-data/onboarding cards.
- `MeetingDetailView.swift` - split detail routes and repeated cards by tab/section.
- `MeetingStore.swift` - split persistence, sample data, AI processing, export, and mutation APIs.
- `Models.swift` - split domain model families after storage compatibility is stable.
- `AuthViews.swift` - split onboarding, lock/sign-in, and shared auth atmosphere.
