import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AuthSessionStore.self) private var authSession
    @Environment(MeetingStore.self) private var meetingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var showsDoneButton = true

    @AppStorage("hasCompletedLaunchOnboarding") private var hasCompletedLaunchOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("homeHeroStyle") private var heroStyleRaw = HeroStyle.briefing.rawValue
    @AppStorage("scribeflow.investorDemoMode") private var investorDemoMode = false
    @AppStorage("scribeflow.demoModePreparedAt") private var demoModePreparedAt = 0.0
    @AppStorage(SpeechRecognitionSupport.localePreferenceKey) private var speechLocaleIdentifier = ""
    @AppStorage("scribeflow.requireAppUnlock") private var requireAppUnlock = false

    @State private var hasAnimatedIn = false
    @State private var showingAudioDiagnostics = false
    @State private var showingRecordingPrivacy = false
    @State private var showingDataControls = false
    @State private var showingAccountSync = false
    @State private var showingLogoutSheet = false
    @State private var showingDeleteAccountConfirm = false
    @State private var showingIntegrations = false
    @State private var showingActivityLog = false
    @State private var showingDiagnostics = false
    @State private var showingUsageImpact = false
    @State private var showingInvestorPresentation = false
    @State private var showingReplaceSamplesConfirm = false
    @State private var sampleDataMessage: String?
    @State private var notificationPermission = ScribeflowNotificationPermission.notDetermined
    @State private var notificationTestMessage: String?
    @Namespace private var appearanceNS

    private let supportEmail = "jaskaran.chana1302@gmail.com"
    private let privacyPolicyURL = URL(string: "https://jaskaranchana.github.io/meeting-notes/PRIVACY")!
    private let termsURL = URL(string: "https://jaskaranchana.github.io/meeting-notes/TERMS")!
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
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(spacing: 12) {
                                    ForEach(AppearancePreference.allCases) { option in
                                        appearanceChip(option)
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    ForEach(AppearancePreference.allCases) { option in
                                        appearanceChip(option)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    #if DEBUG
                    settingsGroup(title: "Home hero") {
                        HeroStylePicker(selectionRaw: $heroStyleRaw)
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    #endif

                    settingsGroup(title: "Audio") {
                        settingLinkRow(
                            icon: "waveform.and.mic",
                            iconColor: AppPalette.accent,
                            title: "Microphone & audio",
                            subtitle: "Run mic test, check route & permissions"
                        ) {
                            showingAudioDiagnostics = true
                        }

                        Divider()
                            .padding(.leading, 54)

                        speechLanguageSettingsRow
                    }
                    .motionEntrance(step: 1, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Notifications") {
                        settingLinkRow(
                            icon: notificationPermission.canSchedule ? "bell.badge.fill" : "bell.slash.fill",
                            iconColor: notificationPermission.canSchedule ? AppPalette.accent : AppPalette.coral,
                            title: "Ready alerts & reminders",
                            subtitle: "\(notificationPermission.title) · \(notificationPermission.detail)"
                        ) {
                            manageNotifications()
                        }

                        if notificationPermission.canSchedule {
                            settingLinkRow(
                                icon: "bell.and.waves.left.and.right.fill",
                                iconColor: AppPalette.gold,
                                title: "Send test alert",
                                subtitle: "Verify delivery on this device"
                            ) {
                                sendTestNotification()
                            }
                        }
                    }
                    .motionEntrance(step: 2, active: hasAnimatedIn)
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

                          appLockRow

                        settingLinkRow(
                            icon: "externaldrive.fill",
                            iconColor: AppPalette.gold,
                            title: "Storage & backup",
                            subtitle: "Export, restore, and protect local notes"
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
                                  value: session.accountLabel
                              )
                          } else {
                              settingInfoRow(
                                  icon: "iphone",
                                  iconColor: AppPalette.accent,
                                  title: "Local workspace",
                                  value: "No account required"
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

                          if authSession.currentSession != nil {
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
                    }
                    .motionEntrance(step: 3, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    settingsGroup(title: "Integrations") {
                        settingLinkRow(
                            icon: "link.circle.fill",
                            iconColor: AppPalette.accent,
                            title: "Secure webhooks",
                            subtitle: WebhookStore.shared.configs.isEmpty
                                ? "Post recaps to an HTTPS endpoint"
                                : "\(WebhookStore.shared.configs.count) configured"
                        ) {
                            showingIntegrations = true
                        }
                    }
                    .motionEntrance(step: 4, active: hasAnimatedIn)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                      settingsGroup(title: "Experience") {
                          #if DEBUG
                          settingLinkRow(
                              icon: "play.fill",
                            iconColor: AppPalette.accent,
                            title: "Launch presentation",
                            subtitle: "A live walkthrough using the current workspace"
                          ) {
                              launchInvestorPresentation()
                          }
                          #endif

                          settingLinkRow(
                            icon: "chart.bar.xaxis",
                            iconColor: AppPalette.success,
                            title: "Usage impact",
                            subtitle: "Captures, follow-through, and source-backed outcomes"
                          ) {
                              showingUsageImpact = true
                          }

                          #if DEBUG
                          demoModeRow

                        settingLinkRow(
                            icon: "shippingbox.fill",
                            iconColor: AppPalette.accent,
                            title: "Add sample data",
                            subtitle: "Calendar notes, source proof, reminders, and recall"
                        ) {
                            addSampleData()
                        }

                        settingLinkRow(
                            icon: "arrow.triangle.2.circlepath",
                            iconColor: AppPalette.gold,
                            title: "Reset demo workspace",
                            subtitle: demoModePreparedSubtitle
                          ) {
                              showingReplaceSamplesConfirm = true
                          }
                          #endif

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
                            icon: "stethoscope",
                            iconColor: AppPalette.success,
                            title: "App health",
                            subtitle: "Readiness checks and private diagnostics"
                        ) {
                            showingDiagnostics = true
                        }

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
                .readingWidth()
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(AppStrings.Screen.settings)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(AppStrings.Action.done) { dismiss() }
                            .fontWeight(.semibold)
                            .tint(AppPalette.accent)
                    }
                }
            }
            .onAppear { hasAnimatedIn = true }
            .task {
                notificationPermission = await ScribeflowNotificationAuthorization.shared.currentPermission()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    notificationPermission = await ScribeflowNotificationAuthorization.shared.currentPermission()
                }
            }
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
            .sheet(isPresented: $showingUsageImpact) {
                UsageImpactView()
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showingInvestorPresentation) {
                InvestorPresentationView()
            }
            .sheet(isPresented: $showingAccountSync) {
                AccountSyncView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingLogoutSheet) {
                LogoutConfirmationSheet {
                    showingLogoutSheet = false
                    authSession.logout()
                    HapticEngine.notify(.warning)
                }
                .presentationDetents([.medium, .large])
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
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsAndReadinessView()
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete account?", isPresented: $showingDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete everything", role: .destructive) {
                    Task {
                        if await authSession.deleteAccount() {
                            await meetingStore.deleteAllUserData()
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This permanently removes your account, all meetings, voice notes, and local recordings on this device. This cannot be undone.")
            }
            .alert("Replace with sample data?", isPresented: $showingReplaceSamplesConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Replace", role: .destructive) {
                    prepareDemoWorkspace()
                }
            } message: {
                Text("This removes local meetings and recordings on this device, then loads the demo workspace for testing calendar prep, reminders, source-backed summaries, transcription states, and recall.")
            }
            .alert("Sample data", isPresented: Binding(
                get: { sampleDataMessage != nil },
                set: { if !$0 { sampleDataMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sampleDataMessage = nil }
            } message: {
                Text(sampleDataMessage ?? "")
            }
            .alert("Test notification", isPresented: Binding(
                get: { notificationTestMessage != nil },
                set: { if !$0 { notificationTestMessage = nil } }
            )) {
                Button("OK", role: .cancel) { notificationTestMessage = nil }
            } message: {
                Text(notificationTestMessage ?? "")
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ScribeflowBrandMark(size: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scribeflow")
                        .font(AppFont.serif(.title2, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    Text("Your meeting memory")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer()
            }
        }
    }

    private func manageNotifications() {
        Task {
            if notificationPermission == .notDetermined {
                notificationPermission = await ScribeflowNotificationAuthorization.shared.requestIfNeeded()
                return
            }
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    private func sendTestNotification() {
        Task {
            let sent = await ScribeflowNotificationTester.send()
            notificationPermission = await ScribeflowNotificationAuthorization.shared.currentPermission()
            notificationTestMessage = sent
                ? "A test alert will arrive in about two seconds. If delivery is quiet, check Notification Center or adjust alerts in iPhone Settings."
                : "The test alert could not be scheduled. Enable notifications in iPhone Settings and try again."
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .fixedSize(horizontal: false, vertical: true)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.ink)
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 38)
                }
                .symbolRenderingMode(.monochrome)
                .tint(iconColor)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 24, height: 24)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var appLockRow: some View {
        HStack(spacing: 14) {
            Image(systemName: requireAppUnlock ? "lock.fill" : "lock.open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(requireAppUnlock ? AppPalette.accent : AppPalette.secondaryInk)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Require app unlock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink)
                Text("Ask for secure sign-in when Scribeflow opens")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $requireAppUnlock)
                .labelsHidden()
                .tint(AppPalette.accent)
                .accessibilityLabel("Require app unlock")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var speechLanguageSettingsRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Transcription language")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink)
                Text(speechLanguageSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    HapticEngine.tap(.light)
                    speechLocaleIdentifier = ""
                } label: {
                    Label(
                        "Automatic",
                        systemImage: speechLocaleIdentifier.isEmpty ? "checkmark" : "globe"
                    )
                }

                Divider()

                ForEach(SpeechRecognitionSupport.availableLocales, id: \.identifier) { locale in
                    Button {
                        HapticEngine.tap(.light)
                        speechLocaleIdentifier = locale.identifier
                    } label: {
                        Label(
                            SpeechRecognitionSupport.displayName(for: locale),
                            systemImage: speechLocaleIdentifier == locale.identifier
                                ? "checkmark"
                                : "waveform"
                        )
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .frame(width: 44, height: 44)
                    .background(AppPalette.highlight, in: Circle())
            }
            .accessibilityLabel("Choose transcription language")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var speechLanguageSubtitle: String {
        let identifier = speechLocaleIdentifier.isEmpty ? nil : speechLocaleIdentifier
        let locale = SpeechRecognitionSupport.resolvedLocale(identifier: identifier)
        let language = SpeechRecognitionSupport.displayName(for: locale)
        return speechLocaleIdentifier.isEmpty ? "Automatic · \(language)" : language
    }

    private var demoModePreparedSubtitle: String {
        guard demoModePreparedAt > 0 else {
            return "Load the investor-ready sample workspace"
        }
        let date = Date(timeIntervalSince1970: demoModePreparedAt)
        return "Prepared \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var demoModeRow: some View {
        HStack(spacing: 14) {
            Image(systemName: investorDemoMode ? "play.rectangle.fill" : "play.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(investorDemoMode ? AppPalette.accent : AppPalette.secondaryInk)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Investor demo mode")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink)
                Text(investorDemoMode ? demoModePreparedSubtitle : "Keep walkthrough data repeatable")
                    .font(.caption)
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $investorDemoMode)
                .labelsHidden()
                .tint(AppPalette.accent)
                .onChange(of: investorDemoMode) { _, isOn in
                    if isOn && demoModePreparedAt == 0 {
                        prepareDemoWorkspace()
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func addSampleData() {
        let added = meetingStore.addSampleData()
        if added == 0 {
            sampleDataMessage = "The demo workspace is already loaded."
        } else {
            sampleDataMessage = "Added \(added) sample meetings for testing."
        }
        HapticEngine.notify(.success)
    }

    private func launchInvestorPresentation() {
        if meetingStore.meetings.isEmpty {
            _ = meetingStore.addSampleData()
            investorDemoMode = true
            demoModePreparedAt = Date().timeIntervalSince1970
        }
        HapticEngine.tap(.medium)
        showingInvestorPresentation = true
    }

    private func prepareDemoWorkspace() {
        meetingStore.replaceWithSampleData()
        investorDemoMode = true
        demoModePreparedAt = Date().timeIntervalSince1970
        sampleDataMessage = "Loaded the investor demo workspace."
        HapticEngine.notify(.success)
    }

}

private struct LogoutConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                HStack(spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(AppPalette.coral.opacity(0.12))
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppPalette.coral)
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Log out?")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AppPalette.ink)
                        Text("Your secure session ends on this device.")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    logoutPoint("Keychain session token will be removed.", icon: "key.fill")
                    logoutPoint("Your local notes and recordings stay saved.", icon: "doc.text.fill")
                    logoutPoint("You can sign in again anytime.", icon: "arrow.clockwise")
                }
                .padding(AppSpacing.md)
                .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            }
            .appScreenContent(top: AppSpacing.lg, bottom: AppSpacing.sm)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AdaptiveActionStack(spacing: AppSpacing.sm) {
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
            .padding(.horizontal, AppLayout.screenHorizontalPadding)
            .padding(.vertical, AppSpacing.sm)
            .background(.ultraThinMaterial)
        }
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
                  if let error = store.persistenceError {
                      Section {
                          Label(error, systemImage: "exclamationmark.shield.fill")
                              .foregroundStyle(AppPalette.coral)
                      }
                  }
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
                                      Text(config.displayLocation)
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
                      Text("Webhook secrets are kept in Keychain. Nothing is sent until you tap Send from a meeting.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppPalette.background.ignoresSafeArea())
            .tint(AppPalette.accent)
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
                    .presentationDetents([.medium, .large])
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
        return parsed.scheme?.lowercased() == "https" && parsed.host != nil
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
                      Text("Only HTTPS endpoints are accepted. The full URL is stored in Keychain.")
                          .font(.caption)
                          .foregroundStyle(AppPalette.secondaryInk)
                  }
                Section("Label (optional)") {
                    TextField("#design-syncs", text: $label)
                        .autocorrectionDisabled()
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppPalette.background.ignoresSafeArea())
            .tint(AppPalette.accent)
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
            .scrollContentBackground(.hidden)
            .background(AppPalette.background.ignoresSafeArea())
            .tint(AppPalette.accent)
            .navigationTitle("Activity log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                events = await AnalyticsLog.shared.loadedEvents()
            }
        }
    }
}
