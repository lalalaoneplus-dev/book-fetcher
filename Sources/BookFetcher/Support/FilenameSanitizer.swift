import Foundation

public enum FilenameSanitizer {
    public static func sanitize(_ proposedName: String, format: BookFormat) -> String {
        let decoded = proposedName.removingPercentEncoding ?? proposedName
        let leaf = (decoded as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/:\0")
            .union(.controlCharacters)

        let scalars = leaf.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "_" : Character(String(scalar))
        }

        var result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty || result == "." {
            result = "Book-\(UUID().uuidString.prefix(8))"
        }

        if URL(fileURLWithPath: result).pathExtension.isEmpty {
            result += ".\(format.rawValue)"
        }

        if result.count > 180 {
            let ext = URL(fileURLWithPath: result).pathExtension
            let stem = URL(fileURLWithPath: result)
                .deletingPathExtension()
                .lastPathComponent
            result = String(stem.prefix(170)) + "." + ext
        }

        return result
    }

    public static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let original = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else {
            return original
        }

        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = ext.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }
}
