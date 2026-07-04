import Foundation

/// The one canonical place the app's name and tagline live, so every user-facing
/// surface reads the same thing (U4/CM-2 — the app previously called itself three
/// different names). The menu-bar title comes from the bundle's `CFBundleName`
/// (set in `scripts/package-app.sh`); these back the in-code strings.
enum AppInfo {
    /// The product name shown in the window title, Help menu, and Welcome header.
    static let productName = "Ghostty Config Editor"

    /// The tagline paired with the name in identity moments and the README — it
    /// respects the Ghostty trademark and sets third-party expectations (U4).
    static let subtitle = "An unofficial config editor for Ghostty"

    /// "Welcome to <product>", shared by the Welcome header and its Help menu item.
    static let welcomeTitle = "Welcome to \(productName)"
}
