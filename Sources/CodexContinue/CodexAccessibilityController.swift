import AppKit
import ApplicationServices
import Foundation

final class CodexAccessibilityController {
    static let shared = CodexAccessibilityController()

    private let codexBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat"
    ]

    struct AXNodeInfo {
        let element: AXUIElement
        let role: String
        let subrole: String
        let title: String
        let value: String
        let desc: String
        let placeholder: String
        let help: String
        let position: CGPoint?
        let size: CGSize?
        let enabled: Bool

        /// Visible text only (excludes aria-label `desc` and `help` tooltips on container groups/toolbars).
        var visibleText: String {
            [value, title]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        }

        /// Combined text including accessibility description/help.
        var combinedText: String {
            [value, title, desc, help]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        }
    }

    /// Checks whether the app has macOS Accessibility trust.
    func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Returns seconds since the user last moved the mouse, clicked, or pressed a key.
    func secondsSinceLastUserActivity() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .mouseMoved,
            .scrollWheel
        ]
        var minSeconds: TimeInterval = 999_999
        for type in eventTypes {
            let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            if secs < minSeconds {
                minSeconds = secs
            }
        }
        return minSeconds
    }

    /// Finds the running Codex / ChatGPT application.
    func findRunningCodexApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: {
            if let bid = $0.bundleIdentifier, codexBundleIdentifiers.contains(bid) {
                return true
            }
            return false
        }) {
            return exact
        }

        return apps.first(where: {
            let name = ($0.localizedName ?? "").lowercased()
            return name == "codex" || name == "chatgpt"
        })
    }

    /// Enables Electron's Chromium accessibility tree on the target application.
    private func enableElectronAccessibility(for appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Captures a lightweight snapshot of the active Codex window state.
    func captureSnapshot(customUsageLimitKeywords: String = "") -> CodexWindowSnapshot {
        var snapshot = CodexWindowSnapshot()

        guard let app = findRunningCodexApp(), !app.isTerminated else {
            return snapshot
        }
        snapshot.isCodexRunning = true

        guard isAccessibilityTrusted(prompt: false) else {
            return snapshot
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(for: appElement)

        guard let windowElement = findPrimaryWindow(for: appElement) else {
            return snapshot
        }

        let windowPos = getPointAttribute(windowElement, attribute: kAXPositionAttribute) ?? .zero
        let windowSize = getSizeAttribute(windowElement, attribute: kAXSizeAttribute) ?? CGSize(width: 1200, height: 800)
        snapshot.isWindowVisible = windowSize.width > 100 && windowSize.height > 100

        var nodes: [AXNodeInfo] = []
        var visited = Set<CFHashCode>()
        collectNodes(
            from: windowElement,
            depth: 0,
            maxDepth: 36,
            maxNodes: 2500,
            visited: &visited,
            into: &nodes
        )

        // Spatial boundaries relative to the Codex window
        let leftSidebarMaxX = windowPos.x + min(max(windowSize.width * 0.19, 180), 270)
        let rightSidebarMinX = windowPos.x + windowSize.width - min(max(windowSize.width * 0.23, 210), 330)
        let topBarMaxY = windowPos.y + 72
        let composerMinY = windowPos.y + windowSize.height - 165

        var centerTranscriptTexts: [(y: CGFloat, x: CGFloat, text: String)] = []
        var allPotentialUsageLimitTexts: [String] = []
        var sidebarCandidates: [String] = []
        var topCenterTitles: [(x: CGFloat, text: String)] = []
        var chatToolbarExtractedTitle: String? = nil
        var activeSubagentWorkingRows = 0

        for node in nodes {
            // Check if this node is the `<div role="toolbar" aria-label="Chat toolbar">` container
            if chatToolbarExtractedTitle == nil &&
                (node.desc.caseInsensitiveCompare("Chat toolbar") == .orderedSame ||
                 node.title.caseInsensitiveCompare("Chat toolbar") == .orderedSame) {
                chatToolbarExtractedTitle = extractChatTitleFromToolbar(node.element)
            }

            let text = node.combinedText
            let visible = node.visibleText
            let pos = node.position
            let x = pos?.x ?? (windowPos.x + windowSize.width * 0.5)
            let y = pos?.y ?? (windowPos.y + windowSize.height * 0.5)

            // 1. Check composer input & send/stop buttons
            if isComposerInputNode(node, composerMinY: composerMinY, leftMaxX: leftSidebarMaxX, rightMinX: rightSidebarMinX) {
                snapshot.hasComposerInput = true
                if node.placeholder.localizedCaseInsensitiveContains("Working") {
                    snapshot.isMainAgentWorking = true
                    snapshot.mainAgentStatusText = "Working…"
                }
            }

            if node.role == kAXButtonRole as String {
                let buttonLabels = [node.title, node.desc, node.help, node.value]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for label in buttonLabels {
                    if label.caseInsensitiveCompare("Send") == .orderedSame {
                        snapshot.hasSendButton = true
                    } else if label.caseInsensitiveCompare("Stop") == .orderedSame && x > leftSidebarMaxX && x < rightSidebarMinX {
                        snapshot.isMainAgentWorking = true
                        snapshot.mainAgentStatusText = "Stop button active"
                    }
                }
            }

            guard !text.isEmpty else { continue }

            // 2. Parse Subagent counts (`Active · N`, `Done · M`, `No active subagents`)
            if let activeCount = parseSubagentHeaderCount(prefix: "Active", from: text) {
                snapshot.activeSubagentsCount = activeCount
            }
            if let doneCount = parseSubagentHeaderCount(prefix: "Done", from: text) {
                snapshot.doneSubagentsCount = doneCount
            }
            if text.localizedCaseInsensitiveContains("No active subagents") {
                snapshot.sawNoActiveSubagentsLabel = true
                if snapshot.activeSubagentsCount == nil {
                    snapshot.activeSubagentsCount = 0
                }
            }

            // Secondary check: count "Working" / "Waiting" badges in the right Subagents panel
            if x >= rightSidebarMinX {
                if text == "Working" || text == "Waiting" {
                    activeSubagentWorkingRows += 1
                }
                continue
            }

            // 3. Left sidebar chat list candidates
            if x <= leftSidebarMaxX {
                if y > topBarMaxY && !visible.isEmpty && isLikelySidebarChatTitle(visible) {
                    if !sidebarCandidates.contains(visible) {
                        sidebarCandidates.append(visible)
                    }
                }
                continue
            }

            // 4. Center column (`leftSidebarMaxX < x < rightSidebarMinX`)
            if y <= topBarMaxY {
                // Only use visibleText on static text / heading / button nodes, never container aria-labels like "Chat toolbar"
                let candidateTitle = visible.isEmpty ? "" : visible
                if !candidateTitle.isEmpty &&
                    (node.role == (kAXStaticTextRole as String) || node.role == "AXHeading" || node.role == (kAXButtonRole as String)) &&
                    isLikelyHeaderChatTitle(candidateTitle) {
                    topCenterTitles.append((x: x, text: candidateTitle))
                }
            } else if y < composerMinY {
                // Main transcript area (plus rate-limit cards above the composer)
                allPotentialUsageLimitTexts.append(text)
                if !visible.isEmpty && visible != text {
                    allPotentialUsageLimitTexts.append(visible)
                }

                if let workingMatch = matchMainAgentWorkingText(text) {
                    snapshot.isMainAgentWorking = true
                    snapshot.mainAgentStatusText = workingMatch
                }

                if isMeaningfulTranscriptText(text, role: node.role) {
                    centerTranscriptTexts.append((y: y, x: x, text: text))
                }
            } else {
                // Composer area texts (rate limit banners/cards often sit just above or inside the composer)
                allPotentialUsageLimitTexts.append(text)
                if !visible.isEmpty && visible != text {
                    allPotentialUsageLimitTexts.append(visible)
                }
            }
        }

        // Fallback if `Active · N` header wasn't matched directly
        if snapshot.activeSubagentsCount == nil && activeSubagentWorkingRows > 0 {
            snapshot.activeSubagentsCount = activeSubagentWorkingRows
        }

        // Resolve active chat title:
        // Priority 1: Direct child text inside `Chat toolbar`
        // Priority 2: Top-left visible text in the center header bar
        // Priority 3: Window title
        if let toolbarTitle = chatToolbarExtractedTitle, !toolbarTitle.isEmpty {
            snapshot.activeChatTitle = toolbarTitle
        } else if let bestHeader = topCenterTitles.sorted(by: { $0.x < $1.x }).first {
            snapshot.activeChatTitle = bestHeader.text
        } else {
            let winTitle = getStringAttribute(windowElement, attribute: kAXTitleAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !winTitle.isEmpty && winTitle != "Codex" && winTitle != "ChatGPT" && isLikelyHeaderChatTitle(winTitle) {
                snapshot.activeChatTitle = winTitle
            }
        }

        if !snapshot.activeChatTitle.isEmpty && !sidebarCandidates.contains(snapshot.activeChatTitle) {
            sidebarCandidates.insert(snapshot.activeChatTitle, at: 0)
        }
        snapshot.detectedChatCandidates = sidebarCandidates

        // Extract the latest primary agent response from the center transcript
        snapshot.latestAgentResponseText = extractLatestAssistantResponse(
            from: centerTranscriptTexts,
            centerLeftX: leftSidebarMaxX,
            centerRightX: rightSidebarMinX
        )

        // Check usage limit / rate limit across center transcript + composer banners
        snapshot.usageLimitMessage = TextGuardrailMatcher.detectUsageLimit(
            in: allPotentialUsageLimitTexts,
            customKeywordsRaw: customUsageLimitKeywords
        )

        return snapshot
    }

    // MARK: - Sending "continue"

    enum SendResult {
        case sent
        case failed(String)
    }

    /// Types the continuation message into the Codex composer and clicks Send,
    /// verifying that the active chat still matches `expectedChatTitle`.
    func sendContinueMessage(
        _ message: String,
        expectedChatTitle: String
    ) -> SendResult {
        guard let app = findRunningCodexApp(), !app.isTerminated else {
            return .failed("Codex app is not running.")
        }
        guard isAccessibilityTrusted(prompt: false) else {
            return .failed("Accessibility permission is not granted.")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(for: appElement)

        guard let windowElement = findPrimaryWindow(for: appElement) else {
            return .failed("Could not find Codex window.")
        }

        let windowPos = getPointAttribute(windowElement, attribute: kAXPositionAttribute) ?? .zero
        let windowSize = getSizeAttribute(windowElement, attribute: kAXSizeAttribute) ?? CGSize(width: 1200, height: 800)
        let leftSidebarMaxX = windowPos.x + min(max(windowSize.width * 0.19, 180), 270)
        let rightSidebarMinX = windowPos.x + windowSize.width - min(max(windowSize.width * 0.23, 210), 330)
        let composerMinY = windowPos.y + windowSize.height - 165

        var nodes: [AXNodeInfo] = []
        var visited = Set<CFHashCode>()
        collectNodes(
            from: windowElement,
            depth: 0,
            maxDepth: 36,
            maxNodes: 2500,
            visited: &visited,
            into: &nodes
        )

        // Verify the active chat title right before injecting input
        let targetTrimmed = expectedChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !targetTrimmed.isEmpty {
            let currentSnapshot = captureSnapshot()
            if !matchesTargetChat(activeTitle: currentSnapshot.activeChatTitle, target: targetTrimmed) {
                return .failed("Active chat changed to '\(currentSnapshot.activeChatTitle)' — aborted send.")
            }
            if currentSnapshot.isMainAgentWorking {
                return .failed("Main agent is already working — aborted send.")
            }
        }

        // Locate composer input element
        guard let composerNode = nodes.first(where: {
            isComposerInputNode($0, composerMinY: composerMinY, leftMaxX: leftSidebarMaxX, rightMinX: rightSidebarMinX)
        }) else {
            return .failed("Could not locate the 'Work with Codex' composer input in the active window.")
        }

        // Step 1: Try setting focus + value directly via Accessibility first
        _ = AXUIElementSetAttributeValue(composerNode.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let setValErr = AXUIElementSetAttributeValue(composerNode.element, kAXValueAttribute as CFString, message as CFTypeRef)

        usleep(140_000) // 140ms for React state update

        // Check if the Send button is now present and enabled in the composer
        if let sendButton = findSendButton(in: windowElement, composerMinY: composerMinY, leftMaxX: leftSidebarMaxX, rightMinX: rightSidebarMinX) {
            let pressErr = AXUIElementPerformAction(sendButton, kAXPressAction as CFString)
            if pressErr == .success {
                return .sent
            }
        }

        // Step 2: Electron ProseMirror/Lexical composer fallback:
        // Activate window briefly, focus composer, insert text via clipboard-preserving paste or keystrokes, then press Send / Return.
        let previouslyActiveApp = NSWorkspace.shared.frontmostApplication
        app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(composerNode.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(composerNode.element, kAXPressAction as CFString)

        usleep(120_000)

        let currentComposerVal = getStringAttribute(composerNode.element, attribute: kAXValueAttribute)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if setValErr != .success || currentComposerVal.lowercased() != message.lowercased() {
            pasteTextPreservingClipboard(message)
            usleep(140_000)
        }

        // Try pressing the Send button via Accessibility first
        if let sendButton = findSendButton(in: windowElement, composerMinY: composerMinY, leftMaxX: leftSidebarMaxX, rightMinX: rightSidebarMinX) {
            if AXUIElementPerformAction(sendButton, kAXPressAction as CFString) == .success {
                if let prev = previouslyActiveApp, prev.processIdentifier != app.processIdentifier {
                    usleep(80_000)
                    prev.activate(options: [])
                }
                return .sent
            }
        }

        // Final fallback: press Return key on the focused composer
        sendKeyCode(36, flags: []) // 36 = Return
        if let prev = previouslyActiveApp, prev.processIdentifier != app.processIdentifier {
            usleep(80_000)
            prev.activate(options: [])
        }
        return .sent
    }

    func matchesTargetChat(activeTitle: String, target: String) -> Bool {
        let cleanActive = activeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { return !cleanActive.isEmpty }
        guard !cleanActive.isEmpty else { return false }
        return cleanActive.localizedCaseInsensitiveContains(cleanTarget)
            || cleanTarget.localizedCaseInsensitiveContains(cleanActive)
    }

    // MARK: - Private Helpers

    /// Walks inside `<div role="toolbar" aria-label="Chat toolbar">` to find the active chat's title string.
    private func extractChatTitleFromToolbar(_ toolbarElement: AXUIElement) -> String? {
        var subNodes: [AXNodeInfo] = []
        var visited = Set<CFHashCode>()
        collectNodes(
            from: toolbarElement,
            depth: 0,
            maxDepth: 12,
            maxNodes: 80,
            visited: &visited,
            into: &subNodes
        )

        var candidates: [(x: CGFloat, text: String)] = []
        for node in subNodes {
            let v = node.visibleText
            guard !v.isEmpty, isLikelyHeaderChatTitle(v) else { continue }
            if node.role == (kAXStaticTextRole as String) || node.role == "AXHeading" || node.role == (kAXButtonRole as String) {
                let x = node.position?.x ?? 9999
                candidates.append((x: x, text: v))
            }
        }
        return candidates.sorted(by: { $0.x < $1.x }).first?.text
    }

    private func findSendButton(
        in windowElement: AXUIElement,
        composerMinY: CGFloat,
        leftMaxX: CGFloat,
        rightMinX: CGFloat
    ) -> AXUIElement? {
        var nodes: [AXNodeInfo] = []
        var visited = Set<CFHashCode>()
        collectNodes(
            from: windowElement,
            depth: 0,
            maxDepth: 36,
            maxNodes: 2500,
            visited: &visited,
            into: &nodes
        )

        return nodes.first(where: { node in
            guard node.role == kAXButtonRole as String, node.enabled else { return false }
            let labels = [node.title, node.desc, node.help, node.value]
            let isSend = labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Send") == .orderedSame })
            guard isSend else { return false }
            if let pos = node.position {
                return pos.x > leftMaxX && pos.x < rightMinX && pos.y >= composerMinY - 40
            }
            return true
        })?.element
    }

    private func pasteTextPreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Cmd+A then Cmd+V
        sendKeyCode(0, flags: .maskCommand)  // 'a'
        usleep(40_000)
        sendKeyCode(9, flags: .maskCommand)  // 'v'
        usleep(100_000)

        if let savedString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                pasteboard.setString(savedString, forType: .string)
            }
        }
    }

    private func sendKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    private func findPrimaryWindow(for appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let win = value {
            return (win as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &value) == .success,
           let win = value {
            return (win as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement],
           let first = windows.first {
            return first
        }
        return nil
    }

    private func collectNodes(
        from element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        visited: inout Set<CFHashCode>,
        into results: inout [AXNodeInfo]
    ) {
        guard depth <= maxDepth, results.count < maxNodes else { return }
        let hash = CFHash(element)
        guard !visited.contains(hash) else { return }
        visited.insert(hash)

        let role = getStringAttribute(element, attribute: kAXRoleAttribute)
        let subrole = getStringAttribute(element, attribute: kAXSubroleAttribute)
        let title = getStringAttribute(element, attribute: kAXTitleAttribute)
        let value = getStringAttribute(element, attribute: kAXValueAttribute)
        let desc = getStringAttribute(element, attribute: kAXDescriptionAttribute)
        let placeholder = getStringAttribute(element, attribute: kAXPlaceholderValueAttribute)
        let help = getStringAttribute(element, attribute: kAXHelpAttribute)
        let pos = getPointAttribute(element, attribute: kAXPositionAttribute)
        let size = getSizeAttribute(element, attribute: kAXSizeAttribute)
        let enabled = getBoolAttribute(element, attribute: kAXEnabledAttribute) ?? true

        if !role.isEmpty {
            results.append(
                AXNodeInfo(
                    element: element,
                    role: role,
                    subrole: subrole,
                    title: title,
                    value: value,
                    desc: desc,
                    placeholder: placeholder,
                    help: help,
                    position: pos,
                    size: size,
                    enabled: enabled
                )
            )
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if results.count >= maxNodes { break }
                collectNodes(
                    from: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxNodes: maxNodes,
                    visited: &visited,
                    into: &results
                )
            }
        }
    }

    private func isComposerInputNode(
        _ node: AXNodeInfo,
        composerMinY: CGFloat,
        leftMaxX: CGFloat,
        rightMinX: CGFloat
    ) -> Bool {
        let isTextRole = node.role == (kAXTextAreaRole as String)
            || node.role == (kAXTextFieldRole as String)
            || node.role == "AXComboBox"

        let labels = [node.placeholder, node.desc, node.title, node.value]
        let hasComposerLabel = labels.contains(where: {
            $0.localizedCaseInsensitiveContains("Work with Codex")
                || $0.localizedCaseInsensitiveContains("Work with ChatGPT")
                || $0.localizedCaseInsensitiveContains("Ask Codex")
                || $0.localizedCaseInsensitiveContains("Do anything")
                || $0.localizedCaseInsensitiveContains("Ask ChatGPT")
        })

        if hasComposerLabel && isTextRole {
            return true
        }

        if isTextRole, let pos = node.position {
            return pos.x > leftMaxX && pos.x < rightMinX && pos.y >= composerMinY
        }
        return false
    }

    private func parseSubagentHeaderCount(prefix: String, from text: String) -> Int? {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: prefix) + #"\s*[·•\-:]\s*(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private func matchMainAgentWorkingText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^Working\s+for\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        if trimmed.caseInsensitiveCompare("Thinking") == .orderedSame
            || trimmed.caseInsensitiveCompare("Working…") == .orderedSame {
            return trimmed
        }
        return nil
    }

    private func isLikelyHeaderChatTitle(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ignoredLower: Set<String> = [
            "codex", "chatgpt", "new chat", "subagents", "pinned", "recents", "projects",
            "chat toolbar", "workspace toolbar", "more actions", "chat actions", "toggle sidebar",
            "new tab", "split view", "enter full view", "exit full view", "show tabs", "hide tabs",
            "close", "back", "forward", "search", "notifications"
        ]
        guard !ignoredLower.contains(lower), text.count >= 2, text.count <= 120 else { return false }
        if lower.hasPrefix("active ·") || lower.hasPrefix("done ·") { return false }
        return true
    }

    private func isLikelySidebarChatTitle(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ignoredLower: Set<String> = [
            "codex", "new chat", "pinned", "projects", "recents", "show more", "chat toolbar"
        ]
        guard !ignoredLower.contains(lower), text.count >= 3, text.count <= 90 else { return false }
        return true
    }

    private func isMeaningfulTranscriptText(_ text: String, role: String) -> Bool {
        guard role == (kAXStaticTextRole as String) || role == "AXGroup" || role == "AXHeading" else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let ignored: Set<String> = ["Copy", "Read aloud", "Good response", "Bad response", "More actions", "Approve for me", "Reset usage", "Upgrade"]
        return !ignored.contains(trimmed)
    }

    /// Extracts only the bottom-most completed primary agent response from the center transcript.
    /// Specifically excludes user prompt bubbles (which sit further right, contain "You said:", or equal "continue").
    private func extractLatestAssistantResponse(
        from items: [(y: CGFloat, x: CGFloat, text: String)],
        centerLeftX: CGFloat,
        centerRightX: CGFloat
    ) -> String {
        guard !items.isEmpty else { return "" }

        // Sort top-to-bottom, then left-to-right
        let sorted = items.sorted {
            if abs($0.y - $1.y) > 4 {
                return $0.y < $1.y
            }
            return $0.x < $1.x
        }

        // Deduplicate adjacent identical text fragments
        var deduped: [(y: CGFloat, x: CGFloat, text: String)] = []
        for item in sorted {
            if deduped.last?.text != item.text {
                deduped.append(item)
            }
        }

        // If Electron provides a turn summary with "ChatGPT said:", prefer the last such turn
        if let lastChatGPTSaid = deduped.last(where: { $0.text.localizedCaseInsensitiveContains("ChatGPT said:") }) {
            return lastChatGPTSaid.text
        }

        // Find the last `Worked for ...` divider, which Codex places immediately above the final assistant response in a turn
        let lastWorkedForIndex = deduped.lastIndex(where: {
            $0.text.range(of: #"^Worked\s+for\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
        })

        let candidateSlice: ArraySlice<(y: CGFloat, x: CGFloat, text: String)>
        if let idx = lastWorkedForIndex, idx + 1 < deduped.count {
            candidateSlice = deduped[(idx + 1)...]
        } else {
            candidateSlice = deduped.suffix(12)
        }

        let centerWidth = max(centerRightX - centerLeftX, 400)
        let userBubbleMinX = centerLeftX + centerWidth * 0.36

        var assistantLines: [String] = []
        for item in candidateSlice {
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.caseInsensitiveCompare("continue") == .orderedSame || t.localizedCaseInsensitiveContains("You said:") {
                assistantLines.removeAll()
                continue
            }
            if item.x > userBubbleMinX {
                assistantLines.removeAll()
                continue
            }
            if t.localizedCaseInsensitiveContains("started working") || t.localizedCaseInsensitiveContains("Sent message to ") {
                continue
            }
            assistantLines.append(t)
        }

        return assistantLines.joined(separator: " ")
    }

    private func getStringAttribute(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value else {
            return ""
        }
        if let str = v as? String {
            return str
        }
        if let attrStr = v as? NSAttributedString {
            return attrStr.string
        }
        return ""
    }

    private func getBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value else {
            return nil
        }
        if let b = v as? Bool {
            return b
        }
        return nil
    }

    private func getPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value,
              CFGetTypeID(v) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        if AXValueGetValue(v as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private func getSizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value,
              CFGetTypeID(v) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        if AXValueGetValue(v as! AXValue, .cgSize, &size) {
            return size
        }
        return nil
    }
}
