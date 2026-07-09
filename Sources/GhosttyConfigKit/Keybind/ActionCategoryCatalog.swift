import Foundation

/// A functional section of the Keybindings editor: a curated group like
/// "Windows & Tabs" or "Splits" that the ~140 actions read under, instead of one flat
/// alphabetical wall.
public struct ActionSection: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One action's placement: its section and within-section rank.
public struct ActionCategory: Sendable, Codable, Equatable {
    public let section: String
    public let rank: Int

    public init(section: String, rank: Int) {
        self.section = section
        self.rank = rank
    }
}

/// The Keybindings editor's action list, partitioned into curated functional sections.
/// Mirrors `OptionTierCatalog`: a small bundled map keyed by **action name**
/// (params stripped, so every `goto_tab:N` lands in the same section), with the same
/// orphan-key guard discipline — a categorized action absent from `+list-actions`
/// is a test failure. Any action we haven't categorized falls into a deterministic
/// **Other** section rather than vanishing.
public struct ActionCategoryCatalog: Sendable {
    /// The always-last fallback bucket for uncategorized actions.
    public static let otherSection = ActionSection(id: "other", title: "Other")

    private let sectionsInOrder: [ActionSection]
    private let categories: [String: ActionCategory]
    /// The declared section ids — so an action mapped to a section that doesn't exist
    /// (a typo in the JSON) resolves to Other rather than vanishing (see `sectionID`).
    private let declaredSectionIDs: Set<String>

    public init(sections: [ActionSection], categories: [String: ActionCategory]) {
        self.sectionsInOrder = sections
        self.categories = categories
        self.declaredSectionIDs = Set(sections.map(\.id))
    }

    // MARK: - Read API

    /// The section id for an action (params stripped). `Other` when uncategorized **or**
    /// when the mapped section isn't a declared one — a mistyped `section` in the JSON
    /// must not make the action's row disappear from the editor (it lands in Other).
    public func sectionID(forAction action: String) -> String {
        guard let id = categories[Keybind.actionName(action)]?.section,
              declaredSectionIDs.contains(id) else { return Self.otherSection.id }
        return id
    }

    /// Categorized actions whose `section` doesn't match any declared section — used by a
    /// referential-integrity test so a typo is caught at test time, even
    /// though `sectionID` degrades gracefully at runtime.
    public var danglingSectionActions: [String] {
        categories.compactMap { name, category in
            declaredSectionIDs.contains(category.section) ? nil : name
        }
    }

    /// The within-section rank, or a sentinel that sorts after every ranked action.
    public func rank(forAction action: String) -> Int {
        categories[Keybind.actionName(action)]?.rank ?? Int.max
    }

    /// Categorized action names — used by the orphan-key guard.
    public var categorizedActionNames: Set<String> { Set(categories.keys) }

    /// The curated sections in display order (the Other bucket is appended by `sections(for:)`).
    public var orderedSections: [ActionSection] { sectionsInOrder }

    // MARK: - Sectioning

    /// Partition action groups into ordered functional sections. Curated sections
    /// appear in their catalog order; an **Other** section (uncategorized actions) is always
    /// last. Within a section, groups sort by curated rank then action name — total and
    /// deterministic. Empty sections are omitted, so a filtered list shows only sections
    /// that still have rows.
    public func sections(for groups: [KeybindActionGroup]) -> [KeybindActionSection] {
        var bySection: [String: [KeybindActionGroup]] = [:]
        for group in groups {
            bySection[sectionID(forAction: group.action), default: []].append(group)
        }
        func sorted(_ groups: [KeybindActionGroup]) -> [KeybindActionGroup] {
            groups.sorted { lhs, rhs in
                let lRank = rank(forAction: lhs.action), rRank = rank(forAction: rhs.action)
                if lRank != rRank { return lRank < rRank }
                return lhs.action < rhs.action
            }
        }
        var result: [KeybindActionSection] = []
        for section in sectionsInOrder {
            guard let groups = bySection[section.id], !groups.isEmpty else { continue }
            result.append(KeybindActionSection(id: section.id, title: section.title, groups: sorted(groups)))
        }
        if let others = bySection[Self.otherSection.id], !others.isEmpty {
            result.append(KeybindActionSection(id: Self.otherSection.id,
                                               title: Self.otherSection.title,
                                               groups: sorted(others)))
        }
        return result
    }

    /// The subset of `groups` belonging to a single section id (params stripped), preserving
    /// the input order. Powers the Keybindings section-filter pills — a coarse filter that
    /// composes with the row text search — without re-partitioning the whole set.
    public func groups(_ groups: [KeybindActionGroup], inSection sectionID: String) -> [KeybindActionGroup] {
        groups.filter { self.sectionID(forAction: $0.action) == sectionID }
    }

    // MARK: - Bundled resource

    private struct File: Codable {
        let sections: [ActionSection]
        let actions: [String: ActionCategory]
    }

    public static func decode(_ data: Data) throws -> ActionCategoryCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        return ActionCategoryCatalog(sections: file.sections, categories: file.actions)
    }

    public static let bundled: ActionCategoryCatalog = {
        guard let url = Bundle.module.url(forResource: "action-categories", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return ActionCategoryCatalog(sections: [], categories: [:])
        }
        return catalog
    }()
}

/// One rendered section of the keybind list: its title and the action groups within it,
/// already ordered. Identifiable so SwiftUI can iterate sections in a `List`.
public struct KeybindActionSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let groups: [KeybindActionGroup]

    public init(id: String, title: String, groups: [KeybindActionGroup]) {
        self.id = id
        self.title = title
        self.groups = groups
    }
}
