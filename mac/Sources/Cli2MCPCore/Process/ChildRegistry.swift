import Darwin
import Foundation

public actor ChildRegistry {
    private var children: [UUID: ChildProcess] = [:]

    public init() {}

    @discardableResult
    public func insert(_ child: ChildProcess) -> UUID {
        let id = UUID()
        children[id] = child
        return id
    }

    public func remove(_ id: UUID) {
        children.removeValue(forKey: id)
    }

    public func terminateAll(signal: Int32 = SIGTERM) {
        for child in children.values {
            child.terminate(signal: signal)
        }
    }

    public func terminateAllGracefully(
        forceKillAfterMilliseconds: Int = 1_000,
        killWaitMilliseconds: Int = 1_000
    ) async {
        guard !children.isEmpty else {
            return
        }

        for child in children.values {
            child.terminate(signal: SIGTERM)
        }

        await waitUntilEmpty(timeoutMilliseconds: forceKillAfterMilliseconds)
        guard !children.isEmpty else {
            return
        }

        for child in children.values {
            child.terminate(signal: SIGKILL)
        }

        await waitUntilEmpty(timeoutMilliseconds: killWaitMilliseconds)
    }

    private func waitUntilEmpty(timeoutMilliseconds: Int) async {
        guard timeoutMilliseconds > 0 else {
            return
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while !children.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

public final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var terminatesProcessGroup = false
    private var pendingSignal: Int32?

    init(process: Process) {
        self.process = process
    }

    @discardableResult
    func configureProcessGroupIfPossible() -> Bool {
        let pid: pid_t
        lock.lock()
        if process.isRunning {
            pid = process.processIdentifier
        } else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let groupIsUsable: Bool
        if getpgid(pid) == pid {
            groupIsUsable = true
        } else if setpgid(pid, pid) == 0 {
            groupIsUsable = getpgid(pid) == pid
        } else {
            // Foundation.Process is commonly backed by posix_spawn on macOS,
            // so the child may have already exec'd by the time this parent can
            // call setpgid. In that case we keep direct-PID termination.
            groupIsUsable = false
        }

        if groupIsUsable {
            lock.lock()
            terminatesProcessGroup = true
            lock.unlock()
        }

        return groupIsUsable
    }

    @discardableResult
    public func terminate(signal: Int32 = SIGTERM) -> Bool {
        let pid: pid_t?
        let useProcessGroup: Bool
        lock.lock()
        if process.isRunning {
            pid = process.processIdentifier
        } else {
            pid = nil
            pendingSignal = signal
        }
        useProcessGroup = terminatesProcessGroup
        lock.unlock()

        guard let pid else {
            return true
        }

        if useProcessGroup, Darwin.kill(-pid, signal) == 0 {
            return true
        }

        return Darwin.kill(pid, signal) == 0
    }

    func applyPendingTerminationIfNeeded() {
        let signal: Int32?
        lock.lock()
        signal = pendingSignal
        pendingSignal = nil
        lock.unlock()

        if let signal {
            terminate(signal: signal)
        }
    }
}
