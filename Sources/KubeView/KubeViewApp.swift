import SwiftUI
import KubeViewKit

/// Deliberately empty. All app logic lives in `KubeViewKit` so test targets can
/// import it - a test target cannot reliably import an executable target, and
/// the assertions worth having live in app code.
@main
struct KubeViewApp: App {
    var body: some Scene { KubeViewScenes() }
}
