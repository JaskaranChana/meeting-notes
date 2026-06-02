import SwiftUI
import ActivityKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Source Cited Chat (Tier 1)

struct SourceCitedChatView: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(messages) { msg in
                                    ChatBubble(message: msg, transcript: meeting.transcript)
                                        .id(msg.id)
                                }
                                if isLoading {
                                    loadingBubble
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .onChange(of: messages.count) {
                            withAnimation { proxy.scrollTo(messages.last?.id) }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }

                if !messages.isEmpty {
                    Divider()
                    suggestionStrip
                }
                chatInputBar
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Chat with Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .tint(AppPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AIModeBadge()
                }
            }
            .onAppear { inputFocused = true }
            .onDisappear {
                sendTask?.cancel()
                sendTask = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "quote.bubble.fill")
                    .scaledFont(size: 36, weight: .regular, relativeTo: .largeTitle)
                    .foregroundStyle(AppPalette.accent.opacity(0.7))
                Text("Ask your notes anything")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("Every answer links back to the exact source in this meeting.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            suggestedQuestions
        }
    }

    private var suggestedQuestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUGGESTED")
                .font(.caption.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(AppPalette.secondaryInk.opacity(0.7))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestedQs, id: \.self) { q in
                        Button {
                            query = q
                            send()
                        } label: {
                            Text(q)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppPalette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppPalette.cardBackground, in: Capsule())
                                .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.8))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var suggestedQs: [String] {
        var qs = ["What was decided?", "What are my action items?", "What risks were raised?"]
        if !meeting.attendees.isEmpty {
            qs.append("What did \(meeting.attendees.first ?? "they") commit to?")
        }
        return qs
    }

    // Compact suggestion strip shown above input regardless of chat state.
    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestedQs, id: \.self) { q in
                    Button {
                        HapticEngine.tap(.light)
                        query = q
                        send()
                    } label: {
                        Text(q)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(AppPalette.softSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var chatInputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything about this meeting…", text: $query, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(query.trimmingCharacters(in: .whitespaces).isEmpty ? AppPalette.border : AppPalette.accent)
            }
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .adaptiveMaterial(solid: AppPalette.dockBackground)
        .overlay(Rectangle().frame(height: 0.5), alignment: .top)
    }

    private var loadingBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            SkeletonRow(height: 12)
            SkeletonRow(width: 160, height: 12)
            SkeletonRow(width: 100, height: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func send() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        query = ""
        HapticEngine.tap(.light)
        let userMsg = ChatMessage(role: .user, text: q, citations: [])
        messages.append(userMsg)
        isLoading = true

        sendTask?.cancel()
        sendTask = Task {
            let (answer, citations) = await generateAnswer(for: q)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isLoading = false
                messages.append(ChatMessage(role: .assistant, text: answer, citations: citations))
                HapticEngine.tap(.light)
            }
        }
    }

    private func generateAnswer(for question: String) async -> (String, [TranscriptCitation]) {
        let transcriptText = meeting.transcript.isEmpty
            ? meeting.rawNotes
            : meeting.transcript.enumerated().map { "\($0.offset + 1). [\($0.element.speaker)]: \($0.element.text)" }.joined(separator: "\n")

        let prompt = """
        Meeting: \(meeting.title)
        Objective: \(meeting.objective)
        Notes: \(meeting.rawNotes)
        Transcript (numbered lines):
        \(transcriptText)

        Question: \(question)

        Answer the question directly and concisely. Reference specific numbered transcript lines when possible using [Line N] format. Be precise and factual — only reference what was actually said.
        """

        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            do {
                let session = LanguageModelSession(instructions: "You are a precise meeting assistant. Answer questions about the provided meeting content accurately and concisely. When referencing specific transcript lines, use [Line N] format.")
                let response = try await session.respond(to: prompt)
                let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let citations = extractCitations(from: answer, transcript: meeting.transcript)
                return (answer, citations)
            } catch {
                return (fallbackAnswer(for: question), [])
            }
            #endif
        }
        return (fallbackAnswer(for: question), [])
    }

    private func fallbackAnswer(for question: String) -> String {
        let q = question.lowercased()
        if q.contains("decided") || q.contains("decision") {
            let decisions = meeting.commitments.filter { $0.status != .superseded }.prefix(3)
            if decisions.isEmpty { return "No clear decisions were recorded in this meeting." }
            return "Decisions made:\n" + decisions.map { "• \($0.statement)" }.joined(separator: "\n")
        }
        if q.contains("action") || q.contains("next") {
            let actions = meeting.commitments.filter { $0.status == .open }.prefix(4)
            if actions.isEmpty { return "No open action items found in this meeting." }
            return "Open actions:\n" + actions.map { "• \($0.statement) — \($0.owner)" }.joined(separator: "\n")
        }
        if q.contains("risk") || q.contains("concern") {
            return "Review the transcript above for risks and concerns raised in this meeting."
        }
        return "Based on the notes for \(meeting.title): \(meeting.objective)"
    }

    private func extractCitations(from text: String, transcript: [TranscriptLine]) -> [TranscriptCitation] {
        var citations: [TranscriptCitation] = []
        let pattern = /\[Line (\d+)\]/
        for match in text.matches(of: pattern) {
            if let lineNum = Int(match.1), lineNum > 0, lineNum <= transcript.count {
                let line = transcript[lineNum - 1]
                citations.append(TranscriptCitation(lineNumber: lineNum, speaker: line.speaker, text: line.text))
            }
        }
        return citations
    }
}

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
    let citations: [TranscriptCitation]
}

struct TranscriptCitation: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let speaker: String
    let text: String
}

private struct ChatBubble: View {
    let message: ChatMessage
    let transcript: [TranscriptLine]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(AppPalette.accent, in: Circle())
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(message.role == .user ? .white : AppPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user ? AppPalette.accent : AppPalette.cardBackground,
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    )

                if !message.citations.isEmpty {
                    citationsView
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.title)
                    .foregroundStyle(AppPalette.secondaryInk.opacity(0.5))
            }
        }
    }

    private var citationsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(.caption2.weight(.bold))
                .kerning(1.0)
                .foregroundStyle(AppPalette.secondaryInk.opacity(0.6))
            ForEach(message.citations) { citation in
                HStack(alignment: .top, spacing: 6) {
                    Text("L\(citation.lineNumber)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(citation.speaker)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryInk)
                        Text(citation.text)
                            .font(.caption2)
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Meeting Score Card (Tier 2)

struct MeetingScoreCard: View {
    let meeting: Meeting

    private var score: MeetingScore {
        meeting.score ?? MeetingScorer.score(for: meeting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(scoreColor(score.overall))
                Text("MEETING QUALITY")
                    .font(.caption.weight(.bold))
                    .kerning(1.3)
                    .foregroundStyle(AppPalette.secondaryInk)
                Spacer()
                scoreRing
            }

            HStack(spacing: 12) {
                scorePill(label: "Clarity", value: score.clarity)
                scorePill(label: "Decisions", value: score.decisiveness)
                scorePill(label: "Actions", value: score.actionability)
            }

            Text(score.insight)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppPalette.secondaryInk)
                .padding(.top, 2)
        }
        .padding(16)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.8)
        )
    }

    private var scoreRing: some View {
        ZStack {
            Circle()
                .stroke(AppPalette.border.opacity(0.4), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(score.overall) / 100)
                .stroke(scoreColor(score.overall), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score.overall)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppPalette.ink)
        }
        .frame(width: 38, height: 38)
    }

    private func scorePill(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryInk.opacity(0.8))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(AppPalette.border.opacity(0.3))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(scoreColor(value))
                        .frame(width: geo.size.width * CGFloat(value) / 100, height: 4)
                }
            }
            .frame(height: 4)
            Text("\(value)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(scoreColor(value))
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreColor(_ value: Int) -> Color {
        if value >= 80 { return AppPalette.accent }
        if value >= 60 { return AppPalette.gold }
        return AppPalette.coral
    }
}

// MARK: - Meeting Context Picker (Tier 2: Adaptive Modes)

struct MeetingContextPickerView: View {
    @Binding var selectedMode: MeetingContextMode
    @Environment(\.dismiss) private var dismiss
    @State private var hasAnimatedIn = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose how Scribeflow interprets this meeting.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(MeetingContextMode.allCases.enumerated()), id: \.element.id) { idx, mode in
                            contextCard(mode)
                                .motionEntrance(step: idx, active: hasAnimatedIn)
                        }
                    }
                }
                .padding(18)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Meeting mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(AppPalette.ink)
                }
            }
            .onAppear { hasAnimatedIn = true }
        }
    }

    private func contextCard(_ mode: MeetingContextMode) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            HapticEngine.select()
            withAnimation(AppMotion.snappy) { selectedMode = mode }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: mode.systemImage)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.tertiaryInk)
                        .symbolEffect(.bounce, value: isSelected)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.accent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AppPalette.accent.opacity(0.05) : AppPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? AppPalette.accent.opacity(0.30) : AppPalette.border.opacity(0.25), lineWidth: isSelected ? 1 : 0.5)
            )
            .appShadow(isSelected ? AppShadow.soft : AppShadow.hairline)
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

// MARK: - People Intelligence Card (Tier 2)

struct PeopleIntelligenceCard: View {
    let person: PersonIntelligence
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if isExpanded { expandedContent }
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.8)
        )
        .animation(AppMotion.smooth, value: isExpanded)
        .onTapGesture {
            HapticEngine.select()
            isExpanded.toggle()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppPalette.accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Text(person.name.prefix(1).uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                HStack(spacing: 4) {
                    Text("\(person.totalMeetings) meeting\(person.totalMeetings == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                    if let days = person.daysSinceLastMeeting {
                        Text("·")
                            .foregroundStyle(AppPalette.border)
                        Text(days == 0 ? "today" : "\(days)d ago")
                            .font(.caption)
                            .foregroundStyle(days > 14 ? AppPalette.coral : AppPalette.secondaryInk)
                    }
                }
            }

            Spacer()

            if !person.openCommitments.isEmpty {
                Text("\(person.openCommitments.count) open")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.coral)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppPalette.coral.opacity(0.10), in: Capsule())
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.border)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if !person.topTopics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOP TOPICS")
                        .font(.caption2.weight(.bold))
                        .kerning(1.0)
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.6))
                    HStack(spacing: 6) {
                        ForEach(person.topTopics.prefix(3), id: \.self) { topic in
                            Text(topic)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppPalette.ink)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(AppPalette.softSurface, in: Capsule())
                        }
                    }
                }
            }

            if !person.openCommitments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("OPEN ITEMS")
                        .font(.caption2.weight(.bold))
                        .kerning(1.0)
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.6))
                    ForEach(person.openCommitments.prefix(3)) { commitment in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppPalette.coral)
                                .frame(width: 5, height: 5)
                            Text(commitment.statement)
                                .font(.caption)
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !person.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECENT MEETINGS")
                        .font(.caption2.weight(.bold))
                        .kerning(1.0)
                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.6))
                    ForEach(person.meetings.prefix(3)) { meeting in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppPalette.border)
                                .frame(width: 5, height: 5)
                            Text(meeting.title)
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .lineLimit(1)
                            Spacer()
                            Text(meeting.when, style: .date)
                                .font(.caption2)
                                .foregroundStyle(AppPalette.secondaryInk.opacity(0.6))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Person Context Banner

struct PersonContextBanner: View {
    let personName: String
    let lastMeetingTitle: String
    let daysSince: Int
    let openCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppPalette.accent.opacity(0.12)).frame(width: 32, height: 32)
                    Text(personName.prefix(1).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(personName.components(separatedBy: " ").first ?? personName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.ink)
                        Text("·")
                            .foregroundStyle(AppPalette.border)
                        Text(daysSince == 0 ? "met today" : "\(daysSince)d ago")
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    Text(lastMeetingTitle)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                }
                Spacer()
                if openCount > 0 {
                    Text("\(openCount) open")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.coral)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppPalette.coral.opacity(0.10), in: Capsule())
                }
                Image(systemName: "arrow.right.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AppPalette.accent.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

