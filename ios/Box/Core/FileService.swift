import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let childCount: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isAudio: Bool { AppConfig.audioExtensions.contains(url.pathExtension.lowercased()) }
}

enum FileService {
    static func list(_ folder: URL) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let items: [FileItem] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDirectory = values.isDirectory ?? false
            let childCount = isDirectory
                ? ((try? fm.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0)
                : 0

            return FileItem(
                url: url,
                isDirectory: isDirectory,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? Date.distantPast,
                childCount: childCount
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Bir klasördeki tüm alt klasörler (taşıma hedefi seçmek için).
    static func folders(in root: URL) -> [URL] {
        var result: [URL] = [root]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.append(url)
            }
        }

        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? "Adsız" : trimmed
    }

    static func uniqueURL(for fileName: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2

        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }

        return candidate
    }

    static func createFolder(named name: String, in parent: URL) throws -> URL {
        let url = uniqueURL(for: sanitize(name), in: parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        var name = sanitize(newName)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if !isDirectory, !url.pathExtension.isEmpty, (name as NSString).pathExtension.lowercased() != url.pathExtension.lowercased() {
            name += "." + url.pathExtension
        }

        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        if destination == url { return url }

        let target = FileManager.default.fileExists(atPath: destination.path)
            ? uniqueURL(for: name, in: url.deletingLastPathComponent())
            : destination

        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func move(_ url: URL, to folder: URL) throws -> URL {
        let destination = uniqueURL(for: url.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
