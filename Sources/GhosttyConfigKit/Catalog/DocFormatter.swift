import Foundation

/// Turns Ghostty's hard-wrapped option documentation into renderable blocks.
///
/// The raw `--docs` text is wrapped at a fixed column, so rendered verbatim it breaks
/// mid-sentence — and worse, mid-token: a code span like `` `CSI q` `` split across a
/// wrap becomes two ugly lines. This reflows each paragraph onto one logical line (the
/// OS then wraps it at the real width) and lifts `* `/`- ` items into bullets. It is
/// **deliberately not** a Markdown renderer — no headings, emphasis, or nested lists;
/// backtick spans are left intact for the view to render as mono.
public enum DocFormatter {

    /// One renderable block of documentation.
    public enum Block: Equatable, Sendable {
        /// A reflowed paragraph — hard wraps joined, ready to wrap at the view's width.
        case paragraph(String)
        /// A single list item (marker stripped; continuation lines folded in).
        case bullet(String)
    }

    /// Parse `documentation` into paragraphs and bullets. Blank lines break paragraphs;
    /// a `* `/`- ` line starts a bullet; an indented line following a bullet folds into
    /// it (so a wrapped bullet stays one item).
    public static func format(_ documentation: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            if !text.isEmpty { blocks.append(.paragraph(text)) }
        }

        for rawLine in documentation.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()                                    // blank line → paragraph break
            } else if let item = bulletText(trimmed) {
                flushParagraph()                                    // a bullet ends the running paragraph
                blocks.append(.bullet(item))
            } else if rawLine.first?.isWhitespace == true,
                      paragraph.isEmpty,
                      case .bullet(let existing)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(existing + " " + trimmed)   // wrapped bullet continuation
            } else {
                paragraph.append(trimmed)                           // reflow: join a wrapped line
            }
        }
        flushParagraph()
        return blocks
    }

    /// The text of a bullet line (`* item` / `- item`), or nil when the line isn't a
    /// bullet. A bare marker with no text ("*") is not a bullet.
    private static func bulletText(_ line: String) -> String? {
        for marker in ["* ", "- "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
