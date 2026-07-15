import Accelerate
import ActivityKit
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import Speech
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Live Activity

/// Attributes for the meeting-recording Live Activity. The widget extension
/// (when present) provides the `ActivityConfiguration` view that consumes
/// these values. The main app only starts / updates / ends activities.
///
/// **Setup note:** Live Activity UI requires a Widget Extension target with
/// an `ActivityConfiguration<MeetingRecordingAttributes>` view. Add via
/// File ▸ New ▸ Target ▸ Widget Extension, include both this app target's
/// shared types, and check "Include Live Activity" when prompted.
struct MeetingRecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock time when recording started; the widget formats elapsed
        /// from this rather than receiving a tick so it stays accurate while
        /// the app is backgrounded.
        var startedAt: Date
        /// 0…1 normalized recent input level for the waveform indicator.
        var inputLevel: Double
        /// True when the user has paused capture — widget switches icon.
        var isPaused: Bool
    }

    /// Title shown in the Live Activity / Dynamic Island. Captured at start
    /// so changes to the meeting title during recording don't ripple through
    /// the activity payload.
    var title: String
}

/// Thin wrapper around `Activity<MeetingRecordingAttributes>`. Silently no-ops
/// on devices where Live Activities are unsupported or disabled. Holds a
/// single active activity at a time.
@MainActor
final class MeetingRecordingLiveActivity {
    static let shared = MeetingRecordingLiveActivity()

    private var current: Activity<MeetingRecordingAttributes>?

    /// Begin a new activity. Returns silently if Live Activities are disabled
    /// in user settings or no widget extension is installed.
    func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end() // ensure only one at a time
        let attrs = MeetingRecordingAttributes(title: title.isEmpty ? "Recording" : title)
        let state = MeetingRecordingAttributes.ContentState(
            startedAt: .now,
            inputLevel: 0,
            isPaused: false
        )
        do {
            current = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            current = nil
        }
    }

    /// Push a fresh content update — input level + paused state.
    func update(inputLevel: Double, isPaused: Bool) {
        guard let current else { return }
        Task {
            let startedAt = current.content.state.startedAt
            await current.update(
                ActivityContent(
                    state: .init(startedAt: startedAt, inputLevel: inputLevel, isPaused: isPaused),
                    staleDate: nil
                )
            )
        }
    }

    /// End the activity immediately. Safe to call when no activity is active.
    func end() {
        guard let current else { return }
        let final = current
        Task {
            await final.end(nil, dismissalPolicy: .immediate)
        }
        self.current = nil
    }
}

enum CapturePermissionState: Equatable {
    case unknown
    case ready
    case denied
    case unsupported
}

enum LiveSpeechActivity: Equatable {
    case idle
    case listening
    case hearingSpeech
    case quietInput
}

enum LiveSpeechFeedback: Equatable {
    case permissionNeeded
    case microphoneBlocked
    case microphoneUnavailable
    case ready
    case listening
    case hearingSpeech
    case quietInput
    case paused
    case captionsUnavailable
    case finalizing
    case captured

    var title: String {
        switch self {
        case .permissionNeeded: "Tap to begin"
        case .microphoneBlocked: "Microphone blocked"
        case .microphoneUnavailable: "Microphone unavailable"
        case .ready: "Ready"
        case .listening: "Listening"
        case .hearingSpeech: "Hearing speech"
        case .quietInput: "Input is quiet"
        case .paused: "Paused"
        case .captionsUnavailable: "Audio is recording"
        case .finalizing: "Finishing last words"
        case .captured: "Recording secured"
        }
    }

    var detail: String {
        switch self {
        case .permissionNeeded: "Microphone access is requested when you start"
        case .microphoneBlocked: "Enable microphone access in Settings"
        case .microphoneUnavailable: "Connect an audio input and try again"
        case .ready: "Full audio and transcript stay together"
        case .listening: "Waiting for clear speech"
        case .hearingSpeech: "Draft captions are updating"
        case .quietInput: "No clear voice for a few seconds"
        case .paused: "Audio and captions are paused"
        case .captionsUnavailable: "Live captions unavailable · transcript rebuilds after Save"
        case .finalizing: "Keeping the final buffered phrase"
        case .captured: "Ready to Save · wording and voice labels refine in background"
        }
    }

    var systemImage: String {
        switch self {
        case .permissionNeeded: "hand.tap.fill"
        case .microphoneBlocked: "mic.slash.fill"
        case .microphoneUnavailable: "exclamationmark.triangle.fill"
        case .ready: "mic.fill"
        case .listening: "ear"
        case .hearingSpeech: "waveform.badge.mic"
        case .quietInput: "waveform.slash"
        case .paused: "pause.fill"
        case .captionsUnavailable: "waveform.badge.exclamationmark"
        case .finalizing: "ellipsis.circle.fill"
        case .captured: "checkmark.shield.fill"
        }
    }
}

enum CaptureSuggestionKind: Equatable {
    case core
    case optional
}

struct CaptureSuggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: CaptureSuggestionKind
}

struct CaptureBookmark: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
@Observable
final class LiveMeetingCoordinator {
    var title = "" { didSet { schedulePurposeRefresh() } }
    var workspace = "Personal workspace" { didSet { schedulePurposeRefresh() } }
    var objective = "" { didSet { schedulePurposeRefresh() } }
    var attendees = "" { didSet { schedulePurposeRefresh() } }
    var manualNotes = "" { didSet { schedulePurposeRefresh() } }
    var selectedTemplate: NoteTemplate = .discovery
    var transcriptText = ""
    var transcriptParagraphs: [String] = []
    var transcriptSegments: [TranscriptionSegment] = []
    var isFinalizingSpeech = false
    var speakerStatus: String?
    var meetingMode: MeetingMode = .privateNotes
    var consentState: ConsentState = .privateCapture
    var retentionPolicy: RetentionPolicy = .keepUntilDeleted
    var transcriptPanelVisible = false
    var hasConfirmedTrustSetup = false
    var suggestions: [CaptureSuggestion] = []
    var bookmarks: [CaptureBookmark] = []
    var catchUpSummary: String?
    var isGeneratingCatchUp = false
    var permissionState: CapturePermissionState = .unknown
    var recognitionLocaleIdentifier = SpeechRecognitionSupport.selectedLocaleIdentifier
    var expectedSpeakerCount: Int?
    var isRecording = false
    var isPaused = false
    var errorMessage: String?
    var elapsedSeconds = 0
    var inputLevel: Double = 0  // 0...1, RMS-normalized, updated from audio tap
    var speechActivity: LiveSpeechActivity = .idle
    private(set) var liveCaptionsAvailable = false
    var currentPurpose = CapturePurpose(
        kind: .personalNote,
        confidence: .conservative,
        evidence: [.privateCapture],
        domain: "Personal"
    )

    @ObservationIgnored
    private let audioEngine = AVAudioEngine()

    @ObservationIgnored
    private var speechSession: (any LiveSpeechTranscribing)?

    @ObservationIgnored
    private var audioWriter: TemporaryMeetingAudioWriter?

    @ObservationIgnored
    private var pendingAudioFileName: String?

    @ObservationIgnored
    private var purposeRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var timer: Timer?

    @ObservationIgnored
    private var acceptedFingerprints: Set<String> = []

    @ObservationIgnored
    private var dismissedFingerprints: Set<String> = []

    @ObservationIgnored
    private var pendingTranscriptUpdateTask: Task<Void, Never>?

    @ObservationIgnored
    private var speechContextUpdateTask: Task<Void, Never>?

    @ObservationIgnored
    private var captureGeneration = 0

    @ObservationIgnored
    private var lastAudibleInputAt: Date?

    /// Audio-thread-readable mirror of `isPaused`. Plain flag so the mic tap
    /// (which runs off the main actor) can check it without hopping actors.
    @ObservationIgnored
    nonisolated(unsafe) private var audioPaused = false

    /// The render callback is serial. Sampling every second 2,048-frame buffer
    /// keeps the visual meter near 10 Hz without flooding the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var audioMeterBufferCount = 0

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var canSave: Bool {
        !manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !transcriptParagraphs.isEmpty
        || pendingAudioFileName != nil
    }

    var hasPendingAudio: Bool { pendingAudioFileName != nil }

    var needsPermissionSettings: Bool {
        let permissions = VoiceRecordingPermissionService.current()
        return permissions.microphone == .denied || permissions.speech == .denied
    }

    var recognitionLanguageTitle: String {
        SpeechRecognitionSupport.displayName(for: recognitionLocale)
    }

    var recognitionLocale: Locale {
        SpeechRecognitionSupport.resolvedLocale(identifier: recognitionLocaleIdentifier)
    }

    var expectedSpeakerCountTitle: String {
        expectedSpeakerCount.map { "\($0) voice\($0 == 1 ? "" : "s")" } ?? "Auto voices"
    }

    var speechFeedback: LiveSpeechFeedback {
        if isFinalizingSpeech { return .finalizing }
        if !isRecording, hasPendingAudio { return .captured }
        guard isRecording else {
            switch permissionState {
            case .unknown:
                return .permissionNeeded
            case .ready:
                return .ready
            case .denied:
                return .microphoneBlocked
            case .unsupported:
                return .microphoneUnavailable
            }
        }
        if isPaused { return .paused }
        if !liveCaptionsAvailable { return .captionsUnavailable }

        switch speechActivity {
        case .idle, .listening:
            return .listening
        case .hearingSpeech:
            return .hearingSpeech
        case .quietInput:
            return .quietInput
        }
    }

    func prepare() async {
        let permissions = VoiceRecordingPermissionService.current()
        switch permissions.microphone {
        case .ready:
            permissionState = .ready
            switch permissions.speech {
            case .denied, .unsupported:
                speakerStatus = "Recording is ready · live captions need Speech Recognition access"
                errorMessage = "Scribeflow will keep the audio. Enable Speech Recognition to generate its transcript."
            case .unknown, .ready:
                errorMessage = nil
            }
        case .denied:
            permissionState = .denied
            errorMessage = "Microphone access is blocked. Enable it in Settings to record a meeting."
        case .unsupported:
            permissionState = .unsupported
            errorMessage = "No microphone input is available. Connect an audio input and try again."
        case .unknown:
            permissionState = .unknown
            errorMessage = nil
        }
    }

    func selectRecognitionLocale(identifier: String?) {
        guard !isRecording, !isFinalizingSpeech else { return }
        let cleaned = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionLocaleIdentifier = cleaned?.isEmpty == false ? cleaned : nil
        SpeechRecognitionSupport.persistSelectedLocale(identifier: recognitionLocaleIdentifier)
    }

    func selectExpectedSpeakerCount(_ count: Int?) {
        guard !isRecording, !isFinalizingSpeech else { return }
        expectedSpeakerCount = count.map { min(max($0, 1), 8) }
    }

    func requestPermissions() async {
        let hasSpeechRecognizer: Bool
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            hasSpeechRecognizer = true
        } else {
            hasSpeechRecognizer = SpeechRecognitionSupport.makeLegacyRecognizer(
                locale: recognitionLocale
            ) != nil
        }

        let microphoneAllowed = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard microphoneAllowed else {
            permissionState = .denied
            errorMessage = "Please allow microphone access in Settings to record a meeting."
            return
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if hasSpeechRecognizer {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            speechStatus = .denied
        }

        permissionState = .ready
        if speechStatus == .authorized, hasSpeechRecognizer {
            errorMessage = nil
        } else {
            speakerStatus = "Recording is available · live captions need Speech Recognition access"
            errorMessage = "Scribeflow will keep the audio. Enable Speech Recognition to generate its transcript."
        }
    }

    func startCapture() async {
        stopCapture()
        captureGeneration &+= 1
        let generation = captureGeneration

        if permissionState != .ready {
            await requestPermissions()
        }

        guard generation == captureGeneration, permissionState == .ready else { return }
        transcriptText = ""
        transcriptParagraphs = []
        transcriptSegments = []
        speakerStatus = nil
        isFinalizingSpeech = false
        suggestions = []
        bookmarks = []
        catchUpSummary = nil
        elapsedSeconds = 0
        inputLevel = 0
        speechActivity = .listening
        liveCaptionsAvailable = false
        lastAudibleInputAt = nil
        audioMeterBufferCount = 0
        errorMessage = nil
        isPaused = false
        audioPaused = false
        acceptedFingerprints.removeAll()
        dismissedFingerprints.removeAll()

        do {
            try configureAudioSession()
            let inputNode = audioEngine.inputNode

            // The long-form speech model is trained for meeting and distant
            // audio. Preserve the natural microphone signal instead of applying
            // voice-call echo suppression, which can clip quiet words.
            if inputNode.isVoiceProcessingEnabled {
                try inputNode.setVoiceProcessingEnabled(false)
            }

            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                errorMessage = "Audio input is unavailable. Check microphone access or try reconnecting audio."
                return
            }
            let audioWriter = try TemporaryMeetingAudioWriter(format: format)
            self.audioWriter = audioWriter

            let context = recognitionContext()
            let session: (any LiveSpeechTranscribing)?
            do {
                session = try await SpeechRecognitionPipeline.makeLiveSession(
                    inputFormat: format,
                    context: context,
                    onTranscript: { [weak self] text, isFinal in
                        guard self?.captureGeneration == generation else { return }
                        self?.handleTranscriptUpdate(text, isFinal: isFinal)
                    },
                    onError: { [weak self] message in
                        guard let self, self.captureGeneration == generation else { return }
                        self.preserveRecordingAfterSpeechFailure(message)
                    }
                )
            } catch {
                session = nil
                preserveRecordingAfterSpeechFailure(error.localizedDescription)
            }
            guard generation == captureGeneration else {
                session?.cancel()
                return
            }
            speechSession = session
            liveCaptionsAvailable = session != nil
            let audioSink = session?.audioSink

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self, audioSink, audioWriter] buffer, _ in
                guard let self else { return }
                // While soft-paused, drop audio so the transcript and level
                // freeze without tearing down the engine (instant resume).
                guard !self.audioPaused else { return }
                audioSink?.append(buffer)
                audioWriter.append(buffer)
                self.computeAndPublishLevel(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            startTimer()
            updateNowPlaying(isLive: true)
            MeetingRecordingLiveActivity.shared.start(title: title)
        } catch {
            errorMessage = "Unable to start live capture: \(error.localizedDescription)"
            stopCapture()
        }
    }

    /// Soft-pause: freeze the transcript, level, and timer without tearing the
    /// engine down, so resume is instant and seamless.
    func pauseCapture() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        audioPaused = true
        inputLevel = 0
        speechActivity = .idle
        lastAudibleInputAt = nil
        updateNowPlaying(isLive: false)
        MeetingRecordingLiveActivity.shared.update(inputLevel: 0, isPaused: true)
    }

    func resumeCapture() {
        guard isRecording, isPaused else { return }
        isPaused = false
        audioPaused = false
        speechActivity = .listening
        lastAudibleInputAt = nil
        updateNowPlaying(isLive: true)
    }

    func stopCapture() {
        beginStoppingCapture()
        stopAudioInput()
        speechSession?.cancel()
        speechSession = nil
        audioWriter?.discard()
        audioWriter = nil
        if let pendingAudioFileName {
            PendingMeetingAudioStore.delete(pendingAudioFileName)
            self.pendingAudioFileName = nil
        }
        isFinalizingSpeech = false
        deactivateAudioSession()
    }

    func finishCapture() async {
        guard isRecording || speechSession != nil || audioWriter != nil else { return }

        let writer = audioWriter
        let session = speechSession
        audioWriter = nil
        speechSession = nil
        stopAudioInput()
        isFinalizingSpeech = true
        speakerStatus = "Finishing the last words"
        beginStoppingCapture()
        deactivateAudioSession()
        defer { isFinalizingSpeech = false }

        // Flush the audio file while Speech finishes its buffered tail. The
        // previous cancel path could drop the final phrase, especially with
        // progressive transcription results.
        let audioFinalization = Task { [writer] in
            await writer?.finish()
        }
        let finalizedTranscript = await session?.finish() ?? ""
        let cleanedTranscript = finalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTranscript.isEmpty {
            applyTranscriptUpdate(cleanedTranscript)
        }

        guard let temporaryURL = await audioFinalization.value else {
            speakerStatus = "The live transcript is ready to save."
            return
        }
        do {
            pendingAudioFileName = try PendingMeetingAudioStore.adopt(temporaryURL)
            speakerStatus = "Recording secured · Save to refine wording and voice labels"
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            speakerStatus = "The live transcript is ready, but enhanced processing is unavailable."
        }
    }

    func refreshRecognitionContext() {
        guard isRecording, let speechSession else { return }
        let context = recognitionContext()
        speechContextUpdateTask?.cancel()
        speechContextUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await speechSession.updateContext(context)
        }
    }

    private func beginStoppingCapture() {
        captureGeneration &+= 1
        isRecording = false
        isPaused = false
        audioPaused = false
        audioMeterBufferCount = 0
        inputLevel = 0
        speechActivity = .idle
        liveCaptionsAvailable = false
        lastAudibleInputAt = nil
        clearNowPlaying()
        MeetingRecordingLiveActivity.shared.end()
        timer?.invalidate()
        timer = nil
        pendingTranscriptUpdateTask?.cancel()
        pendingTranscriptUpdateTask = nil
        speechContextUpdateTask?.cancel()
        speechContextUpdateTask = nil
    }

    private func stopAudioInput() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func deactivateAudioSession() {
        AudioSessionManager.shared.stopObserving()
        AudioSessionManager.shared.deactivate()
    }

    func acceptSuggestion(_ suggestion: CaptureSuggestion) {
        let bullet = suggestion.text.hasPrefix("- ") ? suggestion.text : "- \(suggestion.text)"
        let fingerprint = fingerprint(for: suggestion.text)

        if !noteFingerprints(from: manualNotes).contains(fingerprint) {
            if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualNotes = bullet
            } else {
                manualNotes += "\n\(bullet)"
            }
        }

        acceptedFingerprints.insert(fingerprint)
        suggestions.removeAll { $0.id == suggestion.id }
        refreshSuggestions()
    }

    func dismissSuggestion(_ suggestion: CaptureSuggestion) {
        dismissedFingerprints.insert(fingerprint(for: suggestion.text))
        suggestions.removeAll { $0.id == suggestion.id }
        refreshSuggestions()
    }

    private func schedulePurposeRefresh() {
        purposeRefreshTask?.cancel()
        purposeRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.refreshPurposeUnderstanding()
        }
    }

    func refreshPurposeUnderstanding() {
        purposeRefreshTask?.cancel()
        purposeRefreshTask = nil
        let participantNames = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let speakerCount = Set(transcriptSegments.compactMap { segment -> String? in
            let speaker = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return speaker.isEmpty ? nil : speaker
        }).count

        currentPurpose = MeetingPurposeClassifier.standard.classifyCapture(
            title: title,
            workspace: workspace,
            objective: objective,
            attendees: participantNames,
            notes: manualNotes,
            transcriptParagraphs: Array(transcriptParagraphs.suffix(40)),
            distinctSpeakerCount: speakerCount,
            meetingMode: meetingMode,
            consentState: consentState
        )
    }

    func applyMeetingMode(_ mode: MeetingMode) {
        meetingMode = mode
        hasConfirmedTrustSetup = true

        switch mode {
        case .privateNotes:
            consentState = .privateCapture
            retentionPolicy = .notesOnly
            transcriptPanelVisible = false
        case .internalShared:
            consentState = .disclosedInternal
            retentionPolicy = .transcript7Days
        case .clientSafeRecap:
            consentState = .disclosedExternal
            retentionPolicy = .transcript24Hours
            transcriptPanelVisible = false
        }
        refreshPurposeUnderstanding()
    }

    func saveMeeting(into store: MeetingStore, calendarEvent: CalendarEventSnapshot? = nil) async -> Meeting.ID {
        let normalizedAttendees = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let eventAttendees = calendarEvent?.attendees ?? []
        let mergedAttendees = normalizedAttendees.isEmpty ? eventAttendees : normalizedAttendees

        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled capture" : title
        let resolvedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Personal workspace"
            : workspace
        let resolvedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Understand and organize what matters."
            : objective

        if let fileName = pendingAudioFileName {
            let durationMinutes = max(1, Int(ceil(Double(elapsedSeconds) / 60.0)))
            let capturedAt = Date.now.addingTimeInterval(-Double(elapsedSeconds))
            let pending = store.addPendingLiveMeeting(
                title: resolvedTitle,
                workspace: resolvedWorkspace,
                attendees: mergedAttendees,
                objective: resolvedObjective,
                notes: manualNotes,
                moments: bookmarks.map(\.text),
                transcriptParagraphs: transcriptParagraphs,
                transcriptionSegments: transcriptSegments,
                when: capturedAt,
                durationMinutes: durationMinutes,
                selectedTemplate: selectedTemplate,
                meetingMode: meetingMode,
                consentState: consentState,
                retentionPolicy: retentionPolicy,
                calendarEventID: calendarEvent?.id,
                calendarStartDate: calendarEvent?.startDate,
                calendarEndDate: calendarEvent?.endDate
            )
            let job = PendingMeetingProcessingJob(
                meetingID: pending.id,
                fileName: fileName,
                context: recognitionContext(includeLiveVocabulary: true),
                capturedNotes: manualNotes,
                pendingNotes: pending.pendingNotes,
                moments: bookmarks.map(\.text),
                liveWordCount: transcriptParagraphs.reduce(0) {
                    $0 + $1.split(whereSeparator: \.isWhitespace).count
                },
                recovery: PendingMeetingRecoveryPayload(
                    title: resolvedTitle,
                    workspace: resolvedWorkspace,
                    attendees: mergedAttendees,
                    objective: resolvedObjective,
                    liveTranscript: transcriptParagraphs.joined(separator: "\n"),
                    capturedAt: capturedAt,
                    durationMinutes: durationMinutes,
                    durationSeconds: max(1, elapsedSeconds),
                    selectedTemplate: selectedTemplate,
                    meetingMode: meetingMode,
                    consentState: consentState,
                    retentionPolicy: retentionPolicy,
                    calendarEventID: calendarEvent?.id,
                    calendarStartDate: calendarEvent?.startDate,
                    calendarEndDate: calendarEvent?.endDate
                )
            )
            _ = await MeetingProcessingCoordinator.shared.enqueue(job, using: store)
            pendingAudioFileName = nil
            return pending.id
        }

        let id = await store.addLiveMeeting(
            title: resolvedTitle,
            workspace: resolvedWorkspace,
            attendees: mergedAttendees,
            objective: resolvedObjective,
            notes: manualNotes,
            moments: bookmarks.map(\.text),
            transcriptParagraphs: transcriptParagraphs,
            transcriptionSegments: transcriptSegments,
            meetingMode: meetingMode,
            consentState: consentState,
            retentionPolicy: retentionPolicy,
            calendarEventID: calendarEvent?.id,
            calendarStartDate: calendarEvent?.startDate,
            calendarEndDate: calendarEvent?.endDate
        )
        store.selectTemplate(selectedTemplate, for: id)
        return id
    }

    func bookmarkCurrentMoment() {
        let source = suggestions.first?.text
            ?? transcriptParagraphs.last
            ?? manualNotes
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty })

        guard let source else { return }

        let normalized = cleanSentence(source)
        let bookmarkText = normalized
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "Bookmark:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bookmarkText.isEmpty else { return }

        let fingerprint = self.fingerprint(for: bookmarkText)
        let existingFingerprints = Set(bookmarks.map { self.fingerprint(for: $0.text) })
        guard !existingFingerprints.contains(fingerprint) else { return }

        bookmarks.insert(CaptureBookmark(text: bookmarkText), at: 0)
    }

    func removeBookmark(_ bookmark: CaptureBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    func generateCatchUp() async {
        let notes = manualNotes

        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !transcriptParagraphs.isEmpty || !bookmarks.isEmpty else {
            catchUpSummary = "Capture a little more context first, then Scribeflow can organize what matters."
            return
        }

        isGeneratingCatchUp = true
        defer { isGeneratingCatchUp = false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch AppleIntelligenceLiveAssistant.availability() {
            case .available:
                do {
                    catchUpSummary = try await AppleIntelligenceLiveAssistant.catchUp(
                        title: title,
                        objective: objective,
                        notes: notes,
                        transcriptParagraphs: transcriptParagraphs,
                        purpose: currentPurpose.kind
                    )
                    return
                } catch {
                    break
                }
            default:
                break
            }
        }
        #endif

        catchUpSummary = fallbackCatchUp(notes: notes, transcriptParagraphs: transcriptParagraphs)
    }

    private func handleTranscriptUpdate(_ text: String, isFinal: Bool) {
        noteAudibleSpeech()
        pendingTranscriptUpdateTask?.cancel()

        if isFinal {
            applyTranscriptUpdate(text)
            return
        }

        let candidate = text
        pendingTranscriptUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.applyTranscriptUpdate(candidate)
        }
    }

    private func applyTranscriptUpdate(_ text: String) {
        guard text != transcriptText else { return }
        transcriptText = text
        transcriptParagraphs = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { cleanSentence($0) }
            .filter { !$0.isEmpty }
        refreshPurposeUnderstanding()
        refreshSuggestions()
        autoSuggestTitleIfNeeded()
    }

    private func preserveRecordingAfterSpeechFailure(_ message: String) {
        speechSession?.cancel()
        speechSession = nil
        liveCaptionsAvailable = false
        speakerStatus = "Recording continues safely · live captions will be rebuilt after Save"
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = detail.isEmpty
            ? "Live captions paused. The full recording is still being captured."
            : "Live captions paused: \(detail) The full recording is still being captured."
    }

    private func applyFinalTranscriptionResult(_ result: TranscriptionResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        transcriptText = text
        transcriptSegments = SpeakerIdentityResolver.normalizedSegments(result.segments)
        if transcriptSegments.isEmpty {
            transcriptParagraphs = text
                .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { cleanSentence($0) }
                .filter { !$0.isEmpty }
        } else {
            transcriptParagraphs = transcriptSegments.map(\.text)
        }

        if result.diarizationAvailable {
            let speakerCount = Set(transcriptSegments.map {
                SpeakerIdentityResolver.canonicalKey(for: $0.speaker)
            }).filter { !$0.isEmpty }.count
            speakerStatus = speakerCount == 1
                ? "1 speaker detected on device"
                : "\(speakerCount) speakers detected on device"
        } else {
            speakerStatus = "Transcript refined. Speaker separation was unavailable."
        }
        refreshPurposeUnderstanding()
        refreshSuggestions()
        autoSuggestTitleIfNeeded()
    }

    private func recognitionContext(includeLiveVocabulary: Bool = false) -> SpeechRecognitionContext {
        let participantNames = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SpeechRecognitionContext(
            title: title,
            workspace: workspace,
            objective: objective,
            attendees: participantNames,
            notes: manualNotes,
            templateTitle: selectedTemplate.title,
            templateGuidance: "\(selectedTemplate.description) \(selectedTemplate.aiHint)",
            vocabulary: includeLiveVocabulary ? finalPassVocabulary : [],
            localeIdentifier: recognitionLocale.identifier,
            expectedSpeakerCount: expectedSpeakerCount
        )
    }

    private var finalPassVocabulary: [String] {
        let stopWords: Set<String> = [
            "about", "after", "because", "before", "could", "meeting", "should",
            "their", "there", "these", "they", "this", "through", "today", "would"
        ]
        let tokens = transcriptParagraphs
            .joined(separator: " ")
            .components(separatedBy: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "+#.'-"))
                .inverted)
            .filter { $0.count >= 3 }
        var seen: Set<String> = []

        return tokens.compactMap { token in
            let lower = token.lowercased()
            guard !stopWords.contains(lower) else { return nil }
            let isDistinctive = token != lower
                || token.rangeOfCharacter(from: .decimalDigits) != nil
                || token.contains("+")
                || token.contains("#")
                || token.contains("-")
                || token.count >= 9
            guard isDistinctive, seen.insert(lower).inserted else { return nil }
            return String(token.prefix(48))
        }
        .prefix(40)
        .map { $0 }
    }

    /// When the user hasn't typed a title yet and we have meaningful
    /// transcript content, derive a 4-6 word working title from the first
    /// paragraph. Stays out of the way once user has typed anything.
    private func autoSuggestTitleIfNeeded() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmed.isEmpty
            || trimmed == "New capture"
            || trimmed == "Live meeting"
            || trimmed == "Meeting"
            || trimmed == "Untitled note"
        guard isPlaceholder else { return }
        guard let firstParagraph = transcriptParagraphs.first,
              firstParagraph.split(separator: " ").count >= 4 else { return }
        let suggested = suggestedMeetingTitle(
            objective: objective,
            notes: firstParagraph,
            fallback: "Capture"
        )
        guard !suggested.isEmpty, suggested != trimmed else { return }
        title = suggested
    }

    private func fallbackCatchUp(notes: String, transcriptParagraphs: [String]) -> String {
        let noteLines = notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)

        let transcriptLines = transcriptParagraphs.suffix(2)
        var bullets: [String] = []

        if let first = noteLines.first {
            bullets.append("- \(cleanSentence(first)).")
        }

        if noteLines.count > 1 {
            bullets.append("- \(cleanSentence(String(noteLines.dropFirst().first ?? ""))).")
        } else if let lastTranscript = transcriptLines.last {
            bullets.append("- \(cleanSentence(lastTranscript)).")
        }

        if let earlierTranscript = transcriptLines.first,
           transcriptLines.count > 1 {
            bullets.append("- \(cleanSentence(earlierTranscript)).")
        }

        return bullets.isEmpty
            ? "Scribeflow is listening, but there isn’t enough detail yet for a useful catch-up."
            : bullets.joined(separator: "\n")
    }

    private func refreshSuggestions() {
        let candidateTexts = rankedCandidateBullets(from: transcriptParagraphs)
        let noteFingerprints = noteFingerprints(from: manualNotes)
        var uniqueBullets: [String] = []
        var seenFingerprints: Set<String> = []

        for candidate in candidateTexts {
            let candidateFingerprint = fingerprint(for: candidate)

            guard !candidateFingerprint.isEmpty else { continue }
            guard !acceptedFingerprints.contains(candidateFingerprint) else { continue }
            guard !dismissedFingerprints.contains(candidateFingerprint) else { continue }
            guard !noteFingerprints.contains(candidateFingerprint) else { continue }
            guard !seenFingerprints.contains(candidateFingerprint) else { continue }

            seenFingerprints.insert(candidateFingerprint)
            uniqueBullets.append(candidate)
        }

        var refreshed: [CaptureSuggestion] = []

        if uniqueBullets.count >= 3 {
            refreshed.append(contentsOf: uniqueBullets.prefix(2).map { CaptureSuggestion(text: $0, kind: .core) })
            refreshed.append(CaptureSuggestion(text: uniqueBullets[2], kind: .optional))
        } else {
            refreshed.append(contentsOf: uniqueBullets.prefix(2).map { CaptureSuggestion(text: $0, kind: .core) })
        }

        suggestions = refreshed
    }

    private func rankedCandidateBullets(from paragraphs: [String]) -> [String] {
        let purpose = currentPurpose.kind
        let weightedTerms = purpose.allowsMeetingSignals
            ? SignalWeights.terms
            : [
                ("important", 4), ("remember", 4), ("realized", 4), ("idea", 4),
                ("because", 2), ("learned", 4), ("noticed", 3), ("question", 2),
                ("feel", 2), ("plan", 3), ("means", 2), ("example", 2)
            ]

        let recentParagraphs = Array(paragraphs.suffix(12))

        let scored = recentParagraphs.compactMap { paragraph -> (text: String, score: Int)? in
            guard paragraph.count > 28 else { return nil }

            let lower = paragraph.lowercased()
            var score = 1

            for (term, weight) in weightedTerms where lower.contains(term) {
                score += weight
            }

            if paragraph.rangeOfCharacter(from: .decimalDigits) != nil {
                score += 1
            }

            return (noteBullet(from: paragraph, purpose: purpose), score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.text.count < rhs.text.count
                }
                return lhs.score > rhs.score
            }
            .map(\.text)
    }

    private func noteBullet(from sentence: String, purpose: CapturePurposeKind) -> String {
        let cleaned = cleanSentence(sentence)
        let lower = cleaned.lowercased()

        if !purpose.allowsMeetingSignals {
            switch purpose {
            case .reflection: return "Reflection: \(cleaned)"
            case .idea: return "Idea: \(cleaned)"
            case .personalPlan: return "Plan: \(cleaned)"
            case .conversation: return "Highlight: \(cleaned)"
            case .appointment: return "Remember: \(cleaned)"
            case .learning: return "Takeaway: \(cleaned)"
            case .personalNote: return cleaned
            case .meeting, .call: break
            }
        }

        if lower.contains("next") || lower.contains("follow up") || lower.contains("owner") {
            return "Next step: \(cleaned)"
        }

        if lower.contains("need") || lower.contains("needs") || lower.contains("must") {
            return "Need: \(cleaned)"
        }

        if lower.contains("budget") || lower.contains("price") {
            return "Budget signal: \(cleaned)"
        }

        if lower.contains("timeline") || lower.contains("quarter") || lower.contains("launch") {
            return "Timing: \(cleaned)"
        }

        if lower.contains("risk") || lower.contains("issue") || lower.contains("problem") || lower.contains("security") {
            return "Risk: \(cleaned)"
        }

        return cleaned
    }

    private func cleanSentence(_ sentence: String) -> String {
        sentence
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noteFingerprints(from notes: String) -> Set<String> {
        Set(
            notes
                .split(whereSeparator: \.isNewline)
                .map { fingerprint(for: String($0)) }
                .filter { !$0.isEmpty }
        )
    }

    private func fingerprint(for text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "need: ", with: "")
            .replacingOccurrences(of: "next step: ", with: "")
            .replacingOccurrences(of: "budget signal: ", with: "")
            .replacingOccurrences(of: "timing: ", with: "")
            .replacingOccurrences(of: "risk: ", with: "")
            .replacingOccurrences(of: "reflection: ", with: "")
            .replacingOccurrences(of: "idea: ", with: "")
            .replacingOccurrences(of: "plan: ", with: "")
            .replacingOccurrences(of: "highlight: ", with: "")
            .replacingOccurrences(of: "remember: ", with: "")
            .replacingOccurrences(of: "takeaway: ", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isPaused else { return }
                self.elapsedSeconds += 1
                self.refreshSpeechActivity()
                // Refresh elapsed time on Lock Screen / Control Center every 5s
                if self.elapsedSeconds % 5 == 0 {
                    self.updateNowPlaying(isLive: true)
                    MeetingRecordingLiveActivity.shared.update(
                        inputLevel: self.inputLevel,
                        isPaused: false
                    )
                }
            }
        }
    }

    /// Push current recording state into the system Now Playing center so
    /// the Lock Screen + Control Center show "Scribeflow — Recording …"
    /// with elapsed time. The user can glance without unlocking. This does
    /// not surface playback transport controls because we aren't a media
    /// player; we're using NPIC purely as a status surface tied to the
    /// background-audio session.
    private func updateNowPlaying(isLive: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Live capture"
            : title
        info[MPMediaItemPropertyArtist] = "Scribeflow"
        info[MPMediaItemPropertyPlaybackDuration] = TimeInterval(elapsedSeconds + 1)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = TimeInterval(elapsedSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isLive ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        center.nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func configureAudioSession() throws {
        let mgr = AudioSessionManager.shared
        mgr.startObserving()

        // Resume capture automatically after an interruption (e.g. Siri, alarm).
        mgr.onInterruptionEnded = { [weak self] in
            guard let self, self.isRecording else { return }
            try? await self.restartEngineAfterInterruption()
        }

        // Pause then resume when headphones are unplugged mid-meeting.
        mgr.onRouteChanged = { [weak self] reason in
            guard let self else { return }
            if reason == .oldDeviceUnavailable {
                // Headphones/AirPods disconnected — engine output changed.
                // Remove tap and reinstall on the new route.
                Task { @MainActor [weak self] in
                    self?.handleRouteDisconnect()
                }
            }
        }

        try mgr.configureForLiveMeeting()
    }

    private func restartEngineAfterInterruption() async throws {
        // Session was reactivated by AudioSessionManager after interruption.
        // Restart the engine — the tap and recognition request are still live.
        guard audioEngine.isRunning == false else { return }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated func computeAndPublishLevel(_ buffer: AVAudioPCMBuffer) {
        audioMeterBufferCount &+= 1
        guard audioMeterBufferCount >= 2 else { return }
        audioMeterBufferCount = 0

        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(frames))
        let normalized = min(max(Double(rms) * 12, 0), 1)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A small low-pass filter removes visual chatter without scheduling
            // overlapping SwiftUI animations for every audio sample.
            self.inputLevel = (self.inputLevel * 0.35) + (normalized * 0.65)
            if normalized >= 0.08 {
                self.noteAudibleSpeech()
            }
        }
    }

    private func noteAudibleSpeech() {
        guard isRecording, !isPaused else { return }
        lastAudibleInputAt = .now
        if speechActivity != .hearingSpeech {
            speechActivity = .hearingSpeech
        }
    }

    private func refreshSpeechActivity(now: Date = .now) {
        guard isRecording, !isPaused else { return }
        guard let lastAudibleInputAt else {
            if elapsedSeconds >= 3, speechActivity != .quietInput {
                speechActivity = .quietInput
            }
            return
        }

        let next: LiveSpeechActivity = now.timeIntervalSince(lastAudibleInputAt) > 2.5
            ? .quietInput
            : .hearingSpeech
        if speechActivity != next {
            speechActivity = next
        }
    }

    private func handleRouteDisconnect() {
        guard audioEngine.isRunning else { return }
        let audioSink = speechSession?.audioSink
        let audioWriter = self.audioWriter
        guard audioWriter != nil else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self, audioSink, audioWriter] buffer, _ in
            guard let self, !self.audioPaused else { return }
            audioSink?.append(buffer)
            audioWriter?.append(buffer)
            self.computeAndPublishLevel(buffer)
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleIntelligenceLiveAssistant {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func catchUp(
        title: String,
        objective: String,
        notes: String,
        transcriptParagraphs: [String],
        purpose: CapturePurposeKind
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You are a live capture assistant inside a private note-taking app.
        Generate a short catch-up that matches the actual capture purpose: \(purpose.title).
        Return exactly 3 concise bullet points.
        For a work meeting or structured call, focus on where the discussion stands,
        the most important supported outcome, and an explicit action or question.
        For every other purpose, summarize the central thought, the most useful
        supporting detail, and one thing worth remembering. Do not introduce work
        language such as decisions, owners, risks, or action items.
        Do not invent facts that are not supported by the notes or transcript.
        """)

        let transcriptContext = transcriptParagraphs.suffix(8).joined(separator: "\n")
        let prompt = """
        Capture title: \(title)
        Objective: \(objective)

        Rough notes:
        \(notes.isEmpty ? "No rough notes yet." : notes)

        Transcript context:
        \(transcriptContext.isEmpty ? "No transcript context yet." : transcriptContext)

        Write the catch-up now.
        """

        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
