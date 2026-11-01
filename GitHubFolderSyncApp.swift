import AppKit
import Security
import SwiftUI

@main
struct GitHubFolderSyncApp: App {
    @NSApplicationDelegateAdaptor(FolderSyncApplicationDelegate.self) private var appDelegate
    @StateObject private var model = FolderSyncModel()

    var body: some Scene {
        WindowGroup("Github Manager") {
            FolderSyncView(model: model)
                .frame(minWidth: 980, minHeight: 800)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 900)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Quit Github Manager") {
                    model.requestQuit()
                }
                .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
private final class FolderSyncApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}

@MainActor
private final class FolderSyncModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var files: [SyncFile] = []
    @Published var selectedPaths = Set<String>()
    @Published var repositories: [GitHubRepository] = []
    @Published var selectedRepository = ""
    @Published var repositorySearch = ""
    @Published var repositoryError: String?
    @Published var isLoadingRepositories = false
    @Published var accountName: String?
    @Published var commitMessage = "Sync selected files"
    @Published var status = "Choose a local folder to get started."
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var showingConnection = false
    @Published var showingRepositoryCreation = false
    @Published var showingFileDeletion = false
    @Published var showingVisibilityConfirmation = false
    @Published var pendingVisibilityRepository: GitHubRepository?
    @Published var isCreatingRepository = false
    @Published var downloadProgress = ""
    @Published var activityLogs: [ActivityLogEntry] = []

    private var token: String?
    private var hasScopedAccess = false
    private let maximumActivityEntries = 200

    var currentRepository: GitHubRepository? {
        repositories.first { $0.fullName == selectedRepository }
    }

    var filteredRepositories: [GitHubRepository] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to sync"
        panel.message = "Files in this folder will be available for selection."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if hasScopedAccess { folderURL?.stopAccessingSecurityScopedResource() }
        hasScopedAccess = url.startAccessingSecurityScopedResource()
        folderURL = url
        selectedPaths.removeAll()
        do {
            files = try Self.scanFiles(in: url)
            status = "Found \(files.count) file(s) in \(url.lastPathComponent)."
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ file: SyncFile, selected: Bool) {
        if selected {
            selectedPaths.insert(file.relativePath)
        } else {
            selectedPaths.remove(file.relativePath)
        }
    }

    func selectAll() {
        selectedPaths = Set(files.map(\.relativePath))
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }

    func connect(oauthToken: String) async throws {
        isLoadingRepositories = true
        defer { isLoadingRepositories = false }
        let user: GitHubUser = try await GitHubAPI.get("user", token: oauthToken)
        let repos = try await GitHubAPI.allRepositories(token: oauthToken)
        try GitHubTokenStore.save(oauthToken)
        token = oauthToken
        accountName = user.login
        repositories = repos.sorted {
            $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
        repositorySearch = ""
        repositoryError = nil
        if !repositories.contains(where: { $0.fullName == selectedRepository }) {
            selectedRepository = repositories.first?.fullName ?? ""
        }
        status = "Connected as @\(user.login)."
    }

    func reconnect() async {
        guard let token else { return }
        isLoadingRepositories = true
        repositoryError = nil
        defer { isLoadingRepositories = false }
        do {
            let user: GitHubUser = try await GitHubAPI.get("user", token: token)
            let repos = try await GitHubAPI.allRepositories(token: token)
            accountName = user.login
            repositories = repos.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
            if !repositories.contains(where: { $0.fullName == selectedRepository }) {
                selectedRepository = repositories.first?.fullName ?? ""
            }
            repositoryError = nil
            status = "Connected as @\(user.login)."
        } catch {
            repositoryError = error.localizedDescription
            status = "Could not load GitHub repositories."
        }
    }

    func refreshRepositories() {
        guard !isLoadingRepositories else { return }
        Task { await reconnect() }
    }

    func signOut() {
        guard !isBusy, !isLoadingRepositories else { return }
        do {
            try GitHubTokenStore.delete()
            let signedOutAccount = accountName
            token = nil
            accountName = nil
            repositories = []
            selectedRepository = ""
            repositorySearch = ""
            repositoryError = nil
            pendingVisibilityRepository = nil
            showingVisibilityConfirmation = false
            showingRepositoryCreation = false
            showingFileDeletion = false
            showingConnection = false
            status = signedOutAccount.map { "Signed out of @\($0). Older app credentials may still require GitHub revocation." }
                ?? "Signed out. Older app credentials may still require GitHub revocation."
            logActivity("Signed out locally. Revoke authorization in GitHub settings to invalidate credentials from older app versions.")
        } catch {
            let message = "Could not sign out because the saved GitHub authorization could not be removed from Keychain. \(error.localizedDescription)"
            status = "Sign out failed."
            repositoryError = message
            errorMessage = message
            logActivity("Sign out failed: \(error.localizedDescription)", isError: true)
        }
    }

    func requestVisibilityChange() {
        guard let repository = currentRepository else { return }
        pendingVisibilityRepository = repository
        showingVisibilityConfirmation = true
    }

    func changeVisibility(for repository: GitHubRepository, makePrivate: Bool) async {
        guard !isBusy else { return }
        guard let token else {
            reportOperationError("Visibility was not changed: Authorize GitHub before changing repository settings.")
            return
        }

        let targetVisibility = makePrivate ? "private" : "public"
        isBusy = true
        status = "Changing \(repository.fullName) to \(targetVisibility)…"
        logActivity("Changing \(repository.fullName) visibility to \(targetVisibility)…")
        defer { isBusy = false }
        do {
            let updatedRepository = try await GitHubAPI.updateVisibility(
                of: repository,
                makePrivate: makePrivate,
                token: token
            )
            if let index = repositories.firstIndex(where: { $0.fullName == repository.fullName }) {
                repositories[index] = updatedRepository
            } else {
                repositories.append(updatedRepository)
            }
            selectedRepository = updatedRepository.fullName
            repositoryError = nil
            status = "Changed \(repository.fullName) to \(targetVisibility)."
            logActivity("Visibility updated: \(repository.fullName) is now \(targetVisibility).")
        } catch {
            status = "Could not change \(repository.fullName) visibility."
            repositoryError = error.localizedDescription
            logActivity(
                "Visibility change failed for \(repository.fullName): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func createRepository(name: String, description: String, isPrivate: Bool) async throws -> GitHubRepository {
        guard let token, accountName != nil else {
            throw FolderSyncError.api("Connect a GitHub account before creating a repository.")
        }
        guard !isCreatingRepository else {
            throw FolderSyncError.api("A repository is already being created.")
        }

        isCreatingRepository = true
        defer { isCreatingRepository = false }
        let visibility = isPrivate ? "private" : "public"
        status = "Creating \(visibility) repository…"
        logActivity("Creating \(visibility) repository \(name)…")
        do {
            let repository = try await GitHubAPI.createRepository(
                name: name,
                description: description,
                isPrivate: isPrivate,
                token: token
            )
            repositories.removeAll { $0.fullName == repository.fullName }
            repositories.append(repository)
            repositories.sort {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
            selectedRepository = repository.fullName
            repositorySearch = ""
            repositoryError = nil
            status = "Created \(visibility) repository \(repository.fullName)."
            logActivity("Created \(visibility) repository \(repository.fullName).")
            return repository
        } catch {
            status = "Could not create repository."
            repositoryError = error.localizedDescription
            logActivity("Repository creation failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    func restoreSavedAuthorization() async {
        do {
            token = try await Task.detached(priority: .utility) {
                try GitHubTokenStore.load()
            }.value
            if token != nil {
                await reconnect()
            }
        } catch {
            errorMessage = error.localizedDescription
            repositoryError = error.localizedDescription
        }
    }

    func requestQuit() {
        guard showingConnection else {
            NSApplication.shared.terminate(nil)
            return
        }
        showingConnection = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApplication.shared.terminate(nil)
        }
    }

    func logActivity(_ message: String, isError: Bool = false) {
        activityLogs.append(ActivityLogEntry(message: message, isError: isError))
        if activityLogs.count > maximumActivityEntries {
            activityLogs.removeFirst(activityLogs.count - maximumActivityEntries)
        }
    }

    private func reportOperationError(_ message: String) {
        logActivity(message, isError: true)
        errorMessage = message
    }

    func upload() {
        guard !isBusy else { return }
        guard folderURL != nil else {
            reportOperationError("Upload not started: Choose a local folder before uploading.")
            return
        }
        guard let token else {
            logActivity("Upload not started: Authorize GitHub before uploading.")
            showingConnection = true
            return
        }
        guard let repository = currentRepository else {
            reportOperationError("Upload not started: Choose a GitHub repository before uploading.")
            return
        }
        let chosenFiles = files.filter { selectedPaths.contains($0.relativePath) }
        guard !chosenFiles.isEmpty else {
            reportOperationError("Upload not started: Select at least one file to upload.")
            return
        }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            reportOperationError("Upload not started: Enter a commit message.")
            return
        }

        isBusy = true
        status = "Uploading \(chosenFiles.count) file(s)…"
        logActivity("Starting upload to \(repository.fullName): \(chosenFiles.count) file(s).")
        Task {
            do {
                let sha = try await GitHubAPI.commit(
                    chosenFiles,
                    repository: repository,
                    message: message,
                    token: token
                ) { message in
                    self.logActivity(message)
                }
                status = "Committed \(chosenFiles.count) file(s) to \(repository.fullName) (\(sha.prefix(7)))."
                logActivity("Upload complete: \(chosenFiles.count) file(s) committed to \(repository.fullName) (\(sha.prefix(7))).")
            } catch {
                status = "Upload failed."
                logActivity("Upload failed: \(error.localizedDescription)", isError: true)
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    func downloadRepository() {
        guard !isBusy else { return }
        guard let folderURL else {
            reportOperationError("Download not started: Choose a local folder as the destination.")
            return
        }
        guard let token else {
            logActivity("Download not started: Authorize GitHub before downloading.")
            showingConnection = true
            return
        }
        guard let repository = currentRepository else {
            reportOperationError("Download not started: Choose a GitHub repository before downloading.")
            return
        }

        isBusy = true
        downloadProgress = ""
        status = "Reading \(repository.fullName)…"
        logActivity("Starting download from \(repository.fullName) to \(folderURL.path).")
        Task {
            do {
                let count = try await GitHubAPI.download(
                    repository,
                    into: folderURL,
                    token: token
                ) { path, completed, total in
                    self.downloadProgress = "\(completed) / \(total)"
                    self.status = "Downloading \(repository.fullName)… \(completed) / \(total): \(path)"
                    self.logActivity("Downloaded \(completed)/\(total): \(path)")
                }
                files = try Self.scanFiles(in: folderURL)
                selectedPaths.removeAll()
                status = "Downloaded \(count) file(s) from \(repository.fullName) to \(folderURL.lastPathComponent)."
                logActivity("Download complete: \(count) file(s) from \(repository.fullName) to \(folderURL.path).")
            } catch {
                status = "Download failed."
                logActivity("Download failed: \(error.localizedDescription)", isError: true)
                errorMessage = error.localizedDescription
            }
            downloadProgress = ""
            isBusy = false
        }
    }

    func repositoryBranches(for repository: GitHubRepository) async throws -> [GitHubBranch] {
        guard let token else {
            throw FolderSyncError.api("Authorize GitHub before browsing repository files.")
        }
        return try await GitHubAPI.branches(for: repository, token: token)
    }

    func repositoryFiles(
        in repository: GitHubRepository,
        branch: String
    ) async throws -> [GitHubFile] {
        guard let token else {
            throw FolderSyncError.api("Authorize GitHub before browsing repository files.")
        }
        return try await GitHubAPI.files(in: repository, branch: branch, token: token)
    }

    func deleteFiles(
        _ files: [GitHubFile],
        from repository: GitHubRepository,
        branch: String
    ) async throws {
        guard !isBusy else {
            throw FolderSyncError.api("Another GitHub operation is already in progress.")
        }
        guard let token else {
            throw FolderSyncError.api("Authorize GitHub before deleting repository files.")
        }
        guard !files.isEmpty else {
            throw FolderSyncError.api("Select at least one repository file to delete.")
        }

        isBusy = true
        defer { isBusy = false }
        status = "Deleting \(files.count) file(s) from \(repository.fullName)…"
        logActivity("Starting deletion from \(repository.fullName) (\(branch)): \(files.count) file(s).")
        var deletedCount = 0
        var failures: [String] = []
        for (index, file) in files.enumerated() {
            do {
                let commitSHA = try await GitHubAPI.deleteFile(
                    file,
                    from: repository,
                    branch: branch,
                    token: token
                )
                deletedCount += 1
                logActivity("Deleted \(index + 1)/\(files.count): \(file.path) (commit \(commitSHA.prefix(7))).")
            } catch FolderSyncError.resourceNotFound {
                let detail = "GitHub could not find or authorize deletion of this path on branch \(branch) (HTTP 404). It may have changed, the branch may be wrong, or write access may be missing. Refresh and verify repository permissions."
                failures.append("\(file.path): \(detail)")
                logActivity("Delete failed for \(file.path): \(detail)", isError: true)
            } catch FolderSyncError.apiResponse(let statusCode, let message)
                where statusCode == 409 || statusCode == 422 {
                let detail = "GitHub rejected the saved file SHA (HTTP \(statusCode)); the file may have changed. Refresh and review it again. \(message)"
                failures.append("\(file.path): \(detail)")
                logActivity("Delete failed for \(file.path): \(detail)", isError: true)
            } catch {
                failures.append("\(file.path): \(error.localizedDescription)")
                logActivity("Delete failed for \(file.path): \(error.localizedDescription)", isError: true)
            }
        }

        if failures.isEmpty {
            status = "Deleted \(deletedCount) file(s) from \(repository.fullName) (\(branch))."
            logActivity("Deletion complete: \(deletedCount) file(s) deleted from \(repository.fullName) (\(branch)).")
            return
        }
        status = "Deleted \(deletedCount) of \(files.count) file(s) from \(repository.fullName); some files failed."
        let summary = "Deleted \(deletedCount) of \(files.count) file(s). Failed paths: "
            + failures.joined(separator: " ")
        logActivity("Deletion partially completed: \(summary)", isError: true)
        throw FolderSyncError.api(summary)
    }

    private static func scanFiles(in folder: URL) throws -> [SyncFile] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw FolderSyncError.folderUnreadable
        }

        var result: [SyncFile] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relativePath = String(url.path.dropFirst(folder.path.count + 1))
            result.append(SyncFile(url: url, relativePath: relativePath))
        }
        return result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}

private struct SyncFile: Identifiable {
    let url: URL
    let relativePath: String
    var id: String { relativePath }
}

private struct ActivityLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date.now
    let message: String
    let isError: Bool
}

private struct GitHubUser: Decodable {
    let login: String
}

private struct GitHubRepository: Decodable, Identifiable {
    let fullName: String
    let `private`: Bool
    let defaultBranch: String
    var id: String { fullName }
}

private struct GitObject: Decodable {
    let sha: String
}

private struct GitReference: Decodable {
    let object: GitObject
}

private struct GitCommit: Decodable {
    let tree: GitObject
}

private struct GitBlob: Decodable {
    let sha: String
}

private struct CreatedGitCommit: Decodable {
    let sha: String
}

private struct GitTree: Decodable {
    let sha: String
}

private struct GitTreeEntry: Codable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?
}

private struct GitTreeResponse: Decodable {
    let tree: [GitTreeEntry]
    let truncated: Bool
}

private struct GitHubBranch: Decodable, Identifiable {
    let name: String
    var id: String { name }
}

private struct GitHubFile: Identifiable {
    let path: String
    let sha: String
    var id: String { path }
}

private struct GitBlobContent: Decodable {
    let content: String
    let encoding: String
}

private struct CreateBlob: Encodable {
    let content: String
    let encoding: String
}

private struct CreateRepositoryPayload: Encodable {
    let name: String
    let description: String
    let isPrivate: Bool
    let autoInit = true

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case isPrivate = "private"
        case autoInit = "auto_init"
    }
}

private struct UpdateRepositoryVisibility: Encodable {
    let `private`: Bool
}

private struct CreateContentFile: Encodable {
    let message: String
    let content: String
    let branch: String
}

private struct ContentFileCommitResponse: Decodable {
    let commit: CreatedGitCommit
}

private struct DeleteContentFileResponse: Decodable {
    let commit: CreatedGitCommit
}

private struct DeleteContentFile: Encodable {
    let message: String
    let sha: String
    let branch: String
}

private struct CreateTree: Encodable {
    let baseTree: String
    let tree: [GitTreeEntry]
}

private struct CreateCommit: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct UpdateReference: Encodable {
    let sha: String
    let force: Bool
}

private struct GitHubErrorResponse: Decodable {
    let message: String
}

private struct DeviceAuthorizationCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: URL
    let expiresIn: Int
    let interval: Int
}

private struct DeviceTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?
}

private enum GitHubAPI {
    static func get<Response: Decodable>(_ endpoint: String, token: String) async throws -> Response {
        try await send(endpoint, token: token, method: "GET", body: nil as String?)
    }

    static func allRepositories(token: String) async throws -> [GitHubRepository] {
        var page = 1
        var repositories: [GitHubRepository] = []
        while true {
            let currentPage: [GitHubRepository] = try await get(
                "user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100&page=\(page)",
                token: token
            )
            repositories.append(contentsOf: currentPage)
            guard currentPage.count == 100 else { return repositories }
            page += 1
        }
    }

    static func createRepository(
        name: String,
        description: String,
        isPrivate: Bool,
        token: String
    ) async throws -> GitHubRepository {
        try await send(
            "user/repos",
            token: token,
            method: "POST",
            body: CreateRepositoryPayload(name: name, description: description, isPrivate: isPrivate)
        )
    }

    static func updateVisibility(
        of repository: GitHubRepository,
        makePrivate: Bool,
        token: String
    ) async throws -> GitHubRepository {
        try await send(
            "repos/\(repository.fullName)",
            token: token,
            method: "PATCH",
            body: UpdateRepositoryVisibility(private: makePrivate)
        )
    }

    static func branches(for repository: GitHubRepository, token: String) async throws -> [GitHubBranch] {
        var page = 1
        var branches: [GitHubBranch] = []
        while true {
            let currentPage: [GitHubBranch] = try await get(
                "repos/\(repository.fullName)/branches?per_page=100&page=\(page)",
                token: token
            )
            branches.append(contentsOf: currentPage)
            guard currentPage.count == 100 else { return branches }
            page += 1
        }
    }

    static func files(
        in repository: GitHubRepository,
        branch branchName: String,
        token: String
    ) async throws -> [GitHubFile] {
        let encodedBranch = branchName.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        ) ?? branchName
        let reference: GitReference = try await get(
            "repos/\(repository.fullName)/git/ref/heads/\(encodedBranch)",
            token: token
        )
        let tree: GitTreeResponse = try await get(
            "repos/\(repository.fullName)/git/trees/\(reference.object.sha)?recursive=1",
            token: token
        )
        guard !tree.truncated else {
            throw FolderSyncError.api("This repository tree is too large to browse in one request. Try a smaller repository.")
        }
        return try tree.tree
            .filter { $0.type == "blob" }
            .map { entry in
                try validateRepositoryPath(entry.path)
                return GitHubFile(path: entry.path, sha: entry.sha)
            }
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
    }

    static func deleteFile(
        _ file: GitHubFile,
        from repository: GitHubRepository,
        branch: String,
        token: String
    ) async throws -> String {
        let encodedPath = try encodedContentPath(file.path)
        let result: DeleteContentFileResponse = try await send(
            "repos/\(repository.fullName)/contents/\(encodedPath)",
            token: token,
            method: "DELETE",
            body: DeleteContentFile(
                message: "Delete \(file.path)",
                sha: file.sha,
                branch: branch
            )
        )
        return result.commit.sha
    }

    static func requestDeviceAuthorization(clientID: String) async throws -> DeviceAuthorizationCode {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientID,
            "scope": "repo read:user"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateOAuthResponse(data, response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let oauthError = try? decoder.decode(DeviceTokenResponse.self, from: data),
           let error = oauthError.error {
            throw FolderSyncError.oauth(oauthError.errorDescription ?? "GitHub authorization request failed: \(error)")
        }
        do {
            return try decoder.decode(DeviceAuthorizationCode.self, from: data)
        } catch {
            throw FolderSyncError.invalidResponse
        }
    }

    static func waitForDeviceAuthorization(
        _ authorization: DeviceAuthorizationCode,
        clientID: String,
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var interval = max(authorization.interval, 5)
        let attempts = max(1, authorization.expiresIn / interval)
        for _ in 0..<attempts {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            let result: DeviceTokenResponse
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                result = try decoder.decode(DeviceTokenResponse.self, from: data)
            } catch {
                try validateOAuthResponse(data, response)
                throw FolderSyncError.invalidResponse
            }
            if let accessToken = result.accessToken { return accessToken }
            switch result.error {
            case "authorization_pending":
                await onStatus("Waiting for GitHub authorization…")
            case "slow_down":
                interval += 5
                await onStatus("Waiting for GitHub authorization…")
            case "access_denied":
                throw FolderSyncError.oauth("GitHub authorization was denied.")
            case "expired_token":
                throw FolderSyncError.oauth("The device code expired. Start authorization again.")
            default:
                throw FolderSyncError.oauth(result.errorDescription ?? "GitHub authorization failed.")
            }
        }
        throw FolderSyncError.oauth("The device code expired. Start authorization again.")
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func validateOAuthResponse(_ data: Data, _ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw FolderSyncError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let oauthError = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data)
            throw FolderSyncError.oauth(oauthError?.errorDescription ?? "GitHub returned HTTP \(response.statusCode).")
        }
    }

    fileprivate static func send<Response: Decodable, Body: Encodable>(
        _ endpoint: String,
        token: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else {
            throw FolderSyncError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let authorizationValue = ["Bearer", token].joined(separator: " ")
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FolderSyncError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data).message
            if response.statusCode == 401 {
                throw FolderSyncError.api("GitHub rejected the token. Check its validity and permissions.")
            }
            if response.statusCode == 404 {
                throw FolderSyncError.resourceNotFound
            }
            if response.statusCode == 409,
               message?.localizedCaseInsensitiveContains("git repository is empty") == true {
                throw FolderSyncError.emptyRepository
            }
            throw FolderSyncError.apiResponse(
                response.statusCode,
                message ?? "GitHub returned HTTP \(response.statusCode)."
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw FolderSyncError.invalidResponse
        }
    }

    static func commit(
        _ files: [SyncFile],
        repository: GitHubRepository,
        message: String,
        token: String,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard !files.isEmpty else {
            throw FolderSyncError.api("Select at least one file to upload.")
        }
        for file in files {
            let fileSize = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= 100 * 1024 * 1024 else {
                throw FolderSyncError.fileTooLarge(file.relativePath)
            }
        }

        let repo = repository.fullName
        let branchName = repository.defaultBranch.isEmpty ? "main" : repository.defaultBranch
        let branch = branchName.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        ) ?? branchName
        let reference: GitReference?
        do {
            reference = try await get(
                "repos/\(repo)/git/ref/heads/\(branch)",
                token: token
            )
        } catch FolderSyncError.resourceNotFound {
            reference = nil
        } catch FolderSyncError.emptyRepository {
            reference = nil
        }
        let parentSHA: String
        let parent: GitCommit
        let filesToCommit: [SyncFile]
        let progressOffset: Int
        if let reference {
            parentSHA = reference.object.sha
            parent = try await get("repos/\(repo)/git/commits/\(parentSHA)", token: token)
            filesToCommit = files
            progressOffset = 0
        } else {
            guard let firstFile = files.first else {
                throw FolderSyncError.api("Select at least one file to upload.")
            }
            let data = try Data(contentsOf: firstFile.url)
            guard data.count <= 100 * 1024 * 1024 else {
                throw FolderSyncError.fileTooLarge(firstFile.relativePath)
            }
            let encodedPath = try encodedContentPath(firstFile.relativePath)
            await progress("Initializing empty repository \(repository.fullName) with \(firstFile.relativePath)…")
            let initialCommit: ContentFileCommitResponse = try await send(
                "repos/\(repo)/contents/\(encodedPath)",
                token: token,
                method: "PUT",
                body: CreateContentFile(
                    message: "Initial upload: \(message)",
                    content: data.base64EncodedString(),
                    branch: branchName
                )
            )
            parentSHA = initialCommit.commit.sha
            parent = try await get("repos/\(repo)/git/commits/\(parentSHA)", token: token)
            filesToCommit = Array(files.dropFirst())
            progressOffset = 1
            await progress("Created initial commit with \(firstFile.relativePath).")
            if filesToCommit.isEmpty {
                await progress("Published initial commit \(parentSHA.prefix(7)) to \(repository.fullName).")
                return parentSHA
            }
        }

        var treeEntries: [GitTreeEntry] = []
        for (index, file) in filesToCommit.enumerated() {
            let data = try Data(contentsOf: file.url)
            guard data.count <= 100 * 1024 * 1024 else {
                throw FolderSyncError.fileTooLarge(file.relativePath)
            }
            let blob: GitBlob = try await send(
                "repos/\(repo)/git/blobs",
                token: token,
                method: "POST",
                body: CreateBlob(content: data.base64EncodedString(), encoding: "base64")
            )
            treeEntries.append(GitTreeEntry(
                path: file.relativePath,
                mode: "100644",
                type: "blob",
                sha: blob.sha,
                size: data.count
            ))
            await progress("Uploaded blob \(index + progressOffset + 1)/\(files.count): \(file.relativePath)")
        }

        await progress("Creating GitHub commit in \(repository.fullName)…")
        let tree: GitTree = try await send(
            "repos/\(repo)/git/trees",
            token: token,
            method: "POST",
            body: CreateTree(baseTree: parent.tree.sha, tree: treeEntries)
        )
        let commit: CreatedGitCommit = try await send(
            "repos/\(repo)/git/commits",
            token: token,
            method: "POST",
            body: CreateCommit(message: message, tree: tree.sha, parents: [parentSHA])
        )
        let _: GitReference = try await send(
            "repos/\(repo)/git/refs/heads/\(branch)",
            token: token,
            method: "PATCH",
            body: UpdateReference(sha: commit.sha, force: false)
        )
        await progress("Published commit \(commit.sha.prefix(7)) to \(repository.fullName).")
        return commit.sha
    }

    private static func encodedContentPath(_ path: String) throws -> String {
        try validateRepositoryPath(path)
        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let encodedComponents = components.compactMap {
            $0.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
        }
        guard encodedComponents.count == components.count else {
            throw FolderSyncError.invalidResponse
        }
        return encodedComponents.joined(separator: "/")
    }

    private static func validateRepositoryPath(_ path: String) throws {
        guard !path.isEmpty,
              path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FolderSyncError.unsafeRepositoryPath(path)
        }
    }

    static func download(
        _ repository: GitHubRepository,
        into destination: URL,
        token: String,
        progress: @escaping @MainActor (String, Int, Int) -> Void
    ) async throws -> Int {
        let branchName = repository.defaultBranch.isEmpty ? "main" : repository.defaultBranch
        let branch = branchName.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        ) ?? branchName
        let reference: GitReference = try await get(
            "repos/\(repository.fullName)/git/ref/heads/\(branch)",
            token: token
        )
        let tree: GitTreeResponse = try await get(
            "repos/\(repository.fullName)/git/trees/\(reference.object.sha)?recursive=1",
            token: token
        )
        guard !tree.truncated else {
            throw FolderSyncError.api("This repository is too large to download in one request. Clone it with Git instead.")
        }

        let blobs = tree.tree.filter { $0.type == "blob" && $0.mode != "120000" }
        for (index, entry) in blobs.enumerated() {
            guard entry.path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw FolderSyncError.unsafeRepositoryPath(entry.path)
            }
            guard entry.size ?? 0 <= 100 * 1024 * 1024 else {
                throw FolderSyncError.fileTooLarge(entry.path)
            }
            let blob: GitBlobContent = try await get(
                "repos/\(repository.fullName)/git/blobs/\(entry.sha)",
                token: token
            )
            guard blob.encoding == "base64",
                  let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters) else {
                throw FolderSyncError.invalidResponse
            }
            let fileURL = destination.appending(path: entry.path).standardizedFileURL
            guard fileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw FolderSyncError.unsafeRepositoryPath(entry.path)
            }
            try writeDownloadedFile(data, path: entry.path, into: destination)
            await progress(entry.path, index + 1, blobs.count)
        }
        return blobs.count
    }

    private static func writeDownloadedFile(_ data: Data, path: String, into destination: URL) throws {
        var directory = destination
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw FolderSyncError.unsafeRepositoryPath(path)
                }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        let fileURL = directory.appendingPathComponent(components.last ?? "")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FolderSyncError.unsafeRepositoryPath(path)
            }
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum GitHubTokenStore {
    private static let service = "bt.bt.github-manager.oauth"
    private static let account = "personal-access-token"
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return token
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(request as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    static func delete() throws {
        var lookup = query
        lookup[kSecReturnPersistentRef as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &result)
        if lookupStatus == errSecItemNotFound { return }
        guard lookupStatus == errSecSuccess, let persistentReference = result as? Data else {
            throw keychainError(lookupStatus)
        }

        let status = SecItemDelete([
            kSecValuePersistentRef as String: persistentReference
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func keychainError(_ status: OSStatus) -> FolderSyncError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error."
        return .keychain("\(message) (Security error \(status), 0x\(String(UInt32(bitPattern: status), radix: 16))).")
    }
}

private enum FolderSyncError: LocalizedError {
    case folderUnreadable
    case invalidResponse
    case resourceNotFound
    case emptyRepository
    case apiResponse(Int, String)
    case fileTooLarge(String)
    case unsafeRepositoryPath(String)
    case api(String)
    case keychain(String)
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .folderUnreadable:
            return "The selected folder could not be read."
        case .invalidResponse:
            return "GitHub returned a response this app could not understand. Try again."
        case .resourceNotFound:
            return "GitHub could not find the requested resource (HTTP 404)."
        case .emptyRepository:
            return "The repository has no commits yet; creating its initial commit."
        case .apiResponse(let statusCode, let message):
            return "GitHub returned HTTP \(statusCode): \(message)"
        case .fileTooLarge(let path):
            return "\(path) is larger than GitHub's 100 MB file limit."
        case .unsafeRepositoryPath(let path):
            return "The repository contains an unsafe file path and cannot be downloaded: \(path)"
        case .api(let message):
            return message
        case .keychain(let message):
            return "The GitHub credential Keychain operation failed: \(message)"
        case .oauth(let message):
            return message
        }
    }
}

private struct FolderSyncView: View {
    @ObservedObject var model: FolderSyncModel

    var body: some View {
        ZStack {
            WindowBlurBackdrop()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 17) {
                header
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 17) {
                        githubPanel
                        activityPanel
                            .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    folderPanel
                        .frame(width: 320)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WindowTransparencyConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color.clear)
        .font(.custom("Menlo", size: 13))
        .foregroundStyle(Color.black)
        .buttonStyle(GlossyGreenButtonStyle())
        .alert("Github Manager by Namgyal", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showingConnection) {
            GitHubConnectionSheet(
                onConnect: { token in try await model.connect(oauthToken: token) },
                onQuit: model.requestQuit
            )
        }
        .task {
            if model.accountName == nil { await model.restoreSavedAuthorization() }
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.custom("Menlo", size: 24).weight(.bold))
                .foregroundStyle(Color(red: 0.22, green: 0.37, blue: 0.70))
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Github Manager by Namgyal")
                    .font(.custom("Menlo", size: 22).weight(.bold))
                Text("Choose files, review, and sync them in a single commit.")
                    .font(.custom("Menlo", size: 12))
                    .foregroundStyle(.black.opacity(0.72))
            }
            Spacer()
        }
    }

    private var githubPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.custom("Menlo", size: 13).weight(.bold))
                    Spacer()
                    if let account = model.accountName {
                        Label("@\(account)", systemImage: "checkmark.circle.fill")
                            .font(.custom("Menlo", size: 11).weight(.bold))
                            .foregroundStyle(.green)
                    }
                    Button(model.accountName == nil ? "Connect account" : "Change account") {
                        model.showingConnection = true
                    }
                    .buttonStyle(GlossyGreenButtonStyle())
                    if model.accountName != nil {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            model.signOut()
                        }
                        .buttonStyle(GlossyGreenButtonStyle())
                        .disabled(model.isBusy || model.isLoadingRepositories)
                    }
                }
                HStack {
                    Label("Repositories", systemImage: "shippingbox")
                        .font(.custom("Menlo", size: 11).weight(.bold))
                    Spacer()
                    Button("Create repository", systemImage: "plus") {
                        model.showingRepositoryCreation = true
                    }
                    .buttonStyle(GlossyGreenButtonStyle())
                    .disabled(model.accountName == nil || model.isLoadingRepositories || model.isCreatingRepository)
                }
                HStack(spacing: 8) {
                    TextField("Search repositories", text: $model.repositorySearch)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isLoadingRepositories)
                    Button {
                        model.refreshRepositories()
                    } label: {
                        if model.isLoadingRepositories {
                            ProgressView().controlSize(.small).frame(width: 42, height: 24)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 42, height: 24)
                        }
                    }
                    .accessibilityLabel("Refresh repositories")
                    .disabled(model.isLoadingRepositories || model.accountName == nil)
                }
                HStack(spacing: 12) {
                    Picker("Repository", selection: $model.selectedRepository) {
                        if model.isLoadingRepositories && model.repositories.isEmpty {
                            Text("Loading repositories…").tag("")
                        } else if model.repositories.isEmpty {
                            Text(model.accountName == nil ? "Authorize GitHub to load repositories" : "No repositories found").tag("")
                        } else if model.filteredRepositories.isEmpty {
                            Text("No repositories match your search").tag("")
                        }
                        ForEach(model.filteredRepositories) { repository in
                            Text("\(repository.fullName)\(repository.private ? " · Private" : "")")
                                .tag(repository.fullName)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.repositories.isEmpty || model.isBusy || model.isLoadingRepositories)
                    .frame(maxWidth: .infinity)
                    if let repository = model.currentRepository {
                        Text(repository.defaultBranch)
                            .font(.custom("Menlo", size: 11))
                            .foregroundStyle(.black.opacity(0.72))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                if let repository = model.currentRepository {
                    HStack {
                            Label(
                                repository.private ? "Private repository" : "Public repository",
                                systemImage: repository.private ? "lock.fill" : "globe"
                            )
                            .font(.custom("Menlo", size: 10).weight(.bold))
                            .foregroundStyle(repository.private
                                             ? Color.black.opacity(0.72)
                                             : Color(red: 0.62, green: 0.05, blue: 0.04))
                            Spacer()
                            Button(repository.private ? "Make public…" : "Make private…") {
                                model.requestVisibilityChange()
                            }
                            .buttonStyle(GlossyGreenButtonStyle())
                            .disabled(model.isBusy || model.accountName == nil)
                    }
                }
                if let repositoryError = model.repositoryError {
                    Text(repositoryError)
                            .font(.custom("Menlo", size: 10))
                            .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
                            .fixedSize(horizontal: false, vertical: true)
                } else if model.accountName != nil && model.repositories.isEmpty && !model.isLoadingRepositories {
                    Text("No repositories are available for this GitHub account.")
                            .font(.custom("Menlo", size: 10))
                            .foregroundStyle(.black.opacity(0.72))
                }
                Text(model.accountName == nil
                     ? "Connect an account. Revoke older app access in GitHub Settings > Applications."
                     : "GitHub authorization is stored securely in macOS Keychain.")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(.black.opacity(0.72))
                HStack(spacing: 10) {
                    Button {
                        model.downloadRepository()
                    } label: {
                        Label("Download repository", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlossyGreenButtonStyle())
                    .disabled(model.isBusy || model.currentRepository == nil)

                    Button {
                        model.showingFileDeletion = true
                    } label: {
                        Label("Delete files…", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlossyGreenButtonStyle())
                    .disabled(
                        model.isBusy
                            || model.accountName == nil
                            || model.currentRepository == nil
                    )
                }
                Divider()
                uploadPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog(
                visibilityConfirmationTitle,
                isPresented: Binding(
                    get: { model.showingVisibilityConfirmation },
                    set: { isPresented in
                        model.showingVisibilityConfirmation = isPresented
                        if !isPresented { model.pendingVisibilityRepository = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let repository = model.pendingVisibilityRepository {
                    let makePublic = repository.private
                    Button(
                        makePublic ? "Make \(repository.fullName) Public" : "Make \(repository.fullName) Private",
                        role: makePublic ? .destructive : nil
                    ) {
                        Task {
                            await model.changeVisibility(for: repository, makePrivate: !makePublic)
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        model.pendingVisibilityRepository = nil
                    }
                }
            } message: {
                if let repository = model.pendingVisibilityRepository {
                    Text(visibilityConfirmationMessage(for: repository))
                }
            }
        }
        .sheet(isPresented: $model.showingRepositoryCreation) {
            RepositoryCreationSheet { request in
                try await model.createRepository(
                    name: request.name,
                    description: request.description,
                    isPrivate: request.isPrivate
                )
            }
        }
        .sheet(isPresented: $model.showingFileDeletion) {
            if let repository = model.currentRepository {
                DeleteFilesSheet(
                    repository: repository,
                    onLoadBranches: { try await model.repositoryBranches(for: repository) },
                    onLoadFiles: { branch in
                        try await model.repositoryFiles(in: repository, branch: branch)
                    },
                    onDelete: { files, branch in
                        try await model.deleteFiles(files, from: repository, branch: branch)
                    }
                )
            }
        }
    }

    private var visibilityConfirmationTitle: String {
        guard let repository = model.pendingVisibilityRepository else {
            return "Change repository visibility?"
        }
        return "Change \(repository.fullName) visibility?"
    }

    private func visibilityConfirmationMessage(for repository: GitHubRepository) -> String {
        if repository.private {
            return "\(repository.fullName) will become public. Anyone will be able to view its content and commit history. Existing access controls will no longer restrict viewing."
        }
        return "\(repository.fullName) will become private. Public access will be removed, but existing clones, forks, and copies cannot be recalled."
    }

    private var folderPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Local folder", systemImage: "folder")
                        .font(.custom("Menlo", size: 13).weight(.bold))
                    Spacer()
                    Button("Browse…", systemImage: "folder.badge.plus") {
                        model.chooseFolder()
                    }
                    .buttonStyle(GlossyGreenButtonStyle())
                    .disabled(model.isBusy)
                }
                HStack(spacing: 8) {
                    Image(systemName: model.folderURL == nil ? "folder" : "folder.fill")
                        .foregroundStyle(.black.opacity(0.72))
                    Text(model.folderURL?.path ?? "No folder selected")
                        .font(.custom("Menlo", size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if !model.files.isEmpty {
                        Text("\(model.selectedPaths.count) / \(model.files.count) selected")
                            .font(.custom("Menlo", size: 10).weight(.bold))
                            .foregroundStyle(.black.opacity(0.72))
                    }
                }
                HStack {
                    Text("Files").font(.custom("Menlo", size: 11).weight(.bold))
                    Spacer()
                    Button("Select all", action: model.selectAll).disabled(model.files.isEmpty || model.isBusy)
                    Button("Clear", action: model.clearSelection).disabled(model.selectedPaths.isEmpty || model.isBusy)
                }
                .font(.custom("Menlo", size: 10))
                if model.isBusy, !model.downloadProgress.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Downloaded \(model.downloadProgress) files")
                            .font(.custom("Menlo", size: 10))
                            .foregroundStyle(.black.opacity(0.72))
                    }
                }

                if model.files.isEmpty {
                    ContentUnavailableView(
                        model.folderURL == nil ? "Choose a folder" : "No files found",
                        systemImage: "doc.text",
                        description: Text(model.folderURL == nil
                                          ? "Browse to a folder containing the files you want to upload."
                                          : "Hidden files and .git contents are skipped.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.files) { file in
                        Toggle(isOn: Binding(
                            get: { model.selectedPaths.contains(file.relativePath) },
                            set: { model.toggle(file, selected: $0) }
                        )) {
                            HStack(spacing: 9) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.black.opacity(0.72))
                                    .frame(width: 18)
                                Text(file.relativePath)
                                    .font(.custom("Menlo", size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .listRowBackground(Color.clear)
                        .disabled(model.isBusy)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private var uploadPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Commit message", text: $model.commitMessage)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
            HStack {
                Label("Upload selected files", systemImage: "arrow.up.to.line")
                    .font(.custom("Menlo", size: 12).weight(.bold))
                Spacer()
                Button {
                    model.upload()
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small).frame(width: 140)
                    } else {
                        Label("Upload to GitHub", systemImage: "arrow.up.circle.fill")
                            .frame(minWidth: 140)
                    }
                }
                .buttonStyle(GlossyGreenButtonStyle())
                .disabled(model.isBusy || model.files.isEmpty)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "info.circle")
            Text(model.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("Files up to 100 MB").foregroundStyle(.black.opacity(0.62))
        }
        .font(.custom("Menlo", size: 10))
        .foregroundStyle(.black.opacity(0.78))
    }

    private var activityPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Activity log", systemImage: "list.bullet.rectangle")
                        .font(.custom("Menlo", size: 12).weight(.bold))
                    Spacer()
                    Text("\(model.activityLogs.count) / 200")
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(.black.opacity(0.62))
                }
                if model.activityLogs.isEmpty {
                    Text("Upload and download progress will appear here.")
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(.black.opacity(0.62))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(model.activityLogs) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: entry.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                            .foregroundStyle(entry.isError ? Color.red : Color(red: 0.06, green: 0.34, blue: 0.17))
                                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                            .foregroundStyle(.black.opacity(0.58))
                                        Text(entry.message)
                                            .foregroundStyle(entry.isError ? Color(red: 0.62, green: 0.05, blue: 0.04) : .black)
                                            .textSelection(.enabled)
                                    }
                                    .font(.custom("Menlo", size: 10))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .frame(maxHeight: .infinity)
                        .onChange(of: model.activityLogs.last?.id) { _, _ in
                            if let latest = model.activityLogs.last {
                                proxy.scrollTo(latest.id, anchor: .bottom)
                            }
                        }
                        .onAppear {
                            if let latest = model.activityLogs.last {
                                proxy.scrollTo(latest.id, anchor: .bottom)
                            }
                        }
                    }
                }
                Divider()
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentWindowView {
        TransparentWindowView()
    }

    func updateNSView(_ nsView: TransparentWindowView, context: Context) {}
}

private struct WindowBlurBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private final class TransparentWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private struct RepositoryCreationRequest {
    let name: String
    let description: String
    let isPrivate: Bool
}

private struct DeleteFilesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repository: GitHubRepository
    let onLoadBranches: () async throws -> [GitHubBranch]
    let onLoadFiles: (String) async throws -> [GitHubFile]
    let onDelete: ([GitHubFile], String) async throws -> Void

    @State private var branches: [GitHubBranch] = []
    @State private var selectedBranch = ""
    @State private var files: [GitHubFile] = []
    @State private var selectedPaths = Set<String>()
    @State private var isLoadingBranches = false
    @State private var isLoadingFiles = false
    @State private var isDeleting = false
    @State private var isConfirming = false
    @State private var confirmationFiles: [GitHubFile] = []
    @State private var errorMessage: String?

    private var selectedFiles: [GitHubFile] {
        files.filter { selectedPaths.contains($0.path) }
    }

    var body: some View {
        Group {
            if isConfirming {
                confirmationView
            } else {
                browserView
            }
        }
        .padding(22)
        .frame(width: 650, height: 610)
        .font(.custom("Menlo", size: 12))
        .foregroundStyle(Color.black)
        .buttonStyle(GlossyGreenButtonStyle())
        .task {
            await loadBranches()
        }
    }

    private var browserView: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Delete repository files", systemImage: "trash")
                .font(.custom("Menlo", size: 16).weight(.bold))
            Text("Choose the repository branch and files to remove.")
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(.black.opacity(0.72))

            HStack(spacing: 10) {
                Text("Repository")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                Text(repository.fullName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingBranches || isLoadingFiles || isDeleting)
            }

            HStack {
                Text("Branch")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                Picker("Branch", selection: Binding(
                    get: { selectedBranch },
                    set: { newBranch in
                        selectedBranch = newBranch
                        Task { await loadFiles(on: newBranch) }
                    }
                )) {
                    ForEach(branches) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .labelsHidden()
                .disabled(branches.isEmpty || isLoadingBranches || isLoadingFiles || isDeleting)
                Spacer()
                if isLoadingBranches || isLoadingFiles {
                    ProgressView().controlSize(.small)
                    Text(isLoadingBranches ? "Loading branches…" : "Loading files…")
                        .font(.custom("Menlo", size: 10))
                }
            }

            HStack {
                Text("Files on \(selectedBranch.isEmpty ? "selected branch" : selectedBranch)")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                    .lineLimit(1)
                Spacer()
                Button("Select all") {
                    selectedPaths = Set(files.map(\.path))
                }
                .disabled(files.isEmpty || isLoadingFiles || isDeleting)
                Button("Clear") {
                    selectedPaths.removeAll()
                }
                .disabled(selectedPaths.isEmpty || isDeleting)
                Text("\(selectedPaths.count) selected")
                    .font(.custom("Menlo", size: 10).weight(.bold))
                    .foregroundStyle(.black.opacity(0.68))
            }

            Group {
                if files.isEmpty {
                    ContentUnavailableView(
                        isLoadingFiles ? "Loading files" : "No files found",
                        systemImage: "doc",
                        description: Text(branches.isEmpty
                                          ? "No branches are available in this repository."
                                          : "This branch contains no files.")
                    )
                } else {
                    List(files) { file in
                        Toggle(isOn: Binding(
                            get: { selectedPaths.contains(file.path) },
                            set: { isSelected in
                                if isSelected {
                                    selectedPaths.insert(file.path)
                                } else {
                                    selectedPaths.remove(file.path)
                                }
                            }
                        )) {
                            Text(file.path)
                                .font(.custom("Menlo", size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isLoadingFiles || isDeleting)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Text(errorMessage)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isDeleting)
                Button {
                    confirmationFiles = selectedFiles
                    errorMessage = nil
                    isConfirming = true
                } label: {
                    Label("Review deletion…", systemImage: "trash")
                }
                .disabled(selectedFiles.isEmpty || isLoadingFiles || isDeleting)
            }
        }
    }

    private var confirmationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Confirm file deletion", systemImage: "exclamationmark.triangle.fill")
                .font(.custom("Menlo", size: 16).weight(.bold))
                .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
            Text("You are about to delete \(confirmationFiles.count) file(s) from \(repository.fullName), branch \(selectedBranch).")
                .font(.custom("Menlo", size: 11).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Review the exact paths. GitHub will create one commit for each file deleted.")
                .font(.custom("Menlo", size: 10))
                .foregroundStyle(.black.opacity(0.72))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(confirmationFiles) { file in
                        Text(file.path)
                            .font(.custom("Menlo", size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Text(errorMessage)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Back to selection") {
                    errorMessage = nil
                    isConfirming = false
                }
                .disabled(isDeleting)
                Button(role: .destructive) {
                    Task { await deleteConfirmedFiles() }
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Delete \(confirmationFiles.count) file(s)", systemImage: "trash.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDeleting || confirmationFiles.isEmpty)
            }
        }
    }

    private func loadBranches() async {
        isLoadingBranches = true
        errorMessage = nil
        defer { isLoadingBranches = false }
        do {
            branches = try await onLoadBranches()
            guard !branches.isEmpty else {
                selectedBranch = ""
                files = []
                selectedPaths.removeAll()
                return
            }
            selectedBranch = branches.first(where: { $0.name == repository.defaultBranch })?.name
                ?? branches[0].name
            await loadFiles(on: selectedBranch)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadFiles(on branch: String) async {
        guard !branch.isEmpty else { return }
        isLoadingFiles = true
        errorMessage = nil
        files = []
        selectedPaths.removeAll()
        defer { isLoadingFiles = false }
        do {
            files = try await onLoadFiles(branch)
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        if branches.isEmpty {
            await loadBranches()
        } else {
            await loadFiles(on: selectedBranch)
        }
    }

    private func deleteConfirmedFiles() async {
        guard !confirmationFiles.isEmpty, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await onDelete(confirmationFiles, selectedBranch)
            dismiss()
        } catch {
            let deletionError = error.localizedDescription
            await loadFiles(on: selectedBranch)
            errorMessage = deletionError
            isConfirming = false
        }
    }
}

@MainActor
private final class RepositoryCreationFormModel: ObservableObject {
    @Published var name = ""
    @Published var description = ""
    @Published var isPrivate = true
    @Published var isCreating = false
    @Published var errorMessage: String?

    var validationError: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Enter a repository name." }
        if trimmedName.count > 100 { return "Repository names can be at most 100 characters." }
        if trimmedName == "." || trimmedName == ".." || trimmedName.lowercased().hasSuffix(".git") {
            return "Choose a name other than “.”, “..”, or one ending in “.git”."
        }
        guard trimmedName.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil else {
            return "Use only letters, numbers, periods, hyphens, and underscores in the name."
        }
        if description.count > 350 { return "Descriptions can be at most 350 characters." }
        return nil
    }

    var canCreate: Bool { validationError == nil && !isCreating }
}

private struct RepositoryCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = RepositoryCreationFormModel()

    let onCreate: (RepositoryCreationRequest) async throws -> GitHubRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Create GitHub repository", systemImage: "plus.app")
                .font(.custom("Menlo", size: 16).weight(.bold))
            Text("Create a repository in the currently connected GitHub account.")
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(.black.opacity(0.72))

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository name")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                TextField("my-project", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.isCreating)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description (optional)")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                TextField("What is this repository for?", text: $form.description)
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.isCreating)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Visibility")
                    .font(.custom("Menlo", size: 11).weight(.bold))
                Picker("Visibility", selection: $form.isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(form.isCreating)
                Label(
                    form.isPrivate
                        ? "Private — access is limited to you and people you grant access."
                        : "Public — anyone can view, clone, and fork this repository.",
                    systemImage: form.isPrivate ? "lock.fill" : "globe"
                )
                .font(.custom("Menlo", size: 10).weight(form.isPrivate ? .regular : .bold))
                .foregroundStyle(form.isPrivate ? Color.black.opacity(0.7) : Color(red: 0.62, green: 0.05, blue: 0.04))
                .fixedSize(horizontal: false, vertical: true)
            }

            if let message = form.validationError ?? form.errorMessage {
                Text(message)
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(form.isCreating)
                Button {
                    createRepository()
                } label: {
                    if form.isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(form.isPrivate ? "Create private repository" : "Create public repository")
                    }
                }
                .buttonStyle(GlossyGreenButtonStyle())
                .disabled(!form.canCreate)
            }
        }
        .padding(24)
        .frame(width: 520)
        .font(.custom("Menlo", size: 12))
        .foregroundStyle(Color.black)
        .buttonStyle(GlossyGreenButtonStyle())
    }

    private func createRepository() {
        guard form.canCreate else { return }
        guard form.validationError == nil else { return }
        form.errorMessage = nil
        form.isCreating = true
        let request = RepositoryCreationRequest(
            name: form.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: form.description.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrivate: form.isPrivate
        )
        Task { @MainActor in
            do {
                _ = try await onCreate(request)
                dismiss()
            } catch {
                form.errorMessage = error.localizedDescription
            }
            form.isCreating = false
        }
    }
}

private struct GitHubConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ConnectionFormModel()

    let onConnect: (String) async throws -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect GitHub", systemImage: "person.crop.circle.badge.checkmark")
                .font(.custom("Menlo", size: 16).weight(.bold))
            Text("Register a GitHub OAuth App and enable Device Flow. Enter its public Client ID below; the app never asks for an OAuth client secret.")
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(.black.opacity(0.72))
            TextField("OAuth App Client ID", text: $form.clientID)
                .textFieldStyle(.roundedBorder)
                .disabled(form.isConnecting)
            if let userCode = form.userCode {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Enter this code on GitHub:")
                        .font(.custom("Menlo", size: 11).weight(.bold))
                    HStack {
                        Text(userCode)
                            .font(.custom("Menlo", size: 24).weight(.bold))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(userCode, forType: .string)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                    Text(form.status)
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(.black.opacity(0.72))
                }
            }
            if let errorMessage = form.errorMessage {
                Text(errorMessage)
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(Color(red: 0.62, green: 0.05, blue: 0.04))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(form.isConnecting ? "Cancel authorization" : "Cancel") {
                    form.authorizationTask?.cancel()
                    dismiss()
                }
                    .buttonStyle(GlossyGreenButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Quit app") {
                    form.authorizationTask?.cancel()
                    onQuit()
                }
                .buttonStyle(GlossyGreenButtonStyle())
                .keyboardShortcut("q")
                Button {
                    beginAuthorization()
                } label: {
                    if form.isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(form.userCode == nil ? "Authorize with GitHub" : "Restart authorization")
                    }
                }
                .buttonStyle(GlossyGreenButtonStyle())
                .disabled(form.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form.isConnecting)
            }
        }
        .padding(24)
        .frame(width: 520)
        .font(.custom("Menlo", size: 12))
        .foregroundStyle(Color.black)
        .buttonStyle(GlossyGreenButtonStyle())
        .onDisappear {
            form.authorizationTask?.cancel()
        }
    }

    private func beginAuthorization() {
        let clientID = form.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return }
        UserDefaults.standard.set(clientID, forKey: "githubOAuthClientID")
        form.errorMessage = nil
        form.userCode = nil
        form.isConnecting = true
        form.status = "Requesting a GitHub device code…"

        form.authorizationTask = Task { @MainActor in
            do {
                let authorization = try await GitHubAPI.requestDeviceAuthorization(clientID: clientID)
                form.userCode = authorization.userCode
                form.status = "Waiting for you to authorize this app on GitHub…"
                if !NSWorkspace.shared.open(authorization.verificationUri) {
                    form.status = "Open \(authorization.verificationUri.absoluteString) and enter the code above."
                }
                let accessToken = try await GitHubAPI.waitForDeviceAuthorization(
                    authorization,
                    clientID: clientID
                ) { status in
                    form.status = status
                }
                try await onConnect(accessToken)
                dismiss()
            } catch is CancellationError {
                form.status = "Authorization cancelled."
            } catch {
                form.errorMessage = error.localizedDescription
            }
            form.authorizationTask = nil
            form.isConnecting = false
        }
    }
}

@MainActor
private final class ConnectionFormModel: ObservableObject {
    @Published var clientID = UserDefaults.standard.string(forKey: "githubOAuthClientID") ?? ""
    @Published var errorMessage: String?
    @Published var isConnecting = false
    @Published var userCode: String?
    @Published var status = ""
    var authorizationTask: Task<Void, Never>?
}

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white, lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 4)
    }
}

private struct GlossyGreenButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        GlossyGreenButtonFace(configuration: configuration, isEnabled: isEnabled)
    }
}

private struct GlossyGreenButtonFace: View {
    @Environment(\.isFocused) private var isFocused
    @StateObject private var hoverState = ButtonHoverState()

    let configuration: ButtonStyleConfiguration
    let isEnabled: Bool

    private var isHovered: Bool { hoverState.isHovered }

    private var emeraldGradient: [Color] {
        if !isEnabled {
            return [
                Color(red: 0.19, green: 0.27, blue: 0.23),
                Color(red: 0.28, green: 0.39, blue: 0.32),
                Color(red: 0.17, green: 0.25, blue: 0.21)
            ]
        }
        let sheen = isHovered ? 0.1 : 0
        return [
            Color(red: 0.008, green: 0.075, blue: 0.043),
            Color(red: 0.035, green: 0.40 + sheen, blue: 0.19),
            Color(red: 0.035, green: 0.26, blue: 0.13)
        ]
    }

    var body: some View {
        configuration.label
            .font(.custom("Menlo", size: 13).weight(.bold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
            .padding(.horizontal, 15)
            .frame(minHeight: 42)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: emeraldGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(isEnabled ? (isHovered ? 0.26 : 0.18) : 0.06),
                                        .white.opacity(0.025),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(.bottom, 15)
                    }
                    .overlay(alignment: .top) {
                        Capsule()
                            .stroke(.white.opacity(isEnabled ? 0.78 : 0.28), lineWidth: 1)
                            .padding(.horizontal, 1)
                            .padding(.top, 1)
                    }
                    .overlay {
                        Capsule()
                            .stroke(Color(red: 0.008, green: 0.09, blue: 0.05).opacity(isEnabled ? 0.9 : 0.35), lineWidth: 1)
                            .padding(2)
                    }
                    .overlay {
                        if isFocused {
                            Capsule()
                                .stroke(Color(red: 0.34, green: 0.93, blue: 0.61), lineWidth: 2)
                                .padding(-3)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .black.opacity(isEnabled ? 0.28 : 0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(.top, 20)
                    }
            }
            .shadow(
                color: Color(red: 0.015, green: 0.12, blue: 0.065)
                    .opacity(isEnabled ? (isHovered ? 0.5 : 0.38) : 0.12),
                radius: isHovered && isEnabled ? 7 : 3,
                x: 0,
                y: isHovered && isEnabled ? 3 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered && isEnabled ? 1.015 : 1))
            .offset(y: isHovered && isEnabled && !configuration.isPressed ? -1 : 0)
            .contentShape(Capsule())
            .onHover { hoverState.isHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

@MainActor
private final class ButtonHoverState: ObservableObject {
    @Published var isHovered = false
}
