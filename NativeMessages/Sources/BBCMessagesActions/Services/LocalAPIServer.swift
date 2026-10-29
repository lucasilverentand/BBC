import Foundation
import Network
import BBCClient

/// A bounded one-request-per-connection HTTP listener inside the Mac app.
final class LocalAPIServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "club.bluebubble.http")
    private let router: APIRouter
    private var connections: [UUID: NWConnection] = [:] // queue-confined
    init(host: String, port: UInt16, router: APIRouter) throws {
        self.router = router
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }
    func start(state: @escaping @Sendable (Bool) -> Void) {
        listener.stateUpdateHandler = { value in
            switch value { case .ready: state(true); case .failed, .cancelled: state(false); default: break }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel(); queue.async { for connection in self.connections.values { connection.cancel() }; self.connections.removeAll() } }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 60) { [weak connection] in connection?.cancel() }
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
            Task { @MainActor in
                let response = await self.router.handle(method: method, path: path, headers: requestHeaders, body: body)
                self.reply(connection, status: response.status, value: response.value)
            }
        }
    }
    private func reply(_ connection: NWConnection, status: Int, value: BBCJSONValue) {
        guard let body = try? JSONEncoder().encode(value), body.count <= 2_000_000 else { connection.cancel(); return }
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
