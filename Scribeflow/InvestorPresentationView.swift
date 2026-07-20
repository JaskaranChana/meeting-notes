import SwiftUI

struct InvestorPresentationView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var impact = UsageImpactSnapshot()
    @State private var impactBuilder = UsageImpactBuilder()
    @State private var automaticBackupCount = 0

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            presentationHeader

            TabView(selection: $page) {
                overviewPage.tag(0)
                trustPage.tag(1)
                accountabilityPage.tag(2)
                privacyPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            presentationControls
        }
        .background(AppPalette.background.ignoresSafeArea())
        .task(id: store.revision) {
            let nextImpact = await impactBuilder.make(
                meetings: store.meetings,
                period: .allTime
            )
            let backups = (try? await store.automaticBackups()) ?? []
            guard !Task.isCancelled else { return }
            impact = nextImpact
            automaticBackupCount = backups.count
        }
    }

    private var presentationHeader: some View {
        HStack(spacing: 12) {
            ScribeflowBrandMark(size: 30)
            Text("SCRIBEFLOW")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)
            Spacer()
            Text("\(page + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppPalette.tertiaryInk)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(AppPalette.softSurface, in: Circle())
                    .appTapTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.ink)
            .accessibilityLabel("Close presentation")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var overviewPage: some View {
        presentationScroll {
            presentationEyebrow("PRIVATE MEETING MEMORY", tint: AppPalette.accent)
            Text("Scribeflow")
                .font(.system(.largeTitle, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
            Text("Capture what happened, verify every important claim, and close the loops that remain.")
                .font(.title3)
                .foregroundStyle(AppPalette.secondaryInk)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)

            presentationMetricStrip([
                PresentationMetric(id: "captures", value: "\(impact.captures)", label: "CAPTURES", tint: AppPalette.accent),
                PresentationMetric(id: "minutes", value: "\(impact.capturedMinutes)", label: "MINUTES", tint: AppPalette.gold),
                PresentationMetric(id: "closed", value: "\(impact.closedLoops)", label: "LOOPS CLOSED", tint: AppPalette.success)
            ])

            Text("These numbers come from the local demo workspace or the user's own library. No remote analytics are required.")
                .font(.footnote)
                .foregroundStyle(AppPalette.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var trustPage: some View {
        presentationScroll {
            presentationEyebrow("TRUST", tint: AppPalette.success)
            Text("Every claim can show its work.")
                .font(.system(.title, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let meeting = proofMeeting {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(meeting.purpose.isPersonalCapture ? "Personal capture" : "Meeting-backed intelligence")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryInk)
                }

                VStack(spacing: 0) {
                    ForEach(Array(proofClaims(for: meeting).prefix(4).enumerated()), id: \.offset) { index, claim in
                        let proof = store.sourceProof(for: claim, in: meeting)
                        PresentationProofRow(claim: claim, proof: proof)
                        if index < min(proofClaims(for: meeting).count, 4) - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
            } else {
                EmptyStateCard(
                    title: "No proof sample yet",
                    subtitle: "Load the demo workspace to present source-backed intelligence."
                )
            }
        }
    }

    private var accountabilityPage: some View {
        presentationScroll {
            presentationEyebrow("ACCOUNTABILITY", tint: AppPalette.coral)
            Text("The note keeps working after the meeting.")
                .font(.system(.title, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            presentationMetricStrip([
                PresentationMetric(id: "open", value: "\(impact.openLoops)", label: "OPEN", tint: AppPalette.coral),
                PresentationMetric(id: "closed", value: "\(impact.closedLoops)", label: "CLOSED", tint: AppPalette.success),
                PresentationMetric(id: "follow-through", value: impact.followThroughLabel, label: "FOLLOW-THROUGH", tint: AppPalette.accent)
            ])
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(openCommitments.prefix(4)), id: \.id) { commitment in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: commitment.hasReminder ? "bell.fill" : "circle")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(commitment.status == .atRisk ? AppPalette.coral : AppPalette.accent)
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commitment.statement)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(commitment.owner)
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk)
                        }
                    }
                }
            }
        }
    }

    private var privacyPage: some View {
        presentationScroll {
            presentationEyebrow("USER CONTROL", tint: AppPalette.gold)
            Text("Private by default. Portable by choice.")
                .font(.system(.title, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                presentationSafetyRow(
                    icon: "iphone",
                    title: "Local-first library",
                    detail: "Notes, transcripts, and audio stay on the device."
                )
                Divider().padding(.leading, 44)
                presentationSafetyRow(
                    icon: "clock.arrow.circlepath",
                    title: "Automatic recovery",
                    detail: "\(automaticBackupCount) protected local snapshot\(automaticBackupCount == 1 ? "" : "s") available."
                )
                Divider().padding(.leading, 44)
                presentationSafetyRow(
                    icon: "externaldrive.fill",
                    title: "Portable export",
                    detail: "Full and notes-only JSON backups with restore preview."
                )
                Divider().padding(.leading, 44)
                presentationSafetyRow(
                    icon: "icloud",
                    title: "Optional iCloud backup",
                    detail: ScribeflowCloudBackupService.isConfigured
                        ? "Private CloudKit backup is enabled."
                        : "Prepared for the Apple provisioning profile; never required."
                )
            }

            Button {
                dismiss()
            } label: {
                Label("Continue in Scribeflow", systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.ink)
        }
    }

    private var presentationControls: some View {
        HStack(spacing: 16) {
            Button {
                guard page > 0 else { return }
                withAnimation(AppMotion.smooth) { page -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: AppLayout.minimumTapTarget, height: AppLayout.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(page == 0)
            .accessibilityLabel("Previous page")

            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? AppPalette.accent : AppPalette.border)
                        .frame(width: index == page ? 24 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                if page == pageCount - 1 {
                    dismiss()
                } else {
                    withAnimation(AppMotion.smooth) { page += 1 }
                }
            } label: {
                Image(systemName: page == pageCount - 1 ? "checkmark" : "chevron.right")
                    .frame(width: AppLayout.minimumTapTarget, height: AppLayout.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(AppPalette.ink)
            .accessibilityLabel(page == pageCount - 1 ? "Finish presentation" : "Next page")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(AppPalette.paper)
        .overlay(alignment: .top) { Divider() }
    }

    private func presentationScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func presentationEyebrow(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
    }

    private func presentationMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(.title2, design: .serif).weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .monospacedDigit()
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.tertiaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    private var presentationRule: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(width: 1, height: 42)
    }

    @ViewBuilder
    private func presentationMetricStrip(_ metrics: [PresentationMetric]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    presentationMetric(metric.value, label: metric.label, tint: metric.tint)
                    if index < metrics.count - 1 { Divider() }
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    presentationMetric(metric.value, label: metric.label, tint: metric.tint)
                    if index < metrics.count - 1 { presentationRule }
                }
            }
        }
    }

    private func presentationSafetyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private var proofMeeting: Meeting? {
        store.recentMeetings.first {
            !$0.transcript.isEmpty || $0.evidenceItems.contains { !$0.sourceReferences.isEmpty }
        } ?? store.recentMeetings.first
    }

    private func proofClaims(for meeting: Meeting) -> [String] {
        let evidence = meeting.evidenceItems.map(\.text)
        let commitments = meeting.commitments.map(\.statement)
        return evidence + commitments
    }

    private var openCommitments: [Commitment] {
        store.recentMeetings
            .flatMap(\.commitments)
            .filter { $0.status == .open || $0.status == .atRisk }
    }
}

private struct PresentationMetric: Identifiable {
    let id: String
    let value: String
    let label: String
    let tint: Color
}

private struct PresentationProofRow: View {
    let claim: String
    let proof: SourceProof

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(claim)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Image(systemName: proof.confidence.systemImage)
                Text(proof.confidence.title)
                Text(proof.sourceLine)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(proof.confidence.tint)
        }
        .padding(.vertical, 12)
    }
}
