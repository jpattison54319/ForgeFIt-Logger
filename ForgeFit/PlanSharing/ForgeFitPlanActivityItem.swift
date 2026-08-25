import UIKit
import UniformTypeIdentifiers

enum ForgeFitPlanFileType {
    static let identifier = "org.xpetsllc.ForgeFit.plan"
    static let filenameExtension = "forgefitplan"
    static let mimeType = "application/vnd.xpetsllc.forgefit-plan"
    /// Conforming to .data (opaque data) ensures iOS LaunchServices and QuickLook
    /// route taps directly to ForgeFit rather than opening an inline JSON text preview
    /// in Messages or Files.
    static let contentType = UTType(exportedAs: identifier, conformingTo: .data)
}

/// Keeps the proprietary plan type attached as the file crosses Messages,
/// Mail, AirDrop, or Files instead of letting a service flatten it to JSON.
final class ForgeFitPlanActivityItem: NSObject, UIActivityItemSource {
    let fileURL: URL
    let contentTypeIdentifier = ForgeFitPlanFileType.identifier

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func itemProvider() -> NSItemProvider {
        NSItemProvider(
            contentsOf: fileURL,
            contentType: ForgeFitPlanFileType.contentType,
            openInPlace: false,
            coordinated: false,
            visibility: .all
        )
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        contentTypeIdentifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}
