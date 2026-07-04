import SwiftUI
import AppKit

/// U11 (MO-1, TH-6): "one click to close, one to act."
///
/// A SwiftUI `.popover` on macOS is a `.transient` `NSPopover`. When you click a control
/// *outside* the open popover, AppKit consumes that click to dismiss the popover — so the
/// control you were reaching for (a sidebar row after the font picker, say) needs a
/// *second* click. That reads as the app swallowing your input.
///
/// This installs a popover-scoped local mouse-down monitor **while the popover is open**:
/// a mouse-down landing in the app's own window (the popover lives in its own
/// `_NSPopoverWindow`, so any other window is "outside") closes the popover and — the
/// point — **returns the event unchanged** so it still hit-tests the control beneath.
/// Swallowing it (`return nil`) would defeat the whole fix.
///
/// Disciplined like `KeyRecorderNSView`'s monitor: installed only while presented, torn
/// down on dismissal *and* on disappear, and it only ever closes *its own* popover — it
/// never inspects or perturbs another `isPresented` binding or the U12 hover state.
///
/// This is the documented recipe for the ~11 popover sites; it's applied where the
/// two-click cost actually bites (the info popover and the font picker), not blanket.
private struct PopoverPassthroughDismiss: ViewModifier {
    @Binding var isPresented: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, open in
                if open { install() } else { remove() }
            }
            // A row can scroll away (or the whole view be torn down) while the popover is
            // open — never leak the monitor.
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        // At the moment the popover opens, the app window is still key/main; capture it as
        // a weak local so we can tell an outside click (this window) from a click inside
        // the popover (its own `_NSPopoverWindow`) without retaining the window.
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak host] event in
            if let host, event.window === host {
                // Outside the popover → close it, then let the click through so it acts on
                // the control underneath in the same gesture (MO-1). Flipping the binding
                // fires `.onChange` → `remove()`, so the monitor tears itself down.
                isPresented = false
            }
            return event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Make a `.popover(isPresented:)` dismiss *and pass the closing click through* to the
    /// control underneath, so it takes one click instead of two (U11 / MO-1). Attach to
    /// the same view that carries the `.popover`, bound to the same flag.
    func passthroughPopoverDismiss(isPresented: Binding<Bool>) -> some View {
        modifier(PopoverPassthroughDismiss(isPresented: isPresented))
    }
}
