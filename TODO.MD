# TODO

## A · Bugs / correctness
- [x] And I'm not sure in the KeyboardConfig item why there is a backslash on each key. → Fixed: it was the pencil edit-affordance icon rendering as a stray "\"; removed it (KeyRecorderView).
- [x] Keyboard shortcut "Go to tab N" showed a raw ⌘digit_N capsule next to ⌘N (Ghostty ships both). → Fixed: merged the physical+character pair into one clean ⌘N capsule for the default AND disabled states; edits/turn-off/re-enable manage both underlying lines.
- [x] I also want to take a look at the behavior when we set the wrong value for the config item. The last thing I try is when I try to set a wrong color code. The error still appears even if I cancel it. Not only the color code, I need you to check for other config items as well that have the possibility for the user to enter invalid or wrong values. → Fixed: the rejected-apply error is a global `applyState` that never auto-collapses (only `.succeeded` does); cancelling an editor reset only its local transaction, stranding the red error on the row. Added `AppModel.dismissApplyFailure(forOptionNamed:)` (scoped to the failing option so it never wipes a `.succeeded` or another option's error) and call it from every abandon path: the color / long-value / scroll-multiplier / path popovers on Cancel+dismiss, and the inline free-text field on blur-to-saved. (Note: malformed `#hex` is already caught by the local gate and cleared by Cancel; this covers the genuine Ghostty-rejected case like `cursor-color = notacolor`.) Covered by live-Ghostty tests (`ApplyFailureDismissalTests`).
- [x] Emptying the config file entirely (removing the last remaining line) makes `ghostty +validate-config` exit 1 with no stderr, so the editor shows an unhelpful "The change didn't validate." Detect the would-be-empty write and show a clear message (or guard against writing a zero-byte config). → Fixed: probing confirmed Ghostty rejects *only* a truly zero-byte config (whitespace/comment-only files validate fine), so the writer now refuses a would-be-empty write up front with `ConfigWriteError.emptyConfig` → "A config file can't be empty. Reset options to defaults instead of clearing the file." The guard (`serialized().isEmpty`) runs before validation in every write entry point (apply / validateAndApply / batch / import) so the binary is never asked and the clear message wins, plus a `performCommit` backstop so no zero-byte file can reach disk from any path. Covered by hermetic `ConfigWriterTests` (incl. negative comment-only/`"\n"` cases that must still persist) and live end-to-end `EmptyConfigGuardEndToEndTests` (real AppModel: unset-last-option + import-empty surface the clear message, config byte-intact).

## B · Search
- [] cmd+f for search in each menu, cmd+shift+f for global search
- [] I think when we move to the other menu in the sidebar, we should reset or clear the search field in its section, not the global search field.

## C · Themes + shared horizontal-tabs pattern
- [] In the theme section, I think previewing on hover is a bit disturbing.

## D · Keyboard Shortcut screen
- [] Also, in the keyboard shortcut screen, I'm thinking of adding horizontal tabs that filter out by the group, similar to what we implemented in the themes, so the design looks consistent.
- [] In the keyboard shortcut screen, I think we should allow the user to also search by pressing the keys directly, not just typing it.

## E · Appearance ▸ Advanced
- [] The Advanced section header, I think, needs to be more prominent. I hardly see that there is an Advanced section that collapses some config item.
- [] Go to Appearance and look at the Advanced section and look for the custom shader animation config item. I think we need to handle the long text there. You can also go to Appearance and use the search bar to search for custom shader animation and take a look at the long tag that is displayed almost vertically because there is no space. We need to find a way to better render it.

## F · Modified / Save / Reload UX
- [] Need a better design or indicator for the customized config item other than a yellow dot or yellow circle.
- [] Need to redesign the tools after changing or saving a config item to be much more simple and intuitive. At least I think we do not need to display the copy of the ghostty to reload config.
- [] Put auto reload settings in the recommended section.

## G · Status redesign
- [] The status side bar at the bottom, I think, needs to be redesigned in a way that is indicating a status. Currently, it fails to plan.
- [] Also, I think we need to fully redesign the status screen currently. It feels too long and contains too many sections, so we need to re-layout it as well, maybe by adding a horizontal filter at the top or grouping some similar items and something like that. The goal of redesigning and re-layouting is also to make sure that the important information is more visible and easier to access.
