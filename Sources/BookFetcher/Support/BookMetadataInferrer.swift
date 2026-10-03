import Foundation

public enum BookMetadataInferrer {
    public static func title(from filename: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return components(from: stem).first ?? stem
    }

    public static func authors(from filename: String) -> String? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let parts = components(from: stem)
        guard parts.count > 1 else { return nil }
        let candidate = parts[1]
        guard !candidate.isEmpty, !candidate.range(of: "^[a-fA-F0-9]{24,}$", options: .regularExpression).isPresent else {
            return nil
        }

        let nameParts = candidate.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if nameParts.count == 2, nameParts.allSatisfy({ !$0.isEmpty }) {
            return "\(nameParts[1]) \(nameParts[0])"
        }
        return candidate
    }

    public static func shouldOverrideEmbeddedMetadata(for format: BookFormat) -> Bool {
        switch format {
        case .txt, .text, .txtz, .markdown, .md, .textile, .pml, .pmlz:
            return true
        default:
            return false
        }
    }

    private static func components(from stem: String) -> [String] {
        stem.components(separatedBy: " -- ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension Optional {
    var isPresent: Bool { self != nil }
}
