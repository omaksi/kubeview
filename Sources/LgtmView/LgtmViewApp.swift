import SwiftUI
import LgtmViewKit

/// Deliberately empty. All app logic lives in `LgtmViewKit` so test targets can
/// import it - a test target cannot reliably import an executable target, and
/// the assertions worth having (medians, ratios, node levels, Kahn tiering)
/// live in kit code.
@main
struct LgtmViewApp: App {
    var body: some Scene { LgtmViewScenes() }
}
