import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseWakeWordLocaleTests: XCTestCase {
    private let supported = [
        Locale(identifier: "en-US"),
        Locale(identifier: "en-GB"),
        Locale(identifier: "es-ES"),
        Locale(identifier: "es-MX"),
        Locale(identifier: "it-IT"),
    ]

    // The real bug: Locale.current was `en_ES` (English UI + Spain region), which
    // has no offline model. Negotiation must skip it and land on a supported
    // English variant, never returning en_ES as a usable candidate on its own.
    func testEnglishUIInSpainFallsBackToSupportedEnglish() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["en-ES"],
            supported: supported,
            region: "ES"
        )
        // en-US closes the list and is supported, so it is reachable.
        XCTAssertTrue(candidates.contains { $0.identifier == "en-US" })
        // The first *supported* candidate is an English variant, not es/it.
        let firstSupported = candidates.first { c in supported.contains { $0.identifier == c.identifier } }
        XCTAssertEqual(firstSupported?.languageCode, "en")
    }

    // A Spanish speaker in Spain must get es-ES (region-matched), not es-MX.
    func testSpanishSpainPrefersRegionMatchedVariant() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["es-ES"],
            supported: supported,
            region: "ES"
        )
        let firstSupported = candidates.first { c in supported.contains { $0.identifier == c.identifier } }
        XCTAssertEqual(firstSupported?.identifier, "es-ES")
    }

    // An Italian phone must land on Italian, proving no language is hardcoded.
    func testItalianPhoneLandsOnItalian() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["it-IT"],
            supported: supported,
            region: "IT"
        )
        let firstSupported = candidates.first { c in supported.contains { $0.identifier == c.identifier } }
        XCTAssertEqual(firstSupported?.identifier, "it-IT")
    }

    // Preferred-language order is honoured: the user's first language wins.
    func testPreferredLanguageOrderIsHonoured() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["it-IT", "es-ES"],
            supported: supported,
            region: "ES"
        )
        let firstSupported = candidates.first { c in supported.contains { $0.identifier == c.identifier } }
        XCTAssertEqual(firstSupported?.languageCode, "it")
    }

    // en-US is always present as a final safety net, even for an unsupported
    // language with no model, so the wake word never has zero candidates.
    func testEnUSIsAlwaysTheSafetyNet() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["zz-ZZ"],
            supported: supported,
            region: "ZZ"
        )
        XCTAssertEqual(candidates.last?.identifier, "en-US")
    }

    // No duplicates in the candidate list.
    func testCandidatesAreDeduplicated() {
        let candidates = PulseWakeWordLocale.candidates(
            preferredLanguages: ["en-US", "en-US", "es-ES"],
            supported: supported,
            region: "US"
        )
        XCTAssertEqual(candidates.count, Set(candidates.map { $0.identifier }).count)
    }
}
