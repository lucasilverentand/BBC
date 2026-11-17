import Foundation
import Network
import BBCClient

/// A bounded one-request-per-connection HTTP listener inside the Mac app.
final class LocalAPIServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "club.bluebubble.http")
    private let router: APIRouter
    private let onResponse: @MainActor @Sendable (String, Int) -> Void
    private var streams: [ObjectIdentifier:Task<Void,Never>] = [:] // queue-confined
    private var connections: [UUID: NWConnection] = [:] // queue-confined
    init(host: String, port: UInt16, router: APIRouter,
         onResponse: @escaping @MainActor @Sendable (String, Int) -> Void = { _, _ in }) throws {
        self.router = router; self.onResponse = onResponse
        let parameters = NWParameters.tcp
        // Port zero asks the system for an ephemeral port; see `boundPort`.
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }
    /// The actual listening port once the listener is ready; nil before that.
    var boundPort: UInt16? { listener.port?.rawValue }
    func start(state: @escaping @Sendable (Bool) -> Void) {
        listener.stateUpdateHandler = { value in
            switch value { case .ready: state(true); case .failed, .cancelled: state(false); default: break }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel(); queue.async { for connection in self.connections.values { connection.cancel() }; self.connections.removeAll() } }
    /// Cancels network resources on the listener queue before returning.
    /// Already dispatched router operations retain normal completion semantics.
    /// Never call from `queue`.
    func stopAndDrain() { listener.cancel(); queue.sync { for connection in connections.values { connection.cancel() }; connections.removeAll() } }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.removeValue(forKey:id)
                self?.streams.removeValue(forKey:ObjectIdentifier(connection))?.cancel()
            }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 60) { [weak self, weak connection] in
            if let connection, self?.streams[ObjectIdentifier(connection)] == nil { connection.cancel() }
        }
        receive(connection, buffer: RequestBuffer())
    }
    private final class RequestBuffer: @unchecked Sendable { var data = Data() }
    private func receive(_ connection: NWConnection, buffer state: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let data { state.data.append(data) }
            let buffer = state.data
            guard buffer.count <= MediaStore.maximumBytes + 16384, error == nil else { self.reply(connection, status: 400, value: .object(["error": .string("invalid_request")])); return }
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard !complete, buffer.count <= 16384 else { connection.cancel(); return }
                self.receive(connection, buffer: state); return
            }
            guard range.upperBound <= 16384, let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])) else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { connection.cancel(); return }
                let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard headers[name] == nil else { connection.cancel(); return }; headers[name] = value
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= (first[1] == "/v1/media/upload" ? MediaStore.maximumBytes : 65536) else { connection.cancel(); return }
            let bodyCount = buffer.count - range.upperBound
            guard bodyCount <= length else { connection.cancel(); return }
            if bodyCount < length { guard !complete else { connection.cancel(); return }; self.receive(connection, buffer: state); return }
            let body = Data(buffer[range.upperBound...])
            let method = String(first[0]), path = String(first[1]), requestHeaders = headers
            if method == "GET", path == "/v1/events", length == 0 {
                guard self.streams.count < 2 else { self.reply(connection,status:503,value:.object(["error":.string("stream_limit")])); return }
                self.streams[ObjectIdentifier(connection)] = Task { @MainActor in
                    await self.stream(connection,headers:requestHeaders)
                }
                return
            }
            Task { @MainActor in
                let response = await self.router.handle(method: method, path: path, headers: requestHeaders, body: body, peer: connection.endpoint)
                self.onResponse(method, response.status)
                self.reply(connection, status: response.status, value: response.value)
            }
        }
    }
    @MainActor private func stream(_ connection: NWConnection, headers: [String:String]) async {
        var batch = router.eventBatch(headers:headers,peer:connection.endpoint,after:headers["last-event-id"])
        onResponse("GET",batch.status)
        guard batch.status == 200, let initial = batch.cursor else {
            reply(connection,status:batch.status,value:.object(["error":.string(batch.status == 409 ? "event_cursor_expired" : "stream_unavailable")]))
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n"
        guard await sendStream(Data(head.utf8),to:connection) else { return }
        var cursor = initial
        let until = ContinuousClock.now.advanced(by:.seconds(300))
        var ticks = 0
        // The ready checkpoint lets a new client save a baseline even in an idle chat.
        var data = batch.frames
        if data.isEmpty { data = Data("id: \(cursor)\nevent: bbc.ready\ndata: {}\n\n".utf8) }
        guard await sendStream(data,to:connection) else { return }
        while !Task.isCancelled, ContinuousClock.now < until {
            do { try await Task.sleep(for:.seconds(1)) } catch { break }
            batch = router.eventBatch(headers:headers,peer:connection.endpoint,after:cursor)
            guard batch.status == 200, let next = batch.cursor else {
                _ = await sendStream(Data("event: bbc.reset\ndata: {\"reconnect\":true}\n\n".utf8),to:connection)
                break
            }
            ticks += 1
            if !batch.frames.isEmpty {
                guard await sendStream(batch.frames,to:connection) else { break }
            } else if ticks % 15 == 0 {
                let status = BBCJSONValue.object(["observation":.string(batch.observation)])
                guard let body = try? JSONEncoder().encode(status),
                      await sendStream(Data("event: bbc.status\ndata: ".utf8)+body+Data("\n\n".utf8),to:connection) else { break }
            }
            cursor = next
        }
        connection.cancel()
    }
    private func sendStream(_ data: Data, to connection: NWConnection) async -> Bool {
        // One bounded batch at a time. A stalled peer cannot accumulate queued output.
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline:.now()+10,execute:timeout)
        let sent = await withCheckedContinuation { continuation in
            connection.send(content:data,completion:.contentProcessed { error in continuation.resume(returning:error == nil) })
        }
        timeout.cancel()
        if !sent { connection.cancel() }
        return sent
    }
    private func reply(_ connection: NWConnection, status: Int, value: BBCJSONValue) {
        guard let body = try? JSONEncoder().encode(value), body.count <= 2_000_000 else { connection.cancel(); return }
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
