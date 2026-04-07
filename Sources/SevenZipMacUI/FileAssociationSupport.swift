import Foundation
import UniformTypeIdentifiers
import CoreServices

enum ArchiveAssociationOption: String, CaseIterable, Identifiable {
    case zip
    case sevenZip
    case rar
    case tar
    case gz
    case bz2
    case xz
    case tgz
    case tbz2
    case txz

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .tar: return "tar"
        case .gz: return "gz"
        case .bz2: return "bz2"
        case .xz: return "xz"
        case .tgz: return "tgz"
        case .tbz2: return "tbz2"
        case .txz: return "txz"
        }
    }

    var utiIdentifier: String {
        switch self {
        case .zip: return "public.zip-archive"
        case .sevenZip: return "org.7-zip.7-zip-archive"
        case .rar: return "com.rarlab.rar-archive"
        case .tar: return "public.tar-archive"
        case .gz: return "org.gnu.gnu-zip-archive"
        case .bz2: return "public.bzip2-archive"
        case .xz: return "org.tukaani.xz-archive"
        case .tgz: return "org.gnu.gnu-zip-tar-archive"
        case .tbz2: return "public.tar-bzip2-archive"
        case .txz: return "org.tukaani.xz-tar-archive"
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
