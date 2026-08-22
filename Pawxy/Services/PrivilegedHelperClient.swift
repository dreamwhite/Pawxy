//
//  PrivilegedHelperClient.swift
//  Pawxy
//

import Foundation
import ServiceManagement
import Combine
import CryptoKit

nonisolated struct PrivilegedHelperInstallationIdentity: Codable, Equatable {
    let bundlePath: String
    let executableFingerprint: String

    static func make(
        bundlePath: String,
        appExecutable: Data,
        helperExecutable: Data
    ) -> Self {
        var hasher = SHA256()
        hasher.update(data: Data("Pawxy application\0".utf8))
        hasher.update(data: appExecutable)
        hasher.update(data: Data("Pawxy privileged helper\0".utf8))
        hasher.update(data: helperExecutable)

        return Self(
            bundlePath: URL(fileURLWithPath: bundlePath).standardizedFileURL.path,
            executableFingerprint: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }
}

nonisolated struct PrivilegedHelperClient {
    func perform(_ operation: PawxyPrivilegedOperation) throws -> PawxyPrivilegedResponse {
        let request = PawxyPrivilegedRequest(operation: operation)
        let requestData = try JSONEncoder().encode(request)
        let connection = makeConnection()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<PawxyPrivilegedResponse, Error>?

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            lock.lock()
            result = .failure(ClientError.connectionFailed(error.localizedDescription))
            lock.unlock()
            semaphore.signal()
        }
        guard let helper = proxy as? PawxyPrivilegedHelperXPC else {
            throw ClientError.invalidConnection
        }

        helper.perform(requestData) { responseData, errorMessage in
            lock.lock()
            defer {
                lock.unlock()
                semaphore.signal()
            }
            if let errorMessage {
                result = .failure(ClientError.operationFailed(errorMessage))
            } else if let responseData {
                do {
                    result = .success(
                        try JSONDecoder().decode(
                            PawxyPrivilegedResponse.self,
                            from: responseData
                        )
                    )
                } catch {
                    result = .failure(ClientError.invalidResponse)
                }
            } else {
                result = .failure(ClientError.invalidResponse)
            }
        }

        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw ClientError.timedOut
        }
        lock.lock()
        let completedResult = result
        lock.unlock()
        guard let completedResult else { throw ClientError.invalidResponse }
        return try completedResult.get()
    }

    func ping(timeout: TimeInterval = 3) -> Bool {
        let connection = makeConnection()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var isCompatible = false
        var didFinish = false

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            lock.lock()
            didFinish = true
            lock.unlock()
            semaphore.signal()
        }
        guard let helper = proxy as? PawxyPrivilegedHelperXPC else { return false }
        helper.ping { version in
            lock.lock()
            isCompatible = version == PawxyPrivilegedHelperConstants.protocolVersion
            didFinish = true
            lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return didFinish && isCompatible
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: PawxyPrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: PawxyPrivilegedHelperXPC.self
        )
        connection.resume()
        return connection
    }
}

extension PrivilegedHelperClient {
    nonisolated enum ClientError: LocalizedError {
        case invalidConnection
        case connectionFailed(String)
        case operationFailed(String)
        case invalidResponse
        case timedOut

        var errorDescription: String? {
            switch self {
            case .invalidConnection:
                String(localized: "Pawxy could not create a secure connection to its privileged helper.")
            case let .connectionFailed(detail):
                String(localized: "The Pawxy privileged helper is unavailable: \(detail)")
            case let .operationFailed(detail):
                detail
            case .invalidResponse:
                String(localized: "The Pawxy privileged helper returned an invalid response.")
            case .timedOut:
                String(localized: "The Pawxy privileged helper did not respond in time.")
            }
        }
    }
}

@MainActor
final class PrivilegedHelperController: ObservableObject {
    static let shared = PrivilegedHelperController()

    @Published private(set) var state: State = .checking
    @Published private(set) var isWorking = false

    private let service = SMAppService.daemon(
        plistName: PawxyPrivilegedHelperConstants.launchDaemonPlistName
    )
    private let defaults = UserDefaults.standard
    private let installationIdentityKey = "privilegedHelperInstallationIdentity"
    private var automaticMigrationIdentity: PrivilegedHelperInstallationIdentity?
    private var verificationTask: Task<Void, Never>?

    private init() {}

    func prepareIfNeeded() {
        guard !isWorking else { return }
        if let bundleProblem = embeddedServiceProblem() {
            state = .missingFromBundle(bundleProblem)
            return
        }

        guard service.status == .enabled,
              let currentIdentity = embeddedServiceIdentity()
        else {
            refresh()
            return
        }

        let installedIdentity = storedInstallationIdentity()
        if let installedIdentity, installedIdentity != currentIdentity {
            migrateEmbeddedService(to: currentIdentity)
        } else {
            verifyEnabledService(
                identity: currentIdentity,
                automaticallyMigrateIfUnavailable: installedIdentity == nil
            )
        }
    }

    func install() {
        guard !isWorking else { return }
        if let bundleProblem = embeddedServiceProblem() {
            state = .missingFromBundle(bundleProblem)
            return
        }

        registerEmbeddedService()
    }

    private func registerEmbeddedService() {
        isWorking = true
        defer { isWorking = false }

        do {
            switch service.status {
            case .enabled:
                refresh()
                return
            case .requiresApproval:
                state = .requiresApproval
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
            refresh(retryCount: 6)
        } catch {
            updateState(afterRegistrationError: error)
        }
    }

    /// Re-registers the embedded daemon after an application update. macOS
    /// keeps the previously registered helper until the service is replaced.
    func reinstall() {
        guard !isWorking else { return }
        if let bundleProblem = embeddedServiceProblem() {
            state = .missingFromBundle(bundleProblem)
            return
        }

        reinstallEmbeddedService()
    }

    private func reinstallEmbeddedService() {
        isWorking = true
        defer { isWorking = false }

        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            try service.register()
            refresh(retryCount: 6)
        } catch {
            updateState(afterRegistrationError: error)
        }
    }

    func refresh() {
        refresh(retryCount: 3)
    }

    private func refresh(retryCount: Int) {
        if let bundleProblem = embeddedServiceProblem() {
            state = .missingFromBundle(bundleProblem)
            return
        }

        switch service.status {
        case .enabled:
            verifyEnabledService(
                identity: embeddedServiceIdentity(),
                retryCount: retryCount
            )
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .notInstalled
        case .notFound:
            // `notFound` is also returned when Service Management has not yet
            // accepted a valid bundled daemon. The bundle itself was checked
            // above, so keep installation available and let register() expose
            // the actionable system error.
            state = .notInstalled
        @unknown default:
            state = .failed(String(localized: "macOS returned an unknown helper status."))
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func embeddedServiceProblem() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/PawxyHelper", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return String(localized: "The embedded PawxyHelper executable is missing or is not executable.")
        }

        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(
                PawxyPrivilegedHelperConstants.launchDaemonPlistName,
                isDirectory: false
            )
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return String(localized: "The embedded LaunchDaemon property list is missing.")
        }

        return nil
    }

    private func embeddedServiceIdentity() -> PrivilegedHelperInstallationIdentity? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Resources/PawxyHelper", isDirectory: false)
        guard let appExecutableURL = Bundle.main.executableURL,
              let appExecutable = try? Data(contentsOf: appExecutableURL, options: .mappedIfSafe),
              let helperExecutable = try? Data(contentsOf: helperURL, options: .mappedIfSafe)
        else {
            return nil
        }

        return PrivilegedHelperInstallationIdentity.make(
            bundlePath: bundleURL.path,
            appExecutable: appExecutable,
            helperExecutable: helperExecutable
        )
    }

    private func storedInstallationIdentity() -> PrivilegedHelperInstallationIdentity? {
        guard let data = defaults.data(forKey: installationIdentityKey) else { return nil }
        return try? JSONDecoder().decode(PrivilegedHelperInstallationIdentity.self, from: data)
    }

    private func storeInstallationIdentity(_ identity: PrivilegedHelperInstallationIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: installationIdentityKey)
    }

    private func verifyEnabledService(
        identity: PrivilegedHelperInstallationIdentity?,
        retryCount: Int = 3,
        automaticallyMigrateIfUnavailable: Bool = false
    ) {
        verificationTask?.cancel()
        state = .checking
        verificationTask = Task { [weak self] in
            let isReachable = await Self.pingHelper(attempts: retryCount)
            guard !Task.isCancelled, let self else { return }

            if isReachable {
                if let identity {
                    storeInstallationIdentity(identity)
                }
                state = .ready
            } else if automaticallyMigrateIfUnavailable, let identity {
                migrateEmbeddedService(to: identity)
            } else {
                state = .unreachable
            }
        }
    }

    private func migrateEmbeddedService(to identity: PrivilegedHelperInstallationIdentity) {
        guard automaticMigrationIdentity != identity else {
            verifyEnabledService(identity: identity, retryCount: 6)
            return
        }
        automaticMigrationIdentity = identity
        reinstallEmbeddedService()
    }

    nonisolated private static func pingHelper(attempts: Int) async -> Bool {
        for attempt in 0..<max(attempts, 1) {
            if Task.isCancelled { return false }
            let isReachable = await Task.detached {
                PrivilegedHelperClient().ping(timeout: 1.5)
            }.value
            if isReachable { return true }

            if attempt + 1 < attempts {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return false
    }

    private func updateState(afterRegistrationError error: Error) {
        switch service.status {
        case .enabled:
            refresh()
        case .requiresApproval:
            state = .requiresApproval
        default:
            let error = error as NSError
            let code = String(error.code)
            state = .failed(
                String(
                    localized: "Service Management could not register the helper (\(error.domain), code \(code)): \(error.localizedDescription)"
                )
            )
        }
    }
}

extension PrivilegedHelperController {
    enum State: Equatable {
        case checking
        case notInstalled
        case requiresApproval
        case ready
        case unreachable
        case missingFromBundle(String)
        case failed(String)

        var isReady: Bool { self == .ready }

        var title: String {
            switch self {
            case .checking: String(localized: "Checking helper…")
            case .notInstalled: String(localized: "Helper not installed")
            case .requiresApproval: String(localized: "Approval required")
            case .ready: String(localized: "Privileged helper ready")
            case .unreachable: String(localized: "Helper unavailable")
            case .missingFromBundle: String(localized: "Helper missing from app")
            case .failed: String(localized: "Helper setup failed")
            }
        }

        var detail: String {
            switch self {
            case .checking:
                String(localized: "Pawxy is checking its secure system service.")
            case .notInstalled:
                String(localized: "The Pawxy system service is bundled correctly but has not been registered with macOS.")
            case .requiresApproval:
                String(localized: "Allow Pawxy in System Settings › General › Login Items & Extensions.")
            case .ready:
                String(localized: "DNS changes use Pawxy’s signed XPC service without AppleScript prompts.")
            case .unreachable:
                String(localized: "The helper is registered but did not answer. Reinstall or restart Pawxy.")
            case let .missingFromBundle(message):
                message
            case let .failed(message):
                message
            }
        }

        var systemImage: String {
            switch self {
            case .ready: "checkmark.shield.fill"
            case .checking: "hourglass"
            case .requiresApproval: "person.badge.key.fill"
            default: "exclamationmark.shield.fill"
            }
        }
    }
}
