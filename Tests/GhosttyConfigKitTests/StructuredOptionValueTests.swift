import XCTest
@testable import GhosttyConfigKit

/// U4 (R7/R8): the pure composite/flag-set parsers behind the two-field scroll editor and
/// the labeled bell-features editor. Proven here — separate from any SwiftUI view — so the
/// stable-order reserialization and the "unknown/omitted fragments round-trip verbatim"
/// guarantee are unit-tested rather than trusted by eye (mirrors GhosttyPalette/FontFeatures).
final class StructuredOptionValueTests: XCTestCase {

    // MARK: - Scroll multiplier composite (scenario 3)

    func testScrollMultiplierParsesLabeledFields() {
        let v = ScrollMultiplierValue.parse("precision:0.5,discrete:3")
        XCTAssertEqual(v.precision, "0.5")
        XCTAssertEqual(v.discrete, "3")
        XCTAssertTrue(v.unknown.isEmpty)
    }

    func testScrollMultiplierReserializesInStableOrder() {
        // Order-independent input canonicalizes to precision-then-discrete (stable order).
        XCTAssertEqual(ScrollMultiplierValue.parse("discrete:3,precision:0.5").serialized(),
                       "precision:0.5,discrete:3")
        // The canonical form round-trips byte-for-byte.
        XCTAssertEqual(ScrollMultiplierValue.parse("precision:1,discrete:3").serialized(),
                       "precision:1,discrete:3")
    }

    func testScrollMultiplierPreservesUnknownFragmentThroughEdit() {
        var v = ScrollMultiplierValue.parse("precision:0.5,discrete:3,foo:bar")
        XCTAssertEqual(v.unknown, ["foo:bar"])
        v.precision = "0.2"                       // edit one labeled field
        XCTAssertEqual(v.serialized(), "precision:0.2,discrete:3,foo:bar")   // unknown survives (R8)
    }

    func testScrollMultiplierPreservesBareValue() {
        // A prefix-less value applies to all devices (legacy form) — kept verbatim (R8).
        let v = ScrollMultiplierValue.parse("3")
        XCTAssertNil(v.precision)
        XCTAssertNil(v.discrete)
        XCTAssertEqual(v.serialized(), "3")
    }

    func testScrollMultiplierClearingAFieldDropsItsFragment() {
        var v = ScrollMultiplierValue.parse("precision:0.5,discrete:3")
        v.precision = nil
        XCTAssertEqual(v.serialized(), "discrete:3")
    }

    // MARK: - Bell features flag set (scenario 4)

    func testBellFeaturesUsesDocumentedDefaultsForOmittedFeatures() {
        let v = BellFeaturesValue.parse("")   // nothing explicit → each feature uses its default
        XCTAssertTrue(v.isEnabled("attention"))   // enabled by default per Ghostty docs
        XCTAssertTrue(v.isEnabled("title"))       // enabled by default
        XCTAssertFalse(v.isEnabled("system"))
        XCTAssertFalse(v.isEnabled("audio"))
        XCTAssertFalse(v.isEnabled("border"))
    }

    func testBellFeaturesParsesExplicitEnableAndNoPrefixDisable() {
        let v = BellFeaturesValue.parse("no-system,no-audio,attention,title,no-border")
        XCTAssertFalse(v.isEnabled("system"))
        XCTAssertFalse(v.isEnabled("audio"))
        XCTAssertTrue(v.isEnabled("attention"))
        XCTAssertTrue(v.isEnabled("title"))
        XCTAssertFalse(v.isEnabled("border"))
    }

    func testBellFeaturesTogglePreservesOmittedAndUnknownTokens() {
        var v = BellFeaturesValue.parse("attention,frobnicate")   // frobnicate = unknown/future token
        v.set("audio", enabled: true)
        // audio appended; attention untouched; unknown `frobnicate` preserved verbatim;
        // system/title/border stay OMITTED — a single toggle never force-writes the whole set.
        XCTAssertEqual(v.serialized(), "attention,frobnicate,audio")
        XCTAssertTrue(v.isEnabled("audio"))
    }

    func testBellFeaturesToggleReplacesAnExistingTokenInPlace() {
        var v = BellFeaturesValue.parse("no-system,no-audio,attention,title,no-border")
        v.set("system", enabled: true)
        XCTAssertEqual(v.serialized(), "system,no-audio,attention,title,no-border")
    }

    func testBellFeaturesRoundTripsAnUnknownOnlyValue() {
        // A value made entirely of tokens we don't model must survive untouched (R8).
        XCTAssertEqual(BellFeaturesValue.parse("frobnicate,no-widget").serialized(),
                       "frobnicate,no-widget")
    }

    func testBellFeaturesDisableAnEnabledDefaultFeature() {
        var v = BellFeaturesValue.parse("")     // attention is on by default
        v.set("attention", enabled: false)
        XCTAssertEqual(v.serialized(), "no-attention")
        XCTAssertFalse(v.isEnabled("attention"))
    }
}
