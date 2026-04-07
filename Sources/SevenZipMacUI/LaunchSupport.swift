import AppKit
import Foundation

@MainActor
enum AppTerminationCoordinator {
    private static var bypassPrompt = false

    static func shouldBypassPrompt() -> Bool {
        bypassPrompt
    }

    static func consumeBypassPrompt() {
        bypassPrompt = false
    }

    static func confirmTerminationIfNeeded() -> Bool {
        guard SevenZipRunner.hasActiveProcesses() else { return true }

        let alert = NSAlert()
        alert.messageText = "当前仍有任务在执行"
        alert.informativeText = "压缩/解压任务尚未完成。确定要退出吗？退出后会终止后台的 7zz 进程。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定退出")
        alert.addButton(withTitle: "继续运行")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        bypassPrompt = true
        SevenZipRunner.terminateAllProcesses()
        return true
    }
}


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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppTerminationCoordinator.shouldBypassPrompt() {
            AppTerminationCoordinator.consumeBypassPrompt()
            return .terminateNow
        }
        return AppTerminationCoordinator.confirmTerminationIfNeeded() ? .terminateNow : .terminateCancel
    }

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
