import Foundation

enum UsageLimitAction: String, CaseIterable, Identifiable {
    case pauseManual = "pause_manual"
    case waitUntilResetTime = "wait_reset_time"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pauseManual:
            return "Pause until I manually resume"
        case .waitUntilResetTime:
            return "Auto-resume after parsed reset time"
        }
    }
}

enum MonitorPhase: Equatable {
    case disabled
    case waitingForCodexApp
    case waitingForPermission
    case differentChatActive(current: String)
    case watchingIdleNotArmed
    case armedSubagentsRunning(activeCount: Int)
    case settlingBeforeSend(secondsRemaining: Int)
    case waitingForUserIdle(secondsIdle: Int)
    case sendingContinue
    case postSendCooldown(secondsRemaining: Int)
    case pausedUsageLimit(message: String, resumeAt: Date?)
    case stoppedCompleted(matchedPhrase: String)

    var shortStatus: String {
        switch self {
        case .disabled:
            return "Paused"
        case .waitingForCodexApp:
            return "Codex Not Open"
        case .waitingForPermission:
            return "Needs AX Permission"
        case .differentChatActive(let current):
            let label = current.isEmpty ? "Other Chat" : current
            return "Paused (On: \(label))"
        case .watchingIdleNotArmed:
            return "Watching (Waiting for Active > 0)"
        case .armedSubagentsRunning(let count):
            return "Armed · \(count) Active"
        case .settlingBeforeSend(let rem):
            return "Settling (\(rem)s)…"
        case .waitingForUserIdle:
            return "Waiting for User Idle…"
        case .sendingContinue:
            return "Sending 'continue'…"
        case .postSendCooldown(let rem):
            return "Cooldown (\(rem)s)"
        case .pausedUsageLimit(_, let resumeAt):
            if let resumeAt {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                fmt.dateStyle = Calendar.current.isDateInToday(resumeAt) ? .none : .short
                return "Usage Limit (Until \(fmt.string(from: resumeAt)))"
            }
            return "Paused: Usage Limit Hit"
        case .stoppedCompleted:
            return "Completed 100% ✅"
        }
    }

    var menuBarBadge: String {
        switch self {
        case .disabled:
            return ""
        case .waitingForCodexApp, .waitingForPermission:
            return "!"
        case .differentChatActive:
            return "⏸"
        case .watchingIdleNotArmed:
            return "0"
        case .armedSubagentsRunning(let count):
            return "\(count)"
        case .settlingBeforeSend(let rem):
            return "\(rem)s"
        case .waitingForUserIdle:
            return "⌨️"
        case .sendingContinue:
            return "↑"
        case .postSendCooldown:
            return "⏳"
        case .pausedUsageLimit:
            return "⏳"
        case .stoppedCompleted:
            return "✓"
        }
    }

    var menuBarIconName: String {
        switch self {
        case .disabled:
            return "pause.circle"
        case .waitingForCodexApp, .waitingForPermission:
            return "exclamationmark.triangle"
        case .differentChatActive:
            return "eye.slash"
        case .watchingIdleNotArmed:
            return "eye"
        case .armedSubagentsRunning:
            return "cpu"
        case .settlingBeforeSend, .waitingForUserIdle:
            return "timer"
        case .sendingContinue:
            return "paperplane.fill"
        case .postSendCooldown:
            return "hourglass"
        case .pausedUsageLimit:
            return "clock.badge.exclamationmark"
        case .stoppedCompleted:
            return "checkmark.seal.fill"
        }
    }
}

struct CodexWindowSnapshot: Equatable {
    var isCodexRunning: Bool = false
    var isWindowVisible: Bool = false
    var activeChatTitle: String = ""
    var detectedChatCandidates: [String] = []
    var activeSubagentsCount: Int? = nil
    var doneSubagentsCount: Int? = nil
    var sawNoActiveSubagentsLabel: Bool = false
    var isMainAgentWorking: Bool = false
    var mainAgentStatusText: String = ""
    var latestAgentResponseText: String = ""
    var usageLimitMessage: String? = nil
    var hasComposerInput: Bool = false
    var hasSendButton: Bool = false
    var timestamp: Date = Date()
}

struct ActivityLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isImportant: Bool
}

enum TextGuardrailMatcher {
    /// Checks whether the primary agent's latest response contains any configured completion phrase,
    /// while ignoring quoted instructions (e.g. `only says "Decomp analysis is completed 100%"`).
    static func matchCompletionPhrase(in latestAgentResponse: String, configuredPhrasesRaw: String) -> String? {
        let trimmedResponse = latestAgentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return nil }

        // If the string accidentally includes a "You said:" segment, ignore user segments
        if trimmedResponse.localizedCaseInsensitiveContains("You said:") {
            let parts = trimmedResponse.components(separatedBy: "ChatGPT said:")
            if parts.count > 1, let lastAssistantPart = parts.last {
                return matchCompletionPhrase(in: lastAssistantPart, configuredPhrasesRaw: configuredPhrasesRaw)
            } else {
                return nil
            }
        }

        let phrases = configuredPhrasesRaw
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !phrases.isEmpty else { return nil }

        // Remove segments where a user instruction is quoting the phrase, e.g. `only says "..."` or `respond with "..."`
        let sanitizedResponse = stripInstructionalQuotes(from: trimmedResponse)

        for phrase in phrases {
            if sanitizedResponse.localizedCaseInsensitiveContains(phrase) {
                return phrase
            }
        }
        return nil
    }

    private static func stripInstructionalQuotes(from text: String) -> String {
        let patterns = [
            #"(?i)(?:only\s+says|respond\s+with[a-z\s]*|say|reply\s+with)\s*["“”'][^"“”']+["“”']"#,
            #"(?i)when\s+the\s+investigation\s+is\s+complete[^\n]*"#
        ]
        var result = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result
    }

    enum UsageLimitStatus: Equatable {
        case activeLimit(message: String, resetDate: Date?)
        case expiredLimit(message: String, expiredAt: Date)
    }

    /// Built-in + custom usage limit detection across all visible center-pane strings.
    /// Combines all matching usage-limit sentences so a heading ("You're out of Codex and Work usage")
    /// and its detail line ("Your rate limit resets on 12:28 PM...") are evaluated together.
    static func detectUsageLimit(in texts: [String], customKeywordsRaw: String) -> String? {
        let builtInPatterns = [
            "you've hit your usage limit",
            "you’ve hit your usage limit",
            "you're out of usage",
            "you’re out of usage",
            "you're out of codex and work usage",
            "you’re out of codex and work usage",
            "your rate limit resets on",
            "your rate limit resets at",
            "usage limit reached",
            "messages limit reached",
            "rate limit reached",
            "try again after your usage limit resets",
            "wait until .* to continue using chatgpt work and codex",
            "quota or rate limit",
            "matched signal: rate limit",
            "matched signal: quota or usage limit"
        ]

        let customKeywords = customKeywordsRaw
            .split(whereSeparator: { $0 == "\n" || $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var matchedLines: [String] = []

        for rawText in texts {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()

            // Ignore benign short UI labels
            if lower == "usage remaining" || lower == "rate limit" || lower == "rate limit:" || lower == "reset usage" {
                continue
            }

            var isMatch = false
            for pattern in builtInPatterns {
                if pattern.contains(".*") {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil {
                        isMatch = true
                        break
                    }
                } else if lower.contains(pattern) {
                    isMatch = true
                    break
                }
            }

            if !isMatch {
                for kw in customKeywords {
                    if lower.contains(kw) {
                        isMatch = true
                        break
                    }
                }
            }

            if isMatch && !matchedLines.contains(trimmed) {
                matchedLines.append(trimmed)
            }
        }

        guard !matchedLines.isEmpty else { return nil }
        return matchedLines.joined(separator: " ")
    }

    enum ParsedResetTimeResult: Equatable {
        case future(Date)
        case alreadyPassedRecently(Date)
        case notFound
    }

    /// Evaluates whether a usage limit message contains a future reset time, a reset time that already passed today, or no time.
    static func evaluateResetDate(from message: String, now: Date = Date(), safetyBufferSeconds: TimeInterval = 120) -> ParsedResetTimeResult {
        let calendar = Calendar.current

        // 1. Check relative durations first: e.g., "in 2 hours", "in 45 minutes", "in 1h 30m", "Retry in 45s"
        if let relativeDate = parseRelativeDuration(from: message, now: now) {
            return .future(relativeDate.addingTimeInterval(safetyBufferSeconds))
        }

        // 2. Focus on substring after "try again at", "resets on", "resets at", "wait until", "resets" if present
        let targetSegment: String
        if let range = message.range(of: #"(?i)(?:try\s+again\s+at|rate\s+limit\s+resets\s+on|rate\s+limit\s+resets\s+at|wait\s+until|resets\s+on|resets\s+at|resets|available\s+at)\s+"#, options: .regularExpression) {
            targetSegment = String(message[range.upperBound...])
        } else {
            targetSegment = message
        }

        // 3. Explicit clock time check (e.g. "12:28 PM", "14:35", "2:35pm") when no explicit month/day is attached
        let hasExplicitDateWord = targetSegment.range(
            of: #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}/\d{1,2})\b"#,
            options: .regularExpression
        ) != nil

        if !hasExplicitDateWord,
           let clockDateToday = parseClockTimeToday(from: targetSegment, now: now, calendar: calendar) {
            let bufferedToday = clockDateToday.addingTimeInterval(safetyBufferSeconds)
            if bufferedToday > now {
                return .future(bufferedToday)
            }
            // If `clockDateToday` passed within the last 6 hours, it means today's reset time has ALREADY passed!
            let elapsedSinceReset = now.timeIntervalSince(clockDateToday)
            if elapsedSinceReset >= 0 && elapsedSinceReset < 6 * 3600 {
                return .alreadyPassedRecently(clockDateToday)
            }
            // Otherwise (e.g., it's 11 PM and the message says "try again at 2:00 AM"), roll to tomorrow
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: clockDateToday) {
                return .future(tomorrow.addingTimeInterval(safetyBufferSeconds))
            }
        }

        // 4. Try NSDataDetector for full dates/times ("Oct 29, 2:30 PM", "tomorrow at 9:00 AM")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let nsRange = NSRange(targetSegment.startIndex..<targetSegment.endIndex, in: targetSegment)
            let matches = detector.matches(in: targetSegment, options: [], range: nsRange)
            for match in matches {
                if let detectedDate = match.date {
                    let buffered = detectedDate.addingTimeInterval(safetyBufferSeconds)
                    if buffered > now {
                        return .future(buffered)
                    }
                    let elapsed = now.timeIntervalSince(detectedDate)
                    if elapsed >= 0 && elapsed < 6 * 3600 {
                        return .alreadyPassedRecently(detectedDate)
                    }
                }
            }
        }

        return .notFound
    }

    /// Backwards-compatible helper returning a future `Date` if present.
    static func parseResetDate(from message: String, now: Date = Date(), safetyBufferSeconds: TimeInterval = 90) -> Date? {
        if case .future(let date) = evaluateResetDate(from: message, now: now, safetyBufferSeconds: safetyBufferSeconds) {
            return date
        }
        return nil
    }

    private static func parseClockTimeToday(from segment: String, now: Date, calendar: Calendar) -> Date? {
        let timePattern = #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm|AM|PM)?\b"#
        guard let regex = try? NSRegularExpression(pattern: timePattern),
              let match = regex.firstMatch(in: segment, range: NSRange(segment.startIndex..<segment.endIndex, in: segment)),
              let hourRange = Range(match.range(at: 1), in: segment),
              let minRange = Range(match.range(at: 2), in: segment),
              var hour = Int(segment[hourRange]),
              let minute = Int(segment[minRange]) else {
            return nil
        }

        if match.range(at: 4).location != NSNotFound,
           let ampmRange = Range(match.range(at: 4), in: segment) {
            let ampm = segment[ampmRange].lowercased()
            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }
        }

        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    private static func parseRelativeDuration(from text: String, now: Date) -> Date? {
        var totalSeconds: TimeInterval = 0
        var matchedAny = false

        let hourPattern = #"(?i)\b(\d+)\s*(?:hours?|hrs?|h)\b"#
        let minPattern = #"(?i)\b(\d+)\s*(?:minutes?|mins?|m)\b"#
        let secPattern = #"(?i)\b(?:retry\s+in|in)\s*(\d+)\s*(?:seconds?|secs?|s)\b"#

        guard text.range(of: #"(?i)\b(?:in|resets|wait|after)\b"#, options: .regularExpression) != nil else {
            return nil
        }

        if let regex = try? NSRegularExpression(pattern: hourPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let r = Range(match.range(at: 1), in: text),
           let hours = Double(text[r]) {
            totalSeconds += hours * 3600
            matchedAny = true
        }

        if let regex = try? NSRegularExpression(pattern: minPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let r = Range(match.range(at: 1), in: text),
           let mins = Double(text[r]) {
            totalSeconds += mins * 60
            matchedAny = true
        }

        if !matchedAny,
           let regex = try? NSRegularExpression(pattern: secPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let r = Range(match.range(at: 1), in: text),
           let secs = Double(text[r]) {
            totalSeconds += secs
            matchedAny = true
        }

        return matchedAny && totalSeconds > 0 ? now.addingTimeInterval(totalSeconds) : nil
    }
}
