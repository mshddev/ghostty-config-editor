import SwiftUI
import AppKit
import GhosttyConfigKit

/// The Problems surface: `+validate-config` errors and static footgun warnings
/// (R15, R16). Read-only in M1.
struct ProblemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let report = model.lintReport {
                if isClean(report) {
                    ContentUnavailableView("No problems",
                                           systemImage: "checkmark.seal",
                                           description: Text("Your config validates cleanly and has no known footguns."))
                } else {
                    List {
                        if case .unavailable(let reason) = report.validation {
                            Section("Validation unavailable") {
                                unavailableRow(reason)
                            }
                        }
                        if case .completed(let validation) = report.validation, !validation.isValid {
                            Section("Validation errors") {
                                if validation.messages.isEmpty {
                                    // Validation failed but emitted nothing parseable — show a
                                    // generic row so the surface is never blank for an .error state.
                                    genericValidationFailureRow()
                                } else {
                                    ForEach(Array(validation.messages.enumerated()), id: \.offset) { _, message in
                                        validationRow(message)
                                    }
                                }
                            }
                        }
                        if !report.findings.isEmpty {
                            Section("Footguns") {
                                ForEach(report.findings) { finding in
                                    findingRow(finding)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Checking config…")
            }
        }
        .navigationTitle("Problems")
    }

    private func isClean(_ report: LintReport) -> Bool {
        switch report.validation {
        case .unavailable:
            return false // surface the banner rather than a false all-clear
        case .completed(let result):
            return result.isValid && report.findings.isEmpty
        case .notRun:
            return report.findings.isEmpty
        }
    }

    private func unavailableRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.diamond.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't run ghostty +validate-config").font(.body.bold())
                Text("Static footguns are still listed, but live validation didn't run: \(reason)")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func genericValidationFailureRow() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Config failed validation").font(.body.bold())
                Text("`ghostty +validate-config` reported your config as invalid but returned no specific message.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func validationRow(_ message: ValidationMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.key ?? "Error").font(.body.bold())
                Text(message.message).font(.callout).foregroundStyle(.secondary)
                if let line = message.line {
                    Text("line \(line)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func findingRow(_ finding: LintFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: finding.severity))
                .foregroundStyle(color(for: finding.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.body.bold())
                Text(finding.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let location = finding.locations.first {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: location.file))
                    } label: {
                        Text("\((location.file as NSString).lastPathComponent):\(location.line)")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for severity: LintFinding.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: LintFinding.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
