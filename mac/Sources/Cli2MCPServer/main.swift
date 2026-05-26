import Cli2MCPCore
import Darwin
import Dispatch
import Foundation

@main
enum Cli2MCPServerMain {
    static func main() async {
        let registry = ChildRegistry()
        let signalHandlers = SignalHandlers(registry: registry)

        do {
            let options = try CLIArgumentParser.parse(CommandLine.arguments)
            signalHandlers.install()
            let server = try await MCPServer.start(options: options, registry: registry)
            let transport = StdioLineTransport()
            signalHandlers.attach(server: server, transport: transport)
            try await transport.run(server: server)
            signalHandlers.cancel()
            await server.close()
            exit(0)
        } catch CLIArgumentParser.ParseError.helpRequested(let helpText) {
            FileHandle.standardOutput.write(Data(helpText.utf8))
            exit(0)
        } catch {
            signalHandlers.cancel()
            await registry.terminateAllGracefully()
            if signalHandlers.isShuttingDown {
                exit(0)
            }
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data("cli2mcp: \(message)\n".utf8))
            exit(1)
        }
    }
}

private final class SignalHandlers: @unchecked Sendable {
    private let registry: ChildRegistry
    private let queue = DispatchQueue(label: "cli2mcp.signals")
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var server: MCPServer?
    private var transport: StdioLineTransport?
    private var shuttingDown = false

    var isShuttingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shuttingDown
    }

    init(registry: ChildRegistry) {
        self.registry = registry
    }

    func attach(server: MCPServer, transport: StdioLineTransport) {
        lock.lock()
        let alreadyShuttingDown = shuttingDown
        if !alreadyShuttingDown {
            self.server = server
            self.transport = transport
        }
        lock.unlock()

        if alreadyShuttingDown {
            transport.close()
            Task {
                await server.close()
                exit(0)
            }
        }
    }

    func install() {
        install(signalNumber: SIGINT)
        install(signalNumber: SIGTERM)
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    private func install(signalNumber: Int32) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler { [weak self] in
            self?.shutdown()
        }
        source.resume()
        sources.append(source)
    }

    private func shutdown() {
        lock.lock()
        guard !shuttingDown else {
            lock.unlock()
            return
        }
        shuttingDown = true
        let server = self.server
        let transport = self.transport
        lock.unlock()

        transport?.close()
        Task {
            if let server {
                await server.close()
            } else {
                await registry.terminateAllGracefully()
            }
            exit(0)
        }
    }
}
