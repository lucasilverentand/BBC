import Foundation

/// Connect to the API hosted by the Blue Bubble Club Mac app.
public struct BBCHTTPClient: Sendable {
    public let baseURL: URL
    private let apiKey: String
    public init(baseURL: URL, apiKey: String) { self.baseURL = baseURL; self.apiKey = apiKey }
    public func request(_ payload: BBCJSONValue, operationID: UUID? = nil) async throws -> BBCJSONValue {
        guard let method = payload.object?["method"]?.string else { throw BBCError.invalid("A method is required.") }
        let routes = [
            "status":"status", "send":"messages", "reply":"replies", "link":"links", "media.download":"media/download",
            "messages.after":"messages/after", "messages.status":"messages/status", "messages.search":"messages/search",
            "messages.edit":"messages/edit", "messages.unsend":"messages/unsend", "messages.multipart":"messages/multipart",
            "availability":"availability", "groups.create":"groups/create", "groups.add":"groups/add", "groups.remove":"groups/remove",
            "groups.name":"groups/name", "groups.photo":"groups/photo", "groups.leave":"groups/leave",
            "tapback":"tapbacks", "read":"read", "read.status":"read/status", "typing.start":"typing/start", "typing.stop":"typing/stop",
            "media.visual":"media/visual", "media.transcribe":"media/transcribe",
            "webhooks.register":"webhooks/register", "webhooks.list":"webhooks/list", "webhooks.remove":"webhooks/remove",
            "schedule.create":"schedules/create", "schedule.update":"schedules/update", "schedule.cancel":"schedules/cancel",
            "schedule.get":"schedules/get", "schedule.list":"schedules/list"
        ]
        let routedMethod = method == "send" && payload.object?["params"]?.object?["reply_to"] != nil ? "reply" : method
        guard let route = routes[routedMethod], ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw BBCError.invalid("Invalid BBC endpoint or method.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/" + route))
        request.httpMethod = method == "status" ? "GET" : "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let mutating = !["status","messages.after","messages.status","messages.search","availability","media.download","read.status","media.visual","media.transcribe","webhooks.list","schedule.get","schedule.list"].contains(method)
        if mutating {
            guard let operationID else { throw BBCError.invalid("Persist an operation UUID before dispatching a mutation.") }
            request.setValue(operationID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        if method != "status" { request.httpBody = try JSONEncoder().encode(payload.object?["params"] ?? .object([:])) }
        request.timeoutInterval = 100
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw BBCError.unavailable("Invalid BBC response; reconcile dispatched operations.") }
        guard (200..<300).contains(http.statusCode) else { throw BBCError.unavailable("BBC request failed (HTTP \(http.statusCode)); reconcile dispatched operations.") }
        return try JSONDecoder().decode(BBCJSONValue.self, from: data)
    }
    /// Upload one image, video or audio file (up to 32 MiB). Use media_id with send.
    public func uploadMedia(_ data: Data, filename: String) async throws -> BBCJSONValue {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              filename.utf8.count <= 100, !filename.unicodeScalars.contains(where: { $0.value < 32 }),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw BBCError.invalid("Invalid BBC upload.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/media/upload"))
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 100
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-BBC-Filename")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (result, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201, result.count <= 65536 else { throw BBCError.unavailable("BBC upload failed.") }
        return try JSONDecoder().decode(BBCJSONValue.self, from: result)
    }

}
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
