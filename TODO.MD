# TODO

## A · Bugs / correctness
- [] And I'm not sure in the KeyboardConfig item why there is a backslash on each key.
- [] I also want to take a look at the behavior when we set the wrong value for the config item. The last thing I try is when I try to set a wrong color code. The error still appears even if I cancel it. Not only the color code, I need you to check for other config items as well that have the possibility for the user to enter invalid or wrong values.

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
