import SwiftUI

struct SettingsView: View {
    @Environment(AuthSessionStore.self) private var authSession
    @Environment(MeetingStore.self) private var meetingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var showsDoneButton = true

    @AppStorage("hasCompletedLaunchOnboarding") private var hasCompletedLaunchOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("homeHeroStyle") private var heroStyleRaw = HeroStyle.briefing.rawValue

    @State private var hasAnimatedIn = false
    @State private var showingAudioDiagnostics = false
    @State private var showingRecordingPrivacy = false
    @State private var showingDataControls = false
    @State private var showingAccountSync = false
    @State private var showingLogoutSheet = false
    @State private var showingDeleteAccountConfirm = false
    @State private var showingIntegrations = false
    @State private var showingActivityLog = false
    @Namespace private var appearanceNS

    private let supportEmail = "support@scribeflow.ai"
    private let privacyPolicyURL = URL(string: "https://scribeflow.ai/privacy")!
    private let termsURL = URL(string: "https://scribeflow.ai/terms")!
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    appHeader
                        .motionEntrance(step: 0, active: hasAnimatedIn)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 24)

                    settingsGroup(title: "Appearance") {
                        HStack(spacing: 8) {
                            ForEach(AppearancePreference.allCases) { option in
                                appearanceChip(option)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Home hero") {
                        HeroStylePicker(selectionRaw: $heroStyleRaw)
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Audio") {
                        settingLinkRow(
                            icon: "waveform.and.mic",
                            iconColor: AppPalette.accent,
                            title: "Microphone & audio",
                            subtitle: "Run mic test, check route & permissions"
                        ) {
                            showingAudioDiagnostics = true
                        }
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Privacy") {
                        settingLinkRow(
                            icon: "checkmark.shield.fill",
                            iconColor: AppPalette.accent,
                            title: "Recording privacy",
                            subtitle: "Storage, transcription, and call limits"
                        ) {
                            showingRecordingPrivacy = true
                        }

                        settingLinkRow(
                            icon: "externaldrive.fill",
                            iconColor: AppPalette.gold,
                            title: "Storage & backup",
                            subtitle: "Manage audio files, backups, and deletion"
                        ) {
                            showingDataControls = true
                        }

                        settingLinkRow(
                            icon: "chart.bar.doc.horizontal.fill",
                            iconColor: AppPalette.secondaryInk,
                            title: "Activity log",
                            subtitle: "See what Scribeflow has recorded on this device"
                        ) {
                            showingActivityLog = true
                        }
                    }
                    .motionEntrance(step: 2, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Account") {
                        if let session = authSession.currentSession {
                            settingInfoRow(
                                icon: "person.crop.circle.fill",
                                iconColor: AppPalette.accent,
                                title: "Signed in",
                                value: session.email
                            )
                        }

                        settingLinkRow(
                            icon: "icloud.slash",
                            iconColor: AppPalette.secondaryInk,
                            title: "Storage & sync",
                            subtitle: "Where your data lives"
                        ) {
                            showingAccountSync = true
                        }

                        settingLinkRow(
                            icon: "rectangle.portrait.and.arrow.right",
                            iconColor: AppPalette.coral,
                            title: "Log out",
                            subtitle: "End this secure session on this device"
                        ) {
                            showingLogoutSheet = true
                        }

                        settingLinkRow(
                            icon: "trash.fill",
                            iconColor: AppPalette.coral,
                            title: "Delete account",
                            subtitle: "Permanently remove account and local data"
                        ) {
                            showingDeleteAccountConfirm = true
                        }
                    }
                    .motionEntrance(step: 3, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Integrations") {
                        settingLinkRow(
                            icon: "link.circle.fill",
                            iconColor: AppPalette.accent,
                            title: "Slack, Notion, Linear webhooks",
                            subtitle: WebhookStore.shared.configs.isEmpty
                                ? "Post recaps + action items to your tools"
                                : "\(WebhookStore.shared.configs.count) configured"
                        ) {
                            showingIntegrations = true
                        }
                    }
                    .motionEntrance(step: 4, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Experience") {
                        settingLinkRow(
                            icon: "sparkles.rectangle.stack.fill",
                            iconColor: AppPalette.accent,
                            title: "Show welcome tour",
                            subtitle: "Replay the first-run guide"
                        ) {
                            HapticEngine.tap(.medium)
                            withAnimation(AppMotion.smooth) {
                                hasCompletedLaunchOnboarding = false
                            }
                        }
                    }
                    .motionEntrance(step: 4, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Support") {
                        settingLinkRow(
                            icon: "envelope.fill",
                            iconColor: AppPalette.accent,
                            title: "Send feedback",
                            subtitle: "Email the developer directly"
                        ) {
                            if let url = URL(string: "mailto:\(supportEmail)?subject=Scribeflow%20Feedback") {
                                openURL(url)
                            }
                        }

                        settingLinkRow(
                            icon: "hand.raised.fill",
                            iconColor: AppPalette.secondaryInk,
                            title: "Privacy Policy",
                            subtitle: "How Scribeflow handles your data"
                        ) {
                            openURL(privacyPolicyURL)
                        }

                        settingLinkRow(
                            icon: "doc.text.fill",
                            iconColor: AppPalette.secondaryInk,
                            title: "Terms of Service",
                            subtitle: "Agreement for using Scribeflow"
                        ) {
                            openURL(termsURL)
                        }
                    }
                    .motionEntrance(step: 5, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "About") {
                        settingInfoRow(
                            icon: "info.circle.fill",
                            iconColor: AppPalette.secondaryInk,
                            title: "Version",
                            value: "\(appVersion) (\(buildNumber))"
                        )

                        settingInfoRow(
                            icon: "cpu",
                            iconColor: AppPalette.accent,
                            title: "Transcription",
                            value: "Apple Speech"
                        )

                        settingInfoRow(
                            icon: "lock.shield.fill",
                            iconColor: AppPalette.accent,
                            title: "Privacy",
                            value: "No tracking"
                        )
                    }
                    .motionEntrance(step: 6, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)

                    VStack(spacing: 8) {
                        BreathingDot(tint: AppPalette.accent, size: 4)
                        Text("Built for people who run important meetings.")
                            .font(.system(.caption, design: .serif))
                            .foregroundStyle(AppPalette.tertiaryInk)
                        Text("v\(appVersion)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppPalette.border)
                    }
                    .frame(maxWidth: .infinity)
                    .motionEntrance(step: 7, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .tint(AppPalette.ink)
                    }
                }
            }
            .onAppear { hasAnimatedIn = true }
            .sheet(isPresented: $showingAudioDiagnostics) {
                AudioDiagnosticsView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingRecordingPrivacy) {
                RecordingPrivacyView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingDataControls) {
                DataControlsView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAccountSync) {
                AccountSyncView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingLogoutSheet) {
                LogoutConfirmationSheet {
                    showingLogoutSheet = false
                    // New local auth flow — clear our keys, plus the legacy
                    // backend session for safety.
                    authSession.logout()
                    UserDefaults.standard.removeObject(forKey: "scribeflow.currentUserEmail")
                    UserDefaults.standard.removeObject(forKey: "scribeflow.bioAsked")
                    HapticEngine.notify(.warning)
                }
                .presentationDetents([.height(370)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingIntegrations) {
                IntegrationsSheet()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingActivityLog) {
                ActivityLogSheet()
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete account?", isPresented: $showingDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete everything", role: .destructive) {
                    Task {
                        meetingStore.deleteAllUserData()
                        await authSession.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text("This permanently removes your account, all meetings, voice notes, and local recordings on this device. This cannot be undone.")
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorialEyebrow(text: "Settings")
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppPalette.softSurface)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(decorative: "BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scribeflow")
                        .font(.system(size: 26, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                    Text("Your meeting memory")
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer()
            }
        }
    }

    private func appearanceChip(_ option: AppearancePreference) -> some View {
        let isSelected = appearanceRaw == option.rawValue
        return Button {
            HapticEngine.tap(.light)
            withAnimation(AppMotion.snappy) {
                appearanceRaw = option.rawValue
            }
        } label: {
            VStack(spacing: 8) {
                appearanceSwatch(option)
                    .frame(height: 54)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(isSelected ? AppPalette.accent : AppPalette.border.opacity(0.6), lineWidth: isSelected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(AppPalette.accent)
                                .padding(5)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                HStack(spacing: 5) {
                    Image(systemName: option.icon).font(.caption2.weight(.bold))
                    Text(option.title).font(.caption.weight(isSelected ? .semibold : .medium))
                }
                .foregroundStyle(isSelected ? AppPalette.ink : AppPalette.tertiaryInk)
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        .accessibilityLabel("\(option.title) appearance")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func appearanceSwatch(_ option: AppearancePreference) -> some View {
        let light = Color(red: 0.965, green: 0.953, blue: 0.925)
        let dark = Color(red: 0.078, green: 0.090, blue: 0.110)
        let lightInk = Color(red: 0.086, green: 0.102, blue: 0.133)
        let darkInk = Color(red: 0.953, green: 0.941, blue: 0.910)
        switch option {
        case .light:  swatchFace(bg: light, ink: lightInk)
        case .dark:   swatchFace(bg: dark, ink: darkInk)
        case .system:
            HStack(spacing: 0) {
                swatchFace(bg: light, ink: lightInk)
                swatchFace(bg: dark, ink: darkInk)
            }
        }
    }

    private func swatchFace(bg: Color, ink: Color) -> some View {
        ZStack {
            bg
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(AppPalette.accent).frame(width: 16, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.85)).frame(width: 30, height: 5)
                RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.35)).frame(width: 22, height: 3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .kerning(0.9)
                .foregroundStyle(AppPalette.tertiaryInk)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
            )
            .appShadow(AppShadow.hairline)
        }
    }

    private func settingRow<Accessory: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(iconColor)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Spacer()
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func settingLinkRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticEngine.tap(.light)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(EditorialRowStyle(inset: 4))
    }

    private func settingInfoRow(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppPalette.ink)

            Spacer()

            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.tertiaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

}

private struct LogoutConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppPalette.coral.opacity(0.12))
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppPalette.coral)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Log out?")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("Your secure session ends on this device.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                logoutPoint("Keychain session token will be removed.", icon: "key.fill")
                logoutPoint("Your local notes and recordings stay saved.", icon: "doc.text.fill")
                logoutPoint("You can sign in again anytime.", icon: "arrow.clockwise")
            }
            .padding(14)
            .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Stay signed in")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.ink)

                Button(role: .destructive) {
                    HapticEngine.notify(.warning)
                    onConfirm()
                } label: {
                    Text("Log out")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.coral)
            }
        }
        .padding(22)
        .background(AppPalette.background.ignoresSafeArea())
    }

    private func logoutPoint(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AppPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Integrations sheet

/// Lets the user manage outbound webhook integrations (Slack / Notion /
/// Linear / Zapier / Custom). We never bundle integration secrets: the user
/// pastes their own incoming-webhook URL, so each customer's credentials
/// stay in their own workspace.
private struct IntegrationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = WebhookStore.shared
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.configs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No integrations yet")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text("Paste an incoming-webhook URL from Slack, Notion, Linear, or Zapier to post recaps + action items there with one tap.")
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryInk)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(store.configs) { config in
                            HStack(spacing: 12) {
                                Image(systemName: config.target.systemImage)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AppPalette.accent)
                                    .frame(width: 30, height: 30)
                                    .background(AppPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.label.isEmpty ? config.target.title : config.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppPalette.ink)
                                    Text(config.url)
                                        .font(.caption)
                                        .foregroundStyle(AppPalette.secondaryInk)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.remove(config.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Configured")
                } footer: {
                    Text("Posts include the meeting title, action items, and a clean Markdown recap. Nothing is sent until you tap Send from a meeting.")
                }
            }
            .navigationTitle("Integrations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add integration")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddWebhookSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct AddWebhookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var target: WebhookTarget = .slack
    @State private var url: String = ""
    @State private var label: String = ""

    private var isValidURL: Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (parsed.scheme == "https" || parsed.scheme == "http") && parsed.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Target", selection: $target) {
                        ForEach(WebhookTarget.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Webhook URL") {
                    TextField("https://hooks.slack.com/…", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Label (optional)") {
                    TextField("#design-syncs", text: $label)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Add webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let config = WebhookConfig(
                            target: target,
                            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                            label: label.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        WebhookStore.shared.add(config)
                        AnalyticsLog.shared.log("integration.added", ["target": target.rawValue])
                        dismiss()
                    }
                    .disabled(!isValidURL)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Activity log sheet

/// Privacy-first activity surface. Shows the user every event Scribeflow has
/// recorded on this device + an opt-out toggle. Nothing is uploaded; this is
/// the "right to see" companion to the local analytics log.
private struct ActivityLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var optIn: Bool = AnalyticsLog.shared.isEnabled
    @State private var events: [AnalyticsEvent] = AnalyticsLog.shared.events

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Record local activity", isOn: $optIn)
                        .onChange(of: optIn) { _, newValue in
                            AnalyticsLog.shared.isEnabled = newValue
                            events = AnalyticsLog.shared.events
                        }
                } footer: {
                    Text("Captures usage signals on this device only. Nothing leaves the app. Turn off any time — the log is wiped immediately.")
                }

                if events.isEmpty {
                    Section {
                        Text(optIn ? "No activity recorded yet." : "Activity logging is off.")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                } else {
                    Section("Recent activity (\(events.count))") {
                        ForEach(events.reversed().prefix(200)) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                                Text(formatter.string(from: event.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(AppPalette.secondaryInk)
                                if !event.context.isEmpty {
                                    Text(event.context.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(AppPalette.secondaryInk.opacity(0.85))
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            AnalyticsLog.shared.clear()
                            events = []
                        } label: {
                            Text("Clear log")
                        }
                    }
                }
            }
            .navigationTitle("Activity log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
