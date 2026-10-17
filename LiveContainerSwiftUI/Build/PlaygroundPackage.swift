import Foundation

struct PlaygroundPackage {
    var folderName: String
    var displayName: String
    var bundleIdentifier: String
    var files: [String: Data]

    var repositoryName: String {
        let raw = displayName.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(raw).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = collapsed.isEmpty ? "app" : String(collapsed.prefix(60))
        return "swiftcontainer-\(suffix)"
    }
}

enum PlaygroundPackageLoader {
    static func load(from url: URL) throws -> PlaygroundPackage {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let root = try packageRoot(from: url)
        let packageSwift = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let displayName = firstMatch(#"\bname:\s*"([^"]+)""#, in: packageSwift) ?? root.lastPathComponent.replacingOccurrences(of: ".swiftpm", with: "")
        let bundleID = firstMatch(#"\bbundleIdentifier:\s*"([^"]+)""#, in: packageSwift) ?? "com.swiftcontainer.\(displayName.filter { $0.isLetter || $0.isNumber })"
        var files: [String: Data] = [:]
        let keys = try fileURLs(in: root)
        if !keys.contains(where: { $0.pathExtension == "swift" && $0.lastPathComponent != "Package.swift" }) {
            throw CloudBuildError("This package has no Swift files to compile.")
        }
        for file in keys {
            var relative = file.path
            if relative.hasPrefix(root.path) {
                relative.removeFirst(root.path.count)
            }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            files[relative] = try Data(contentsOf: file)
        }
        files[".github/workflows/swiftcontainer.yml"] = Data(CloudBuildTemplates.workflow.utf8)
        files["BuildSupport/generate_xcodeproj.py"] = Data(CloudBuildTemplates.projectGenerator.utf8)
        files[".gitignore"] = Data("build/\nSwiftContainerBuild/\n.DS_Store\n".utf8)
        files["source.json"] = Data(sourceJSON(name: displayName, bundleID: bundleID).utf8)
        return PlaygroundPackage(folderName: root.lastPathComponent, displayName: displayName, bundleIdentifier: bundleID, files: files)
    }

    static func sourceJSON(name: String, bundleID: String, owner: String = "OWNER", repo: String = "REPO") -> String {
        let download = "https://github.com/\(owner)/\(repo)/releases/latest/download/App.ipa"
        let payload: [String: Any] = [
            "name": "\(name) — SwiftContainer",
            "identifier": bundleID,
            "subtitle": "Built with SwiftContainer",
            "description": "On-device Swift Playgrounds build shared from a GitHub repository.",
            "tintColor": "#FF5C24",
            "apps": [[
                "name": name,
                "bundleIdentifier": bundleID,
                "developerName": owner,
                "subtitle": "SwiftContainer cloud build",
                "version": "1.0",
                "versionDate": ISO8601DateFormatter.gitHubDay.string(from: Date()),
                "downloadURL": download,
                "localizedDescription": "Compiled with GitHub Actions and installed by SwiftContainer.",
                "tintColor": "#FF5C24"
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func packageRoot(from url: URL) throws -> URL {
        let fileManager = FileManager.default
        if url.pathExtension.lowercased() == "zip" {
            let destination = fileManager.temporaryDirectory.appendingPathComponent("swiftpm-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            guard extract(url.path, destination.path, Progress(totalUnitCount: 100)) == 0 else {
                throw CloudBuildError("SwiftContainer could not open that archive.")
            }
            if let root = findPackageRoot(in: destination) {
                return root
            }
            throw CloudBuildError("The archive does not contain a Swift Playgrounds package.")
        }
        if url.lastPathComponent == "Package.swift" {
            return url.deletingLastPathComponent()
        }
        if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        if let root = findPackageRoot(in: url) {
            return root
        }
        throw CloudBuildError("Choose an exported .swiftpm package, or a zip that contains one.")
    }

    private static func findPackageRoot(in directory: URL) -> URL? {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            return directory
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return children.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
    }

    private static func fileURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CloudBuildError("SwiftContainer could not read the package.")
        }
        var files: [URL] = []
        let blocked = Set([".git", ".build", "build", "SwiftContainerBuild", "BuildSupport"])
        for case let url as URL in enumerator {
            if blocked.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

private extension ISO8601DateFormatter {
    static let gitHubDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
