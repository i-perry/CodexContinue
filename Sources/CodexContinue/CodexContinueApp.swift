import AppKit
import SwiftUI

@main
struct CodexContinueApp: App {
    @StateObject private var engine = MonitorEngine()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            Self.runSelfTestsAndExit()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: CustomIconRenderer.menuBarImage(for: engine.phase.iconStyle, pointSize: 18, isTemplate: true))
                if !engine.phase.menuBarBadge.isEmpty {
                    Text(engine.phase.menuBarBadge)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static func runSelfTestsAndExit() -> Never {
        let phrase = "Decomp analysis is completed 100%"

        // Test 1: Instructional user prompt must NOT false-positive
        let userInstruction = #"Continue - also just so I don't need to keep asking, when the investigation is complete I want you to respond with a message that only says "Decomp analysis is completed 100%""#
        assert(
            TextGuardrailMatcher.matchCompletionPhrase(in: userInstruction, configuredPhrasesRaw: phrase) == nil,
            "Failed: Should ignore instructional quote in user prompt"
        )

        // Test 2: Actual primary agent completion response MUST match
        let agentCompletion = "10:25 AM ChatGPT said: Decomp analysis is completed 100%"
        assert(
            TextGuardrailMatcher.matchCompletionPhrase(in: agentCompletion, configuredPhrasesRaw: phrase) == phrase,
            "Failed: Should match primary agent completion response"
        )

        // Test 3: Usage limit detection for both inline message and card banner from screenshot
        let inlineLimit = "You've hit your usage limit. Upgrade your plan or add credits to continue, or try again at 11:45 PM."
        let bannerTitle = "You're out of Codex and Work usage"
        let bannerBody = "Your rate limit resets on 11:45 PM. Upgrade or use one of your rate limit resets now."
        let combinedDetected = TextGuardrailMatcher.detectUsageLimit(
            in: ["Worked for 10s", bannerTitle, bannerBody, inlineLimit],
            customKeywordsRaw: ""
        )
        assert(combinedDetected != nil && combinedDetected!.contains("11:45 PM"), "Failed: Should combine usage limit banner and timestamp")

        // Test 4: Reset time parsing for "resets on 11:45 PM"
        let now = Date()
        if let parsed1 = TextGuardrailMatcher.parseResetDate(from: combinedDetected!, now: now, safetyBufferSeconds: 120) {
            assert(parsed1 > now, "Failed: Parsed reset date should be in the future")
        } else {
            assertionFailure("Failed: Could not parse reset date from '\(combinedDetected!)'")
        }

        // Test 5: Recently passed reset time today should return .alreadyPassedRecently (not tomorrow)
        let cal = Calendar.current
        var tenAmComps = cal.dateComponents([.year, .month, .day], from: now)
        tenAmComps.hour = 10
        tenAmComps.minute = 0
        let tenAm = cal.date(from: tenAmComps)!
        let elevenAm = tenAm.addingTimeInterval(3600)
        let evalPast = TextGuardrailMatcher.evaluateResetDate(
            from: "Your rate limit resets on 10:00 AM.",
            now: elevenAm,
            safetyBufferSeconds: 120
        )
        if case .alreadyPassedRecently = evalPast {
            // expected
        } else {
            assertionFailure("Failed: 10:00 AM evaluated at 11:00 AM should be .alreadyPassedRecently, got \(evalPast)")
        }

        let relMsg = "You've hit your usage limit. Try again in 45 minutes."
        if let parsedRel = TextGuardrailMatcher.parseResetDate(from: relMsg, now: now, safetyBufferSeconds: 60) {
            let diff = parsedRel.timeIntervalSince(now)
            assert(abs(diff - (45 * 60 + 60)) < 5, "Failed: Relative duration parse mismatch")
        } else {
            assertionFailure("Failed: Could not parse relative reset time")
        }

        print("ALL SELF-TESTS PASSED ✅")
        exit(0)
    }
}
