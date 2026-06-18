import Foundation

/// A single parsed message from `ghostty +validate-config`.
public struct ValidationMessage: Sendable, Equatable {
    public let file: String?
    public let line: Int?
    public let key: String?
    public let message: String

    public init(file: String?, line: Int?, key: String?, message: String) {
        self.file = file
        self.line = line
        self.key = key
        self.message = message
    }
}

/// The result of running `+validate-config` (R15).
public struct ValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let messages: [ValidationMessage]
    public let rawOutput: String

    public init(isValid: Bool, messages: [ValidationMessage], rawOutput: String) {
        self.isValid = isValid
        self.messages = messages
        self.rawOutput = rawOutput
    }
}

/// A statically-detected configuration footgun (R16).
public struct LintFinding: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Equatable {
        case error
        case warning
        case info
    }

    public let rule: String
    public let severity: Severity
    public let title: String
    public let message: String
    public let locations: [SettingLocation]

    public var id: String {
        rule + ":" + locations.map { "\($0.file):\($0.line)" }.joined(separator: ",")
    }

    public init(rule: String, severity: Severity, title: String, message: String, locations: [SettingLocation]) {
        self.rule = rule
        self.severity = severity
        self.title = title
        self.message = message
        self.locations = locations
    }
}

/// The outcome of the `+validate-config` step — distinguishes "validated, no
/// errors" from "couldn't validate", which a plain `ValidationResult?` conflated
/// into `nil` and let the UI render a false all-clear (R15).
public enum ValidationOutcome: Sendable, Equatable {
    /// Not attempted — no binary available (e.g. first launch with no config).
    case notRun
    /// Ran to completion; carries validity and any parsed messages.
    case completed(ValidationResult)
    /// Attempted but the binary call failed; carries a human-readable reason.
    case unavailable(String)
}

/// Combined validation + footgun report.
public struct LintReport: Sendable {
    public let validation: ValidationOutcome
    public let findings: [LintFinding]

    public init(validation: ValidationOutcome, findings: [LintFinding]) {
        self.validation = validation
        self.findings = findings
    }

    public var hasProblems: Bool {
        let validationFailed: Bool
        if case .completed(let result) = validation { validationFailed = !result.isValid }
        else { validationFailed = false }
        return validationFailed || findings.contains { $0.severity != .info }
    }

    /// At-a-glance config health for the window-chrome chip (R15, R16). `.error`
    /// outranks `.warning`; `.unknown` means live validation couldn't run
    /// (surfaced instead of a false all-clear), and `.clean` means
    /// validated/not-run with no actionable footguns.
    public enum Health: Sendable, Equatable {
        case clean
        case warning
        case error
        case unknown
    }

    /// Count of actionable problems: validation errors (only when validation ran
    /// and failed) plus non-`.info` footguns. Single source of truth for the
    /// count the sidebar previously rendered and the top-bar chip now shows.
    ///
    /// A failed validation that emitted no parseable messages still counts as one
    /// problem (the failure itself), so `health == .error` always implies
    /// `problemCount >= 1` — the chip never shows a red "0 problems".
    public var problemCount: Int {
        let validationErrors: Int
        if case .completed(let result) = validation, !result.isValid {
            validationErrors = max(1, result.messages.count)
        } else {
            validationErrors = 0
        }
        let footguns = findings.filter { $0.severity != .info }.count
        return validationErrors + footguns
    }

    /// Severity classification for the top-bar health chip. Hard validation
    /// errors outrank footgun warnings, which in turn outrank an unavailable
    /// validation run: footgun lint is static (it doesn't need the validation
    /// binary), so an actionable footgun still surfaces as `.warning` even when
    /// `ghostty +validate-config` couldn't run. `.unknown` therefore means
    /// validation was unavailable AND nothing else is actionable.
    public var health: Health {
        if case .completed(let result) = validation, !result.isValid { return .error }
        if findings.contains(where: { $0.severity != .info }) { return .warning }
        if case .unavailable = validation { return .unknown }
        return .clean
    }

    /// One-line label for the top-bar health chip, derived entirely from this
    /// report so the copy and its pluralization are tested in the kit rather
    /// than the untested view layer.
    public var badgeText: String {
        switch health {
        case .clean:
            return "No problems"
        case .warning, .error:
            let count = problemCount
            return "\(count) problem\(count == 1 ? "" : "s")"
        case .unknown:
            return "Health unknown"
        }
    }
}

/// Validates config via the Ghostty CLI and flags known footguns statically
/// (R15, R16).
public struct ConfigLinter: Sendable {

    public init() {}

    // MARK: - CLI validation (R15)

    /// Run `+validate-config`, optionally against a specific file. Errors are
    /// parsed from output of the form `path:line:key: message`.
    public func validate(cli: GhosttyCLI, configFile: String? = nil) async throws -> ValidationResult {
        var args = ["+validate-config"]
        if let configFile { args.append("--config-file=\(configFile)") }
        let result = try await cli.run(args)
        let combined = result.stdoutString + result.stderrString
        return ValidationResult(
            isValid: result.exitCode == 0,
            messages: Self.parseValidationOutput(combined),
            rawOutput: combined
        )
    }

    static func parseValidationOutput(_ output: String) -> [ValidationMessage] {
        // `path:line:key: message`, with the `:key` segment optional so a
        // `path:line: message` diagnostic still yields file + line.
        let regex = try? NSRegularExpression(pattern: #"^(.+):(\d+):(?:([^:]+):)?\s?(.*)$"#)
        var messages: [ValidationMessage] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let regex, let match = regex.firstMatch(in: line, range: range),
               let fileR = Range(match.range(at: 1), in: line),
               let lineR = Range(match.range(at: 2), in: line),
               let msgR = Range(match.range(at: 4), in: line) {
                let key = Range(match.range(at: 3), in: line).map {
                    String(line[$0]).trimmingCharacters(in: .whitespaces)
                }
                messages.append(ValidationMessage(
                    file: String(line[fileR]),
                    line: Int(line[lineR]),
                    key: key,
                    message: String(line[msgR])
                ))
            } else {
                messages.append(ValidationMessage(file: nil, line: nil, key: nil, message: trimmed))
            }
        }
        return messages
    }

    // MARK: - Static footgun lint (R16)

    /// Flag known footguns over the parsed config model.
    public func lint(_ model: ConfigModel) -> [LintFinding] {
        var findings: [LintFinding] = []
        var byTrigger: [String: [(value: String, location: SettingLocation)]] = [:]

        for file in model.allFiles {
            for configLine in file.lines {
                guard case .setting(let key, let value) = configLine.kind, key == "keybind" else { continue }
                let location = SettingLocation(file: file.resolvedPath, line: configLine.lineNumber)
                let v = value.trimmingCharacters(in: .whitespaces)

                if v.isEmpty {
                    findings.append(LintFinding(
                        rule: "keybind-clears-all",
                        severity: .warning,
                        title: "This clears all keybinds",
                        message: "A bare `keybind =` removes every keybinding, including Ghostty's defaults. If that's intentional you can ignore this; otherwise give it a `trigger=action`.",
                        locations: [location]
                    ))
                    continue
                }
                if v.lowercased() == "clear" {
                    findings.append(LintFinding(
                        rule: "keybind-explicit-clear",
                        severity: .info,
                        title: "Clears all keybinds",
                        message: "`keybind = clear` removes all keybindings defined before this line, including defaults.",
                        locations: [location]
                    ))
                    continue
                }
                guard let eq = v.firstIndex(of: "="), eq != v.startIndex else {
                    findings.append(LintFinding(
                        rule: "keybind-malformed",
                        severity: .warning,
                        title: "Keybind has no action",
                        message: "`keybind = \(v)` is missing an action. The form is `keybind = trigger=action` (e.g., `keybind = super+t=new_tab`).",
                        locations: [location]
                    ))
                    continue
                }
                let trigger = String(v[..<eq]).trimmingCharacters(in: .whitespaces)
                byTrigger[trigger, default: []].append((value: v, location: location))
            }
        }

        for (trigger, binds) in byTrigger where binds.count > 1 {
            let actions = Set(binds.map { Self.action(of: $0.value) })
            if actions.count > 1 {
                findings.append(LintFinding(
                    rule: "keybind-conflict",
                    severity: .warning,
                    title: "Conflicting keybind for \(trigger)",
                    message: "`\(trigger)` is bound \(binds.count) times to different actions. Ghostty uses the last one; the earlier binding(s) never fire.",
                    locations: binds.map(\.location)
                ))
            }
        }

        return findings.sorted {
            let l = $0.locations.first, r = $1.locations.first
            if l?.file != r?.file { return (l?.file ?? "") < (r?.file ?? "") }
            return (l?.line ?? 0) < (r?.line ?? 0)
        }
    }

    private static func action(of binding: String) -> String {
        guard let eq = binding.firstIndex(of: "=") else { return "" }
        return String(binding[binding.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Combined

    /// Validate + lint in one pass for the Explorer's problems surface.
    public func analyze(model: ConfigModel, cli: GhosttyCLI?) async -> LintReport {
        let findings = lint(model)
        let validation: ValidationOutcome
        if let cli {
            do {
                validation = .completed(try await validate(cli: cli, configFile: model.primary.resolvedPath))
            } catch {
                // Don't swallow it into a false "no problems": surface that live
                // validation couldn't run, distinct from "ran and found nothing".
                validation = .unavailable(error.localizedDescription)
            }
        } else {
            validation = .notRun
        }
        return LintReport(validation: validation, findings: findings)
    }
}
