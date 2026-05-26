import Foundation

public final class StdioLineTransport: @unchecked Sendable {
    private let input: FileHandle
    private let writer: StdioLineWriter
    private let state = StdioLineTransportState()

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.input = input
        self.writer = StdioLineWriter(output: output)
    }

    public func run(server: MCPServer) async throws {
        var buffer = Data()
        let tracker = StdioLineTaskTracker()
        var reachedEOF = false

        while !state.isClosed {
            let chunk = input.availableData
            if chunk.isEmpty {
                reachedEOF = true
                break
            }

            buffer.append(chunk)
            await processCompleteLines(in: &buffer, server: server, tracker: tracker)
        }

        if !buffer.isEmpty {
            await processLine(buffer, server: server, tracker: tracker)
        }

        if reachedEOF {
            await server.close()
        }

        try await tracker.waitForAll()
    }

    public func close() {
        state.close()
        try? input.close()
    }
}

private extension StdioLineTransport {
    func processCompleteLines(
        in buffer: inout Data,
        server: MCPServer,
        tracker: StdioLineTaskTracker
    ) async {
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            await processLine(line, server: server, tracker: tracker)
        }
    }

    func processLine(_ line: Data, server: MCPServer, tracker: StdioLineTaskTracker) async {
        guard !line.isEmpty else {
            return
        }

        await tracker.start()
        Task {
            do {
                let message: JSONRPCIncomingMessage
                message = try JSONDecoder().decode(JSONRPCIncomingMessage.self, from: line)

                if let response = await server.handle(message) {
                    try await writer.write(response)
                }

                await tracker.finish(.success(()))
            } catch is DecodingError {
                do {
                    try await writer.write(.failure(id: nil, code: -32700, message: "Parse error"))
                    await tracker.finish(.success(()))
                } catch {
                    await tracker.finish(.failure(error))
                }
            } catch {
                await tracker.finish(.failure(error))
            }
        }
    }
}

private actor StdioLineWriter {
    private let output: FileHandle

    init(output: FileHandle) {
        self.output = output
    }

    func write(_ response: JSONRPCResponse) throws {
        let data = try JSONEncoder().encode(response)
        try output.write(contentsOf: data)
        try output.write(contentsOf: Data([0x0A]))
    }
}

private actor StdioLineTaskTracker {
    private var inFlight = 0
    private var firstError: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func start() {
        inFlight += 1
    }

    func finish(_ result: Result<Void, Error>) {
        if case .failure(let error) = result, firstError == nil {
            firstError = error
        }

        inFlight -= 1
        guard inFlight == 0 else {
            return
        }

        let waiters = waiters
        self.waiters.removeAll()

        if let firstError {
            for waiter in waiters {
                waiter.resume(throwing: firstError)
            }
        } else {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForAll() async throws {
        if inFlight == 0 {
            if let firstError {
                throw firstError
            }
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class StdioLineTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
