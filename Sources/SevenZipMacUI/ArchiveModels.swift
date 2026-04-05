import Foundation

struct ArchiveEntry: Identifiable, Hashable {
    let path: String
    let size: Int64?
    let packedSize: Int64?
    let modified: String?
    let isDirectory: Bool

    var id: String { path }
}

struct BrowserRow: Identifiable, Hashable {
    let fullPath: String
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let packedSize: Int64?
    let modified: String?

    var id: String { fullPath }
}

enum ArchiveListParser {
    private static let slashCharset = CharacterSet(charactersIn: "/")

    private struct RowAccumulator {
        let fullPath: String
        let name: String
        let isDirectory: Bool
        var size: Int64?
        var packedSize: Int64?
        var modified: String?

        mutating func absorb(file entry: ArchiveEntry) {
            guard !entry.isDirectory else { return }
            if let fileSize = entry.size {
                size = (size ?? 0) + fileSize
            }
            if let filePackedSize = entry.packedSize {
                packedSize = (packedSize ?? 0) + filePackedSize
            }
            if let modified = entry.modified, (self.modified ?? "") < modified {
                self.modified = modified
            }
        }

        mutating func overlay(with entry: ArchiveEntry) {
            if let size = entry.size, size > 0 || self.size == nil {
                self.size = size
            }
            if let packedSize = entry.packedSize, packedSize > 0 || self.packedSize == nil {
                self.packedSize = packedSize
            }
            if let modified = entry.modified {
                self.modified = modified
            }
        }

        var row: BrowserRow {
            BrowserRow(
                fullPath: fullPath,
                name: name,
                isDirectory: isDirectory,
                size: size,
                packedSize: packedSize,
                modified: modified
            )
        }
    }

    static func parseSLT(_ text: String) -> [ArchiveEntry] {
        var results: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            guard let path = current["Path"], !path.isEmpty else {
                current.removeAll(keepingCapacity: true)
                return
            }

            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            if normalized.hasPrefix("/") {
                current.removeAll(keepingCapacity: true)
                return
            }

            let attributes = current["Attributes"] ?? ""
            let isDir =
                (current["Folder"] == "+") ||
                normalized.hasSuffix("/") ||
                attributes.hasPrefix("D")
            let entry = ArchiveEntry(
                path: normalized,
                size: Int64(current["Size"] ?? ""),
                packedSize: Int64(current["Packed Size"] ?? ""),
                modified: current["Modified"],
                isDirectory: isDir
            )
            results.append(entry)
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushCurrent()
                continue
            }

            guard let idx = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            current[key] = value
        }

        flushCurrent()

        return results
            .filter { !$0.path.isEmpty && $0.path != "-" }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
    }

    static func rows(entries: [ArchiveEntry], currentFolder: String) -> [BrowserRow] {
        let folder = normalizeFolder(currentFolder)
        var byName: [String: RowAccumulator] = [:]

        for entry in entries {
            let cleanPath = entry.path.trimmingCharacters(in: slashCharset)
            if cleanPath.isEmpty {
                continue
            }

            if !folder.isEmpty {
                let prefix = folder + "/"
                if cleanPath != folder && !cleanPath.hasPrefix(prefix) {
                    continue
                }
            }

            let relative: String
            if folder.isEmpty {
                relative = cleanPath
            } else if cleanPath == folder {
                continue
            } else {
                relative = String(cleanPath.dropFirst(folder.count + 1))
            }

            if relative.isEmpty {
                continue
            }

            if let firstSlash = relative.firstIndex(of: "/") {
                let first = String(relative[..<firstSlash])
                let childPath = folder.isEmpty ? first : "\(folder)/\(first)"
                if byName[first] == nil {
                    byName[first] = RowAccumulator(
                        fullPath: childPath,
                        name: first,
                        isDirectory: true,
                        size: nil,
                        packedSize: nil,
                        modified: nil
                    )
                }
                byName[first]?.absorb(file: entry)
            } else {
                let first = relative
                if var existing = byName[first], entry.isDirectory {
                    existing.overlay(with: entry)
                    byName[first] = existing
                } else {
                    byName[first] = RowAccumulator(
                        fullPath: cleanPath,
                        name: first,
                        isDirectory: entry.isDirectory,
                        size: entry.size,
                        packedSize: entry.packedSize,
                        modified: entry.modified
                    )
                }
            }
        }

        return byName.values.map(\.row).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func normalizeFolder(_ folder: String) -> String {
        folder.trimmingCharacters(in: slashCharset)
    }
}

extension Int64 {
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
