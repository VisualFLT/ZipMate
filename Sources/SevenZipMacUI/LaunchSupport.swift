import AppKit
import Foundation

extension Notification.Name {
    static let sevenZipOpenArchiveURLs = Notification.Name("ZipMate.openArchiveURLs")
    static let sevenZipQuickExtractURLs = Notification.Name("ZipMate.quickExtractURLs")
}

enum LaunchCommand: Equatable {
    case none
    case openArchives([URL])
    case quickExtract([URL])
}

enum LaunchCommandParser {
    static func parse(arguments: [String]) -> LaunchCommand {
        guard arguments.count > 1 else { return .none }

        let raw = Array(arguments.dropFirst())
        if let quickExtractIndex = raw.firstIndex(of: "--quick-extract") {
            let urls = raw[(quickExtractIndex + 1)...]
                .filter { !$0.hasPrefix("--") }
                .map { URL(fileURLWithPath: $0) }
            return urls.isEmpty ? .none : .quickExtract(urls)
        }

        let archiveURLs = raw
            .filter { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0) }
            .filter { !$0.path.isEmpty }
        return archiveURLs.isEmpty ? .none : .openArchives(archiveURLs)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .sevenZipOpenArchiveURLs, object: urls)
    }

    @MainActor @objc func extractSelectedArchives(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard
            let items = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !items.isEmpty
        else {
            error.pointee = "No archive files were received." as NSString
            return
        }

        let archiveURLs = items.filter(\.isFileURL)
        guard !archiveURLs.isEmpty else {
            error.pointee = "No valid archive files were received." as NSString
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .sevenZipQuickExtractURLs, object: archiveURLs)
    }
}
