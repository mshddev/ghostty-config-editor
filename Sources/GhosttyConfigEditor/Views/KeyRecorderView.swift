import SwiftUI
import AppKit
import Carbon.HIToolbox
import GhosttyConfigKit

/// A focusable control that records a single modifier+key chord — press the real
/// hotkey, exactly like a system shortcut field — and hands a canonical trigger
/// token back to SwiftUI (RK3, KTD6). All the token logic lives in the kit
/// (`KeybindTrigger.token(from:)`); this view only captures the keystroke and
/// resolves the layout-correct character (KTD5).
struct KeyRecorderView: NSViewRepresentable {
    /// The trigger token to display (the binding's current trigger).
    let token: String
    /// Called with a freshly captured canonical token.
    let onCapture: (String) -> Void
    /// Called with a soft warning (e.g. "add a modifier") or nil to clear it.
    var onWarning: (String?) -> Void = { _ in }

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onToken = onCapture
        view.onWarning = onWarning
        view.displayToken = token
        return view
    }

    func updateNSView(_ view: KeyRecorderNSView, context: Context) {
        view.onToken = onCapture
        view.onWarning = onWarning
        view.displayToken = token
        view.needsDisplay = true
    }
}

/// The AppKit control behind `KeyRecorderView`. Owns a local `NSEvent` monitor so
/// it sees menu key-equivalents (⌘Q/⌘W) *before* the menu does and swallows them
/// (KTD6), and resolves character keys against the live keyboard layout so
/// non-US layouts bind correctly (KTD5).
final class KeyRecorderNSView: NSView {
    var onToken: ((String) -> Void)?
    var onWarning: ((String?) -> Void)?
    var displayToken: String = "" {
        didSet {
            guard oldValue != displayToken else { return }
            needsDisplay = true
            updateAccessibilityValue()
            updateToolTip()
        }
    }

    /// Held **strongly**: a weak token deallocates the moment install returns,
    /// orphaning the app-wide `.keyDown` handler so it swallows every keystroke for
    /// the rest of the session (the bug `KeyboardShortcuts`/`MASShortcut` avoid by
    /// retaining it). Torn down on resign / window removal.
    private var monitor: Any?
    private var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            needsDisplay = true
            // The focus ring is suppressed while recording (the accent border stands in),
            // so re-note the mask when recording toggles.
            noteFocusRingMaskChanged()
            updateAccessibilityValue()
            // MO-7: cross-fade the capsule's border/fill on the recording toggle (~120ms,
            // gated by Reduce Motion).
            applyChrome(animated: true)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Pointer hover, from an `NSTrackingArea` — tints the idle capsule so it reads as
    /// clickable (the SwiftUI hover parity the surrounding rows have).
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering, !isRecording else { return }
            applyChrome(animated: true)
        }
    }
    private var trackingArea: NSTrackingArea?

    /// Tints mirroring the U2 design tokens (DS-14): `subtleFill`/`hoverLift`/`accentFill`
    /// expressed in AppKit so the recorder no longer hand-picks divergent alphas.
    private enum Tint {
        static let recordingFill = NSColor.controlAccentColor.withAlphaComponent(0.15)   // ~accentFill
        static let hoverFill = NSColor.controlAccentColor.withAlphaComponent(0.06)        // ~hoverLift
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A real keyboard-focus ring (A11Y-9): focus no longer auto-starts recording, so
        // the focused-but-idle state needs its own visible affordance.
        focusRingType = .exterior
        // Layer-backed so the border/fill can cross-fade on the recording toggle (MO-7)
        // rather than snapping; the text/pencil/chip still draw in `draw(_:)`.
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.standard
        layer?.borderWidth = 1
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut recorder")
        updateAccessibilityValue()
        updateToolTip()
        applyChrome(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Chrome (border + fill on the layer, so it can fade)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colors are resolved CGColors — re-resolve them for the new appearance.
        applyChrome(animated: false)
    }

    /// Set the capsule's border and fill for the current state. Recording draws an accent
    /// border + fill; a hovered idle capsule gets a faint accent tint; otherwise it's a
    /// plain control-background field. The recording transition cross-fades (~120ms) unless
    /// Reduce Motion is on (MO-7).
    private func applyChrome(animated: Bool) {
        guard let layer else { return }
        // Resolve the dynamic system colors against *this view's* appearance so dark mode
        // and the system accent are honored on the layer's plain CGColors.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: CGColor
            let border: CGColor
            let borderW: CGFloat
            if isRecording {
                fill = Tint.recordingFill.cgColor
                border = NSColor.controlAccentColor.cgColor
                borderW = 2
            } else {
                fill = (isHovering ? Tint.hoverFill : NSColor.controlBackgroundColor).cgColor
                border = NSColor.separatorColor.cgColor
                borderW = 1
            }
            let duration = (animated && !reduceMotion) ? 0.12 : 0
            if duration > 0 {
                animateLayer("backgroundColor", from: layer.backgroundColor, to: fill, duration: duration)
                animateLayer("borderColor", from: layer.borderColor, to: border, duration: duration)
                animateLayer("borderWidth", from: layer.borderWidth, to: borderW, duration: duration)
            }
            layer.backgroundColor = fill
            layer.borderColor = border
            layer.borderWidth = borderW
        }
        needsDisplay = true
    }

    private func animateLayer(_ keyPath: String, from: Any?, to: Any, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        layer?.add(animation, forKey: keyPath)
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// A tooltip that names a physical hardware key, or invites a click on a bound chord.
    private func updateToolTip() {
        if KeybindTrigger.isPhysicalNamedKey(displayToken) {
            toolTip = "Physical \(KeybindTrigger.displaySymbol(for: displayToken).capitalized) key — click to change"
        } else if displayToken.isEmpty {
            toolTip = "Click or press Return to record a shortcut"
        } else {
            toolTip = "Click to change this shortcut"
        }
    }

    /// Expose the current shortcut (or the recording state) to VoiceOver, which
    /// otherwise reads only the static label.
    private func updateAccessibilityValue() {
        if isRecording {
            setAccessibilityValue("Recording — press the shortcut. Delete to clear, Escape to cancel.")
        } else if displayToken.isEmpty {
            setAccessibilityValue("No shortcut. Press Return to record.")
        } else {
            setAccessibilityValue(KeybindTrigger.displaySymbol(for: displayToken))
        }
    }

    // MARK: - Focus ring (A11Y-9: focus is a state distinct from recording)

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        // Recording draws its own accent border, so only ring the focused-idle state.
        guard !isRecording else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: DesignTokens.Radius.standard, yRadius: DesignTokens.Radius.standard).fill()
    }

    // MARK: - Focus / lifecycle

    override func mouseDown(with event: NSEvent) {
        // A click both focuses and starts recording (the discoverable, pointer-first path)
        // — but only if focus was actually granted. Recording on a *failed* makeFirstResponder
        // would install the app-wide key monitor on a non-first-responder view that never gets
        // `resignFirstResponder`, stranding it (a runaway capture + keystroke swallow). This
        // keeps "monitor installed" ⇒ "is first responder" (review F #1).
        if window?.makeFirstResponder(self) == true { startRecording() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Focus only — recording begins on a click or on Return/Space (see keyDown), so
        // Tab-traversing the ~140-row list no longer hijacks the keyboard per row (A11Y-9).
        if became { needsDisplay = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    /// While focused but idle, Return/Space begins recording; every other key passes
    /// through so keyboard focus can keep traversing the list (A11Y-9). While recording,
    /// the local monitor handles keys, so this rarely fires.
    override func keyDown(with event: NSEvent) {
        guard !isRecording else { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            startRecording()
        default:
            super.keyDown(with: event)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Leaving the window (sheet dismissed, view torn down) must remove the
        // monitor — otherwise it lingers and swallows keystrokes app-wide.
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func startRecording() {
        guard monitor == nil else { return }
        onWarning?(nil)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    /// Speak a transient message to VoiceOver from this (focused) element — used for the
    /// soft capture warning, which otherwise only updates a sibling visual Label (A11Y).
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.high.rawValue),
            ])
    }

    // MARK: - Capture

    /// Process a key-down while recording. Returns nil to swallow the event (so no
    /// menu fires and there's no beep) or the event to let the system handle it
    /// (Tab focus traversal). Runs synchronously on the main thread; only Sendable
    /// value types are extracted from the `NSEvent` (KTD1, Swift 6).
    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)
        let hasRealModifier = hasCommand || hasControl || hasOption
        let keyCode = event.keyCode

        // Bare navigation keys keep their conventional editing meaning.
        if !hasRealModifier {
            switch Int(keyCode) {
            case kVK_Escape:
                window?.makeFirstResponder(nil) // cancel
                return nil
            case kVK_Delete, kVK_ForwardDelete:
                onWarning?(nil)
                onToken?("") // clear the trigger
                return nil
            case kVK_Tab:
                return event // let focus move to the next field
            default:
                break
            }
        }

        let named = KeybindTrigger.namedKey(forKeyCode: keyCode)

        // A character key with no ⌘/⌃/⌥ fires on ordinary typing — reject and keep
        // recording. (Bare named keys like F5 / arrows are allowed.)
        if !hasRealModifier, named == nil {
            let message = "Add ⌘, ⌃, or ⌥ — that key alone would fire while you type."
            onWarning?(message)
            // The warning is a sibling Label in the row, outside the recorder's focused
            // element, so a VoiceOver user gets no feedback on why capture was rejected —
            // announce it from the focused recorder (A11Y).
            announce(message)
            return nil
        }

        // Character keys resolve against the live layout (KTD5); named keys are
        // named by the kit from their position-stable keyCode.
        let resolved = named == nil ? Self.unshiftedCharacter(forKeyCode: keyCode) : nil
        let captured = CapturedKey(keyCode: keyCode, modifierFlags: event.modifierFlags.rawValue, resolvedCharacter: resolved)
        guard let token = KeybindTrigger.token(from: captured) else {
            return nil // unmappable (e.g. a dead key) — keep listening
        }

        onWarning?(nil)
        onToken?(token)
        window?.makeFirstResponder(nil) // chord captured; stop recording
        return nil
    }

    /// The unshifted, layout-correct character a key produces in the *current*
    /// keyboard layout (so `[` on US, `ü` on QWERTZ), via Carbon `UCKeyTranslate`
    /// — the same approach `MASShortcut`/`KeyboardShortcuts` use, which a
    /// deliberately NSEvent-free kit can't replicate (KTD5).
    static func unshiftedCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0, // no modifier bits → the unshifted base character
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let character = String(utf16CodeUnits: chars, count: length)
        // Ignore control characters / whitespace that aren't real bindable glyphs.
        return character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : character
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The border/fill live on the layer now (so they can cross-fade, MO-7); `draw`
        // renders only the text, the recording hint, and the bound-state pencil.
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let physical = KeybindTrigger.isPhysicalNamedKey(displayToken)
        // The stored token is Ghostty's raw `super+…` spelling; show the macOS glyphs.
        let shown = KeybindTrigger.displaySymbol(for: displayToken)
        let text: String
        let color: NSColor
        let font: NSFont
        if isRecording {
            text = displayToken.isEmpty ? "Press the keys…" : "Press the keys…  (\(shown))"
            color = .secondaryLabelColor
            font = .systemFont(ofSize: NSFont.systemFontSize)
        } else if displayToken.isEmpty {
            // Names both affordances now that focus and recording are decoupled (A11Y-9).
            text = "Click or press ⏎ to record"
            color = .secondaryLabelColor   // was tertiary — strict contrast (H3)
            font = .systemFont(ofSize: NSFont.systemFontSize)
        } else if physical {
            // A physical hardware key (Copy/Paste): mono small-caps chip so a lone word
            // doesn't read as prose beside the ⌘⌃⌥⇧ glyph chords (KB-3/CB-6).
            text = shown.uppercased()
            color = .labelColor
            font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        } else {
            text = shown
            // System font (not monospaced): the macOS shortcut glyphs (⌘⇧⌥⌃) render with
            // correct spacing here — monospaced cells cram them together.
            color = .labelColor
            font = .systemFont(ofSize: NSFont.systemFontSize)
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        // While recording, lift the main line to make room for the hint beneath it;
        // otherwise center it vertically (isFlipped, so y grows downward from the top).
        let mainY = isRecording ? bounds.minY + 3 : bounds.midY - size.height / 2
        attributed.draw(at: NSPoint(x: bounds.minX + 10, y: mainY))

        if isRecording {
            let hint = NSAttributedString(string: "⌫ clear · esc cancel", attributes: [
                // `smallSystemFontSize` (~11pt) instead of a hardcoded 9pt — it tracks the
                // system control-size setting, the closest AppKit gets to Dynamic Type here
                // (H3, review nit #4). Contrast raised from tertiary to secondary.
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            hint.draw(at: NSPoint(x: bounds.minX + 10, y: bounds.minY + 3 + size.height))
        } else if !displayToken.isEmpty {
            drawEditAffordance(in: bounds)
        }
    }

    /// A dimmed pencil at the trailing edge (KB-6): a *persistent* signal the bound capsule
    /// is clickable to re-record, brightening slightly on hover — no need to hover to learn
    /// it's editable.
    private func drawEditAffordance(in bounds: NSRect) {
        let side: CGFloat = 12
        let rect = NSRect(x: bounds.maxX - side - 6, y: bounds.midY - side / 2, width: side, height: side)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        guard let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let alpha: CGFloat = isHovering ? 0.85 : 0.45
        // Tint the template symbol to a secondary label color, then draw at reduced opacity.
        let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
            pencil.draw(in: drawRect)
            NSColor.secondaryLabelColor.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }
}
