import SwiftUI
import AppKit
import GhosttyConfigKit

/// The Problems surface: `+validate-config` errors and static footgun warnings
/// (R15, R16). Read-only in M1.
struct ProblemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(title: "Problems")
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let report = model.lintReport {
                if isClean(report) {
                    ContentUnavailableView("No problems",
                                           systemImage: "checkmark.seal",
                                           description: Text("Your config validates cleanly with no known problems."))
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
                            // "Footgun" is our internal term (kept in CONCEPTS.md/code); the
                            // surface says it in plain language (CM-9).
                            Section("Potential problems") {
                                ForEach(report.findings) { finding in
                                    findingRow(finding)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Checking config…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Fill the remaining height so the shared header stays pinned to the top;
        // the clean-state ContentUnavailableView otherwise sizes to its content and
        // lets the whole surface drift to vertical center.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't run ghostty +validate-config").font(.body.bold())
                Text("Known problems are still listed, but live validation didn't run: \(reason)")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
    }

    private func genericValidationFailureRow() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                .accessibilityLabel("Error")
            VStack(alignment: .leading, spacing: 2) {
                Text("Config failed validation").font(.body.bold())
                Text("`ghostty +validate-config` reported your config as invalid but returned no specific message.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
    }

    private func validationRow(_ message: ValidationMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                .accessibilityLabel("Error")
            VStack(alignment: .leading, spacing: 2) {
                // G5: when the validation `key` names a real catalog option, the title
                // is a deep-link that jumps to that control (clears search, selects its
                // category, scrolls it into view via the shared `focus(optionNamed:)`);
                // otherwise it's plain text (unmapped keys keep the "line N" fallback).
                if let key = message.key, model.hasOption(named: key) {
                    Button { model.focus(optionNamed: key) } label: {
                        Text(key).font(.body.bold())
                    }
                    .buttonStyle(.link)
                    .accessibilityHint("Show this setting")
                } else {
                    Text(message.key ?? "Error").font(.body.bold())
                }
                Text(message.message).font(.callout).foregroundStyle(.secondary)
                if let line = message.line {
                    Text("line \(line)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
    }

    private func findingRow(_ finding: LintFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: finding.severity))
                .foregroundStyle(color(for: finding.severity))
                // H2/A11Y-8: severity is conveyed as a word, not color/icon alone.
                .accessibilityLabel(severityLabel(for: finding.severity))
            VStack(alignment: .leading, spacing: 2) {
                // Group the title + message into one VoiceOver element (a finding is one
                // thought), while the file:line link stays a separate, actionable element.
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(.body.bold())
                    Text(finding.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
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
        .padding(.vertical, RowMetrics.rowVerticalPadding)
    }

    private func icon(for severity: LintFinding.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func severityLabel(for severity: LintFinding.Severity) -> String {
        switch severity {
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
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
