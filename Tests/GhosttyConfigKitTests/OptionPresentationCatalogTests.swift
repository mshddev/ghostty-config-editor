import XCTest
@testable import GhosttyConfigKit

final class OptionPresentationCatalogTests: XCTestCase {
    func testExcludedConfigOnlyInertOptionDoesNotReachCatalogOrSearch() throws {
        let catalog = try referenceCatalog()

        XCTAssertNil(catalog.option(named: "config-default-files"))
        XCTAssertFalse(CatalogSearch(catalog: catalog).search("config-default-files").contains {
            $0.optionName == "config-default-files"
        })
    }

    func testPresentationOverridesHaveNoOrphans() throws {
        let names = Set(try unfilteredReferenceCatalog().options.map(\.name))
        let orphans = OptionPresentationCatalog.bundled.curatedOptionNames.subtracting(names)

        XCTAssertTrue(orphans.isEmpty, "option-presentations.json has unknown keys: \(orphans.sorted())")
    }

    func testEveryRepeatableHasAnEditorClassification() throws {
        for option in try referenceCatalog().options where option.isRepeatable {
            switch option.presentation.editorKind {
            case .dedicated, .repeatableList, .pathList:
                break
            default:
                XCTFail("repeatable option has no editor classification: \(option.name)")
            }
        }
    }

    func testUnknownOptionsReceiveLosslessFallbackPolicies() {
        let scalar = makeOption(name: "future-scalar", repeatable: false)
        let repeatable = makeOption(name: "future-repeatable", repeatable: true)

        XCTAssertEqual(scalar.presentation.editorKind, .automatic)
        XCTAssertEqual(repeatable.presentation.editorKind, .repeatableList)
        XCTAssertEqual(scalar.presentation.editability, .editable)
        XCTAssertEqual(repeatable.presentation.editability, .editable)
    }

    func testCursorBlinkCarriesItsEffectiveDefault() throws {
        let option = try XCTUnwrap(referenceCatalog().option(named: "cursor-style-blink"))

        XCTAssertEqual(option.presentation.effectiveDefault, "true")
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"), version: "fixture")
    }

    private func unfilteredReferenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(
            try Fixture.text("show-config-default-docs", "txt"),
            version: "fixture",
            applyingPresentationExclusions: false
        )
    }

    private func makeOption(name: String, repeatable: Bool) -> CatalogOption {
        CatalogOption(
            name: name,
            defaultValues: [""],
            documentation: "Future option.",
            category: "Advanced",
            valueType: .string,
            enumValues: [],
            isRepeatable: repeatable
        )
    }
}
