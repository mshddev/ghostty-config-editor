import Foundation

/// Per-option state after merging the user's config against the catalog (R5, R6).
public enum OptionState: Sendable, Equatable {
    /// Not present in the config — the catalog default applies. Surfaced in the
    /// "you're not using this" view (R6).
    case unset
    /// Explicitly set, but to the same value as the default.
    case setToDefault
    /// Explicitly set to a non-default value.
    case setNonDefault
}

/// A catalog option joined with the user's current value(s) and where they live.
public struct MergedOption: Sendable, Identifiable {
    public var id: String { option.name }
    public let option: CatalogOption
    public let state: OptionState
    /// The user's value(s); empty when unset. Repeatable keys carry many.
    public let userValues: [String]
    /// Where each value was set (file + line) — drives the writer and the UI.
    public let sources: [SettingLocation]

    public var isSet: Bool { state != .unset }

    /// Values in force: the user's if set, otherwise the catalog defaults.
    public var effectiveValues: [String] {
        isSet ? userValues : option.defaultValues
    }

    public init(option: CatalogOption, state: OptionState, userValues: [String], sources: [SettingLocation]) {
        self.option = option
        self.state = state
        self.userValues = userValues
        self.sources = sources
    }
}

/// One selectable row in an enumerated option's dropdown (R1, R2, R3).
public struct EnumChoice: Sendable, Equatable, Identifiable {
    public var id: String { value }
    /// The value written/selected — the SwiftUI `Picker` tag.
    public let value: String
    /// Human-facing row text (a bare value, or an annotated current/unset entry).
    public let label: String
    /// True for the row the editor seeds its selection to.
    public let isSelected: Bool

    public init(value: String, label: String, isSelected: Bool) {
        self.value = value
        self.label = label
        self.isSelected = isSelected
    }
}

public extension MergedOption {
    /// Ordered rows for an enumerated option's dropdown, made safe against the
    /// SwiftUI `Picker` footgun where a selection with no matching tag renders
    /// blank and silently overwrites the user's value (R3).
    ///
    /// - Parameter current: the option's *saved* value (the editor's seeded
    ///   selection) — `userValues.first` when set, else the catalog default. Pass
    ///   the saved value, never the in-progress draft, or an out-of-enum row would
    ///   vanish the moment the selection moves off it.
    /// - Returns: `enumValues` in documented order, prefixed by a distinct leading
    ///   row whenever `current` is not one of them — an "— current value" row for a
    ///   saved out-of-enum value, or a "Not set — uses default" row for an unset
    ///   option whose default isn't itself listed. The leading row carries `current`
    ///   as its tag so the editor's selection always has a match.
    func enumChoices(current: String) -> [EnumChoice] {
        let values = option.enumValues
        if !current.isEmpty, values.contains(current) {
            // The saved value is a listed choice — just mark it selected.
            return values.map { EnumChoice(value: $0, label: $0, isSelected: $0 == current) }
        }
        // `current` is empty or outside the set: lead with a row that carries it as
        // the tag so the seeded selection matches, and is the only selected row.
        let leadLabel: String
        if isSet {
            leadLabel = "\(current) — current value"
        } else {
            let def = option.defaultValue
            leadLabel = def.isEmpty ? "Not set — uses default" : "Not set — uses default (\(def))"
        }
        let lead = EnumChoice(value: current, label: leadLabel, isSelected: true)
        return [lead] + values.map { EnumChoice(value: $0, label: $0, isSelected: false) }
    }
}

/// The merged view the Explorer renders.
public struct MergedConfig: Sendable {
    public let options: [MergedOption]
    public let model: ConfigModel
    /// Keys the user set that aren't in the catalog — preserved (R11), shown as custom.
    public let unknownUserKeys: [String]

    public init(options: [MergedOption], model: ConfigModel, unknownUserKeys: [String]) {
        self.options = options
        self.model = model
        self.unknownUserKeys = unknownUserKeys
    }

    public func option(named name: String) -> MergedOption? {
        options.first { $0.option.name == name }
    }

    /// Options the user has not set — the discovery surface (R6).
    public var unusedOptions: [MergedOption] {
        options.filter { !$0.isSet }
    }

    /// Options the user has set to a non-default value.
    public var customizedOptions: [MergedOption] {
        options.filter { $0.state == .setNonDefault }
    }

    public func options(in category: String) -> [MergedOption] {
        options.filter { $0.option.category == category }
    }
}

public enum ConfigReadError: Error, Equatable, Sendable {
    case notFound
    case unreadable(path: String)
}

/// Reads the active config (search-path precedence + `config-file` includes)
/// and merges it with the catalog (R5, R6, R7).
public struct ConfigReader: Sendable {

    /// Config filenames tried in priority order within the config directory.
    /// `config` is Ghostty's canonical name; `config.ghostty` is also supported
    /// (and is what this project's author uses).
    public static let candidateFilenames = ["config", "config.ghostty"]

    public init() {}

    // MARK: - Path resolution

    /// The Ghostty config directory: `$XDG_CONFIG_HOME/ghostty` or `~/.config/ghostty`.
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("ghostty")
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/ghostty")
    }

    /// First existing config file among the candidates in `directory`.
    public static func locatePrimaryConfig(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        for name in candidateFilenames {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Canonicalize a path (resolve symlinks + standardize) so include lookups
    /// and writer targeting agree on identity (R20).
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Reading

    /// Read the primary config plus all `config-file` includes into a
    /// line-preserving model. Missing includes are skipped; cycles are guarded.
    public func readModel(primaryPath: String, fileManager: FileManager = .default) throws -> ConfigModel {
        guard let primary = try Self.readFile(at: primaryPath, fileManager: fileManager) else {
            throw ConfigReadError.notFound
        }
        var includes: [ConfigFile] = []
        var visited: Set<String> = [primary.resolvedPath]
        collectIncludes(of: primary, into: &includes, visited: &visited, fileManager: fileManager)
        return ConfigModel(primary: primary, includes: includes)
    }

    private func collectIncludes(
        of file: ConfigFile,
        into includes: inout [ConfigFile],
        visited: inout Set<String>,
        fileManager: FileManager
    ) {
        let dir = (file.resolvedPath as NSString).deletingLastPathComponent
        for line in file.lines where line.key == "config-file" {
            guard let directive = line.value,
                  let resolved = Self.resolveIncludePath(directive, relativeToDir: dir)
            else { continue }
            let canonical = Self.canonicalPath(resolved)
            if visited.contains(canonical) { continue }
            visited.insert(canonical)
            guard let included = try? Self.readFile(at: resolved, fileManager: fileManager) else { continue }
            includes.append(included)
            collectIncludes(of: included, into: &includes, visited: &visited, fileManager: fileManager)
        }
    }

    private static func readFile(at path: String, fileManager: FileManager) throws -> ConfigFile? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let data = fileManager.contents(atPath: path) else {
            throw ConfigReadError.unreadable(path: path)
        }
        let resolved = canonicalPath(path)
        // Refuse non-UTF-8 rather than lossily decoding (U+FFFD replacement),
        // which would silently corrupt the file on the next write (R11, R23).
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigReadError.unreadable(path: path)
        }
        var file = ConfigFile.parse(text: text, path: path, resolvedPath: resolved)
        // Capture the read-time identity stamp so the writer can detect external
        // changes and preserve permissions (R22, R23).
        file.identity = FileIdentity.capture(path: resolved, fileManager: fileManager)
        return file
    }

    /// Resolve a `config-file` directive to an absolute path. Handles the `?`
    /// optional prefix, `~` expansion, and relative-to-including-file paths.
    static func resolveIncludePath(_ raw: String, relativeToDir dir: String) -> String? {
        var p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("?") { p.removeFirst(); p = p.trimmingCharacters(in: .whitespaces) }
        // Strip one layer of surrounding double quotes (used for paths with spaces).
        if p.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") { p = String(p.dropFirst().dropLast()) }
        guard !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        if p.hasPrefix("/") { return (p as NSString).standardizingPath }
        return URL(fileURLWithPath: dir).appendingPathComponent(p).standardizedFileURL.path
    }

    // MARK: - Effective settings (precedence)

    struct EffectiveSetting: Equatable {
        let key: String
        let value: String
        let location: SettingLocation
    }

    /// Walk the config in processing order, splicing includes at the position of
    /// their `config-file` directive. Order matters: the last occurrence of a
    /// scalar key wins (R5).
    func effectiveSettings(_ model: ConfigModel) -> [EffectiveSetting] {
        var out: [EffectiveSetting] = []
        var visited: Set<String> = []
        walk(model.primary, model: model, visited: &visited, into: &out)
        return out
    }

    private func walk(
        _ file: ConfigFile,
        model: ConfigModel,
        visited: inout Set<String>,
        into out: inout [EffectiveSetting]
    ) {
        guard !visited.contains(file.resolvedPath) else { return }
        visited.insert(file.resolvedPath)
        let dir = (file.resolvedPath as NSString).deletingLastPathComponent
        for line in file.lines {
            guard case .setting(let key, let value) = line.kind else { continue }
            if key == "config-file" {
                if let resolved = Self.resolveIncludePath(value, relativeToDir: dir),
                   let included = model.file(resolvedPath: Self.canonicalPath(resolved)) {
                    walk(included, model: model, visited: &visited, into: &out)
                }
            } else {
                out.append(EffectiveSetting(
                    key: key,
                    value: value,
                    location: SettingLocation(file: file.resolvedPath, line: line.lineNumber)
                ))
            }
        }
    }

    // MARK: - Merge

    /// Join the config model against the catalog into the Explorer's view.
    public func merge(model: ConfigModel, catalog: OptionCatalog) -> MergedConfig {
        let effective = effectiveSettings(model)
        var byKey: [String: [EffectiveSetting]] = [:]
        for setting in effective {
            byKey[setting.key, default: []].append(setting)
        }

        let merged = catalog.options.map { option -> MergedOption in
            guard let occurrences = byKey[option.name], !occurrences.isEmpty else {
                return MergedOption(option: option, state: .unset, userValues: [], sources: [])
            }
            let values: [String]
            let sources: [SettingLocation]
            if option.isRepeatable {
                values = occurrences.map(\.value)              // all accumulate (R9)
                sources = occurrences.map(\.location)
            } else {
                values = [occurrences.last!.value]             // last wins (R5)
                sources = [occurrences.last!.location]
            }
            let isDefault = matchesDefault(option: option, values: values)
            return MergedOption(
                option: option,
                state: isDefault ? .setToDefault : .setNonDefault,
                userValues: values,
                sources: sources
            )
        }

        let catalogNames = Set(catalog.options.map(\.name))
        let unknown = Set(byKey.keys)
            .subtracting(catalogNames)
            .subtracting(["config-file"])
            .sorted()

        return MergedConfig(options: merged, model: model, unknownUserKeys: unknown)
    }

    private func matchesDefault(option: CatalogOption, values: [String]) -> Bool {
        if option.isRepeatable {
            return values.map(normalize) == option.defaultValues.map(normalize)
        }
        return normalize(values.first ?? "") == normalize(option.defaultValue)
    }

    /// Compare values forgivingly: trim whitespace and a single layer of
    /// surrounding double quotes so `"block"` equals `block`.
    private func normalize(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    // MARK: - Convenience

    /// Locate, read, and merge in one step. Throws `.notFound` when no config
    /// file exists (the UI can render a first-launch "no config yet" state).
    public func read(
        catalog: OptionCatalog,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> MergedConfig {
        let directory = Self.configDirectory(environment: environment, home: home)
        guard let primary = Self.locatePrimaryConfig(in: directory, fileManager: fileManager) else {
            throw ConfigReadError.notFound
        }
        let model = try readModel(primaryPath: primary.path, fileManager: fileManager)
        return merge(model: model, catalog: catalog)
    }
}
