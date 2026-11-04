import SwiftUI
import UIKit

/// System share sheet for a file that was generated on demand (list swipe action,
/// "Export CSV first" in the delete dialog).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
