import CursorAPICore
import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CursorAPIAppModel
    @State private var showingAPIKeyDialog = false

    var body: some View {
        ZStack {
            AppTheme.windowBackground
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header

                if let lastError = model.lastError {
                    AppNoticeBanner(
                        title: model.statusText == "Could not start" ? "Could not start" : "\(CursorAPIBrand.displayName) needs attention",
                        message: lastError,
                        dismiss: model.dismissError
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        guidedContent
                    }
                    .padding(24)
                }
            }
        }
        .background(AppTheme.windowBackground)
        .onAppear {
            model.startServerWithoutPromptIfReady()
        }
        .onChange(of: model.settings.cursorAPIKey) { _, _ in
            model.apiKeyDidChange()
        }
        .sheet(isPresented: $showingAPIKeyDialog) {
            APIKeyDialog(model: model)
        }
    }

    enum TopPage: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case settings = "Settings"

        var id: String { rawValue }
    }

    private var header: some View {
        HStack(spacing: 12) {
            UsageSummaryHeader(activity: model.apiActivity)

            Spacer()

            MenuBarModeToggle(
                isOn: Binding(
                    get: { model.settings.menuBarOnly },
                    set: { model.setMenuBarOnly($0) }
                )
            )

            HStack(spacing: 6) {
                StatusPill(tone: statusTone, text: statusLabel)
                StatusPill(
                    tone: model.isRunning ? (model.needsKeychainPermission ? .warning : .ok) : .muted,
                    text: model.isRunning ? "Server On" : "Server Off"
                )
            }

            APIKeyHeaderButton(
                isChecking: model.isCheckingSDK,
                isVerified: model.sdkCheckSucceeded && !model.needsKeychainPermission,
                needsAttention: !model.hasCursorAPIKey || model.needsKeychainPermission || model.sdkCheckFailed
            ) {
                showingAPIKeyDialog = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var guidedContent: some View {
        Group {
            if !model.hasCursorAPIKey {
                APIKeyOnlyPanel(model: model)
            } else if model.needsKeychainPermission {
                UnlockOnlyPanel(model: model)
            } else if !model.sdkConfigured {
                TransportSetupPanel()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    EndpointPanel(model: model)
                    SimpleIntegrationsPanel(model: model)
                }
            }
        }
    }

    private var statusLabel: String {
        if !model.hasCursorAPIKey {
            return "Needs Key"
        }
        if model.needsKeychainPermission {
            return "Key Locked"
        }
        if !model.sdkConfigured {
            return "Bridge Missing"
        }
        return "Ready"
    }

    private var statusTone: StatusPill.Tone {
        model.hasCursorAPIKey && !model.needsKeychainPermission && model.sdkConfigured ? .ok : .warning
    }
}

struct MenuBarModeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text("Menu Bar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                MenuBarSwitch(isOn: isOn)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.controlBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator.opacity(0.7), lineWidth: 0.5)
        }
        .help("Run as a macOS menu bar app")
        .accessibilityLabel("Run as a macOS menu bar app")
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
        .focusEffectDisabled()
    }
}

struct MenuBarSwitch: View {
    var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : AppTheme.separator.opacity(0.55))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                .padding(2)
        }
        .frame(width: 31, height: 18)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

struct UsageSummaryHeader: View {
    var activity: LocalAPIActivitySnapshot

    var body: some View {
        HStack(spacing: 10) {
            UsageMetric(label: "In", value: compact(activity.inputTokens))
            UsageMetric(label: "Out", value: compact(activity.outputTokens))
            UsageMetric(label: "Cached", value: compact(activity.cachedInputTokens))
            UsageMetric(label: "Cost", value: cost(activity.costDollars))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.controlBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator.opacity(0.7), lineWidth: 0.5)
        }
        .help("Estimated local API usage recorded by this app")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func cost(_ value: Double) -> String {
        if value == 0 {
            return "$0"
        }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}

struct UsageMetric: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 44, alignment: .trailing)
    }
}

struct APIKeyOnlyPanel: View {
    @ObservedObject var model: CursorAPIAppModel
    @State private var draftKey = ""
    @FocusState private var keyFieldFocused: Bool

    private var trimmedDraftKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveKey: Bool {
        trimmedDraftKey.count >= 16
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                Label("Add your Cursor API key", systemImage: "key.fill")
                    .font(.title3.weight(.semibold))
                Text("The local API starts after the key is saved. The key is stored in macOS Keychain and is only read by \(CursorAPIBrand.displayName).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    SecureField("crsr_...", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFieldFocused)
                    PillActionButton("Save Key") {
                        model.settings.cursorAPIKey = trimmedDraftKey
                        model.saveKeyStartAndCheckIfReady()
                        draftKey = ""
                        keyFieldFocused = false
                    }
                    .disabled(!canSaveKey)
                }
            }
        }
        .onAppear {
            keyFieldFocused = true
        }
    }
}

struct UnlockOnlyPanel: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        GlassPanel {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock the saved API key")
                        .font(.title3.weight(.semibold))
                    Text("macOS needs permission before the local API can read the key from Keychain.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                PillActionButton("Unlock Key") {
                    model.startServer()
                }
            }
        }
    }
}

struct EndpointPanel: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Local API")
                    .font(.title3.weight(.semibold))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                EndpointRow(title: "Root", value: model.baseURL)
                EndpointRow(title: "Chat", value: model.chatCompletionsURL)
                EndpointRow(title: "Responses", value: model.responsesURL)
                EndpointRow(title: "Models", value: model.modelsURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EndpointRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            CopyEndpointControl(value: value)
        }
        .padding(.vertical, 7)
    }
}

struct CopyEndpointControl: View {
    var value: String
    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        Group {
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 24, height: 24)
            } else {
                LucideCopyIcon()
                    .stroke(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 16, height: 16)
                    .frame(width: 24, height: 24)
            }
        }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .help(copied ? "Copied" : "Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                copy()
            }
            .focusable(false)
            .focusEffectDisabled()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                if copyGeneration == generation {
                    copied = false
                }
            }
        }
    }
}

struct LucideCopyIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let scale = size / 24
        let origin = CGPoint(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2
        )
        func x(_ value: CGFloat) -> CGFloat { origin.x + value * scale }
        func y(_ value: CGFloat) -> CGFloat { origin.y + value * scale }

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: x(8), y: y(8), width: 14 * scale, height: 14 * scale),
            cornerSize: CGSize(width: 2 * scale, height: 2 * scale)
        )
        path.move(to: CGPoint(x: x(4), y: y(16)))
        path.addCurve(
            to: CGPoint(x: x(2), y: y(14)),
            control1: CGPoint(x: x(2.9), y: y(16)),
            control2: CGPoint(x: x(2), y: y(15.1))
        )
        path.addLine(to: CGPoint(x: x(2), y: y(4)))
        path.addCurve(
            to: CGPoint(x: x(4), y: y(2)),
            control1: CGPoint(x: x(2), y: y(2.9)),
            control2: CGPoint(x: x(2.9), y: y(2))
        )
        path.addLine(to: CGPoint(x: x(14), y: y(2)))
        path.addCurve(
            to: CGPoint(x: x(16), y: y(4)),
            control1: CGPoint(x: x(15.1), y: y(2)),
            control2: CGPoint(x: x(16), y: y(2.9))
        )
        return path
    }
}

struct APIKeyHeaderButton: View {
    var isChecking: Bool
    var isVerified: Bool
    var needsAttention: Bool
    var action: () -> Void

    var body: some View {
        Group {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
        }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help("api key")
            .accessibilityLabel("API key")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
            .focusable(false)
            .focusEffectDisabled()
    }

    private var iconColor: Color {
        if isVerified {
            return .green
        }
        if needsAttention {
            return .orange
        }
        return .secondary
    }
}

struct APIKeyDialog: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CursorAPIAppModel
    @State private var draftKey = ""
    @FocusState private var keyFieldFocused: Bool

    private var trimmedDraftKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveKey: Bool {
        trimmedDraftKey.count >= 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("API Key")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text(model.hasCursorAPIKey ? "Enter a new Cursor API key to replace the saved key." : "Enter a Cursor API key to start the local API.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("crsr_...", text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .focused($keyFieldFocused)
                .onSubmit(save)

            Text("Saved locally in macOS Keychain and used only by \(CursorAPIBrand.displayName).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                PillActionButton("Cancel") {
                    dismiss()
                }
                PillActionButton(model.hasCursorAPIKey ? "Replace Key" : "Save Key") {
                    save()
                }
                .disabled(!canSaveKey)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.async {
                keyFieldFocused = true
            }
        }
    }

    private func save() {
        guard canSaveKey else { return }
        model.settings.cursorAPIKey = trimmedDraftKey
        model.saveKeyStartAndCheckIfReady()
        draftKey = ""
        keyFieldFocused = false
        dismiss()
    }
}

struct SimpleIntegrationsPanel: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Setup")
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.integrations) { status in
                    SimpleIntegrationRow(
                        status: status,
                        actionTitle: model.actionTitle(for: status),
                        canPrepareAgentConfigs: model.canPrepareAgentConfigs
                    ) {
                        model.install(status.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SimpleIntegrationRow: View {
    var status: AgentIntegrationStatus
    var actionTitle: String
    var canPrepareAgentConfigs: Bool
    var install: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IntegrationIcon(id: status.id, installed: status.installed)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.id.displayName)
                    .font(.body.weight(.semibold))
                Text(status.detail)
                    .font(.callout)
                    .foregroundStyle(status.needsUpdate ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PillActionButton(actionTitle) {
                install()
            }
            .disabled(status.installed || !status.canInstall || !canPrepareAgentConfigs)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 10)
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct AgentSetupNotice: View {
    var message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AppNoticeBanner: View {
    var title: String
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 22, height: 22)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(AppTheme.controlBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum AppTheme {
    static var headerBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var controlBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var panelBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static var keyRequiredBackground: Color {
        Color.orange.opacity(0.12)
    }

    static var keyRequiredStroke: Color {
        Color.orange.opacity(0.38)
    }
}

struct HeaderPageTabs: View {
    @Binding var selection: ContentView.TopPage

    var body: some View {
        HStack(spacing: 10) {
            HeaderPageTab(
                icon: "server.rack",
                label: "Connection",
                isSelected: selection == .connection
            ) {
                selection = .connection
            }
            HeaderPageTab(
                icon: "gearshape",
                label: "Settings",
                isSelected: selection == .settings
            ) {
                selection = .settings
            }
        }
        .accessibilityLabel("Page")
    }
}

struct HeaderPageTab: View {
    var icon: String
    var label: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .focusable(false)
        .focusEffectDisabled()
    }
}

struct IconActionButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    var body: some View {
        icon
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
            .focusable(false)
            .focusEffectDisabled()
    }

    @ViewBuilder
    private var icon: some View {
        if systemName == "doc.on.doc" {
            LucideCopyIcon()
                .stroke(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct PillActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button {
            if isEnabled {
                action()
            }
        } label: {
            Text(title)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.65))
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(backgroundColor)
                .clipShape(Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.primary.opacity(0.045)
        }
        return Color.primary.opacity(isHovering ? 0.12 : 0.08)
    }
}

struct CursorLogo: View {
    var body: some View {
        Group {
            if let image = Bundle.module.url(forResource: "cursor-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
                    .overlay {
                        Image(systemName: "cursorarrow")
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityLabel("Cursor")
    }
}

struct APIKeyRequiredPanel: View {
    @ObservedObject var model: CursorAPIAppModel
    @State private var draftKey = ""
    @FocusState private var keyFieldFocused: Bool

    private var trimmedDraftKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveKey: Bool {
        trimmedDraftKey.count >= 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Cursor API key required")
                    .font(.callout.weight(.semibold))
                Text("The local API stays off until a key is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                SecureField("crsr_...", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFieldFocused)
                PillActionButton(model.sdkConfigured ? "Save & Start" : "Save Key") {
                    model.settings.cursorAPIKey = trimmedDraftKey
                    model.saveKeyStartAndCheckIfReady()
                    draftKey = ""
                    keyFieldFocused = false
                }
                .disabled(!canSaveKey)
            }
        }
        .padding(12)
        .background(AppTheme.keyRequiredBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.keyRequiredStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            keyFieldFocused = true
        }
    }
}

struct KeychainPermissionPanel: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved key needs permission")
                    .font(.callout.weight(.semibold))
                Text("\(CursorAPIBrand.displayName) stores your Cursor API key in macOS Keychain and reads it only when you unlock Composer access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PillActionButton(model.isRunning ? "Unlock Key" : "Unlock & Start") {
                model.startServer()
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TransportSetupPanel: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("SDK bridge missing")
                    .font(.callout.weight(.semibold))
                Text("This build was packaged without the local SDK bridge script or runtime dependencies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ConnectionPage: View {
    @ObservedObject var model: CursorAPIAppModel
    var editAPIKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.hasCursorAPIKey {
                APIKeyRequiredPanel(model: model)
            } else if model.needsKeychainPermission {
                KeychainPermissionPanel(model: model)
            } else if !model.sdkConfigured {
                TransportSetupPanel()
            }

            HStack(spacing: 12) {
                Text(model.baseURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppTheme.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                IconActionButton(systemName: "doc.on.doc", help: "Copy local API URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.baseURL, forType: .string)
                }
                Spacer()
                PillActionButton(model.isRunning ? "Stop" : "Start") {
                    model.isRunning ? model.stopServer() : model.startServerWithoutPromptIfReady()
                }
                .disabled(!model.isRunning && !model.canStartServer)
                PillActionButton("Restart") {
                    model.restartServer()
                }
                .disabled(!model.canStartServer)
            }

            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            APIActivityPanel(activity: model.apiActivity) {
                model.clearAPIActivity()
            }

            if model.hasCursorAPIKey && !model.needsKeychainPermission {
                SDKConnectivityPanel(model: model, editAPIKey: editAPIKey)
            }
        }
    }
}

struct APIActivityPanel: View {
    var activity: LocalAPIActivitySnapshot
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(activity.totalRequests == 0 ? Color.secondary : Color.green)
                    .frame(width: 24, height: 24)
                    .background((activity.totalRequests == 0 ? Color.secondary : Color.green).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Local API Activity")
                        .font(.callout.weight(.semibold))
                    Text(activitySummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    ActivityMetric(label: "OK", value: activity.successfulRequests, tone: .green)
                    ActivityMetric(label: "Errors", value: activity.failedRequests, tone: .orange)
                    ActivityMetric(label: "Streams", value: activity.streamingRequests, tone: .blue)
                }

                PillActionButton("Clear") {
                    clear()
                }
                .disabled(activity.totalRequests == 0)
            }

            if !activity.recentRequests.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(activity.recentRequests.enumerated()), id: \.offset) { _, event in
                        APIRequestRow(event: event)
                    }
                }
                .background(AppTheme.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.separator, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var activitySummary: String {
        guard let last = activity.lastRequest else {
            return "No local requests yet."
        }
        let mode = last.streaming ? "stream" : "json"
        return "\(last.method) \(last.path) returned \(last.status) in \(last.durationMilliseconds) ms (\(mode))."
    }
}

struct ActivityMetric: View {
    var label: String
    var value: Int
    var tone: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(value == 0 ? Color.secondary : tone)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 42, alignment: .trailing)
    }
}

struct APIRequestRow: View {
    var event: LocalAPIRequestEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.method)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(event.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if event.streaming {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .help("Streaming response")
            }
            Text("\(event.status)")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(event.status >= 400 ? Color.orange : Color.green)
                .frame(width: 34, alignment: .trailing)
            Text("\(event.durationMilliseconds) ms")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 10)
        }
    }
}

struct SDKConnectivityPanel: View {
    @ObservedObject var model: CursorAPIAppModel
    var editAPIKey: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tone.opacity(0.12))
                if model.isCheckingSDK {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if model.sdkCheckNeedsAPIKeyAction {
                PillActionButton("Fix API Key") {
                    editAPIKey()
                }
            } else {
                PillActionButton(model.isCheckingSDK ? "Checking" : "Check Composer") {
                    model.checkSDKConnectivity()
                }
                .disabled(!model.canCheckSDK)
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        if model.isCheckingSDK {
            return "Checking Composer"
        }
        switch model.sdkCheckState {
        case .idle:
            return model.sdkConfigured ? "Composer Ready to Check" : "SDK Bridge Missing"
        case .success:
            return "Composer Check Passed"
        case .failure:
            return "Composer Check Failed"
        }
    }

    private var detail: String {
        if model.isCheckingSDK {
            return "Testing the saved key through the bundled local SDK bridge."
        }
        switch model.sdkCheckState {
        case .idle:
            return model.sdkConfigured ? "Ready to verify Composer through the bundled local SDK bridge." : "This app build is missing its bundled SDK bridge."
        case .success(let message), .failure(let message):
            return message
        }
    }

    private var iconName: String {
        switch model.sdkCheckState {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        case .idle:
            return model.sdkConfigured ? "network" : "network.slash"
        }
    }

    private var tone: Color {
        switch model.sdkCheckState {
        case .success:
            return .green
        case .failure:
            return .orange
        case .idle:
            return model.sdkConfigured ? .blue : .orange
        }
    }
}

struct SettingsPage: View {
    @ObservedObject var model: CursorAPIAppModel
    var apiKeyReplacementRequestID: Int
    @State private var showsAdvancedTransport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsSummaryTile(
                    icon: "key.fill",
                    title: model.hasCursorAPIKey ? "Key Saved" : "Key Required",
                    detail: "macOS Keychain",
                    tone: model.hasCursorAPIKey ? .ok : .warning
                )
                SettingsSummaryTile(
                    icon: model.isRunning ? (model.needsKeychainPermission ? "lock.circle.fill" : "checkmark.circle.fill") : "power.circle",
                    title: model.isRunning ? (model.needsKeychainPermission ? "API Locked" : "API Running") : (model.sdkConfigured ? (model.hasCursorAPIKey ? "Ready to Start" : "Needs Key") : "SDK Bridge Missing"),
                    detail: model.isRunning ? (model.needsKeychainPermission ? "Unlock saved key" : model.baseURL) : (model.sdkConfigured ? "Bundled SDK bridge" : "SDK bridge missing"),
                    tone: model.isRunning && model.sdkConfigured && !model.needsKeychainPermission ? .ok : (model.sdkConfigured && !model.needsKeychainPermission ? .muted : .warning)
                )
                SettingsSummaryTile(
                    icon: model.settings.launchAtLogin ? "power.circle.fill" : "power.circle",
                    title: model.settings.launchAtLogin ? "Login Launch" : "Manual Launch",
                    detail: "Startup behavior",
                    tone: model.settings.launchAtLogin ? .ok : .muted
                )
            }

            SettingsGroup(title: "Credentials", icon: "key.fill") {
                SettingsFieldRow(title: "Cursor API Key", subtitle: "Stored locally in Keychain") {
                    APIKeySettingsControl(model: model, replacementRequestID: apiKeyReplacementRequestID)
                }
            }

            SettingsGroup(title: "Local Server", icon: "server.rack") {
                SettingsFieldRow(title: "Port", subtitle: "Loopback listener port") {
                    TextField("8787", value: $model.settings.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                SettingsFieldRow(title: "Launch at Login", subtitle: "Start \(CursorAPIBrand.displayName) when macOS signs in") {
                    Toggle("", isOn: $model.settings.launchAtLogin)
                        .labelsHidden()
                }
            }

            AdvancedTransportGroup(isExpanded: $showsAdvancedTransport, model: model)

            HStack {
                Spacer()
                PillActionButton("Save Settings") {
                    model.saveSettings()
                }
            }
        }
    }
}

struct APIKeySettingsControl: View {
    @ObservedObject var model: CursorAPIAppModel
    var replacementRequestID: Int
    @State private var isReplacing = false
    @State private var draftKey = ""
    @FocusState private var keyFieldFocused: Bool

    private var trimmedDraftKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveDraft: Bool {
        trimmedDraftKey.count >= 16
    }

    var body: some View {
        Group {
            if model.hasCursorAPIKey && !isReplacing {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Using saved key")
                        Text("Read from Keychain only when starting the local API")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PillActionButton("Replace Key") {
                        draftKey = ""
                        isReplacing = true
                        keyFieldFocused = true
                    }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("crsr_...", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFieldFocused)
                    PillActionButton(model.hasCursorAPIKey ? "Save Key" : "Add Key") {
                        model.settings.cursorAPIKey = trimmedDraftKey
                        model.saveKeyStartAndCheckIfReady()
                        draftKey = ""
                        isReplacing = false
                        keyFieldFocused = false
                    }
                    .disabled(!canSaveDraft)

                    if model.hasCursorAPIKey {
                        PillActionButton("Cancel") {
                            draftKey = ""
                            isReplacing = false
                            keyFieldFocused = false
                        }
                    }
                }
                .onAppear {
                    keyFieldFocused = true
                }
            }
        }
        .onChange(of: replacementRequestID) { _, _ in
            draftKey = ""
            isReplacing = true
            keyFieldFocused = true
        }
    }
}

struct AdvancedTransportGroup: View {
    @Binding var isExpanded: Bool
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                TransportOverrideNotice(configured: model.sdkConfigured)

                Text("\(CursorAPIBrand.displayName) runs a bundled local SDK bridge. These settings are only for diagnostics and compatibility labels; the app supplies the SDK bridge automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                VStack(spacing: 0) {
                    SettingsFieldRow(title: "Bridge Mode", subtitle: "Bundled local SDK bridge") {
                        Text("Automatic")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SettingsFieldRow(title: "Client Version", subtitle: "SDK compatibility label") {
                        TextField("sdk-1.0.13", text: $model.settings.clientVersion)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .background(AppTheme.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.separator, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced SDK Bridge")
                        .font(.callout.weight(.semibold))
                    Text(model.sdkConfigured ? "Bundled SDK bridge ready" : "Bundled SDK bridge missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TransportOverrideNotice: View {
    var configured: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: configured ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(configured ? .green : .blue)
                .frame(width: 22, height: 22)
                .background((configured ? Color.green : Color.blue).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(configured ? "Bundled SDK bridge ready" : "Bundled SDK bridge missing")
                    .font(.caption.weight(.semibold))
                Text(configured ? "Save Settings restarts the local API with these SDK bridge settings." : "A distributable build should bundle the SDK bridge script, runtime, and dependencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AppTheme.panelBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsSummaryTile: View {
    enum Tone {
        case ok
        case warning
        case muted
    }

    var icon: String
    var title: String
    var detail: String
    var tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(AppTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch tone {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .muted:
            return .secondary
        }
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            VStack(spacing: 0) {
                content
            }
            .background(AppTheme.panelBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.separator, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SettingsFieldRow<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 204)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        SettingsPage(model: model, apiKeyReplacementRequestID: 0)
        .padding(24)
    }
}

struct StatusPill: View {
    enum Tone {
        case ok
        case muted
        case warning
    }

    var tone: Tone
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch tone {
        case .ok:
            return .green
        case .muted:
            return .secondary
        case .warning:
            return .orange
        }
    }
}

struct SectionTitle: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
    }
}

struct IntegrationRow: View {
    var status: AgentIntegrationStatus
    var actionTitle: String
    var canPrepareAgentConfigs: Bool
    var install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IntegrationIcon(id: status.id, installed: status.installed)
                Text(status.id.displayName)
                    .font(.body.weight(.semibold))
                Spacer()
                PillActionButton(actionTitle) {
                    install()
                }
                .disabled(status.installed || !status.canInstall || !canPrepareAgentConfigs)
            }
            Text(status.detail)
                .font(.callout)
                .foregroundStyle(status.needsUpdate ? Color.orange : Color.secondary)
                .lineLimit(2)
            if let path = status.configPath {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .background(AppTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct IntegrationIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var id: AgentIntegrationID
    var installed: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppTheme.separator, lineWidth: 0.5)
                }
            if let image = id.iconImage(darkMode: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if installed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .background(Circle().fill(AppTheme.panelBackground))
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 30, height: 30)
        .help(id.displayName)
    }
}

private extension AgentIntegrationID {
    var iconFileName: String {
        switch self {
        case .opencode:
            return "opencode"
        case .codex:
            return "codex"
        case .vscode:
            return "vscode"
        case .cline:
            return "cline"
        case .kilo:
            return "kilo"
        case .pi:
            return "pi"
        case .factory:
            return "factory"
        case .continueDev:
            return "continue"
        case .aider:
            return "aider"
        case .roo:
            return "roo"
        }
    }

    func iconImage(darkMode: Bool) -> NSImage? {
        let darkFileName = "\(iconFileName)-dark"
        let resourceName = darkMode && Bundle.module.url(forResource: darkFileName, withExtension: "png") != nil ? darkFileName : iconFileName
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
