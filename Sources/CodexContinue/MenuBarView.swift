import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: MonitorEngine
    @State private var selectedTab: Int = 0

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            if !engine.isAccessibilityGranted {
                permissionWarningBanner
            }

            if case .pausedUsageLimit(let msg, let resumeAt) = engine.phase {
                usageLimitBanner(message: msg, resumeAt: resumeAt)
            }

            if case .stoppedCompleted(let phrase) = engine.phase {
                completedBanner(phrase: phrase)
            }

            Picker("", selection: $selectedTab) {
                Text("Monitor").tag(0)
                Text("Guardrails").tag(1)
                Text("Log (\(engine.logs.count))").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selectedTab {
                case 0:
                    monitorTab
                case 1:
                    guardrailsTab
                default:
                    activityLogTab
                }
            }

            Divider()

            footerSection
        }
        .padding(12)
        .frame(width: 390)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(nsImage: CustomIconRenderer.menuBarImage(for: engine.phase.iconStyle, pointSize: 20, isTemplate: true))
                .foregroundColor(statusColor)
                .frame(width: 30, height: 30)
                .background(statusColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Codex Continue")
                        .font(.system(size: 13, weight: .bold))
                    Text("Cycles: \(engine.continueSentCount)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(engine.phase.shortStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: $engine.isMonitoringEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enable or pause automatic monitoring")
        }
    }

    private var statusColor: Color {
        switch engine.phase {
        case .disabled:
            return .secondary
        case .waitingForCodexApp, .waitingForPermission, .pausedUsageLimit:
            return .orange
        case .differentChatActive:
            return .yellow
        case .watchingIdleNotArmed:
            return .blue
        case .armedSubagentsRunning, .settlingBeforeSend, .sendingContinue:
            return .green
        case .waitingForUserIdle, .postSendCooldown:
            return .teal
        case .stoppedCompleted:
            return .mint
        }
    }

    // MARK: - Banners

    private var permissionWarningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.orange)
                Text("Accessibility Permission Required")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text("CodexContinue uses macOS Accessibility to read the active chat & subagent count and click Send.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack {
                Button("Prompt Permission") {
                    engine.promptForAccessibilityPermission()
                }
                .controlSize(.small)
                Button("Reset & Re-prompt") {
                    engine.resetAndPromptAccessibilityPermission()
                }
                .controlSize(.small)
                .help("Clears stale macOS TCC entry and re-prompts so you don't have to manually remove the app in System Settings")
                Button("Re-check") {
                    engine.refreshLiveSnapshotOnly()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func usageLimitBanner(message: String, resumeAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundColor(.orange)
                Text("Usage Limit Guardrail Triggered")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(3)

            if let resumeAt {
                Text("Auto-resuming & sending '\(engine.continueMessageText)' at \(resumeAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 6) {
                Button("Resume Now") {
                    engine.clearUsageLimitAndResume()
                }
                .controlSize(.small)

                Button("+30m") {
                    engine.setCustomUsageLimitResume(minutesFromNow: 30)
                }
                .controlSize(.small)

                Button("+1h") {
                    engine.setCustomUsageLimitResume(minutesFromNow: 60)
                }
                .controlSize(.small)

                Button("+3h") {
                    engine.setCustomUsageLimitResume(minutesFromNow: 180)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func completedBanner(phrase: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("Primary Agent Reported Completion!")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text("Matched phrase: \"\(phrase)\"")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tab 0: Monitor & Target Chat

    private var monitorTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Target Chat Card (with non-overlapping header buttons and full-width text field)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Target Chat / Tab")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()

                    if !engine.latestSnapshot.detectedChatCandidates.isEmpty {
                        Menu {
                            ForEach(engine.latestSnapshot.detectedChatCandidates, id: \.self) { candidate in
                                Button(candidate) {
                                    engine.targetChatTitle = candidate
                                }
                            }
                        } label: {
                            Label("Pick Chat", systemImage: "list.bullet")
                                .font(.system(size: 10))
                        }
                        .controlSize(.mini)
                        .fixedSize()
                        .help("Pick from detected chats in the Codex sidebar")
                    }

                    Button("Use Active Chat") {
                        engine.lockToCurrentCodexChat()
                    }
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Lock onto the chat currently open in the Codex window")
                }

                TextField("e.g. Clone the Klimper app", text: $engine.targetChatTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Live Telemetry Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Live Codex Window State")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button {
                        engine.refreshLiveSnapshotOnly()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh live Codex snapshot now")
                }

                telemetryRow(
                    label: "Codex App:",
                    value: engine.latestSnapshot.isCodexRunning
                        ? (engine.latestSnapshot.isWindowVisible ? "Running (Window Visible)" : "Running (No Window)")
                        : "Not Running",
                    highlight: engine.latestSnapshot.isCodexRunning ? .primary : .secondary
                )

                let chatMatches = CodexAccessibilityController.shared.matchesTargetChat(
                    activeTitle: engine.latestSnapshot.activeChatTitle,
                    target: engine.targetChatTitle
                )
                telemetryRow(
                    label: "Open Chat:",
                    value: engine.latestSnapshot.activeChatTitle.isEmpty
                        ? "—"
                        : "\(engine.latestSnapshot.activeChatTitle) \(chatMatches ? "✓" : "( mismatch )")",
                    highlight: chatMatches ? .green : .orange
                )

                let activeSubText: String = {
                    if let c = engine.latestSnapshot.activeSubagentsCount {
                        let donePart = engine.latestSnapshot.doneSubagentsCount.map { " · Done: \($0)" } ?? ""
                        return "Active · \(c)\(donePart)"
                    }
                    return engine.latestSnapshot.sawNoActiveSubagentsLabel ? "Active · 0 (No active)" : "Not visible"
                }()

                telemetryRow(
                    label: "Subagents:",
                    value: activeSubText,
                    highlight: (engine.latestSnapshot.activeSubagentsCount ?? 0) > 0 ? .green : .primary
                )

                telemetryRow(
                    label: "Primary Agent:",
                    value: engine.latestSnapshot.isMainAgentWorking
                        ? "Working (\(engine.latestSnapshot.mainAgentStatusText))"
                        : "Idle / Waiting",
                    highlight: engine.latestSnapshot.isMainAgentWorking ? .orange : .primary
                )

                if let limitMsg = engine.latestSnapshot.usageLimitMessage {
                    let bufferSecs = TimeInterval(max(0, engine.usageLimitBufferMinutes) * 60)
                    let evalResult = TextGuardrailMatcher.evaluateResetDate(from: limitMsg, safetyBufferSeconds: bufferSecs)
                    let limitSummary: String = {
                        switch evalResult {
                        case .future(let d):
                            return "Active (Resets + buffer: \(d.formatted(date: .omitted, time: .shortened)))"
                        case .alreadyPassedRecently:
                            return "Expired (Reset time already passed)"
                        case .notFound:
                            return "Active (No timestamp found)"
                        }
                    }()
                    telemetryRow(
                        label: "Usage Limit:",
                        value: limitSummary,
                        highlight: .orange
                    )
                }

                if !engine.latestSnapshot.latestAgentResponseText.isEmpty {
                    Divider()
                    Text("Latest Primary Agent Response:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(engine.latestSnapshot.latestAgentResponseText)
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Manual Control Row
            HStack(spacing: 8) {
                Button {
                    engine.sendContinueNowManual()
                } label: {
                    Label("Send '\(engine.continueMessageText)' Now", systemImage: "paperplane")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .help("Immediately type and send the continue message to the locked chat")

                Spacer()
            }
        }
    }

    private func telemetryRow(label: String, value: String, highlight: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(highlight)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Tab 1: Guardrails & Settings

    private var guardrailsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Guardrail A: Completion Phrase
                VStack(alignment: .leading, spacing: 4) {
                    Text("Completion Stop Phrase (Primary Agent)")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Stops monitoring when the primary agent's latest reply includes this phrase (separate multiple phrases with ';').")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("Decomp analysis is completed 100%", text: $engine.completionPhrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Guardrail B: Usage Limit
                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage / Rate Limit Guardrail")
                        .font(.system(size: 11, weight: .semibold))

                    Picker("When limit is hit:", selection: $engine.usageLimitAction) {
                        ForEach(UsageLimitAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .font(.system(size: 11))

                    if engine.usageLimitAction == .waitUntilResetTime {
                        HStack {
                            Text("Safety buffer after reset time:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Stepper("+\(engine.usageLimitBufferMinutes) min", value: $engine.usageLimitBufferMinutes, in: 0...30)
                                .font(.system(size: 10, weight: .medium))
                        }
                    }

                    Text("Optional extra limit keywords (comma-separated):")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("e.g. capacity exceeded, quota reached", text: $engine.customUsageLimitKeywords)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Message & Timing Guardrails
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continuation Message & Timing")
                        .font(.system(size: 11, weight: .semibold))

                    HStack {
                        Text("Message to send:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("continue", text: $engine.continueMessageText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 160)
                    }

                    HStack {
                        Text("Check interval:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $engine.pollIntervalSeconds) {
                            Text("2s").tag(2.0)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                            Text("15s").tag(15.0)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    HStack {
                        Text("Settle delay after Active · 0:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Stepper("\(engine.settleDelaySeconds)s", value: $engine.settleDelaySeconds, in: 1...60)
                            .font(.system(size: 10, weight: .medium))
                    }

                    HStack {
                        Text("User keyboard/mouse idle guard:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Stepper("\(engine.userIdleGuardSeconds)s", value: $engine.userIdleGuardSeconds, in: 0...30)
                            .font(.system(size: 10, weight: .medium))
                    }

                    HStack {
                        Text("Post-send cooldown:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Stepper("\(engine.postSendCooldownSeconds)s", value: $engine.postSendCooldownSeconds, in: 5...120, step: 5)
                            .font(.system(size: 10, weight: .medium))
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep Mac Awake (Screen-Off Mode):")
                                .font(.system(size: 10, weight: .medium))
                            Text("Prevents App Nap & idle sleep while monitoring (allows display off)")
                                .font(.system(size: 8.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $engine.keepAwakeWhileMonitoring)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Launch at Login:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: $engine.launchAtLogin)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Custom Menu Bar Icon Pack Legend
                VStack(alignment: .leading, spacing: 6) {
                    Text("Menu Bar Status Icon Pack")
                        .font(.system(size: 11, weight: .semibold))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            HStack(spacing: 6) {
                                Image(nsImage: CustomIconRenderer.menuBarImage(for: style, pointSize: 16, isTemplate: true))
                                    .frame(width: 18, height: 18)
                                Text(style.label)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxHeight: 290)
    }

    // MARK: - Tab 2: Activity Log

    private var activityLogTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Activity")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Clear") {
                    engine.clearLogs()
                }
                .controlSize(.mini)
            }

            if engine.logs.isEmpty {
                Text("No events logged yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(engine.logs) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.system(size: 10, weight: entry.isImportant ? .medium : .regular))
                                    .foregroundColor(entry.isImportant ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                .frame(height: 220)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("Low-resource AX monitor (~0% CPU)")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}
