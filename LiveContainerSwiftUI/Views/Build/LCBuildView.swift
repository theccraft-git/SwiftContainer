import SwiftUI
import UniformTypeIdentifiers

extension NSNotification {
    static let SwiftContainerAddSource = Notification.Name("SwiftContainerAddSource")
    static let SwiftContainerOpenPackage = Notification.Name("SwiftContainerOpenPackage")
}

@MainActor
final class CloudBuildSession: ObservableObject {
    @Published var login: String?
    @Published var package: PlaygroundPackage?
    @Published var status = "Import an exported Swift Playgrounds .swiftpm package."
    @Published var isBusy = false
    @Published var deviceFlow: DeviceCode?
    @Published var billingText: String?
    @Published var repositoryURL: URL?
    @Published var sourceLink: String?
    @Published var runURL: URL?
    @Published var clientID = GitHubAccount.clientID
    @Published var tokenDraft = ""
    @Published var hasCertificate = false

    private let repositoryKey = "SwiftContainerRepositories"
    private var signInTask: Task<Void, Never>?

    func onAppear() {
        hasCertificate = LCSharedUtils.certificatePassword() != nil
        clientID = GitHubAccount.clientID
        guard GitHubAccount.token() != nil else { return }
        Task { await refreshAccount() }
    }

    func refreshAccount() async {
        guard let token = GitHubAccount.token() else {
            login = nil
            billingText = nil
            return
        }
        do {
            let client = GitHubCloudClient(token: token)
            let user = try await client.currentUser()
            login = user.login
            if let billing = try? await client.actionsBilling(for: user.login) {
                let remaining = max(billing.includedMinutes - billing.totalMinutesUsed, 0)
                billingText = "GitHub reports \(billing.minutesUsedBreakdown.macos) macOS minutes used. About \(remaining) included minutes remain this month. macOS runners count 10×, so a free account usually covers 15 to 20 builds."
            } else {
                billingText = "Free GitHub accounts include 2,000 Action minutes a month. macOS runners count 10×, so that is usually 15 to 20 full builds."
            }
        } catch {
            login = nil
            status = error.localizedDescription
        }
    }

    func startDeviceSignIn() {
        GitHubAccount.clientID = clientID
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            status = "Enter the client ID of a GitHub OAuth app with device flow enabled, or paste a token instead."
            return
        }
        signInTask?.cancel()
        signInTask = Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let client = GitHubCloudClient(token: "")
                let flow = try await client.startDeviceFlow(clientID: trimmedID)
                deviceFlow = flow
                UIPasteboard.general.string = flow.userCode
                status = "Enter \(flow.userCode) on GitHub. The code is copied."
                let token = try await client.pollDeviceToken(clientID: trimmedID, deviceCode: flow.deviceCode, interval: flow.interval)
                try GitHubAccount.save(token: token)
                deviceFlow = nil
                status = "GitHub connected."
                await refreshAccount()
            } catch is CancellationError {
                deviceFlow = nil
            } catch {
                deviceFlow = nil
                status = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        deviceFlow = nil
        isBusy = false
    }

    func savePastedToken() async {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try GitHubAccount.save(token: token)
            tokenDraft = ""
            status = "GitHub token saved on this device."
            await refreshAccount()
        } catch {
            status = error.localizedDescription
        }
    }

    func signOut() {
        GitHubAccount.signOut()
        login = nil
        billingText = nil
        status = "Signed out of GitHub. The token was removed from this device."
    }

    func importPackage(from url: URL) {
        do {
            package = try PlaygroundPackageLoader.load(from: url)
            runURL = nil
            if let package {
                status = "\(package.displayName) is ready. \(package.files.count) files will be pushed to a private repository."
                if let saved = savedRepository(for: package.bundleIdentifier) {
                    repositoryURL = URL(string: "https://github.com/\(saved)")
                    sourceLink = "https://raw.githubusercontent.com/\(saved)/main/source.json"
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func buildAndInstall() async {
        guard let token = GitHubAccount.token() else {
            status = "Sign in to GitHub before building. The token needs the repo and workflow scopes."
            return
        }
        guard var package else {
            status = "Import a .swiftpm package first."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let client = GitHubCloudClient(token: token)
            let user = try await client.currentUser()
            login = user.login
            status = "Preparing a private repository…"
            let repo = try await ensureRepository(client: client, user: user.login, package: package)
            package.files["source.json"] = Data(PlaygroundPackageLoader.sourceJSON(name: package.displayName, bundleID: package.bundleIdentifier, owner: user.login, repo: repo.name).utf8)
            self.package = package
            repositoryURL = repo.htmlURL
            sourceLink = "https://raw.githubusercontent.com/\(repo.fullName)/main/source.json"
            status = "Uploading \(package.displayName)…"
            let parent = try await client.branchCommit(repo: repo.fullName, branch: "main")
            _ = try await client.publish(
                files: package.files,
                repo: repo.fullName,
                branch: "main",
                parent: parent,
                message: parent == nil ? "Add Swift Playgrounds project" : "Update Swift Playgrounds project"
            )
            await client.useMainBranch(repo: repo.fullName)
            status = "Starting the macOS build…"
            let started = Date()
            let previous = try? await client.latestRun(repo: repo.fullName)
            try await client.dispatchWorkflow(repo: repo.fullName, branch: "main")
            status = "GitHub Actions is compiling. This usually takes 2 to 5 minutes."
            let run = try await client.waitForRun(repo: repo.fullName, after: started, excluding: previous?.id)
            runURL = run.htmlURL
            guard run.conclusion == "success" else {
                throw CloudBuildError("The cloud build \(run.conclusion ?? "did not succeed"). Open the log: \(run.htmlURL.absoluteString)")
            }
            status = "Downloading the IPA…"
            let ipa = try await client.downloadIPA(repo: repo.fullName, run: run)
            status = "Publishing a private release for the source link…"
            if let assetURL = try? await client.publishRelease(repo: repo.fullName, tag: "build-\(run.runNumber)", ipa: ipa) {
                status = "Release ready at \(assetURL.absoluteString)"
            }
            let ipaURL = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftContainer-\(UUID().uuidString).ipa")
            try ipa.write(to: ipaURL)
            status = hasCertificate
                ? "Signing \(package.displayName) on this device and installing it."
                : "No signing certificate is imported yet. SwiftContainer will still install the app, and you can import a certificate from Settings to sign it."
            DataManager.shared.model.selectedTab = .apps
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": ipaURL])
            }
        } catch is CancellationError {
            status = "Build cancelled."
        } catch {
            status = error.localizedDescription
        }
    }

    func copy(_ value: String?) {
        guard let value else { return }
        UIPasteboard.general.string = value
        status = "Copied."
    }

    func addSourceToLibrary() {
        guard let sourceLink else { return }
        var urls = UserDefaults.standard.array(forKey: "LCAltStoreSourceURLs") as? [String] ?? []
        if !urls.contains(sourceLink) {
            urls.append(sourceLink)
            UserDefaults.standard.set(urls, forKey: "LCAltStoreSourceURLs")
        }
        NotificationCenter.default.post(name: .SwiftContainerAddSource, object: sourceLink)
        status = "Source saved. Open the Sources tab to browse it. A private repository can only be fetched by someone who can access that GitHub repo."
    }

    private func ensureRepository(client: GitHubCloudClient, user: String, package: PlaygroundPackage) async throws -> GitHubRepo {
        if let fullName = savedRepository(for: package.bundleIdentifier) {
            return try await client.repository(fullName: fullName)
        }
        do {
            let created = try await client.createPrivateRepository(named: package.repositoryName)
            remember(fullName: created.fullName, bundleID: package.bundleIdentifier)
            return created
        } catch {
            let existing = "\(user)/\(package.repositoryName)"
            if let repo = try? await client.repository(fullName: existing) {
                remember(fullName: repo.fullName, bundleID: package.bundleIdentifier)
                return repo
            }
            throw error
        }
    }

    private func savedRepository(for bundleID: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: repositoryKey) as? [String: String]
        return map?[bundleID]
    }

    private func remember(fullName: String, bundleID: String) {
        var map = UserDefaults.standard.dictionary(forKey: repositoryKey) as? [String: String] ?? [:]
        map[bundleID] = fullName
        UserDefaults.standard.set(map, forKey: repositoryKey)
    }
}

struct LCBuildView: View {
    @StateObject private var session = CloudBuildSession()
    @State private var choosingPackage = false
    @EnvironmentObject private var sharedModel: SharedModel

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if let login = session.login {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Text(login).foregroundStyle(.secondary)
                        }
                        Button("Sign out", role: .destructive) { session.signOut() }
                    } else {
                        TextField("OAuth app client ID", text: $session.clientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Sign in with GitHub") { session.startDeviceSignIn() }
                            .disabled(session.isBusy)
                        if let flow = session.deviceFlow {
                        HStack {
                            Text("Code")
                            Spacer()
                            Text(flow.userCode).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                            Button("Open GitHub") {
                                UIApplication.shared.open(flow.verificationURI)
                            }
                            Button("Cancel sign-in", role: .cancel) { session.cancelSignIn() }
                        }
                        SecureField("Or paste a token with repo and workflow scopes", text: $session.tokenDraft)
                        Button("Save token") { Task { await session.savePastedToken() } }
                            .disabled(session.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("GitHub")
                } footer: {
                    Text("Code is pushed only to a private repository on your account. SwiftContainer does not send it anywhere else. A personal token needs the repo and workflow scopes.")
                }

                Section {
                    if let package = session.package {
                        HStack {
                            Text("Project")
                            Spacer()
                            Text(package.displayName).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Bundle ID")
                            Spacer()
                            Text(package.bundleIdentifier).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                    Button("Import .swiftpm") { choosingPackage = true }
                        .disabled(session.isBusy)
                    Button("Build and install") { Task { await session.buildAndInstall() } }
                        .disabled(session.isBusy || session.package == nil || session.login == nil)
                } header: {
                    Text("Swift Playgrounds")
                } footer: {
                    Text("SwiftContainer uploads the package, runs xcodebuild on a GitHub-hosted Mac, downloads the IPA, and signs it on this device with the certificate in Settings.")
                }

                Section {
                    HStack {
                        Text("Certificate")
                        Spacer()
                        Text(session.hasCertificate ? "Imported" : "Not imported").foregroundStyle(.secondary)
                    }
                    Button("Open signing settings") {
                        sharedModel.selectedTab = .settings
                    }
                } header: {
                    Text("On-device signing")
                } footer: {
                    Text("Apple ID sign-in stays in the local signer. SwiftContainer uses the certificate already stored for this app and does not upload Apple ID credentials.")
                }

                if session.repositoryURL != nil || session.sourceLink != nil {
                    Section {
                        if let repositoryURL = session.repositoryURL {
                            Button("Copy repository link") { session.copy(repositoryURL.absoluteString) }
                        }
                        if session.sourceLink != nil {
                            Button("Copy AltStore source link") { session.copy(session.sourceLink) }
                            Button("Add source in SwiftContainer") { session.addSourceToLibrary() }
                        }
                        if let runURL = session.runURL {
                            Button("Open build log") { UIApplication.shared.open(runURL) }
                        }
                    } header: {
                        Text("Share")
                    } footer: {
                        Text("Share the private repository with collaborators, or make it public on GitHub before someone else can install from the source link. There is no central SwiftContainer server.")
                    }
                }

                Section {
                    Text(session.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Status")
                }

                if let billingText = session.billingText {
                    Section {
                        Text(billingText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Cloud quota")
                    }
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.large)
            .tint(Color("AccentColor"))
            .fileImporter(isPresented: $choosingPackage, allowedContentTypes: packageTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    session.importPackage(from: url)
                } else if case .failure(let error) = result {
                    session.status = error.localizedDescription
                }
            }
            .onAppear { session.onAppear() }
            .onReceive(NotificationCenter.default.publisher(for: .SwiftContainerOpenPackage)) { note in
                if let url = note.object as? URL {
                    session.importPackage(from: url)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var packageTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        if let swiftpm = UTType(filenameExtension: "swiftpm") {
            types.append(swiftpm)
        }
        if let package = UTType(tag: "swiftpm", tagClass: .filenameExtension, conformingTo: .package) {
            types.append(package)
        }
        return types
    }
}
