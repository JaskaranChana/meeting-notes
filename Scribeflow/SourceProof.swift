import SwiftUI
import UIKit

enum SourceProofConfidence: String, Codable, CaseIterable, Identifiable {
    case confirmed
    case likely
    case inferred
    case needsReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .confirmed: "Confirmed"
        case .likely: "Likely"
        case .inferred: "Inferred"
        case .needsReview: "Needs review"
        }
    }

    var detail: String {
        switch self {
        case .confirmed: "Backed by a saved transcript line."
        case .likely: "Backed by saved notes or calendar context."
        case .inferred: "Generated from meeting context without a direct matching line."
        case .needsReview: "There is not enough saved source material to verify this claim."
        }
    }

    var systemImage: String {
        switch self {
        case .confirmed: "checkmark.seal.fill"
        case .likely: "doc.text.magnifyingglass"
        case .inferred: "sparkles"
        case .needsReview: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .confirmed: AppPalette.success
        case .likely: AppPalette.accent
        case .inferred: AppPalette.gold
        case .needsReview: AppPalette.coral
        }
    }
}

enum SourceReferenceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcript
    case audioTranscript
    case note
    case calendar
    case meetingContext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .audioTranscript: "Audio transcript"
        case .note: "Saved note"
        case .calendar: "Calendar"
        case .meetingContext: "Meeting context"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: "quote.bubble.fill"
        case .audioTranscript: "waveform.badge.mic"
        case .note: "note.text"
        case .calendar: "calendar"
        case .meetingContext: "doc.text.magnifyingglass"
        }
    }
}

enum SourceMatchStrength: String, Codable, Hashable, Sendable {
    /// The claim is the same normalized text as the referenced source, or the
    /// model selected the exact persisted source identifier during generation.
    case exact
    /// The source shares meaningful content with the claim but does not prove
    /// that every part of the claim is true.
    case partial
    /// The reference provides surrounding context only.
    case contextual
}

struct SourceReference: Codable, Hashable, Identifiable {
    var id = UUID()
    var meetingID: Meeting.ID
    var meetingTitle: String
    var kind: SourceReferenceKind
    var snippet: String
    var speaker: String? = nil
    var transcriptLineID: TranscriptLine.ID? = nil
    var lineIndex: Int? = nil
    /// Optional for backward-compatible decoding of notes saved before source
    /// strength was persisted. A missing value must never be treated as exact.
    var matchStrength: SourceMatchStrength? = nil

    var title: String {
        guard let speaker, !speaker.isEmpty else { return kind.title }
        return "\(kind.title) - \(speaker)"
    }
}

struct SourceProof: Hashable {
    var confidence: SourceProofConfidence
    var sourceMeetingTitle: String
    var references: [SourceReference]
    var fallbackDetail: String

    var primaryReference: SourceReference? { references.first }

    var sourceLine: String {
        guard let primaryReference else { return sourceMeetingTitle }
        return "\(sourceMeetingTitle) - \(primaryReference.title)"
    }

    var snippetLine: String {
        primaryReference?.snippet ?? fallbackDetail
    }
}

struct SourceProofSelection: Identifiable, Hashable {
    let id = UUID()
    let claim: String
    let proof: SourceProof
}

struct SourceProofButton: View {
    let proof: SourceProof
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: proof.confidence.systemImage)
                Text(proof.confidence.title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(proof.confidence.tint)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(proof.confidence.tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(proof.confidence.tint.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(proof.confidence.title) source proof")
        .accessibilityHint("Opens the saved source")
    }
}

struct SourceProofInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: SourceProofSelection

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    claimSection
                    confidenceSection
                    sourcesSection
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Source proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share source proof")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var claimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLAIM")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
            Text(selection.claim)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confidenceSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selection.proof.confidence.systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(selection.proof.confidence.tint)
                .frame(width: 38, height: 38)
                .background(selection.proof.confidence.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(selection.proof.confidence.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(selection.proof.confidence.detail)
                    .font(.footnote)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SAVED SOURCES")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)

            if selection.proof.references.isEmpty {
                sourceFallback
            } else {
                ForEach(selection.proof.references) { reference in
                    sourceRow(reference)
                }
            }
        }
    }

    private var sourceFallback: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 26, height: 26)
            Text(selection.proof.fallbackDetail)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppPalette.softSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceRow(_ reference: SourceReference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: reference.kind.systemImage)
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(reference.meetingTitle)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = reference.snippet
                    HapticEngine.tap(.light)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.secondaryInk)
                .accessibilityLabel("Copy source")
            }

            Text(reference.snippet)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.6))
    }

    private var shareText: String {
        let sources = selection.proof.references.isEmpty
            ? selection.proof.fallbackDetail
            : selection.proof.references.map { "\($0.title): \($0.snippet)" }.joined(separator: "\n")
        return "\(selection.claim)\n\n\(selection.proof.confidence.title)\n\(sources)"
    }
}
