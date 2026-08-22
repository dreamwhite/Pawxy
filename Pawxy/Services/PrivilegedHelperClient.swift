//
//  PrivilegedHelperClient.swift
//  Pawxy
//

import Foundation
import ServiceManagement
import Combine

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

    private init() {}

    func prepareIfNeeded() {
        if service.status == .notRegistered {
            install()
        } else {
            refresh()
        }
    }

    func install() {
        guard !isWorking else { return }
        isWorking = true
        do {
            if service.status == .notRegistered {
                try service.register()
            }
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
        isWorking = false
    }

    /// Re-registers the embedded daemon after an application update. macOS
    /// keeps the previously registered helper until the service is replaced.
    func reinstall() {
        guard !isWorking else { return }
        isWorking = true
        do {
            if service.status != .notRegistered {
                try service.unregister()
            }
            try service.register()
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
        isWorking = false
    }

    func refresh() {
        switch service.status {
        case .enabled:
            state = .checking
            Task {
                let isReachable = await Task.detached {
                    PrivilegedHelperClient().ping()
                }.value
                state = isReachable ? .ready : .unreachable
            }
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .notInstalled
        case .notFound:
            state = .missingFromBundle
        @unknown default:
            state = .failed(String(localized: "macOS returned an unknown helper status."))
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension PrivilegedHelperController {
    enum State: Equatable {
        case checking
        case notInstalled
        case requiresApproval
        case ready
        case unreachable
        case missingFromBundle
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
                String(localized: "Install the Pawxy system service before changing DNS configuration.")
            case .requiresApproval:
                String(localized: "Allow Pawxy in System Settings › General › Login Items & Extensions.")
            case .ready:
                String(localized: "DNS changes use Pawxy’s signed XPC service without AppleScript prompts.")
            case .unreachable:
                String(localized: "The helper is registered but did not answer. Reinstall or restart Pawxy.")
            case .missingFromBundle:
                String(localized: "This build does not contain the Pawxy privileged helper.")
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
