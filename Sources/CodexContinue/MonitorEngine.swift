import AppKit
import Combine
import Foundation
import ServiceManagement
@preconcurrency import UserNotifications

@MainActor
final class MonitorEngine: ObservableObject {
    // MARK: - Persisted Settings
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                    addLog("Enabled Launch at Login.", important: false)
                } else {
                    try SMAppService.mainApp.unregister()
                    addLog("Disabled Launch at Login.", important: false)
                }
            } catch {
                addLog("Launch at Login update failed: \(error.localizedDescription)", important: true)
            }
        }
    }

    @Published var isMonitoringEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isMonitoringEnabled, forKey: "isMonitoringEnabled")
            handleMonitoringToggle()
        }
    }

    @Published var targetChatTitle: String {
        didSet { UserDefaults.standard.set(targetChatTitle, forKey: "targetChatTitle") }
    }

    @Published var continueMessageText: String {
        didSet { UserDefaults.standard.set(continueMessageText, forKey: "continueMessageText") }
    }

    @Published var completionPhrase: String {
        didSet { UserDefaults.standard.set(completionPhrase, forKey: "completionPhrase") }
    }

    @Published var usageLimitAction: UsageLimitAction {
        didSet { UserDefaults.standard.set(usageLimitAction.rawValue, forKey: "usageLimitAction") }
    }

    @Published var usageLimitBufferMinutes: Int {
        didSet { UserDefaults.standard.set(usageLimitBufferMinutes, forKey: "usageLimitBufferMinutes") }
    }

    @Published var customUsageLimitKeywords: String {
        didSet { UserDefaults.standard.set(customUsageLimitKeywords, forKey: "customUsageLimitKeywords") }
    }

    @Published var pollIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(pollIntervalSeconds, forKey: "pollIntervalSeconds")
            restartTimerIfNeeded()
        }
    }

    @Published var settleDelaySeconds: Int {
        didSet { UserDefaults.standard.set(settleDelaySeconds, forKey: "settleDelaySeconds") }
    }

    @Published var userIdleGuardSeconds: Int {
        didSet { UserDefaults.standard.set(userIdleGuardSeconds, forKey: "userIdleGuardSeconds") }
    }

    @Published var postSendCooldownSeconds: Int {
        didSet { UserDefaults.standard.set(postSendCooldownSeconds, forKey: "postSendCooldownSeconds") }
    }

    // MARK: - Live State
    @Published private(set) var phase: MonitorPhase = .disabled
    @Published private(set) var latestSnapshot = CodexWindowSnapshot()
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var isArmedForZeroTransition: Bool = false
    @Published private(set) var continueSentCount: Int = 0
    @Published private(set) var logs: [ActivityLogEntry] = []

    private var timer: Timer?
    private var zeroSubagentsFirstSeenAt: Date?
    private var cooldownUntil: Date?
    private var usageLimitResumeAt: Date?
    private var usageLimitDetectedMessage: String?
    private var suppressedUsageLimitMessage: String?

    init() {
        let defaults = UserDefaults.standard
        self.targetChatTitle = defaults.string(forKey: "targetChatTitle") ?? "Clone the Klimper app"
        self.continueMessageText = defaults.string(forKey: "continueMessageText") ?? "continue"
        self.completionPhrase = defaults.string(forKey: "completionPhrase") ?? "Decomp analysis is completed 100%"
        let rawUsageAction = defaults.string(forKey: "usageLimitAction") ?? UsageLimitAction.waitUntilResetTime.rawValue
        self.usageLimitAction = UsageLimitAction(rawValue: rawUsageAction) ?? .waitUntilResetTime
        let savedBuffer = defaults.object(forKey: "usageLimitBufferMinutes") as? Int
        self.usageLimitBufferMinutes = savedBuffer ?? 2
        self.customUsageLimitKeywords = defaults.string(forKey: "customUsageLimitKeywords") ?? ""

        let savedPoll = defaults.double(forKey: "pollIntervalSeconds")
        self.pollIntervalSeconds = savedPoll > 0 ? savedPoll : 3.0

        let savedSettle = defaults.object(forKey: "settleDelaySeconds") as? Int
        self.settleDelaySeconds = savedSettle ?? 5

        let savedIdle = defaults.object(forKey: "userIdleGuardSeconds") as? Int
        self.userIdleGuardSeconds = savedIdle ?? 3

        let savedCooldown = defaults.object(forKey: "postSendCooldownSeconds") as? Int
        self.postSendCooldownSeconds = savedCooldown ?? 15

        self.isAccessibilityGranted = CodexAccessibilityController.shared.isAccessibilityTrusted(prompt: false)
        addLog("CodexContinue initialized. Ready to monitor.", important: false)
        refreshLiveSnapshotOnly()
    }

    // MARK: - Public Actions

    func promptForAccessibilityPermission() {
        isAccessibilityGranted = CodexAccessibilityController.shared.isAccessibilityTrusted(prompt: true)
        if isAccessibilityGranted {
            addLog("Accessibility permission granted.", important: true)
        } else {
            addLog("Prompted for Accessibility permission in System Settings.", important: false)
        }
    }

    func resetAndPromptAccessibilityPermission() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", "com.local.CodexContinue"]
        try? proc.run()
        proc.waitUntilExit()

        isAccessibilityGranted = CodexAccessibilityController.shared.isAccessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        addLog("Reset stale TCC entry and re-prompted for Accessibility permission.", important: true)
    }

    func refreshLiveSnapshotOnly() {
        isAccessibilityGranted = CodexAccessibilityController.shared.isAccessibilityTrusted(prompt: false)
        latestSnapshot = CodexAccessibilityController.shared.captureSnapshot(
            customUsageLimitKeywords: customUsageLimitKeywords
        )
    }

    func lockToCurrentCodexChat() {
        refreshLiveSnapshotOnly()
        let active = latestSnapshot.activeChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isEmpty else {
            addLog("Could not detect an active chat title in Codex window.", important: true)
            return
        }
        targetChatTitle = active
        addLog("Locked target chat to '\(active)'.", important: true)
        if isMonitoringEnabled {
            tick()
        }
    }

    func sendContinueNowManual() {
        refreshLiveSnapshotOnly()
        let target = targetChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty && !CodexAccessibilityController.shared.matchesTargetChat(activeTitle: latestSnapshot.activeChatTitle, target: target) {
            addLog("Blocked manual send: active chat '\(latestSnapshot.activeChatTitle)' does not match target '\(target)'.", important: true)
            return
        }
        if let limitMsg = latestSnapshot.usageLimitMessage {
            suppressedUsageLimitMessage = limitMsg
        }
        usageLimitResumeAt = nil
        usageLimitDetectedMessage = nil
        performSendContinue(reason: "Manual trigger")
    }

    func clearUsageLimitAndResume() {
        if let msg = usageLimitDetectedMessage ?? latestSnapshot.usageLimitMessage {
            suppressedUsageLimitMessage = msg
        }
        usageLimitResumeAt = nil
        usageLimitDetectedMessage = nil
        if !isMonitoringEnabled {
            isMonitoringEnabled = true
        }
        addLog("Cleared usage limit pause and resumed monitoring.", important: true)
        tick()
    }

    func setCustomUsageLimitResume(minutesFromNow: Int) {
        let resumeDate = Date().addingTimeInterval(TimeInterval(minutesFromNow * 60))
        usageLimitResumeAt = resumeDate
        let msg = usageLimitDetectedMessage ?? latestSnapshot.usageLimitMessage ?? "Usage limit pause"
        usageLimitDetectedMessage = msg
        if !isMonitoringEnabled {
            isMonitoringEnabled = true
        }
        phase = .pausedUsageLimit(message: msg, resumeAt: resumeDate)
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        addLog("Scheduled auto-resume & continue at \(fmt.string(from: resumeDate)).", important: true)
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Monitoring Loop

    private func handleMonitoringToggle() {
        if isMonitoringEnabled {
            usageLimitDetectedMessage = nil
            usageLimitResumeAt = nil
            addLog("Started monitoring chat '\(targetChatTitle)'.", important: true)
            restartTimerIfNeeded()
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            zeroSubagentsFirstSeenAt = nil
            isArmedForZeroTransition = false
            usageLimitResumeAt = nil
            usageLimitDetectedMessage = nil
            phase = .disabled
            addLog("Paused monitoring.", important: false)
        }
    }

    private func restartTimerIfNeeded() {
        timer?.invalidate()
        timer = nil
        guard isMonitoringEnabled else { return }

        let interval = max(1.0, pollIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func tick() {
        isAccessibilityGranted = CodexAccessibilityController.shared.isAccessibilityTrusted(prompt: false)
        guard isAccessibilityGranted else {
            phase = .waitingForPermission
            return
        }

        let snap = CodexAccessibilityController.shared.captureSnapshot(
            customUsageLimitKeywords: customUsageLimitKeywords
        )
        latestSnapshot = snap

        guard isMonitoringEnabled else {
            phase = .disabled
            return
        }

        // Reset suppressed usage limit once a new turn or subagent activity actually runs
        if snap.isMainAgentWorking || (snap.activeSubagentsCount ?? 0) > 0 {
            suppressedUsageLimitMessage = nil
        }

        // 0. If currently waiting for a scheduled usage-limit reset time, check countdown first
        if let resumeAt = usageLimitResumeAt {
            if Date() < resumeAt {
                phase = .pausedUsageLimit(
                    message: usageLimitDetectedMessage ?? "Usage limit active",
                    resumeAt: resumeAt
                )
                return
            } else {
                // Reset time reached! Suppress the old message in scrollback and send "continue" to wake the parent agent
                if let msg = usageLimitDetectedMessage ?? snap.usageLimitMessage {
                    suppressedUsageLimitMessage = msg
                }
                usageLimitResumeAt = nil
                usageLimitDetectedMessage = nil
                addLog("Usage limit reset time reached! Sending '\(continueMessageText)' to resume session.", important: true)
                performSendContinue(reason: "Usage limit reset time reached")
                return
            }
        }

        guard snap.isCodexRunning, snap.isWindowVisible else {
            phase = .waitingForCodexApp
            return
        }

        // 1. Guardrail 1: Verify active chat matches configured target chat
        let target = targetChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty && !CodexAccessibilityController.shared.matchesTargetChat(activeTitle: snap.activeChatTitle, target: target) {
            zeroSubagentsFirstSeenAt = nil
            phase = .differentChatActive(current: snap.activeChatTitle)
            return
        }

        // 2. Guardrail 4 (a): Check if the primary agent's latest response contains the completion phrase
        if let matchedPhrase = TextGuardrailMatcher.matchCompletionPhrase(
            in: snap.latestAgentResponseText,
            configuredPhrasesRaw: completionPhrase
        ) {
            isArmedForZeroTransition = false
            zeroSubagentsFirstSeenAt = nil
            isMonitoringEnabled = false
            phase = .stoppedCompleted(matchedPhrase: matchedPhrase)
            addLog("Completion phrase detected in primary agent response: \"\(matchedPhrase)\". Stopping monitor!", important: true)
            sendUserNotification(
                title: "Codex Task 100% Complete",
                body: "Detected completion phrase: \"\(matchedPhrase)\" in '\(snap.activeChatTitle)'."
            )
            return
        }

        // 3. Guardrail 5 (b): Check if usage limit / rate limit is hit
        if let limitMsg = snap.usageLimitMessage, limitMsg != suppressedUsageLimitMessage {
            let bufferSecs = TimeInterval(max(0, usageLimitBufferMinutes) * 60)
            let resetEval = TextGuardrailMatcher.evaluateResetDate(from: limitMsg, safetyBufferSeconds: bufferSecs)

            switch resetEval {
            case .alreadyPassedRecently:
                // This usage limit message in the scrollback is from earlier today and its reset time already passed!
                suppressedUsageLimitMessage = limitMsg

            case .future(let parsedDate):
                zeroSubagentsFirstSeenAt = nil
                isArmedForZeroTransition = false
                usageLimitDetectedMessage = limitMsg

                switch usageLimitAction {
                case .pauseManual:
                    isMonitoringEnabled = false
                    phase = .pausedUsageLimit(message: limitMsg, resumeAt: nil)
                    addLog("Usage limit detected: \"\(limitMsg)\". Paused until manual resume.", important: true)
                    sendUserNotification(
                        title: "Codex Usage Limit Reached",
                        body: "Monitoring paused for '\(snap.activeChatTitle)'."
                    )
                    return

                case .waitUntilResetTime:
                    usageLimitResumeAt = parsedDate
                    phase = .pausedUsageLimit(message: limitMsg, resumeAt: parsedDate)
                    let fmt = DateFormatter()
                    fmt.timeStyle = .short
                    fmt.dateStyle = Calendar.current.isDateInToday(parsedDate) ? .none : .short
                    addLog("Usage limit hit. Auto-pausing until \(fmt.string(from: parsedDate)) (includes +\(usageLimitBufferMinutes)m buffer).", important: true)
                    sendUserNotification(
                        title: "Codex Usage Limit — Auto-Resume Scheduled",
                        body: "Will resume '\(snap.activeChatTitle)' at \(fmt.string(from: parsedDate))."
                    )
                    return
                }

            case .notFound:
                zeroSubagentsFirstSeenAt = nil
                isArmedForZeroTransition = false
                usageLimitDetectedMessage = limitMsg
                isMonitoringEnabled = false
                phase = .pausedUsageLimit(message: limitMsg, resumeAt: nil)
                addLog("Usage limit detected (no reset time found in message: \"\(limitMsg)\"). Paused for manual resume.", important: true)
                sendUserNotification(
                    title: "Codex Usage Limit Reached",
                    body: "No reset timestamp found in message. Paused for manual resume."
                )
                return
            }
        }

        // 4. Check if subagents are currently active (`Active · N` where N > 0)
        if let activeCount = snap.activeSubagentsCount, activeCount > 0 {
            if !isArmedForZeroTransition {
                addLog("Detected \(activeCount) active subagent(s) in '\(snap.activeChatTitle)' — armed for completion.", important: true)
            }
            isArmedForZeroTransition = true
            zeroSubagentsFirstSeenAt = nil
            cooldownUntil = nil
            phase = .armedSubagentsRunning(activeCount: activeCount)
            return
        }

        // 5. Post-send cooldown check (while waiting for parent agent to spin up new subagents)
        if let cooldownUntil {
            let rem = Int(ceil(cooldownUntil.timeIntervalSinceNow))
            if rem > 0 {
                phase = .postSendCooldown(secondsRemaining: rem)
                return
            } else {
                self.cooldownUntil = nil
            }
        }

        // 6. Strict Edge Trigger (Option 1): Only trigger when armed (`Active > 0` was observed)
        guard isArmedForZeroTransition else {
            phase = .watchingIdleNotArmed
            return
        }

        // Confirm subagents are at 0 and the main agent is NOT currently working
        let isSubagentsZero = (snap.activeSubagentsCount == 0) || snap.sawNoActiveSubagentsLabel
        guard isSubagentsZero && !snap.isMainAgentWorking else {
            zeroSubagentsFirstSeenAt = nil
            if snap.isMainAgentWorking {
                phase = .watchingIdleNotArmed
            }
            return
        }

        // 7. Settle delay: ensure `Active · 0` and main agent idle persist for `settleDelaySeconds`
        let now = Date()
        if zeroSubagentsFirstSeenAt == nil {
            zeroSubagentsFirstSeenAt = now
            addLog("All subagents finished (Active · 0). Settling for \(settleDelaySeconds)s before sending '\(continueMessageText)'…", important: false)
        }

        let elapsedSettle = now.timeIntervalSince(zeroSubagentsFirstSeenAt ?? now)
        let remainingSettle = max(0, settleDelaySeconds - Int(floor(elapsedSettle)))
        if remainingSettle > 0 {
            phase = .settlingBeforeSend(secondsRemaining: remainingSettle)
            return
        }

        // 8. Guardrail 3: User Activity Guard (don't interrupt if user is typing or moving the mouse)
        let userIdleSecs = CodexAccessibilityController.shared.secondsSinceLastUserActivity()
        if Int(userIdleSecs) < userIdleGuardSeconds {
            phase = .waitingForUserIdle(secondsIdle: Int(userIdleSecs))
            return
        }

        // 9. All guardrails passed! Send "continue"
        performSendContinue(reason: "All subagents completed (Active · 0)")
    }

    private func performSendContinue(reason: String) {
        phase = .sendingContinue
        let msg = continueMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "continue"
            : continueMessageText.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = CodexAccessibilityController.shared.sendContinueMessage(
            msg,
            expectedChatTitle: targetChatTitle
        )

        switch result {
        case .sent:
            continueSentCount += 1
            isArmedForZeroTransition = false
            zeroSubagentsFirstSeenAt = nil
            cooldownUntil = Date().addingTimeInterval(TimeInterval(max(5, postSendCooldownSeconds)))
            phase = .postSendCooldown(secondsRemaining: postSendCooldownSeconds)
            addLog("Sent '\(msg)' to '\(latestSnapshot.activeChatTitle)' (\(reason)). Cycle #\(continueSentCount).", important: true)
        case .failed(let errorMsg):
            zeroSubagentsFirstSeenAt = Date()
            addLog("Send failed: \(errorMsg)", important: true)
        }
    }

    private func addLog(_ message: String, important: Bool) {
        let entry = ActivityLogEntry(timestamp: Date(), message: message, isImportant: important)
        logs.insert(entry, at: 0)
        if logs.count > 80 {
            logs.removeLast(logs.count - 80)
        }
    }

    private func sendUserNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
