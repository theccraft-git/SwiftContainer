import Foundation

struct GitHubUser: Decodable {
    let login: String
}

struct GitHubRepo: Decodable {
    let name: String
    let fullName: String
    let htmlURL: URL
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
    }
}

struct GitHubActionsBilling: Decodable {
    let totalMinutesUsed: Int
    let includedMinutes: Int
    let minutesUsedBreakdown: Breakdown

    struct Breakdown: Decodable {
        let macos: Int
        enum CodingKeys: String, CodingKey { case macos = "MACOS" }
    }

    enum CodingKeys: String, CodingKey {
        case totalMinutesUsed = "total_minutes_used"
        case includedMinutes = "included_minutes"
        case minutesUsedBreakdown = "minutes_used_breakdown"
    }
}

final class GitHubCloudClient {
    let token: String
    private let session: URLSession
    private let redirectDelegate = ArtifactRedirectDelegate()

    init(token: String) {
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func currentUser() async throws -> GitHubUser {
        try await send(url: api("user"), method: "GET")
    }

    func actionsBilling(for login: String) async throws -> GitHubActionsBilling {
        try await send(url: api("users/\(login)/settings/billing/actions"), method: "GET")
    }

    func createPrivateRepository(named name: String) async throws -> GitHubRepo {
        let body: [String: Any] = [
            "name": name,
            "private": true,
            "auto_init": false,
            "description": "Private SwiftContainer project. Built on-device from a Swift Playgrounds package."
        ]
        return try await send(url: api("user/repos"), method: "POST", json: body, expected: [201])
    }

    func repository(fullName: String) async throws -> GitHubRepo {
        try await send(url: api("repos/\(fullName)"), method: "GET")
    }

    func branchCommit(repo: String, branch: String) async throws -> String? {
        do {
            let ref: GitRef = try await send(url: api("repos/\(repo)/git/ref/heads/\(branch)"), method: "GET")
            return ref.object.sha
        } catch let error as CloudBuildError where error.message.contains("404") || Self.isEmptyRepository(error) {
            return nil
        }
    }

    func publish(
        files: [String: Data],
        repo: String,
        branch: String,
        parent: String?,
        message: String,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> String {
        if parent == nil {
            return try await publishInitialCommit(files: files, repo: repo, branch: branch, message: message, onProgress: onProgress)
        }
        do {
            return try await publishUpdate(files: files, repo: repo, branch: branch, parent: parent, message: message)
        } catch let error as CloudBuildError where Self.isEmptyRepository(error) {
            return try await publishInitialCommit(files: files, repo: repo, branch: branch, message: message, onProgress: onProgress)
        }
    }

    /// The Git Database API refuses to write blobs, trees, or refs until a repository has its first commit.
    /// The Contents API is the call that creates that commit.
    private func publishInitialCommit(
        files: [String: Data],
        repo: String,
        branch: String,
        message: String,
        onProgress: (@Sendable (Int, Int, String) -> Void)?
    ) async throws -> String {
        let paths = files.keys.sorted { lhs, rhs in
            let lhsWorkflow = lhs.contains(".github/workflows/")
            let rhsWorkflow = rhs.contains(".github/workflows/")
            if lhsWorkflow != rhsWorkflow { return !lhsWorkflow }
            return lhs < rhs
        }
        guard !paths.isEmpty else {
            throw CloudBuildError("The Playgrounds package has no files to upload.")
        }
        var lastSHA = ""
        for (index, path) in paths.enumerated() {
            onProgress?(index + 1, paths.count, path)
            do {
                lastSHA = try await putContents(
                    repo: repo,
                    path: path,
                    data: files[path] ?? Data(),
                    message: index == 0 ? message : "Add \(path)",
                    branch: branch
                )
            } catch {
                if path.contains(".github/workflows/") {
                    throw CloudBuildError("The project files are in the repository, but GitHub rejected the build workflow. Recreate the personal token with the repo and workflow scopes. \(error.localizedDescription)")
                }
                throw error
            }
        }
        return lastSHA
    }

    private func publishUpdate(files: [String: Data], repo: String, branch: String, parent: String?, message: String) async throws -> String {
        guard let parent else {
            throw CloudBuildError("Cannot update a repository that has no commits yet.")
        }
        var tree: [[String: String]] = []
        for path in files.keys.sorted() {
            let data = files[path] ?? Data()
            let sha = try await blobSHA(repo: repo, data: data)
            tree.append(["path": path, "mode": "100644", "type": "blob", "sha": sha])
        }
        let createdTree: GitTree = try await send(url: api("repos/\(repo)/git/trees"), method: "POST", json: ["tree": tree], expected: [201])
        let commit: GitCommit = try await send(
            url: api("repos/\(repo)/git/commits"),
            method: "POST",
            json: ["message": message, "tree": createdTree.sha, "parents": [parent]],
            expected: [201]
        )
        let _: GitRef = try await send(
            url: api("repos/\(repo)/git/refs/heads/\(branch)"),
            method: "PATCH",
            json: ["sha": commit.sha, "force": false],
            expected: [200]
        )
        return commit.sha
    }

    private func putContents(repo: String, path: String, data: Data, message: String, branch: String) async throws -> String {
        let url = api("repos/\(repo)/contents/\(encodeGitPath(path))")
        var body: [String: Any] = [
            "message": message,
            "content": (data.isEmpty ? Data("\n".utf8) : data).base64EncodedString(),
            "branch": branch
        ]
        do {
            let written: ContentWrite = try await send(url: url, method: "PUT", json: body, expected: [200, 201])
            return written.commit.sha
        } catch let error as CloudBuildError where error.message.contains("422") {
            let existing: ContentFile = try await send(url: url, method: "GET")
            body["sha"] = existing.sha
            let written: ContentWrite = try await send(url: url, method: "PUT", json: body, expected: [200, 201])
            return written.commit.sha
        }
    }

    private func encodeGitPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
        }.joined(separator: "/")
    }

    private static func isEmptyRepository(_ error: CloudBuildError) -> Bool {
        error.message.contains("409") && error.message.localizedCaseInsensitiveContains("empty")
    }

    func useMainBranch(repo: String) async {
        _ = try? await sendData(url: api("repos/\(repo)"), method: "PATCH", json: ["default_branch": "main"], expected: [200])
    }

    func dispatchWorkflow(repo: String, branch: String) async throws {
        let url = api("repos/\(repo)/actions/workflows/swiftcontainer.yml/dispatches")
        var lastError: Error?
        for attempt in 0..<8 {
            do {
                try await sendEmpty(url: url, method: "POST", json: ["ref": branch], expected: [204])
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(2 + attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? CloudBuildError("GitHub did not accept the build workflow.")
    }

    func latestRun(repo: String) async throws -> WorkflowRun? {
        let page: WorkflowRuns = try await send(
            url: api("repos/\(repo)/actions/workflows/swiftcontainer.yml/runs?per_page=1"),
            method: "GET"
        )
        return page.workflowRuns.first
    }

    func waitForRun(repo: String, after date: Date, excluding previousID: Int?) async throws -> WorkflowRun {
        let deadline = Date().addingTimeInterval(20 * 60)
        var seen: WorkflowRun?
        while Date() < deadline {
            try Task.checkCancellation()
            if let run = try await latestRun(repo: repo),
               run.id != previousID,
               run.createdAt >= date.addingTimeInterval(-30) {
                seen = run
                if run.status == "completed" {
                    return run
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if let seen {
            throw CloudBuildError("The cloud build is still \(seen.status). Open it on GitHub: \(seen.htmlURL.absoluteString)")
        }
        throw CloudBuildError("GitHub Actions did not start a build.")
    }

    func downloadIPA(repo: String, run: WorkflowRun) async throws -> Data {
        let artifacts: ArtifactList = try await send(url: api("repos/\(repo)/actions/runs/\(run.id)/artifacts"), method: "GET")
        guard let artifact = artifacts.artifacts.first(where: { $0.name == "SwiftContainerIPA" && $0.expired == false }) ?? artifacts.artifacts.first else {
            throw CloudBuildError("The build finished without an IPA artifact. \(run.htmlURL.absoluteString)")
        }
        let zip = try await sendData(url: api("repos/\(repo)/actions/artifacts/\(artifact.id)/zip"), method: "GET")
        return try unzipIPA(zip)
    }

    func publishRelease(repo: String, tag: String, ipa: Data) async throws -> URL {
        let release: GitRelease = try await send(
            url: api("repos/\(repo)/releases"),
            method: "POST",
            json: [
                "tag_name": tag,
                "name": "SwiftContainer \(tag)",
                "body": "Unsigned IPA produced by SwiftContainer. SwiftContainer signs it on this device before install.",
                "make_latest": true
            ],
            expected: [201]
        )
        var components = URLComponents(url: URL(string: "https://uploads.github.com/repos/\(repo)/releases/\(release.id)/assets")!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: "App.ipa")]
        let assetData = try await sendData(url: components.url!, method: "POST", body: ipa, contentType: "application/octet-stream", expected: [201])
        let asset = try JSONDecoder().decode(GitAsset.self, from: assetData)
        return asset.browserDownloadURL
    }

    func startDeviceFlow(clientID: String) async throws -> DeviceCode {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "scope": "repo workflow"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data, expected: [200])
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    func pollDeviceToken(clientID: String, deviceCode: String, interval: Int) async throws -> String {
        var wait = max(interval, 5)
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, data: data, expected: [200])
            let payload = try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
            if let token = payload.accessToken {
                return token
            }
            switch payload.error {
            case "authorization_pending":
                continue
            case "slow_down":
                wait += 5
            case "expired_token":
                throw CloudBuildError("The GitHub sign-in code expired. Start again.")
            case "access_denied":
                throw CloudBuildError("GitHub sign-in was cancelled.")
            default:
                throw CloudBuildError(payload.errorDescription ?? payload.error ?? "GitHub sign-in failed.")
            }
        }
        throw CloudBuildError("GitHub sign-in timed out.")
    }

    private func blobSHA(repo: String, data: Data) async throws -> String {
        let encoding: String
        let content: String
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            encoding = "utf-8"
            content = text
        } else {
            encoding = "base64"
            content = data.base64EncodedString()
        }
        let blob: GitBlob = try await send(
            url: api("repos/\(repo)/git/blobs"),
            method: "POST",
            json: ["content": content, "encoding": encoding],
            expected: [201]
        )
        return blob.sha
    }

    private func unzipIPA(_ zip: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftcontainer-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zipURL = directory.appendingPathComponent("artifact.zip")
        try zip.write(to: zipURL)
        let progress = Progress(totalUnitCount: 100)
        guard extract(zipURL.path, directory.path, progress) == 0 else {
            throw CloudBuildError("The build artifact could not be unpacked.")
        }
        guard let ipa = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.pathExtension.lowercased() == "ipa" }) else {
            throw CloudBuildError("The build artifact did not contain an IPA.")
        }
        return try Data(contentsOf: ipa)
    }

    private func api(_ path: String) -> URL {
        URL(string: "https://api.github.com/\(path)")!
    }

    private func send<T: Decodable>(url: URL, method: String, json: [String: Any]? = nil, expected: Set<Int> = [200]) async throws -> T {
        let data = try await sendData(url: url, method: method, json: json, expected: expected)
        if T.self == EmptyJSON.self {
            return EmptyJSON() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudBuildError("GitHub returned a response SwiftContainer could not read.")
        }
    }

    private func sendEmpty(url: URL, method: String, json: [String: Any]? = nil, expected: Set<Int>) async throws {
        _ = try await sendData(url: url, method: method, json: json, expected: expected)
    }

    private func sendData(url: URL, method: String, json: [String: Any]? = nil, body: Data? = nil, contentType: String? = nil, expected: Set<Int> = [200]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SwiftContainer", forHTTPHeaderField: "User-Agent")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data, expected: expected)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data, expected: Set<Int>) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard expected.contains(status) else {
            let message = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message) ?? "GitHub request failed (\(status))."
            throw CloudBuildError("\(message) [\(status)]")
        }
    }
}

private struct EmptyJSON: Decodable {}
private struct GitHubMessage: Decodable { let message: String }
private struct GitBlob: Decodable { let sha: String }
private struct GitTree: Decodable { let sha: String }
private struct GitCommit: Decodable { let sha: String }
private struct ContentFile: Decodable { let sha: String }
private struct ContentWrite: Decodable {
    struct Commit: Decodable { let sha: String }
    let commit: Commit
}
private struct GitRef: Decodable {
    let object: Object
    struct Object: Decodable { let sha: String }
}
private struct WorkflowRuns: Decodable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}
struct WorkflowRun: Decodable {
    let id: Int
    let status: String
    let conclusion: String?
    let htmlURL: URL
    let createdAt: Date
    let runNumber: Int

    enum CodingKeys: String, CodingKey {
        case id, status, conclusion
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case runNumber = "run_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        runNumber = try container.decode(Int.self, forKey: .runNumber)
        let rawDate = try container.decode(String.self, forKey: .createdAt)
        guard let date = ISO8601DateFormatter.gitHub.date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: rawDate)
        }
        createdAt = date
    }
}
private struct ArtifactList: Decodable { let artifacts: [Artifact] }
private struct Artifact: Decodable {
    let name: String
    let id: Int
    let expired: Bool
}
private struct GitRelease: Decodable { let id: Int }
private struct GitAsset: Decodable {
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey { case browserDownloadURL = "browser_download_url" }
}

struct DeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try container.decode(String.self, forKey: .deviceCode)
        userCode = try container.decode(String.self, forKey: .userCode)
        verificationURI = try container.decode(URL.self, forKey: .verificationURI)
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5
    }
}

private struct DeviceTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

private extension ISO8601DateFormatter {
    static let gitHub: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class ArtifactRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}
