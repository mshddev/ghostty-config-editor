import XCTest
@testable import GhosttyConfigKit

/// U3 (CV-1/CM-1): the enum-value humanizer fallback chain, plus the coverage guard
/// that no enum value renders as its own raw lowercase token.
final class EnumValueLabelTests: XCTestCase {

    private let bundled = EnumValueLabels.bundled

    // MARK: - Fallback chain

    func testUncuratedSnakeCaseValueIsHumanized() {
        // curated miss → not boolean → humanized token (never the raw string).
        let empty = EnumValueLabels(labels: [:])
        XCTAssertEqual(empty.label(option: "cursor-style", value: "block_hollow"), "Block hollow")
        XCTAssertEqual(empty.label(option: "any", value: "linear-corrected"), "Linear corrected")
    }

    func testBooleanFallbackToOnOff() {
        let empty = EnumValueLabels(labels: [:])
        XCTAssertEqual(empty.label(option: "whatever", value: "true"), "On")
        XCTAssertEqual(empty.label(option: "whatever", value: "false"), "Off")
    }

    func testCuratedLabelWinsOverFallback() {
        // A bespoke phrase beats the humanizer...
        XCTAssertEqual(bundled.label(option: "link-previews", value: "osc8"), "OSC 8 only")
        XCTAssertEqual(bundled.label(option: "cursor-style", value: "block_hollow"), "Hollow block")
        // ...and a curated boolean beats the generic On/Off.
        XCTAssertEqual(bundled.label(option: "link-previews", value: "true"), "Always")
        XCTAssertEqual(bundled.label(option: "link-previews", value: "false"), "Never")
    }

    // MARK: - Guards against the real captured catalog

    func testNoEnumValueRendersAsItsRawLowercaseToken() throws {
        let catalog = try referenceCatalog()
        var offenders: [String] = []
        for option in catalog.options where option.valueType == .enumeration {
            for value in option.enumValues where Self.isLowercaseToken(value) {
                if option.enumValueLabel(value) == value {
                    offenders.append("\(option.name)=\(value)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "enum values rendering as their raw token: \(offenders.sorted())")
    }

    func testEveryCuratedEnumOptionResolvesInCatalog() throws {
        let names = Set(try referenceCatalog().options.map(\.name))
        let orphans = EnumValueLabels.bundled.labeledOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty, "enum-value-labels.json has keys absent from the catalog: \(orphans.sorted())")
    }

    /// A raw config token that would look unprofessional shown verbatim: starts with a
    /// lowercase letter and contains only lowercase letters, digits, or underscores.
    /// (A proper-cased value like `sRGB` is exempt — the humanizer keeps its casing.)
    private static func isLowercaseToken(_ value: String) -> Bool {
        guard let first = value.first, first.isLowercase else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
