import Foundation

enum DebugLogger {
    private static let queue = DispatchQueue(label: "sevenzip.macui.debug.logger")
    private static let logURL: URL = {
        URL(fileURLWithPath: "/tmp/SevenZipMacUI-debug.log")
    }()

    static func reset() {
        queue.sync {
            let header = "\n\n========== NEW SESSION \(timestamp()) ==========\n"
            if let data = header.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logURL, options: .atomic)
                }
            }
        }
    }

    static func log(_ message: String) {
        let line = "[\(timestamp())][\(Thread.isMainThread ? "main" : "bg")] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    static var path: String {
        logURL.path
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
