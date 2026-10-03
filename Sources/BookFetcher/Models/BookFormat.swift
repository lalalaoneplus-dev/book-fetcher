import Foundation

public enum BookFormat: String, CaseIterable, Codable, Sendable {
    case epub
    case pdf
    case azw3
    case mobi
    case txt
    case rtf
    case docx
    case odt
    case html
    case htm
    case htmlz
    case fb2
    case fbz
    case azw
    case azw4
    case prc
    case lit
    case lrf
    case pdb
    case pml
    case rb
    case snb
    case tcr
    case cbz
    case cbr
    case cb7
    case cbc
    case chm
    case djvu
    case djv
    case txtz
    case docm
    case downloadedRecipe = "downloaded_recipe"
    case kepub
    case markdown
    case md
    case opf
    case pmlz
    case pobi
    case recipe
    case shtm
    case shtml
    case text
    case textile
    case updb
    case xhtm
    case xhtml
    case zip

    public var displayName: String {
        rawValue.uppercased()
    }

    public static func detect(fileName: String?, mimeType: String?) -> BookFormat? {
        if let fileName {
            let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
            if let format = BookFormat(rawValue: ext) {
                return format
            }
        }

        let mime = mimeType?
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        switch mime {
        case "application/epub+zip":
            return .epub
        case "application/pdf":
            return .pdf
        case "application/x-mobipocket-ebook", "application/vnd.amazon.ebook":
            return .mobi
        case "text/plain":
            return .txt
        case "text/html", "application/xhtml+xml":
            return .html
        case "application/rtf", "text/rtf":
            return .rtf
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return .docx
        case "application/vnd.ms-word.document.macroenabled.12":
            return .docm
        case "application/vnd.oasis.opendocument.text":
            return .odt
        case "application/vnd.comicbook+zip", "application/x-cbz":
            return .cbz
        case "application/zip", "application/x-zip-compressed":
            return .zip
        case "application/vnd.comicbook-rar", "application/x-cbr":
            return .cbr
        case "application/x-chm":
            return .chm
        case "image/vnd.djvu", "image/x-djvu":
            return .djvu
        case "text/markdown":
            return .markdown
        default:
            return nil
        }
    }
}
