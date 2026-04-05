import Foundation
import UniformTypeIdentifiers
import CoreServices

enum ArchiveAssociationOption: String, CaseIterable, Identifiable {
    case zip
    case sevenZip
    case rar
    case tar

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .tar: return "tar"
        }
    }

    var utiIdentifier: String {
        switch self {
        case .zip: return "public.zip-archive"
        case .sevenZip: return "org.7-zip.7-zip-archive"
        case .rar: return "com.rarlab.rar-archive"
        case .tar: return "public.tar-archive"
        }
    }
}

enum FileAssociationManager {
    static let firstLaunchPromptKey = "ZipMate.didShowAssociationPrompt"

    static func shouldShowFirstLaunchPrompt() -> Bool {
        !UserDefaults.standard.bool(forKey: firstLaunchPromptKey)
    }

    static func markFirstLaunchPromptShown() {
        UserDefaults.standard.set(true, forKey: firstLaunchPromptKey)
    }

    static func setDefaultHandler(
        options: [ArchiveAssociationOption],
        bundleIdentifier: String
    ) -> [ArchiveAssociationOption: OSStatus] {
        var results: [ArchiveAssociationOption: OSStatus] = [:]
        for option in options {
            let status = LSSetDefaultRoleHandlerForContentType(
                option.utiIdentifier as CFString,
                .all,
                bundleIdentifier as CFString
            )
            results[option] = status
        }
        return results
    }
}
