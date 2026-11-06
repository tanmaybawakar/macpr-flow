import Testing
import Foundation
@testable import MacprFlow

// MARK: Shortcut state machine

private let none = ModifierState()

@Test func holdThenReleaseFiresOncePerPress() {
    var m = TriggerMachine(key: .fn)
    #expect(m.modifiers(ModifierState(fn: true), at: 0) == .pressed)
    #expect(m.modifiers(ModifierState(fn: true), at: 0.2) == nil)
    #expect(m.modifiers(none, at: 1.5) == .released(held: 1.5))
    #expect(m.modifiers(none, at: 1.6) == nil)
}

@Test func controlCommandWorksInEitherOrder() {
    for commandFirst in [true, false] {
        var m = TriggerMachine(key: .controlCommand)
        let first = commandFirst ? ModifierState(leftCommand: true) : ModifierState(control: true)
        #expect(m.modifiers(first, at: 0) == nil)
        #expect(m.modifiers(ModifierState(control: true, leftCommand: true), at: 0.05) == .pressed)
        #expect(m.modifiers(first, at: 0.6) == .released(held: 0.6 - 0.05))
        #expect(m.modifiers(none, at: 0.7) == nil)
    }
}

@Test func shortcutsUsingTheTriggerAreInterrupted() {
    var m = TriggerMachine(key: .controlCommand)
    #expect(m.modifiers(ModifierState(control: true, leftCommand: true), at: 0) == .pressed)
    #expect(m.keyDown(code: 49, at: 0.1) == .interrupted)          // ⌃⌘Space
    #expect(m.keyDown(code: 49, at: 0.15) == nil)
    #expect(m.modifiers(none, at: 0.3) == nil)                       // no release after an interruption

    var fn = TriggerMachine(key: .fn)
    #expect(fn.modifiers(ModifierState(fn: true), at: 0) == .pressed)
    #expect(fn.modifiers(ModifierState(shift: true, fn: true), at: 0.1) == .interrupted)
}

@Test func strayKeyDuringLongHoldDoesNotCancel() {
    var m = TriggerMachine(key: .rightOption)
    #expect(m.modifiers(ModifierState(rightOption: true), at: 0) == .pressed)
    #expect(m.keyDown(code: 0, at: 2) == nil)
    #expect(m.modifiers(none, at: 3) == .released(held: 3))
}

@Test func triggerHeldWithOtherModifiersNeverStarts() {
    var m = TriggerMachine(key: .rightCommand)
    #expect(m.modifiers(ModifierState(shift: true), at: 0) == nil)
    #expect(m.modifiers(ModifierState(shift: true, rightCommand: true), at: 0.1) == nil)
    #expect(m.modifiers(ModifierState(rightCommand: true), at: 0.2) == nil)   // still blocked until full release
    #expect(m.modifiers(none, at: 0.3) == nil)
    #expect(m.modifiers(ModifierState(rightCommand: true), at: 0.4) == .pressed)
}

@Test func escapeAlwaysReported() {
    var m = TriggerMachine(key: .fn)
    #expect(m.keyDown(code: 53, at: 0) == .escape)
}

@Test func deviceFlagsDistinguishLeftAndRight() {
    let rightOption = ModifierState(flags: 0x0008_0000 | 0x40)
    #expect(rightOption.rightOption && !rightOption.leftOption)
    let leftCommand = ModifierState(flags: 0x0010_0000 | 0x08)
    #expect(leftCommand.leftCommand && !leftCommand.rightCommand)
    let bareCommand = ModifierState(flags: 0x0010_0000)
    #expect(bareCommand.leftCommand)
    #expect(ModifierState(flags: 0x0080_0000).fn)
}

// MARK: Deterministic cleanup

@Test func fillersAreRemovedWithoutBreakingSentences() {
    #expect(TextPolish.basic("Um, so we need the report.") == "So we need the report.")
    #expect(TextPolish.basic("I, um, think it works.") == "I think it works.")
    #expect(TextPolish.basic("We shipped it. Uh, next week we test.") == "We shipped it. Next week we test.")
    #expect(TextPolish.basic("It works, um.") == "It works.")
}

@Test func stuttersCollapseButMeaningfulRepeatsStay() {
    #expect(TextPolish.basic("The the plan is ready.") == "The plan is ready.")
    #expect(TextPolish.basic("I I think so.") == "I think so.")
    #expect(TextPolish.basic("He had had enough.") == "He had had enough.")
}

@Test func casingRespectsBrandNames() {
    #expect(TextPolish.basic("iPhone sales are up.") == "iPhone sales are up.")
    #expect(TextPolish.basic("um, eBay called.") == "eBay called.")
}

@Test func spokenBreaks() {
    #expect(TextPolish.basic("Hello. New paragraph. Can you join tomorrow?") == "Hello.\n\nCan you join tomorrow?")
    #expect(TextPolish.basic("First item, new line. Second item.") == "First item.\nSecond item.")
    #expect(TextPolish.basic("We launched a new line of products.") == "We launched a new line of products.")
}

@Test func dictionarySpellsTermsYourWay() {
    let words = [DictionaryEntry(term: "Supabase", heardAs: "super base, soup a base"), DictionaryEntry(term: "Tangenix")]
    #expect(TextPolish.basic("Deploy it to super base for tangenix.", dictionary: words) == "Deploy it to Supabase for Tangenix.")
}

@Test func modelOnlyWhenItEarnsItsLatency() {
    #expect(!TextPolish.needsModel("Send the report on Wednesday."))
    #expect(TextPolish.needsModel("Send it Tuesday, actually Wednesday."))
    #expect(TextPolish.needsModel("We need one apples, two bananas, three oranges."))
    #expect(TextPolish.needsModel(String(repeating: "word ", count: 50)))
}

// MARK: Guarding the model's output

@Test func vettingRejectsAnswersAndAcceptsEdits() {
    let question = "Can you review my pull request?"
    #expect(TextPolish.vetted(original: question, candidate: "Sure! I'd be happy to review your pull request. Please share the link and I will take a look.") == nil)
    #expect(TextPolish.vetted(original: "What's the capital of France?", candidate: "The capital of France is Paris.") == nil)
    #expect(TextPolish.vetted(original: "Send it Tuesday, actually Wednesday.", candidate: "Send it Wednesday.") == "Send it Wednesday.")
    #expect(TextPolish.vetted(original: "We need one apples, two bananas, three oranges.",
                              candidate: "We need:\n1. Apples\n2. Bananas\n3. Oranges") != nil)
    #expect(TextPolish.vetted(original: "Hello there.", candidate: "Here is the edited dictation: Hello there.") == "Hello there.")
    #expect(TextPolish.vetted(original: "Hello there.", candidate: "\"Hello there.\"") == "Hello there.")
    #expect(TextPolish.vetted(original: "Hello there.", candidate: "  ") == nil)
}

@Test func spacingMatchesWhatYoudType() {
    #expect(Spacing.adjust("Next sentence.", after: ".") == " Next sentence.")
    #expect(Spacing.adjust("word", after: " ") == "word")
    #expect(Spacing.adjust("Hello", after: "\n") == "Hello")
    #expect(Spacing.adjust("Hello", after: nil) == "Hello")
    #expect(Spacing.adjust(", and more", after: "x") == ", and more")
    #expect(Spacing.adjust("quoted", after: "\u{201C}") == "quoted")
}

// MARK: Deadlines

@Test @MainActor func deadlineReturnsNilInsteadOfWaiting() async {
    let start = ContinuousClock.now
    let late = await firstResult(within: .milliseconds(20)) { () async throws -> String in
        try? await Task.sleep(for: .seconds(2))
        return "too late"
    }
    #expect(late == nil)
    #expect(ContinuousClock.now - start < .seconds(1))
    let failed = await firstResult(within: .seconds(1)) { () async throws -> String in throw FlowError("model failure") }
    #expect(failed == nil)
    let fast = await firstResult(within: .seconds(1)) { "ok" }
    #expect(fast == "ok")
}

// MARK: Learning from corrections

private let common: @Sendable (String) -> Bool = { ["there", "their", "meeting", "the", "report"].contains($0) }

@Test func learnsAMisheardName() {
    let found = CorrectionLearner.corrections(inserted: "Deploy it to super base tonight.",
                                              edited: "Deploy it to Supabase tonight.", known: [], isCommonWord: common)
    #expect(found == [.init(heard: "super base", term: "Supabase")])
}

@Test func learnsWhenMoreTextWasTypedAfterwards() {
    let found = CorrectionLearner.corrections(inserted: "Thanks, ton may.",
                                              edited: "Thanks, Tanmay. See you at the standup tomorrow", known: [], isCommonWord: common)
    #expect(found.map(\.term) == ["Tanmay"])
}

@Test func ignoresOrdinaryRewritesAndKnownWords() {
    #expect(CorrectionLearner.corrections(inserted: "Put it over their.", edited: "Put it over there.", known: [], isCommonWord: common).isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "Send the report.", edited: "Send the meeting notes.", known: [], isCommonWord: common).isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "Ask super base.", edited: "Ask Supabase.", known: ["supabase"], isCommonWord: common).isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "Hello there.", edited: "Hello there.", known: [], isCommonWord: common).isEmpty)
}

@Test func learnsBrandCasing() {
    let found = CorrectionLearner.corrections(inserted: "Push to github now.", edited: "Push to GitHub now.", known: [], isCommonWord: { _ in true })
    #expect(found.map(\.term) == ["GitHub"])
}

@Test func snippetsMatchTheWholeUtterance() {
    let snippets = [Snippet(trigger: "my calendar link", text: "https://cal.com/tan")]
    #expect(Snippet.match("My calendar link.", in: snippets)?.text == "https://cal.com/tan")
    #expect(Snippet.match("Here is my calendar link.", in: snippets) == nil)
}

@Test func oldDictionaryEntriesStillDecode() throws {
    let old = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","term":"Supabase","heardAs":"super base"}]"#
    let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: Data(old.utf8))
    #expect(decoded.first?.term == "Supabase" && decoded.first?.learned == false)
}

// MARK: Spoken self-corrections

@Test func correctionsKeepOnlyTheFinalVersion() {
    #expect(SelfCorrection.resolve("Let's meet at 3, sorry, 4 pm.") == "Let's meet at 4 pm.")
    #expect(SelfCorrection.resolve("Send it to John. Sorry, not John, Mike.") == "Send it to Mike.")
    #expect(SelfCorrection.resolve("The meeting is on Monday, I mean Tuesday.") == "The meeting is on Tuesday.")
    #expect(SelfCorrection.resolve("We should go with the blue design, sorry, the red design.") == "We should go with the red design.")
    #expect(SelfCorrection.resolve("I'll be there in 10, no wait, 20 minutes.") == "I'll be there in 20 minutes.")
    #expect(SelfCorrection.resolve("Buy milk and eggs. Scratch that. Just buy milk.") == "Just buy milk.")
    #expect(SelfCorrection.resolve("Hi team. Book it for Friday, sorry, Saturday. Thanks.") == "Hi team. Book it for Saturday. Thanks.")
}

@Test func apologiesAndLiteralUsesStay() {
    for text in ["Sorry I'm late.", "I'm sorry for the delay.", "I was so sorry to hear that.",
                 "Do you see what I mean?", "That's what I mean, we need more people.", "Coffee, no sugar, please."] {
        #expect(SelfCorrection.resolve(text) == text)
    }
}

@Test func correctionsSkipTheModel() {
    let fixed = TextPolish.basic("Um, let's meet at 3, sorry, 4 pm.")
    #expect(fixed == "Let's meet at 4 pm.")
    #expect(!TextPolish.needsModel(fixed))
}
