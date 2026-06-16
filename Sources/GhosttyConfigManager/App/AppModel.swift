import Foundation
import Observation
import GhosttyConfigKit

/// Root application state (KTD9: `@Observable`, macOS 14+).
///
/// Owns the discovered Ghostty environment and the high-level load state the
/// SwiftUI shell renders. Later units extend this with the catalog, the parsed
/// config, and the merged view.
@MainActor
@Observable
public final class AppModel {

    /// Where the app is in the bootstrap lifecycle.
    public enum EnvironmentState {
        case loading
        case ready(GhosttyEnvironment)
        /// No `ghostty` binary could be located (R19).
        case notFound
        /// The binary was found but could not be verified (R19).
        case unsupported(String)
    }

    public private(set) var environmentState: EnvironmentState = .loading

    /// An optional user-configured path to the `ghostty` binary, tried first.
    public var binaryOverride: String?

    public init() {}

    /// Locate and verify Ghostty, updating `environmentState`. Designed to be
    /// called from `.task` on first appearance; failures become explicit states
    /// rather than crashes.
    public func bootstrap() async {
        environmentState = .loading
        do {
            let environment = try await GhosttyEnvironment.discover(userOverride: binaryOverride)
            environmentState = .ready(environment)
        } catch GhosttyCLIError.binaryNotFound {
            environmentState = .notFound
        } catch GhosttyCLIError.versionUnverified(let output) {
            environmentState = .unsupported(output.isEmpty ? "unknown" : output)
        } catch {
            environmentState = .unsupported(error.localizedDescription)
        }
    }
}
