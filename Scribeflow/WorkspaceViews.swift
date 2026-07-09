import SwiftUI

// MARK: - Ask (workspace-wide AI surface)

/// Top-level "Ask" tab. Lets the user ask questions across every saved
/// meeting and get a single grounded answer back. Designed as tab content —
/// the caller wraps in NavigationStack.
struct AskView: View {
    @Environment(MeetingStore.self) private var store

    @State private var prompt = ""
    @FocusState private var composerFocused: Bool
    @AppStorage("scribeflow.ask.includeTranscripts") private var includeTranscripts = true
    @AppStorage("scribeflow.ask.model") private var modelSelection: ChatModelSelection = .auto
    @AppStorage("scribeflow.ask.recents") private var recentsRaw = ""

    private var recentQuestions: [String] {
        recentsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func rememberQuestion(_ q: String) {
        var list = recentQuestions.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentsRaw = list.prefix(5).joined(separator: "\n")
    }
    @State private var turns: [AskTurn] = []
    @State private var hasAnimatedIn = false
    @State private var promptTask: Task<Void, Never>?
    @State private var copiedTurnID: AskTurn.ID?
    // Cached so typing in the composer doesn't re-scan every meeting per keystroke.
    @State private var cachedScope = ""
    @State private var cachedSuggestions: [(String, String)] = []

    private var isAnyRunning: Bool { turns.contains { $0.isRunning } }

    private var showClearButton: Bool {
        !isAnyRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stop an in-flight answer. Cancels the task and resolves the running turn
    /// so the UI doesn't hang on a spinner the user dismissed.
    private func cancelRun() {
        promptTask?.cancel()
        promptTask = nil
        if let idx = turns.lastIndex(where: { $0.isRunning }) {
            turns[idx].isRunning = false
            if turns[idx].answer == nil {
                turns[idx].answer = "Stopped before finishing."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            contextHeader.background(AppPalette.background)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty {
                            emptyPrompt
                                .motionEntrance(step: 0, active: hasAnimatedIn)
                        } else {
                            ForEach(turns) { turn in
                                turnView(turn, isLast: turn.id == turns.last?.id).id(turn.id)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .background(AppPalette.background.ignoresSafeArea())
                .onChange(of: turns.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(AppMotion.smooth) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: turns.last?.answer) { _, _ in
                    guard let id = turns.last?.id else { return }
                    withAnimation(AppMotion.smooth) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The root dock reserves the bottom safe-area inset, so the
            // composer only needs a little breathing room at rest.
            inputBar
                .padding(.bottom, composerFocused ? 0 : AppSpacing.xs)
                .animation(AppMotion.smooth, value: composerFocused)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("ask.view")
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !turns.isEmpty {
                    Button {
                        HapticEngine.tap(.light)
                        promptTask?.cancel()
                        withAnimation(AppMotion.smooth) { turns = [] }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.bubble")
                                .font(.caption.weight(.bold))
                            Text("New")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.accent)
                    }
                    .accessibilityLabel("Start a new conversation")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Use transcripts", isOn: $includeTranscripts)
                    Divider()
                    Picker("Model", selection: $modelSelection) {
                        ForEach(ChatModelSelection.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.medium))
                }
                .accessibilityLabel("Ask options")
            }
        }
        .onAppear { hasAnimatedIn = true; refreshAskDerived() }
        .onChange(of: store.revision) { refreshAskDerived() }
        .onDisappear { promptTask?.cancel(); promptTask = nil }
    }

    /// Recompute the meeting-derived header + suggestions only when the library
    /// changes, not on every keystroke in the composer.
    private func refreshAskDerived() {
        cachedScope = scopeSummary
        cachedSuggestions = smartSuggestions
    }

    // MARK: Header

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                EditorialEyebrow(text: "Across your library")
                Spacer(minLength: 8)
                AIModeBadge()
            }
            Text(cachedScope.isEmpty ? scopeSummary : cachedScope)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var scopeSummary: String {
        let total = store.meetings.count
        if total == 0 { return "Capture your first meeting to start asking." }
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let week = store.meetings.filter { $0.when >= weekStart }.count
        let weekPart = week == 0 ? "none yet this week" : "\(week) from this week"
        return "Searching \(total) meeting\(total == 1 ? "" : "s") · \(weekPart)"
    }

    // MARK: Empty state with smart, data-derived suggestions

    private var smartSuggestions: [(String, String)] {
        var out: [(String, String)] = []
        if let latest = store.meetings.sorted(by: Meeting.sortDescending).first(where: { !$0.title.isEmpty }) {
            out.append(("doc.text.magnifyingglass", "Summarize \(latest.title)"))
        }
        let accountabilityMeetings = store.meetings.filter { $0.allowsAccountabilityExtraction }
        let mineOwned = accountabilityMeetings.flatMap { $0.commitments }.contains { c in
            guard c.status == .open || c.status == .atRisk else { return false }
            let o = c.owner.lowercased()
            return o.contains("you") || o == "me" || o == "i"
        }
        if mineOwned { out.append(("person.fill", "What's owed to me right now?")) }
        if store.meetings.contains(where: \.isPinned) {
            out.append(("pin.fill", "What's the latest from my pinned meetings?"))
        }
        out.append(("checkmark.seal.fill", "What decisions did we make this week?"))
        if !accountabilityMeetings.isEmpty {
            out.append(("exclamationmark.triangle.fill", "What's at risk across every meeting?"))
        }
        return Array(out.prefix(5))
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                EditorialEyebrow(text: "Ask your library", tint: AppPalette.accent)
                Text("What do you want to know?")
                    .scaledFont(size: 28, weight: .medium, design: .serif, relativeTo: .title)
                    .foregroundStyle(AppPalette.ink)
                Text("Tap a suggestion — or type your own. Answers cite the meetings they came from.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            if store.meetings.isEmpty {
                askFirstRunHint
            } else {
            if !recentQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    EditorialEyebrow(text: "Recent")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentQuestions, id: \.self) { q in
                                Button {
                                    HapticEngine.tap(.light)
                                    runPrompt(q)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.caption2.weight(.bold))
                                        Text(q).font(.caption.weight(.semibold)).lineLimit(1)
                                    }
                                    .foregroundStyle(AppPalette.secondaryInk)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(AppPalette.softSurface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.7))
                                }
                                .buttonStyle(PressScaleButtonStyle(scale: 0.95))
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                EditorialEyebrow(text: "Try these · \(cachedSuggestions.count)")
                VStack(spacing: 0) {
                    let suggestions = Array(cachedSuggestions.enumerated())
                    ForEach(suggestions, id: \.offset) { index, item in
                        Button {
                            HapticEngine.tap(.light)
                            runPrompt(item.1)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.0)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(AppPalette.accent)
                                    .frame(width: 30, height: 30)
                                    .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                                Text(item.1)
                                    .scaledFont(size: 14, weight: .medium, design: .serif, relativeTo: .body)
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(AppPalette.tertiaryInk)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if index < suggestions.count - 1 {
                                    EditorialRule(inset: 56)
                                }
                            }
                        }
                        .buttonStyle(EditorialRowStyle(inset: 4))
                        .disabled(isAnyRunning)
                        .opacity(isAnyRunning ? 0.5 : 1)
                        .editorialReveal()
                    }
                }
                .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
                )
                .appShadow(AppShadow.soft)
            }
            }

            capabilityFooter
                .motionEntrance(step: 2, active: hasAnimatedIn)
        }
    }

    /// Shown when the library is empty — there's nothing to ask about yet, so
    /// point the user at capture instead of dangling meeting-shaped prompts.
    private var askFirstRunHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing to ask yet")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                    Text("Capture a meeting or voice note and Ask can answer across it.")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                HapticEngine.tap(.medium)
                PendingCaptureInbox.shared.requestStartRecord()
            } label: {
                Label("Capture your first meeting", systemImage: "waveform.badge.mic")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppPalette.accentButton, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.8)
        )
        .appShadow(AppShadow.soft)
    }

    /// Quiet "how Ask works" strip below the suggestions. Anchors the lower
    /// half of the empty state so it reads as composed rather than blank, and
    /// sets expectations: answers are grounded, cited, and stay on device.
    private var capabilityFooter: some View {
        let status = AIIntelligenceStatus.current
        return VStack(alignment: .leading, spacing: 10) {
            EditorialRule()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    capabilityChip("text.quote", "Cites every source")
                    capabilityChip(
                        status.isOnDevice ? "lock.shield.fill" : "magnifyingglass",
                        status.isOnDevice ? "Stays on device" : "Keyword match"
                    )
                    capabilityChip("arrow.turn.down.right", "Suggests follow-ups")
                }
            }
            .scrollClipDisabled()
        }
        .padding(.top, 4)
    }

    private func capabilityChip(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(AppPalette.secondaryInk)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(AppPalette.softSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.7))
    }

    // MARK: Conversation turns

    private func turnView(_ turn: AskTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Spacer(minLength: 36)
                Text(turn.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppPalette.accent.opacity(0.18), lineWidth: 0.8))
            }

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(AppPalette.accent)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 10) {
                    if turn.isRunning {
                        runningBlock
                    } else if let answer = turn.answer {
                        // Equatable: skips re-parsing the answer (regex) on
                        // unrelated re-renders such as typing in the input.
                        AnswerBody(answer: answer).equatable()

                        if !turn.citations.isEmpty {
                            AskCitationsCard(citations: turn.citations) { meetingID in
                                NotificationCenter.default.post(name: .scribeflowOpenMeeting, object: meetingID)
                            }
                        }

                        HStack(spacing: 12) {
                            let status = AIIntelligenceStatus.current
                            HStack(spacing: 4) {
                                Image(systemName: status.systemImage).font(.caption2.weight(.bold))
                                Text(status.isOnDevice ? "Apple Intelligence" : "Basic mode · keyword match")
                                    .font(.caption2.weight(.semibold))
                                Text("· \(turn.askedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(AppPalette.tertiaryInk)
                            Spacer()
                            let didCopy = copiedTurnID == turn.id
                            Button {
                                HapticEngine.notify(.success)
                                UIPasteboard.general.string = answer
                                withAnimation(AppMotion.snappy) { copiedTurnID = turn.id }
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    if copiedTurnID == turn.id {
                                        withAnimation(AppMotion.fade) { copiedTurnID = nil }
                                    }
                                }
                            } label: {
                                Label(didCopy ? "Copied" : "Copy",
                                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(didCopy ? AppPalette.accent : AppPalette.secondaryInk)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(didCopy ? "Copied" : "Copy answer")
                        }

                        if isLast {
                            followUpChips(for: turn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Follow-up suggestions

    /// One-tap follow-up questions shown under the latest answer so the user
    /// can drill deeper without retyping. Drops candidates that echo what was
    /// just asked so the chips always advance the conversation.
    private func followUps(for turn: AskTurn) -> [String] {
        guard turn.answer != nil, !turn.isRunning else { return [] }
        let asked = turn.question.lowercased()
        let pool = [
            "What are the action items?",
            "Who owns the next steps?",
            "What decisions were made?",
            "What's at risk?",
            "Summarize the key points",
            "What should I follow up on?"
        ]
        let echoes: [(String, String)] = [
            ("action", "action"), ("decision", "decision"), ("risk", "risk"),
            ("summar", "summar"), ("next step", "next step"), ("follow up", "follow up")
        ]
        return Array(
            pool.filter { candidate in
                let key = candidate.lowercased()
                return !echoes.contains { asked.contains($0.0) && key.contains($0.1) }
            }
            .prefix(3)
        )
    }

    @ViewBuilder
    private func followUpChips(for turn: AskTurn) -> some View {
        let suggestions = followUps(for: turn)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FOLLOW UP")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppPalette.tertiaryInk)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { question in
                            Button {
                                HapticEngine.tap(.light)
                                runPrompt(question)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2.weight(.bold))
                                    Text(question)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(AppPalette.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppPalette.accentSoft, in: Capsule())
                                .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.2), lineWidth: 0.7))
                            }
                            .buttonStyle(PressScaleButtonStyle(scale: 0.95))
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var runningBlock: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.8)
            Text("Thinking across your meetings…")
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.secondaryInk)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(AppPalette.border, lineWidth: 1))
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(AppPalette.divider.opacity(0.4))
            HStack(alignment: .bottom, spacing: 10) {
                TextField(turns.isEmpty ? "Ask anything about your meetings" : "Ask a follow-up — or anything", text: $prompt, axis: .vertical)
                    .focused($composerFocused)
                    .font(.subheadline)
                    .lineLimit(5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .padding(.trailing, showClearButton ? 26 : 0)
                    .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(AppPalette.border, lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if showClearButton {
                            Button {
                                HapticEngine.tap(.light)
                                prompt = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(AppPalette.tertiaryInk)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 10)
                            .padding(.bottom, 11)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityLabel("Clear")
                        }
                    }
                    .animation(AppMotion.fade, value: showClearButton)

                Button {
                    if isAnyRunning {
                        HapticEngine.tap(.light)
                        cancelRun()
                    } else {
                        HapticEngine.tap(.medium)
                        runPrompt(prompt)
                    }
                } label: {
                    let isSendDisabled = !isAnyRunning && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Image(systemName: isAnyRunning ? "stop.fill" : "arrow.up")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            isSendDisabled
                                ? AnyShapeStyle(AppPalette.secondaryInk.opacity(0.25))
                                : (isAnyRunning
                                    ? AnyShapeStyle(AppPalette.coral)
                                    : AnyShapeStyle(AppPalette.accentButton)),
                            in: Circle()
                        )
                        .overlay(Circle().strokeBorder(.white.opacity(isSendDisabled ? 0 : 0.2), lineWidth: 0.8))
                        .shadow(color: isSendDisabled ? .clear : (isAnyRunning ? AppPalette.coral : AppPalette.accent).opacity(0.3), radius: 8, y: 3)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.92))
                .disabled(!isAnyRunning && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(isAnyRunning ? "Stop" : "Send")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppPalette.paper)
        }
    }

    // MARK: Run

    private func runPrompt(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        rememberQuestion(cleaned)
        promptTask?.cancel()
        let turn = AskTurn(question: cleaned)
        let id = turn.id
        withAnimation(AppMotion.smooth) { turns.append(turn) }
        prompt = ""

        let snapshotMeetings = store.meetings
        promptTask = Task {
            async let response = store.answerAcrossMeetings(
                prompt: cleaned,
                includeTranscripts: includeTranscripts,
                modelSelection: modelSelection
            )
            // Keyword search can scan many transcripts — run it off the main
            // actor so the keyboard / UI never stalls while an answer resolves.
            let rag = await Task.detached(priority: .userInitiated) {
                LocalRAG.search(cleaned, in: snapshotMeetings, limit: 4)
            }.value
            let resolved = await response
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let idx = turns.firstIndex(where: { $0.id == id }) {
                    turns[idx].answer = resolved
                    turns[idx].citations = rag
                    turns[idx].isRunning = false
                }
                AnalyticsLog.shared.log("ask.run", ["resultCount": "\(rag.count)"])
            }
        }
    }
}

// MARK: - Rich answer presentation

/// The answer surface (key points + structured body). Equatable on the answer
/// string so SwiftUI skips its (regex-parsing) body whenever the answer hasn't
/// changed — keystrokes in the composer no longer reflow finished answers.
private struct AnswerBody: View, Equatable {
    let answer: String

    static func == (lhs: AnswerBody, rhs: AnswerBody) -> Bool { lhs.answer == rhs.answer }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnswerHighlights(answer: answer)
            StructuredAnswer(text: answer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(AppPalette.border, lineWidth: 1))
    }
}

/// Auto-extracted "Key points" callout — the headline facts (decisions,
/// risks, owners, numbers, deadlines) lifted out of the answer so the user
/// gets the gist before reading the prose.
private struct AnswerHighlights: View {
    let answer: String

    private static let cues = [
        "decid", "agreed", "approv", "risk", "block", "due", "deadline",
        "owner", "next step", "must", "should", "$", "%", "by friday",
        "by monday", "blocker"
    ]

    private var points: [String] {
        let lines = answer
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                String(line)
                    .replacingOccurrences(of: #"\[source:[^\]]*\]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^[\-\*•]\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.count > 24 }
        let hits = lines.filter { line in
            let low = line.lowercased()
            return Self.cues.contains { low.contains($0) }
        }
        return Array(hits.prefix(3))
    }

    var body: some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption2.weight(.bold))
                    Text("KEY POINTS").font(.caption2.weight(.bold)).tracking(1.0)
                }
                .foregroundStyle(AppPalette.accent)
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.accent)
                            .padding(.top, 2)
                        Text(point)
                            .scaledFont(size: 13, weight: .medium, relativeTo: .body)
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 0.8)
            )
        }
    }
}

/// Renders an answer with real structure: bullet and numbered lists, short
/// "subhead:" lines, and paragraphs — instead of one flat text blob. Inline
/// markdown is honored and `[source: …]` tags are lifted into a quiet caption.
private struct StructuredAnswer: View {
    let text: String

    private struct Line: Identifiable {
        let id = UUID()
        enum Kind: Equatable { case bullet, numbered(String), subhead, paragraph }
        let kind: Kind
        let content: AttributedString
        let source: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(parsed) { line in
                row(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        switch line.kind {
        case .subhead:
            Text(line.content)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.top, 2)
        case .bullet:
            markerRow("•", line)
        case .numbered(let n):
            markerRow(n, line)
        case .paragraph:
            body(for: line)
        }
    }

    private func markerRow(_ marker: String, _ line: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppPalette.accent)
                .frame(minWidth: 14, alignment: .leading)
            body(for: line)
        }
    }

    private func body(for line: Line) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.content)
                .scaledFont(size: 15.5, design: .serif, relativeTo: .body)
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let source = line.source {
                Text(source)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
        }
    }

    private var parsed: [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            var s = String(raw).trimmingCharacters(in: .whitespaces)

            var source: String?
            if let r = s.range(of: #"\[source:[^\]]*\]"#, options: .regularExpression) {
                source = "from " + s[r]
                    .replacingOccurrences(of: "[source:", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                s.removeSubrange(r)
                s = s.trimmingCharacters(in: .whitespaces)
            }

            if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ") {
                return Line(kind: .bullet, content: md(String(s.dropFirst(2))), source: source)
            }
            if let m = s.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let num = String(s[m]).trimmingCharacters(in: .whitespaces)
                s.removeSubrange(m)
                return Line(kind: .numbered(num), content: md(s), source: source)
            }
            if s.count < 48, s.hasSuffix(":") {
                return Line(kind: .subhead, content: md(s), source: source)
            }
            return Line(kind: .paragraph, content: md(s), source: source)
        }
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

struct AskTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: String? = nil
    var citations: [RAGResult] = []
    var isRunning: Bool = true
    let askedAt = Date()
}

// MARK: - Citation card

/// Renders RAG-retrieved source snippets under the AI answer so the user can
/// trust + tap through to the exact meeting where the answer came from.
struct AskCitationsCard: View {
    let citations: [RAGResult]
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources".uppercased())
                .font(.caption2.weight(.bold))
                .kerning(1.4)
                .foregroundStyle(AppPalette.secondaryInk)

            VStack(spacing: 0) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    Button {
                        HapticEngine.tap(.light)
                        onOpen(citation.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(AppPalette.accent, in: Circle())
                                Text(citation.meetingTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppPalette.secondaryInk.opacity(0.45))
                            }
                            Text(citation.snippet)
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .padding(.leading, 30)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleButtonStyle(scale: 0.985, opacity: 0.96))
                    if index < citations.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .background(AppPalette.paper, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8)
            )
        }
    }
}
