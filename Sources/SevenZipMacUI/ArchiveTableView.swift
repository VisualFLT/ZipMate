import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ArchiveBrowserTableView: NSTableView {
    var onBackKey: (() -> Void)?
    weak var contextualCoordinator: ArchiveTableView.Coordinator?
    private var localKeyMonitor: Any?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextualCoordinator?.makeContextMenu()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onBackKey?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            if row >= 0, !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if let menu = contextualCoordinator?.makeContextMenu() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
        }
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        guard window != nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            guard self.window?.isKeyWindow == true else { return event }
            if let responder = self.window?.firstResponder {
                if responder is NSTextView || responder is NSTextField {
                    return event
                }
                if let view = responder as? NSView, view.isDescendant(of: self) {
                    self.onBackKey?()
                    return nil
                }
            }

            self.onBackKey?()
            return nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func deleteBackward(_ sender: Any?) {
        onBackKey?()
    }

    override func deleteForward(_ sender: Any?) {
        onBackKey?()
    }
}

struct ArchiveTableView: NSViewRepresentable {
    let rows: [BrowserRow]
    @Binding var selectedPaths: Set<String>
    let isInteractionEnabled: Bool
    let onNavigateUp: () -> Void
    let onDoubleClick: (BrowserRow) -> Void
    let onDragExtract: (_ includePath: String, _ destination: URL, _ completion: @escaping (Error?) -> Void) -> Void
    let onDropImport: (_ sourceURLs: [URL]) -> Bool
    let onDeleteSelected: () -> Void
    let onExtractSelectedToOtherDirectory: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        let tableView = ArchiveBrowserTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 30
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.registerForDraggedTypes([.filePromise])
        tableView.registerForDraggedTypes([.fileURL])

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 150
        nameColumn.minWidth = 100
        nameColumn.maxWidth = 190
        nameColumn.resizingMask = .userResizingMask

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 90
        sizeColumn.minWidth = 64
        sizeColumn.maxWidth = 130
        sizeColumn.resizingMask = .userResizingMask

        let packedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("packed"))
        packedColumn.title = "Packed"
        packedColumn.width = 90
        packedColumn.minWidth = 64
        packedColumn.maxWidth = 130
        packedColumn.resizingMask = .userResizingMask

        let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedColumn.title = "Modified"
        modifiedColumn.width = 220
        modifiedColumn.minWidth = 130
        modifiedColumn.resizingMask = .autoresizingMask

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(packedColumn)
        tableView.addTableColumn(modifiedColumn)

        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.action = #selector(Coordinator.handleSingleClick(_:))
        tableView.onBackKey = context.coordinator.handleBackKey
        tableView.contextualCoordinator = context.coordinator

        context.coordinator.tableView = tableView

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let tableView = context.coordinator.tableView else { return }
        tableView.allowsMultipleSelection = isInteractionEnabled
        tableView.allowsEmptySelection = isInteractionEnabled
        if context.coordinator.rows != rows {
            context.coordinator.rows = rows
            tableView.reloadData()
        }

        let desired = IndexSet(rows.indices.filter { selectedPaths.contains(rows[$0].fullPath) })
        if tableView.selectedRowIndexes != desired {
            context.coordinator.applyingProgrammaticSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            context.coordinator.applyingProgrammaticSelection = false
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
        var parent: ArchiveTableView
        var rows: [BrowserRow] = []
        weak var tableView: NSTableView?
        var applyingProgrammaticSelection = false

        init(parent: ArchiveTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count else { return nil }
            let model = rows[row]
            let key = tableColumn?.identifier.rawValue ?? "name"
            switch key {
            case "name":
                return nameCell(model)
            case "size":
                if model.isDirectory {
                    let display = (model.size ?? 0) > 0 ? model.size?.humanSize ?? "—" : "—"
                    return textCell(display)
                }
                return textCell(model.size?.humanSize ?? "—")
            case "packed":
                if model.isDirectory {
                    let display = (model.packedSize ?? 0) > 0 ? model.packedSize?.humanSize ?? "—" : "—"
                    return textCell(display)
                }
                return textCell(model.packedSize?.humanSize ?? "—")
            case "modified":
                return textCell(model.modified ?? "—")
            default:
                return textCell("")
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingProgrammaticSelection, let tableView else { return }
            let indexes = tableView.selectedRowIndexes
            var next: Set<String> = []
            for idx in indexes {
                guard idx >= 0 && idx < rows.count else { continue }
                next.insert(rows[idx].fullPath)
            }
            if parent.selectedPaths != next {
                parent.selectedPaths = next
            }
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.isInteractionEnabled else { return [] }
            let board = info.draggingPasteboard
            if board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            }
            return []
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard parent.isInteractionEnabled else { return false }
            let board = info.draggingPasteboard
            guard
                let items = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                !items.isEmpty
            else {
                return false
            }
            return parent.onDropImport(items)
        }

        func makeContextMenu() -> NSMenu? {
            guard parent.isInteractionEnabled, !parent.selectedPaths.isEmpty else { return nil }
            let menu = NSMenu()

            let extract = NSMenuItem(
                title: "解压到...",
                action: #selector(handleExtractSelectedFromMenu),
                keyEquivalent: ""
            )
            extract.target = self
            menu.addItem(extract)

            menu.addItem(.separator())

            let delete = NSMenuItem(
                title: "删除",
                action: #selector(handleDeleteSelectedFromMenu),
                keyEquivalent: ""
            )
            delete.target = self
            menu.addItem(delete)

            return menu
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard row >= 0 && row < rows.count else { return nil }
            let model = rows[row]
            let fileType = model.isDirectory ? UTType.folder.identifier : UTType.data.identifier
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
            provider.userInfo = [
                "includePath": model.fullPath,
                "name": model.name
            ]
            return provider
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            guard
                let info = filePromiseProvider.userInfo as? [String: String],
                let name = info["name"],
                !name.isEmpty
            else {
                return "item"
            }
            return name
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            guard
                let info = filePromiseProvider.userInfo as? [String: String],
                let includePath = info["includePath"],
                !includePath.isEmpty
            else {
                completionHandler(NSError(domain: "SevenZipMacUI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid drag item"]))
                return
            }
            // `url` is usually the promised file URL (includes item name), not the directory.
            // Extract to its parent folder so files are placed directly in drop destination.
            parent.onDragExtract(includePath, url.deletingLastPathComponent(), completionHandler)
        }

        @objc func handleSingleClick(_ sender: Any?) {
            // Keep native single-click selection behavior.
        }

        @objc func handleDeleteSelectedFromMenu() {
            parent.onDeleteSelected()
        }

        @objc func handleExtractSelectedFromMenu() {
            parent.onExtractSelectedToOtherDirectory()
        }

        func handleBackKey() {
            guard parent.isInteractionEnabled else { return }
            parent.onNavigateUp()
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0 && row < rows.count else { return }
            parent.onDoubleClick(rows[row])
        }

        private func textCell(_ text: String) -> NSView {
            let view = NSTableCellView()
            let label = NSTextField(labelWithString: text)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }

        private func nameCell(_ row: BrowserRow) -> NSView {
            let view = NSTableCellView()
            let stack = NSStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSImage(systemSymbolName: row.isDirectory ? "folder.fill" : "doc.text", accessibilityDescription: nil)
            icon.contentTintColor = row.isDirectory ? .systemBlue : .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

            let label = NSTextField(labelWithString: row.name)
            label.lineBreakMode = .byTruncatingMiddle

            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(label)
            view.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }
    }
}
