import Foundation

/// Whether a Ghostty catalog entry belongs in a config-file editor.
public enum OptionEditability: String, Codable, Sendable, Equatable {
    case editable
    case readOnly
    case excluded
}

/// The semantic editor selected before SwiftUI renders an option row.
public enum OptionEditorKind: String, Codable, Sendable, Equatable, CaseIterable {
    case automatic
    case dedicated
    case repeatableList
    case path
    case pathList
    case flagSet
    case scrollMultiplier
    case color
}

/// Resolved presentation facts that Ghostty's self-describing catalog cannot
/// express on its own. Values remain sparse so this never becomes a second schema.
public struct OptionPresentation: Codable, Sendable, Equatable {
    public let editability: OptionEditability
    public let editorKind: OptionEditorKind
    public let effectiveDefault: String?
    public let semanticGroup: String?

    public init(
        editability: OptionEditability = .editable,
        editorKind: OptionEditorKind = .automatic,
        effectiveDefault: String? = nil,
        semanticGroup: String? = nil
    ) {
        self.editability = editability
        self.editorKind = editorKind
        self.effectiveDefault = effectiveDefault
        self.semanticGroup = semanticGroup
    }
}

/// Sparse, bundled overrides layered over the installed Ghostty catalog.
public struct OptionPresentationCatalog: Sendable {
    private struct Override: Codable, Sendable {
        let editability: OptionEditability?
        let editorKind: OptionEditorKind?
        let effectiveDefault: String?
        let semanticGroup: String?
    }

    private struct File: Codable { let options: [String: Override] }

    private let overrides: [String: Override]

    private init(overrides: [String: Override]) {
        self.overrides = overrides
    }

    public var curatedOptionNames: Set<String> { Set(overrides.keys) }

    public func presentation(for option: CatalogOption) -> OptionPresentation {
        presentation(name: option.name, isRepeatable: option.isRepeatable)
    }

    func presentation(name: String, isRepeatable: Bool) -> OptionPresentation {
        let override = overrides[name]
        let editor = override?.editorKind ?? (isRepeatable ? .repeatableList : .automatic)
        return OptionPresentation(
            editability: override?.editability ?? .editable,
            editorKind: editor,
            effectiveDefault: override?.effectiveDefault,
            semanticGroup: override?.semanticGroup
        )
    }

    public static func decode(_ data: Data) throws -> OptionPresentationCatalog {
        OptionPresentationCatalog(overrides: try JSONDecoder().decode(File.self, from: data).options)
    }

    public static let bundled: OptionPresentationCatalog = {
        guard let url = Bundle.module.url(forResource: "option-presentations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return OptionPresentationCatalog(overrides: [:])
        }
        return catalog
    }()
}

public extension CatalogOption {
    var presentation: OptionPresentation {
        OptionPresentationCatalog.bundled.presentation(for: self)
    }
}
