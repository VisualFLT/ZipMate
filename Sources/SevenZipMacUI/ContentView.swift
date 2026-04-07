import AppKit
import Foundation
import SwiftUI

private func stageItemForCompression(from source: URL, to target: URL, fileManager fm: FileManager) throws {
    let attributes = try fm.attributesOfItem(atPath: source.path)
    let itemType = attributes[.type] as? FileAttributeType

    if itemType == .typeSymbolicLink {
        let destination = try fm.destinationOfSymbolicLink(atPath: source.path)
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        return
    }

    var isDir: ObjCBool = false
    if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            let childTarget = target.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            try stageItemForCompression(from: child, to: childTarget, fileManager: fm)
        }
        return
    }

    do {
        try fm.linkItem(at: source, to: target)
    } catch {
        try fm.copyItem(at: source, to: target)
    }
}

struct HoverTrackingArea: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void
    let onMouseMoved: (CGPoint) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChanged = onHoverChanged
        view.onMouseMoved = onMouseMoved
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onMouseMoved = onMouseMoved
    }

    final class TrackingView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        var onMouseMoved: ((CGPoint) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaRef = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
            reportLocation(event)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseMoved(with event: NSEvent) {
            // Keep the popup anchored at the entry point instead of chasing the cursor.
        }

        private func reportLocation(_ event: NSEvent) {
            onMouseMoved?(convert(event.locationInWindow, from: nil))
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans
    case enUS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zhHans: return "中文"
        case .enUS: return "English"
        }
    }
}

enum CreateArchiveType: String, CaseIterable, Identifiable {
    case sevenZip = "7z"
    case zip = "zip"

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .sevenZip:
            return "7z"
        case .zip:
            return "ZIP"
        }
    }

    var compressionArguments: [String] {
        switch self {
        case .sevenZip:
            // Keep a reasonable ratio, but bias toward speed.
            return ["-mx=3"]
        case .zip:
            // Keep ZIP reasonably fast, while restoring a useful compression ratio.
            return ["-tzip", "-mm=Deflate", "-mx=3"]
        }
    }

    static func fromArchivePath(_ path: String) -> CreateArchiveType? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "7z":
            return .sevenZip
        case "zip":
            return .zip
        default:
            return nil
        }
    }
}

enum ExtractConflictPolicy {
    case askUser
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sevenZipPath: String = "/opt/homebrew/bin/7zz"
    @Published var language: AppLanguage = .zhHans
    @Published var preferBundledBinary: Bool = true
    @Published var archiveURL: URL?
    @Published var extractDestinationURL: URL?
    @Published var currentFolder: String = ""
    @Published var searchText: String = "" {
        didSet { refreshVisibleRows() }
    }
    @Published private(set) var loadedEntries: [ArchiveEntry] = [] {
        didSet { refreshVisibleRows() }
    }
    @Published var selectedPaths: Set<String> = []
    @Published var isRunning: Bool = false
    @Published var extractProgress: Double? = nil
    @Published var showLogs: Bool = false
    @Published var status: String = "请选择压缩包开始。"
    @Published var logs: String = ""
    @Published private(set) var visibleRows: [BrowserRow] = []
    @Published private(set) var totalFileCount: Int = 0
    @Published private(set) var totalFolderCount: Int = 0
    @Published var rememberedExtractConflictOverwrite: Bool? = nil
    @Published var suggestedAssociationOptions: Set<ArchiveAssociationOption> = [
        .zip,
        .sevenZip,
        .rar,
        .tar,
        .gz,
        .bz2,
        .xz,
        .tgz,
        .tbz2,
        .txz
    ]
    private var folderEntryCache: [String: [ArchiveEntry]] = [:]
    private var processedLaunchCommand: LaunchCommand = .none
    private static let progressRegex = try! NSRegularExpression(pattern: #"(\d{1,3})%"#)

    func tr(_ zhHans: String, _ enUS: String) -> String {
        language == .zhHans ? zhHans : enUS
    }

    var breadcrumb: [String] {
        let folder = ArchiveListParser.normalizeFolder(currentFolder)
        if folder.isEmpty {
            return []
        }
        return folder.split(separator: "/").map(String.init)
    }

    var selectedCount: Int {
        selectedPaths.count
    }

    var canExtractAll: Bool {
        !isRunning && archiveURL != nil && !loadedEntries.isEmpty
    }

    var canExtractSelected: Bool {
        !isRunning && archiveURL != nil && !selectedPaths.isEmpty
    }

    func browseSevenZipBinary() {
        let panel = NSOpenPanel()
        panel.title = tr("选择 7zz 可执行文件", "Select 7zz binary")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sevenZipPath = url.path
        }
    }

    func browseArchive() {
        let panel = NSOpenPanel()
        panel.title = tr("打开压缩包", "Open archive")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            archiveURL = url
            if extractDestinationURL == nil {
                extractDestinationURL = url.deletingPathExtension()
            }
            loadArchive()
        }
    }

    func applyFileAssociations(_ options: Set<ArchiveAssociationOption>) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            status = tr("当前运行方式不支持设置文件关联。", "The current run mode does not support file association.")
            return
        }

        let selected = ArchiveAssociationOption.allCases.filter { options.contains($0) }
        guard !selected.isEmpty else {
            status = tr("未选择任何后缀名关联。", "No file associations were selected.")
            FileAssociationManager.markFirstLaunchPromptShown()
            return
        }

        let results = FileAssociationManager.setDefaultHandler(options: selected, bundleIdentifier: bundleIdentifier)
        let failed = results.filter { $0.value != noErr }.map(\.key)
        let selectedNames = selected.map { $0.fileExtension }.joined(separator: ", ")
        let failedNames = failed.map { $0.fileExtension }.joined(separator: ", ")

        if failed.isEmpty {
            status = tr("已设置默认打开后缀：\(selectedNames)", "Associated file types: \(selectedNames)")
        } else {
            status = tr("部分后缀关联失败：\(failedNames)", "Some associations failed: \(failedNames)")
        }

        FileAssociationManager.markFirstLaunchPromptShown()
    }

    func openArchive(url: URL) {
        archiveURL = url
        if extractDestinationURL == nil || extractDestinationURL?.deletingLastPathComponent() != url.deletingLastPathComponent() {
            extractDestinationURL = url.deletingPathExtension()
        }
        loadArchive()
    }

    func handleLaunchCommand(_ command: LaunchCommand) {
        guard processedLaunchCommand != command else { return }
        processedLaunchCommand = command

        switch command {
        case .none:
            return
        case .openArchives(let urls):
            guard let first = urls.first else { return }
            openArchive(url: first)
        case .quickExtract(let urls):
            quickExtractArchives(urls)
        }
    }

    func chooseFolder(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = tr("选择目录", "Choose directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseDestinationDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = tr("选择解压目标目录", "Choose extract destination")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let extractDestinationURL {
            panel.directoryURL = extractDestinationURL
        } else if let archiveURL {
            panel.directoryURL = archiveURL.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        extractDestinationURL = url
        return url
    }

    func loadArchive(preserveCurrentFolder: Bool = false) {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            status = tr("压缩包不存在。", "Archive file does not exist.")
            return
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return
        }

        let requestedFolder = preserveCurrentFolder ? ArchiveListParser.normalizeFolder(currentFolder) : ""
        Task {
            await loadFolderContents(
                folder: requestedFolder,
                resetCache: true,
                loadingStatus: requestedFolder.isEmpty
                    ? tr("正在读取压缩包索引...", "Reading archive index...")
                    : tr("正在读取当前目录...", "Reading current folder...")
            )
        }
    }

    func navigateToRoot() {
        showFolder("")
    }

    func navigateUp() {
        let parts = breadcrumb
        guard !parts.isEmpty else { return }
        showFolder(parts.dropLast().joined(separator: "/"))
    }

    func navigateToBreadcrumb(index: Int) {
        let parts = breadcrumb
        guard index >= 0 && index < parts.count else { return }
        showFolder(parts[0...index].joined(separator: "/"))
    }

    func openRow(_ row: BrowserRow) {
        guard row.isDirectory else { return }
        showFolder(row.fullPath)
    }

    func extractAll() {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }
        runExtract(includePaths: [], destination: archiveURL.deletingLastPathComponent())
    }

    func extractSelected() {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }
        let snapshot = Array(selectedPaths).sorted()
        guard !snapshot.isEmpty else {
            status = tr("请先选中要解压的条目。", "Please select items to extract first.")
            return
        }
        runExtract(includePaths: snapshot, destination: archiveURL.deletingLastPathComponent())
    }

    func extractAllToOtherDirectory() {
        guard let url = chooseDestinationDirectory() else { return }
        runExtract(includePaths: [], destination: url)
    }

    func extractSelectedToOtherDirectory() {
        let snapshot = Array(selectedPaths).sorted()
        guard !snapshot.isEmpty else {
            status = tr("请先选中要解压的条目。", "Please select items to extract first.")
            return
        }
        guard let url = chooseDestinationDirectory() else { return }
        runExtract(includePaths: snapshot, destination: url)
    }

    func deleteSelected() {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }

        let snapshot = Array(selectedPaths).sorted()
        guard !snapshot.isEmpty else {
            status = tr("请先选中要删除的条目。", "Please select items to delete first.")
            return
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return
        }

        Task {
            isRunning = true
            extractProgress = nil
            status = tr("正在删除选中项...", "Deleting selected items...")
            DebugLogger.log("deleteSelected() begin count=\(snapshot.count)")

            var args = ["d", archiveURL.path, "-bb0", "-bso0", "-bsp0", "-bse0", "-y"]
            args.append(contentsOf: snapshot)
            let exitCode = await SevenZipRunner.runSilent(
                executablePath: bin,
                arguments: args
            )
            DebugLogger.log("deleteSelected() exit=\(exitCode)")

            if exitCode == 0 {
                selectedPaths.removeAll()
                status = tr("已删除选中项。", "Selected items deleted.")
                loadArchive(preserveCurrentFolder: true)
            } else {
                status = tr("删除失败（退出码 \(exitCode)）。", "Delete failed (exit \(exitCode)).")
                isRunning = false
            }
        }
    }

    func clearLogs() {
        logs = ""
    }

    func extractByDrag(includePath: String, destination: URL, completion: @escaping (Error?) -> Void) {
        guard let archiveURL else {
            completion(NSError(domain: "SevenZipMacUI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Archive is not selected"]))
            return
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            completion(NSError(domain: "SevenZipMacUI", code: -2, userInfo: [NSLocalizedDescriptionKey: "7zz not found"]))
            return
        }

        Task {
            DebugLogger.log("dragExtract() begin includePath=\(includePath) destination=\(destination.path)")
            let result = await extractFlattenedSelection(
                executablePath: bin,
                archivePath: archiveURL.path,
                includePaths: [includePath],
                destination: destination,
                conflictPolicy: .askUser
            )
            DebugLogger.log("dragExtract() finished includePath=\(includePath) result=\(result)")
            switch result {
            case .success:
                completion(nil)
            case .failure(let err):
                completion(err)
            }
        }
    }

    func importByDrag(sourceURLs: [URL]) -> Bool {
        guard !sourceURLs.isEmpty else { return false }
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return false
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            return false
        }

        let folder = ArchiveListParser.normalizeFolder(currentFolder)
        let dropped = sourceURLs.filter { $0.isFileURL }
        guard !dropped.isEmpty else { return false }

        Task {
            isRunning = true
            extractProgress = nil
            status = tr("正在准备拖入文件...", "Preparing dropped files...")
            DebugLogger.log("importByDrag() begin currentFolder=\(folder) count=\(dropped.count)")

            let result = await addDroppedItems(
                executablePath: bin,
                archivePath: archiveURL.path,
                sourceURLs: dropped,
                destinationFolder: folder,
                onProgress: { progress in
                    self.extractProgress = progress
                }
            )

            switch result {
            case .success:
                status = tr("已添加拖入文件。", "Dropped files added.")
                DebugLogger.log("importByDrag() success")
                loadArchive(preserveCurrentFolder: true)
            case .failure(let error):
                status = tr("添加到压缩包失败。", "Failed to add files to archive.")
                DebugLogger.log("importByDrag() failed error=\(error.localizedDescription)")
            }

            isRunning = false
            extractProgress = nil
        }

        return true
    }

    func createArchive(
        directoryURL: URL,
        name: String,
        type: CreateArchiveType
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            status = tr("请输入压缩包名称。", "Please enter an archive name.")
            return false
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return false
        }

        Task {
            isRunning = true
            extractProgress = nil
            status = tr("正在创建压缩包...", "Creating archive...")
            let result = await createEmptyArchive(
                executablePath: bin,
                directoryURL: directoryURL,
                name: trimmedName,
                type: type
            )

            switch result {
            case .success(let archiveURL):
                self.archiveURL = archiveURL
                self.extractDestinationURL = archiveURL.deletingPathExtension()
                self.status = tr("压缩包已创建。", "Archive created.")
                self.loadArchive()
            case .failure(let error):
                self.status = tr("创建压缩包失败。", "Failed to create archive.")
                DebugLogger.log("createArchive() failed error=\(error.localizedDescription)")
                self.isRunning = false
            }
        }

        return true
    }

    func choosePackSources(startingAt url: URL?) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = tr("选择要打包的文件或文件夹", "Choose files or folders to pack")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = url
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func createArchiveFromSources(
        sourceURLs: [URL],
        outputDirectoryURL: URL,
        name: String,
        type: CreateArchiveType
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceURLs.isEmpty else {
            status = tr("请先选择要打包的文件或文件夹。", "Please choose files or folders to pack first.")
            return false
        }
        guard !trimmedName.isEmpty else {
            status = tr("请输入压缩包名称。", "Please enter an archive name.")
            return false
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return false
        }

        Task {
            isRunning = true
            extractProgress = 0
            status = tr("正在打包...", "Packing...")
            let result = await createArchiveFromSourcesTask(
                executablePath: bin,
                sourceURLs: sourceURLs,
                outputDirectoryURL: outputDirectoryURL,
                name: trimmedName,
                type: type,
                onProgress: { progress in
                    self.extractProgress = progress
                }
            )

            switch result {
            case .success(let archiveURL):
                self.archiveURL = archiveURL
                self.extractDestinationURL = archiveURL.deletingPathExtension()
                self.status = tr("打包完成。", "Packing completed.")
                self.loadArchive()
            case .failure(let error):
                self.status = tr("打包失败。", "Packing failed.")
                DebugLogger.log("createArchiveFromSources() failed error=\(error.localizedDescription)")
                self.isRunning = false
            }
            self.extractProgress = nil
        }

        return true
    }

    func quickExtractArchives(_ urls: [URL]) {
        let archives = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !archives.isEmpty else {
            status = tr("没有可解压的压缩包。", "No archives to extract.")
            return
        }

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return
        }

        Task {
            isRunning = true
            extractProgress = 0
            status = archives.count == 1
                ? tr("正在直接解压...", "Extracting directly...")
                : tr("正在批量直接解压...", "Extracting archives directly...")

            var revealedFolders: Set<String> = []
            for archive in archives {
                let destination = archive.deletingLastPathComponent()
                let result = await extractFlattenedSelection(
                    executablePath: bin,
                    archivePath: archive.path,
                    includePaths: [],
                    destination: destination,
                    conflictPolicy: .askUser,
                    onProgress: { progress in
                        self.extractProgress = progress
                    }
                )

                switch result {
                case .success:
                    revealedFolders.insert(destination.path)
                case .failure(let error):
                    DebugLogger.log("quickExtractArchives() failed archive=\(archive.path) error=\(error.localizedDescription)")
                    status = tr("直接解压失败：\(archive.lastPathComponent)", "Direct extract failed: \(archive.lastPathComponent)")
                    isRunning = false
                    extractProgress = nil
                    return
                }
            }

            for path in revealedFolders {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            if let first = archives.first {
                archiveURL = first
                extractDestinationURL = first.deletingPathExtension()
                loadArchive()
            } else {
                status = tr("直接解压完成。", "Direct extract completed.")
                isRunning = false
            }
            extractProgress = nil
        }
    }

    private func refreshVisibleRows() {
        let baseRows = ArchiveListParser.rows(entries: loadedEntries, currentFolder: currentFolder)
        totalFileCount = baseRows.filter { !$0.isDirectory }.count
        totalFolderCount = baseRows.filter(\.isDirectory).count
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            visibleRows = baseRows
            return
        }
        visibleRows = baseRows.filter { row in
            row.name.localizedCaseInsensitiveContains(query) ||
                row.fullPath.localizedCaseInsensitiveContains(query)
        }
    }

    private func runExtract(includePaths: [String], destination: URL) {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }
        extractDestinationURL = destination

        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return
        }

        Task {
            DebugLogger.log("runExtract() begin selectedCount=\(includePaths.count) destination=\(destination.path)")
            isRunning = true
            extractProgress = 0
            status = includePaths.isEmpty
                ? tr("正在解压全部...", "Extracting all...")
                : tr("正在解压选中项...", "Extracting selected...")

            DebugLogger.log("runExtract() calling unified extraction count=\(includePaths.count)")
            let result = await extractFlattenedSelection(
                executablePath: bin,
                archivePath: archiveURL.path,
                includePaths: includePaths,
                destination: destination,
                conflictPolicy: .askUser,
                onProgress: { progress in
                    self.extractProgress = progress
                }
            )
            let exitCode: Int32
            switch result {
            case .success:
                exitCode = 0
            case .failure(let error):
                DebugLogger.log("runExtract() unified extraction failed: \(error.localizedDescription)")
                exitCode = -1
            }

            if exitCode == 0 {
                status = includePaths.isEmpty
                    ? tr("全部解压完成。", "Extract all completed.")
                    : tr("选中项解压完成。", "Extract selected completed.")
                DebugLogger.log("runExtract() open Finder start path=\(destination.path)")
                NSWorkspace.shared.open(destination)
                DebugLogger.log("runExtract() open Finder returned")
            } else {
                status = tr("解压失败（退出码 \(exitCode)）。", "Extract failed (exit \(exitCode)).")
            }
            extractProgress = nil
            isRunning = false
            DebugLogger.log("runExtract() end isRunning=false")
        }
    }

    private func addDroppedItems(
        executablePath: String,
        archivePath: String,
        sourceURLs: [URL],
        destinationFolder: String,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Result<Void, NSError> {
        let stagingResult = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [String]), NSError> in
            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("SevenZipMacUI_add_\(UUID().uuidString)")

            do {
                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

                let stagingRoot = destinationFolder.isEmpty
                    ? tempRoot
                    : tempRoot.appendingPathComponent(destinationFolder, isDirectory: true)
                try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

                var relativePaths: [String] = []
                for source in sourceURLs {
                    let target = stagingRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
                    }
                    try stageItemForCompression(from: source, to: target, fileManager: fm)
                    let relativePath = destinationFolder.isEmpty
                        ? source.lastPathComponent
                        : "\(destinationFolder)/\(source.lastPathComponent)"
                    relativePaths.append(relativePath)
                }
                return .success((tempRoot, relativePaths))
            } catch let error as NSError {
                try? fm.removeItem(at: tempRoot)
                return .failure(error)
            }
        }.value

        switch stagingResult {
        case .failure(let error):
            return .failure(error)
        case .success(let (tempRoot, relativePaths)):
            defer {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            await MainActor.run {
                onProgress?(0.01)
                self.status = self.tr("正在压缩拖入文件...", "Compressing dropped files...")
            }

            let compressionArguments = CreateArchiveType.fromArchivePath(archivePath)?.compressionArguments ?? ["-mx=3"]
            let args = ["a", "-r", "-snl", "-bb0", "-bso1", "-bsp1", "-bse0"] + compressionArguments + [archivePath] + relativePaths
            DebugLogger.log("addDroppedItems() calling run cwd=\(tempRoot.path) args=\(args.joined(separator: " "))")
            let exit = await SevenZipRunner.run(
                executablePath: executablePath,
                arguments: args,
                currentDirectoryURL: tempRoot,
                onOutput: { output in
                    if let progress = Self.parseProgress(from: output) {
                        onProgress?(progress)
                    }
                }
            )
            guard exit == 0 else {
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(exit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz add failed with exit \(exit)"]
                ))
            }
            return .success(())
        }
    }

    private func createEmptyArchive(
        executablePath: String,
        directoryURL: URL,
        name: String,
        type: CreateArchiveType
    ) async -> Result<URL, NSError> {
        let fm = FileManager.default
        let archiveName = name.hasSuffix(".\(type.fileExtension)") ? name : "\(name).\(type.fileExtension)"
        let archiveURL = directoryURL.appendingPathComponent(archiveName)
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SevenZipMacUI_create_\(UUID().uuidString)")
        let placeholderName = ".sevenzipmacui-empty"

        do {
            if fm.fileExists(atPath: archiveURL.path) {
                try fm.removeItem(at: archiveURL)
            }

            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempRoot) }

            try fm.createDirectory(at: tempRoot.appendingPathComponent(placeholderName, isDirectory: true), withIntermediateDirectories: true)

            let createArgs = ["a"] + type.compressionArguments + [archiveURL.path, placeholderName]
            let createExit = await SevenZipRunner.runSilent(
                executablePath: executablePath,
                arguments: createArgs,
                currentDirectoryURL: tempRoot
            )
            guard createExit == 0 else {
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(createExit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz create failed with exit \(createExit)"]
                ))
            }

            let deleteArgs = ["d", archiveURL.path, placeholderName]
            let deleteExit = await SevenZipRunner.runSilent(
                executablePath: executablePath,
                arguments: deleteArgs
            )
            guard deleteExit == 0 else {
                try? fm.removeItem(at: archiveURL)
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(deleteExit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz cleanup failed with exit \(deleteExit)"]
                ))
            }

            DebugLogger.log("createArchive() created archive=\(archiveURL.path)")
            return .success(archiveURL)
        } catch let error as NSError {
            return .failure(error)
        }
    }

    private func createArchiveFromSourcesTask(
        executablePath: String,
        sourceURLs: [URL],
        outputDirectoryURL: URL,
        name: String,
        type: CreateArchiveType,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Result<URL, NSError> {
        let archiveName = name.hasSuffix(".\(type.fileExtension)") ? name : "\(name).\(type.fileExtension)"
        let archiveURL = outputDirectoryURL.appendingPathComponent(archiveName)

        let directParents = Set(sourceURLs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if directParents.count == 1, let parentPath = directParents.first {
            let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
            let relativePaths = sourceURLs.map(\.lastPathComponent)

            do {
                if FileManager.default.fileExists(atPath: archiveURL.path) {
                    try FileManager.default.removeItem(at: archiveURL)
                }
            } catch let error as NSError {
                return .failure(error)
            }

            await MainActor.run {
                onProgress?(0.01)
                self.status = self.tr("正在直接打包源文件...", "Packing source files directly...")
            }

            let args = ["a", "-r", "-snl", "-bb0", "-bso1", "-bsp1", "-bse0"] + type.compressionArguments + [archiveURL.path] + relativePaths
            DebugLogger.log("createArchiveFromSourcesTask() direct mode cwd=\(parentURL.path) args=\(args.joined(separator: " "))")
            let exit = await SevenZipRunner.run(
                executablePath: executablePath,
                arguments: args,
                currentDirectoryURL: parentURL,
                onOutput: { output in
                    if let progress = Self.parseProgress(from: output) {
                        onProgress?(progress)
                    }
                }
            )
            guard exit == 0 else {
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(exit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz pack failed with exit \(exit)"]
                ))
            }
            return .success(archiveURL)
        }

        let stagingResult = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [String]), NSError> in
            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("SevenZipMacUI_pack_\(UUID().uuidString)")

            do {
                if fm.fileExists(atPath: archiveURL.path) {
                    try fm.removeItem(at: archiveURL)
                }

                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

                var relativePaths: [String] = []
                for source in sourceURLs {
                    let target = tempRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
                    }
                    try stageItemForCompression(from: source, to: target, fileManager: fm)
                    relativePaths.append(source.lastPathComponent)
                }

                return .success((tempRoot, relativePaths))
            } catch let error as NSError {
                try? fm.removeItem(at: tempRoot)
                return .failure(error)
            }
        }.value

        switch stagingResult {
        case .failure(let error):
            return .failure(error)
        case .success(let (tempRoot, relativePaths)):
            defer {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            await MainActor.run {
                onProgress?(0.01)
                self.status = self.tr("正在整理源文件后打包...", "Preparing source files for packing...")
            }

            let args = ["a", "-r", "-snl", "-bb0", "-bso1", "-bsp1", "-bse0"] + type.compressionArguments + [archiveURL.path] + relativePaths
            DebugLogger.log("createArchiveFromSourcesTask() args=\(args.joined(separator: " "))")
            let exit = await SevenZipRunner.run(
                executablePath: executablePath,
                arguments: args,
                currentDirectoryURL: tempRoot,
                onOutput: { output in
                    if let progress = Self.parseProgress(from: output) {
                        onProgress?(progress)
                    }
                }
            )
            guard exit == 0 else {
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(exit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz pack failed with exit \(exit)"]
                ))
            }
            return .success(archiveURL)
        }
    }

    private func extractFlattenedSelection(
        executablePath: String,
        archivePath: String,
        includePaths: [String],
        destination: URL,
        conflictPolicy: ExtractConflictPolicy,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Result<Void, NSError> {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SevenZipMacUI_extract_\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempRoot) }

            var args = ["x", archivePath, "-bb0", "-bso1", "-bsp1", "-bse0", "-o\(tempRoot.path)", "-y"]
            args.append(contentsOf: includePaths)
            let exit = await SevenZipRunner.run(
                executablePath: executablePath,
                arguments: args,
                onOutput: { output in
                    if let progress = Self.parseProgress(from: output) {
                        onProgress?(progress)
                    }
                }
            )
            guard exit == 0 else {
                return .failure(NSError(
                    domain: "SevenZipMacUI",
                    code: Int(exit),
                    userInfo: [NSLocalizedDescriptionKey: "7zz extract failed with exit \(exit)"]
                ))
            }

            if includePaths.isEmpty {
                let extractedItems = try fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
                for item in extractedItems {
                    let target = destination.appendingPathComponent(item.lastPathComponent)
                    try mergeExtractedItem(from: item, to: target, conflictPolicy: conflictPolicy)
                }
                return .success(())
            }

            for includePath in includePaths {
                let normalized = includePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !normalized.isEmpty else { continue }
                let source = tempRoot.appendingPathComponent(normalized)
                guard fm.fileExists(atPath: source.path) else { continue }
                let targetName = URL(fileURLWithPath: normalized).lastPathComponent
                let target = destination.appendingPathComponent(targetName)
                try mergeExtractedItem(from: source, to: target, conflictPolicy: conflictPolicy)
            }
            return .success(())
        } catch let error as NSError {
            return .failure(error)
        }
    }

    private func mergeExtractedItem(
        from source: URL,
        to destination: URL,
        conflictPolicy: ExtractConflictPolicy
    ) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            var targetIsDir: ObjCBool = false
            if fm.fileExists(atPath: destination.path, isDirectory: &targetIsDir), targetIsDir.boolValue {
                let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for child in children {
                    try mergeExtractedItem(
                        from: child,
                        to: destination.appendingPathComponent(child.lastPathComponent),
                        conflictPolicy: conflictPolicy
                    )
                }
                try? fm.removeItem(at: source)
            } else {
                if fm.fileExists(atPath: destination.path) {
                    if case .askUser = conflictPolicy, !shouldOverwriteExistingItem(at: destination) {
                        try? fm.removeItem(at: source)
                        return
                    }
                    try fm.removeItem(at: destination)
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
            }
            return
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            if case .askUser = conflictPolicy, !shouldOverwriteExistingItem(at: destination) {
                try? fm.removeItem(at: source)
                return
            }
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: source, to: destination)
    }

    private func shouldOverwriteExistingItem(at url: URL) -> Bool {
        if let remembered = rememberedExtractConflictOverwrite {
            return remembered
        }

        let alert = NSAlert()
        alert.messageText = tr("发现同名文件", "A file with the same name exists")
        alert.informativeText = tr(
            "目标目录中已存在“\(url.lastPathComponent)”。要覆盖它还是保留原文件？",
            "\"\(url.lastPathComponent)\" already exists in the destination. Do you want to overwrite it or keep the existing file?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("覆盖", "Overwrite"))
        alert.addButton(withTitle: tr("保留原文件", "Keep Existing"))

        let rememberButton = NSButton(checkboxWithTitle: tr("记住我的选择", "Remember my choice"), target: nil, action: nil)
        rememberButton.state = .off
        alert.accessoryView = rememberButton

        let shouldOverwrite = alert.runModal() == .alertFirstButtonReturn
        if rememberButton.state == .on {
            rememberedExtractConflictOverwrite = shouldOverwrite
        }
        return shouldOverwrite
    }

    private static func parseProgress(from text: String) -> Double? {
        let nsText = text as NSString
        let matches = progressRegex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )
        guard let last = matches.last, last.numberOfRanges >= 2 else {
            return nil
        }
        let numberText = nsText.substring(with: last.range(at: 1))
        guard let value = Double(numberText) else {
            return nil
        }
        return min(max(value / 100.0, 0.0), 1.0)
    }

    private func resolved7zzPath() -> String {
        if preferBundledBinary, let bundled = bundled7zzPath() {
            return bundled
        }
        if FileManager.default.isExecutableFile(atPath: sevenZipPath) {
            return sevenZipPath
        }
        let candidates = [
            "/opt/homebrew/bin/7zz",
            "/usr/local/bin/7zz",
            "/usr/bin/7zz"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return sevenZipPath
    }

    private func bundled7zzPath() -> String? {
        var candidates: [URL] = []

        #if SWIFT_PACKAGE
        if let resource = Bundle.module.resourceURL {
            candidates.append(resource.appendingPathComponent("7zz"))
        }
        #endif

        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("7zz"))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("7zz"))
        }

        for url in candidates {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            ensureExecutable(path: path)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func ensureExecutable(path: String) {
        if FileManager.default.isExecutableFile(atPath: path) {
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func binaryResolutionHint(selectedPath: String) -> String {
        var lines: [String] = []
        lines.append("7zz executable is not found: \(selectedPath)")

        if preferBundledBinary {
            var bundledPaths: [String] = []
            #if SWIFT_PACKAGE
            if let resource = Bundle.module.resourceURL {
                bundledPaths.append(resource.appendingPathComponent("7zz").path)
            }
            #endif
            if let resource = Bundle.main.resourceURL {
                bundledPaths.append(resource.appendingPathComponent("7zz").path)
            }
            if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
                bundledPaths.append(exeDir.appendingPathComponent("7zz").path)
            }
            for p in bundledPaths {
                lines.append("checked bundled path: \(p)")
            }
        }

        lines.append("checked custom path: \(sevenZipPath)")
        lines.append("checked system path: /opt/homebrew/bin/7zz")
        lines.append("checked system path: /usr/local/bin/7zz")
        lines.append("checked system path: /usr/bin/7zz")
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendLog(_ text: String) {
        guard showLogs else { return }
        logs += text
        let maxChars = 200_000
        if logs.count > maxChars {
            let keep = logs.suffix(maxChars)
            logs = String(keep)
        }
    }

    private func showFolder(_ folder: String) {
        let normalized = ArchiveListParser.normalizeFolder(folder)
        selectedPaths.removeAll()

        if let cached = folderEntryCache[normalized] {
            currentFolder = normalized
            loadedEntries = cached
            status = normalized.isEmpty
                ? tr("已显示根目录。", "Showing root folder.")
                : tr("已显示目录：\(normalized)", "Showing folder: \(normalized)")
            return
        }

        guard archiveURL != nil else { return }
        Task {
            await loadFolderContents(
                folder: normalized,
                resetCache: false,
                loadingStatus: normalized.isEmpty
                    ? tr("正在读取根目录...", "Reading root folder...")
                    : tr("正在读取目录：\(normalized)", "Reading folder: \(normalized)")
            )
        }
    }

    private func loadFolderContents(
        folder: String,
        resetCache: Bool,
        loadingStatus: String
    ) async {
        guard let archiveURL else {
            status = tr("请先选择压缩包。", "Pick an archive first.")
            return
        }

        let normalizedFolder = ArchiveListParser.normalizeFolder(folder)
        let bin = resolved7zzPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            status = tr("未找到 7zz，请先设置路径。", "7zz not found. Set the 7zz path first.")
            appendLog(binaryResolutionHint(selectedPath: bin))
            return
        }

        if resetCache {
            folderEntryCache.removeAll()
            loadedEntries = []
        }

        DebugLogger.log("loadFolderContents() start archive=\(archiveURL.path) folder=\(normalizedFolder)")
        isRunning = true
        extractProgress = nil
        status = loadingStatus
        selectedPaths.removeAll()

        let result = await SevenZipRunner.runCapture(
            executablePath: bin,
            arguments: archiveListingArguments(archivePath: archiveURL.path, folder: normalizedFolder)
        )
        DebugLogger.log("loadFolderContents() capture returned exit=\(result.exitCode) outputChars=\(result.output.count)")

        guard result.exitCode == 0 else {
            status = tr("读取压缩包失败（退出码 \(result.exitCode)）。", "Failed to read archive (exit \(result.exitCode)).")
            if resetCache {
                currentFolder = ""
                loadedEntries = []
            }
            isRunning = false
            return
        }

        let parsed = ArchiveListParser.parseSLT(result.output)
        if normalizedFolder.isEmpty == false && parsed.isEmpty {
            DebugLogger.log("loadFolderContents() empty result for folder=\(normalizedFolder), fallback root")
            await loadFolderContents(
                folder: "",
                resetCache: resetCache,
                loadingStatus: tr("当前目录不存在，正在返回根目录...", "Folder no longer exists, returning to root...")
            )
            return
        }

        folderEntryCache[normalizedFolder] = parsed
        currentFolder = normalizedFolder
        loadedEntries = parsed
        status = normalizedFolder.isEmpty
            ? tr("已加载根目录。", "Root folder loaded.")
            : tr("已加载目录：\(normalizedFolder)", "Folder loaded: \(normalizedFolder)")
        isRunning = false
        DebugLogger.log("loadFolderContents() done folder=\(normalizedFolder) parsedEntries=\(parsed.count)")
    }

    private func archiveListingArguments(archivePath: String, folder: String) -> [String] {
        let normalizedFolder = ArchiveListParser.normalizeFolder(folder)
        var arguments = ["l", "-slt", archivePath]
        if !normalizedFolder.isEmpty {
            arguments.append(normalizedFolder)
        }
        return arguments
    }

}



struct WindowCloseInterceptor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?

        @MainActor
        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if AppTerminationCoordinator.shouldBypassPrompt() {
                return true
            }
            guard SevenZipRunner.hasActiveProcesses() else { return true }
            guard AppTerminationCoordinator.confirmTerminationIfNeeded() else { return false }
            NSApp.terminate(nil)
            return false
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var hoverAllButton = false
    @State private var hoverAllMenu = false
    @State private var hoverSelectedButton = false
    @State private var hoverSelectedMenu = false
    @State private var hoverAllPoint: CGPoint = .zero
    @State private var hoverSelectedPoint: CGPoint = .zero
    @State private var showCreateArchiveSheet = false
    @State private var showPackArchiveSheet = false
    @State private var showAssociationSheet = false
    @State private var createArchiveType: CreateArchiveType = .sevenZip
    @State private var createArchiveDirectory = FileManager.default.homeDirectoryForCurrentUser
    @State private var createArchiveName = ""
    @State private var packArchiveType: CreateArchiveType = .sevenZip
    @State private var packArchiveOutputDirectory = FileManager.default.homeDirectoryForCurrentUser
    @State private var packArchiveName = ""
    @State private var packSourceURLs: [URL] = []

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.11, blue: 0.20), Color(red: 0.16, green: 0.24, blue: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                browserPanel
                bottomBar
            }
            .padding(14)
        }
        .sheet(isPresented: $showCreateArchiveSheet) {
            createArchiveSheet
        }
        .sheet(isPresented: $showPackArchiveSheet) {
            packArchiveSheet
        }
        .sheet(isPresented: $showAssociationSheet) {
            associationSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .sevenZipOpenArchiveURLs)) { notification in
            guard let urls = notification.object as? [URL], let first = urls.first else { return }
            viewModel.openArchive(url: first)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sevenZipQuickExtractURLs)) { notification in
            guard let urls = notification.object as? [URL], !urls.isEmpty else { return }
            viewModel.handleLaunchCommand(.quickExtract(urls))
        }
        .background(WindowCloseInterceptor())
        .task {
            if FileAssociationManager.shouldShowFirstLaunchPrompt() {
                showAssociationSheet = true
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label(viewModel.tr("压缩包", "Archive"), systemImage: "archivebox")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(viewModel.archiveURL?.path ?? viewModel.tr("尚未打开压缩包", "No archive opened"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Picker("", selection: $viewModel.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Button(viewModel.tr("打开压缩包", "Open Archive"), action: viewModel.browseArchive)
                    .buttonStyle(.borderedProminent)
                Button(viewModel.tr("创建空包", "Create Empty Archive")) {
                    createArchiveDirectory = viewModel.archiveURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
                    if createArchiveName.isEmpty {
                        createArchiveName = "NewArchive"
                    }
                    showCreateArchiveSheet = true
                }
                .buttonStyle(.bordered)
                Button(viewModel.tr("打包", "Pack")) {
                    packSourceURLs = []
                    packArchiveName = ""
                    packArchiveType = .sevenZip
                    packArchiveOutputDirectory = viewModel.archiveURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
                    showPackArchiveSheet = true
                }
                .buttonStyle(.bordered)
                Button(viewModel.tr("刷新", "Reload")) {
                    viewModel.loadArchive(preserveCurrentFolder: true)
                }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.archiveURL == nil || viewModel.isRunning)
            }

            HStack(spacing: 8) {
                TextField(viewModel.tr("7zz 路径", "Path to 7zz"), text: $viewModel.sevenZipPath)
                    .textFieldStyle(.roundedBorder)
                Button(viewModel.tr("选择 7zz...", "7zz..."), action: viewModel.browseSevenZipBinary)
                    .buttonStyle(.bordered)

                Toggle(isOn: $viewModel.preferBundledBinary) {
                    Text(viewModel.tr("优先内置 7zz", "Prefer bundled 7zz"))
                }
                .toggleStyle(.switch)
                .foregroundStyle(.white.opacity(0.9))

                Divider()
                    .frame(height: 20)

                Text(viewModel.tr("最近解压目录", "Last destination"))
                    .foregroundStyle(.white.opacity(0.85))
                Text(viewModel.extractDestinationURL?.path ?? viewModel.tr("未选择", "Not selected"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var browserPanel: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            VStack(spacing: 10) {
                breadcrumbs
                tableView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(viewModel.tr("压缩包浏览器", "Archive Explorer"), systemImage: "folder.fill")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                statRow(viewModel.tr("文件", "Files"), "\(viewModel.totalFileCount)")
                statRow(viewModel.tr("目录", "Folders"), "\(viewModel.totalFolderCount)")
                statRow(viewModel.tr("已选", "Selected"), "\(viewModel.selectedCount)")
            }
            .padding(10)
            .background(Color.black.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            TextField(viewModel.tr("搜索当前目录", "Search current folder"), text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)

            Button(viewModel.tr("解压全部", "Extract All"), action: viewModel.extractAll)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExtractAll)
                .background(
                    HoverTrackingArea(
                        onHoverChanged: { hoverAllButton = $0 },
                        onMouseMoved: { hoverAllPoint = $0 }
                    )
                )
                .overlay(alignment: .topLeading) {
                    if (hoverAllButton || hoverAllMenu) && viewModel.canExtractAll {
                        destinationPopup(
                            onArchiveFolder: viewModel.extractAll,
                            onOtherFolder: viewModel.extractAllToOtherDirectory
                        )
                        .offset(x: hoverAllPoint.x, y: hoverAllPoint.y)
                        .fixedSize(horizontal: true, vertical: false)
                        .onHover { hoverAllMenu = $0 }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: hoverAllButton || hoverAllMenu)

            Button(viewModel.tr("解压选中项", "Extract Selected"), action: viewModel.extractSelected)
                .buttonStyle(.bordered)
                .disabled(!viewModel.canExtractSelected)
                .background(
                    HoverTrackingArea(
                        onHoverChanged: { hoverSelectedButton = $0 },
                        onMouseMoved: { hoverSelectedPoint = $0 }
                    )
                )
                .overlay(alignment: .topLeading) {
                    if (hoverSelectedButton || hoverSelectedMenu) && viewModel.canExtractSelected {
                        destinationPopup(
                            onArchiveFolder: viewModel.extractSelected,
                            onOtherFolder: viewModel.extractSelectedToOtherDirectory
                        )
                        .offset(x: hoverSelectedPoint.x, y: hoverSelectedPoint.y)
                        .fixedSize(horizontal: true, vertical: false)
                        .onHover { hoverSelectedMenu = $0 }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: hoverSelectedButton || hoverSelectedMenu)

            Spacer(minLength: 0)

            Text(viewModel.tr("提示", "Tips"))
                .font(.headline)
            Text(viewModel.tr(
                "双击目录可进入。\n单击选中，按住 Command 或 Shift 可多选。\n按住 Option 点击可选择删除文件。\n按 Backspace 返回上一级。",
                "Double-click folders to enter.\nSingle-click selects; hold Command or Shift for multi-select.\nHold Option and click to choose delete.\nPress Backspace to go up."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func statRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
    }

    private func destinationPopup(
        onArchiveFolder: @escaping () -> Void,
        onOtherFolder: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onArchiveFolder) {
                Text(viewModel.tr("解压到压缩包目录", "Extract to archive folder"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Divider()
            Button(action: onOtherFolder) {
                Text(viewModel.tr("解压到其他目录...", "Extract to other folder..."))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(minWidth: 220, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 8)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button(action: viewModel.navigateToRoot) {
                Label(viewModel.tr("根目录", "Root"), systemImage: "house.fill")
            }
            .buttonStyle(.bordered)

            Button(action: viewModel.navigateUp) {
                Label(viewModel.tr("上级", "Up"), systemImage: "arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.breadcrumb.isEmpty)

            ForEach(Array(viewModel.breadcrumb.enumerated()), id: \.offset) { index, name in
                Text(">")
                    .foregroundStyle(.secondary)
                Button(name) {
                    viewModel.navigateToBreadcrumb(index: index)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var tableView: some View {
        ZStack {
            ArchiveTableView(
                rows: viewModel.visibleRows,
                selectedPaths: $viewModel.selectedPaths,
                isInteractionEnabled: !viewModel.isRunning,
                onNavigateUp: {
                    viewModel.navigateUp()
                },
                onDoubleClick: { row in
                    viewModel.openRow(row)
                },
                onDragExtract: { includePath, destination, completion in
                    viewModel.extractByDrag(includePath: includePath, destination: destination, completion: completion)
                },
                onDropImport: { sourceURLs in
                    viewModel.importByDrag(sourceURLs: sourceURLs)
                },
                onDeleteSelected: {
                    viewModel.deleteSelected()
                },
                onExtractSelectedToOtherDirectory: {
                    viewModel.extractSelectedToOtherDirectory()
                }
            )

            if viewModel.visibleRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                    Text(viewModel.tr("此目录暂无条目。", "No items in this folder."))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Label(viewModel.status, systemImage: viewModel.isRunning ? "hourglass" : "checkmark.seal")
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.white)

            HStack {
                Text(viewModel.tr("调试日志", "Debug log"))
                Text(DebugLogger.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))

            if viewModel.isRunning {
                HStack(spacing: 10) {
                    if let progress = viewModel.extractProgress {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(width: 42, alignment: .trailing)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text(viewModel.tr("准备中", "Preparing"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var createArchiveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.tr("创建空包", "Create Empty Archive"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.tr("类型", "Type"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $createArchiveType) {
                    ForEach(CreateArchiveType.allCases) { type in
                        Text(type.title(viewModel.language)).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.tr("名称", "Name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(viewModel.tr("输入压缩包名称", "Archive name"), text: $createArchiveName)
                    .textFieldStyle(.roundedBorder)

                Text(viewModel.tr("目录", "Directory"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(createArchiveDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(viewModel.tr("选择", "Choose")) {
                        if let url = viewModel.chooseFolder(startingAt: createArchiveDirectory) {
                            createArchiveDirectory = url
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(viewModel.tr("取消", "Cancel")) {
                    showCreateArchiveSheet = false
                }
                .buttonStyle(.bordered)

                Button(viewModel.tr("创建", "Create")) {
                    let started = viewModel.createArchive(
                        directoryURL: createArchiveDirectory,
                        name: createArchiveName,
                        type: createArchiveType
                    )
                    if started {
                        showCreateArchiveSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.regularMaterial)
    }

    private var packArchiveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.tr("打包", "Pack"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.tr("源文件/文件夹", "Source files/folders"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(packSourceURLs.isEmpty ? viewModel.tr("尚未选择", "Not selected") : packSourceURLs.map(\.lastPathComponent).joined(separator: ", "))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(viewModel.tr("选择文件...", "Choose...")) {
                        let baseURL = packSourceURLs.first?.deletingLastPathComponent() ?? packArchiveOutputDirectory
                        let urls = viewModel.choosePackSources(startingAt: baseURL)
                        guard !urls.isEmpty else { return }
                        packSourceURLs = urls
                        if packArchiveName.isEmpty {
                            packArchiveName = urls[0].deletingPathExtension().lastPathComponent
                        } else {
                            packArchiveName = urls[0].deletingPathExtension().lastPathComponent
                        }
                        packArchiveOutputDirectory = urls[0].deletingLastPathComponent()
                    }
                }

                Text(viewModel.tr("名称", "Name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(viewModel.tr("输入压缩包名称", "Archive name"), text: $packArchiveName)
                    .textFieldStyle(.roundedBorder)

                Text(viewModel.tr("类型", "Type"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $packArchiveType) {
                    ForEach(CreateArchiveType.allCases) { type in
                        Text(type.title(viewModel.language)).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Text(viewModel.tr("输出目录", "Output directory"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(packArchiveOutputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(viewModel.tr("选择", "Choose")) {
                        if let url = viewModel.chooseFolder(startingAt: packArchiveOutputDirectory) {
                            packArchiveOutputDirectory = url
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(viewModel.tr("取消", "Cancel")) {
                    showPackArchiveSheet = false
                }
                .buttonStyle(.bordered)

                Button(viewModel.tr("开始打包", "Pack")) {
                    let started = viewModel.createArchiveFromSources(
                        sourceURLs: packSourceURLs,
                        outputDirectoryURL: packArchiveOutputDirectory,
                        name: packArchiveName,
                        type: packArchiveType
                    )
                    if started {
                        showPackArchiveSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private var associationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.tr("关联压缩包后缀", "Associate Archive Types"))
                .font(.title3.weight(.semibold))

            Text(viewModel.tr(
                "首次打开时可选择让 ZipMate 直接打开这些压缩包。关联后，你可以在 Finder 中双击相应压缩包直接用本软件打开。",
                "Choose which archive types ZipMate should open by default. After association, you can double-click those archives in Finder to open them with this app."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ArchiveAssociationOption.allCases) { option in
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.suggestedAssociationOptions.contains(option) },
                            set: { isOn in
                                if isOn {
                                    viewModel.suggestedAssociationOptions.insert(option)
                                } else {
                                    viewModel.suggestedAssociationOptions.remove(option)
                                }
                            }
                        )
                    ) {
                        Text(".\(option.fileExtension)")
                            .font(.body.monospaced())
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                Button(viewModel.tr("暂不设置", "Not Now")) {
                    FileAssociationManager.markFirstLaunchPromptShown()
                    showAssociationSheet = false
                }
                .buttonStyle(.bordered)

                Button(viewModel.tr("应用关联", "Apply Associations")) {
                    viewModel.applyFileAssociations(viewModel.suggestedAssociationOptions)
                    showAssociationSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(.regularMaterial)
    }
}
