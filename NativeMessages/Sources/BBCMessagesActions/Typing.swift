import Foundation
import BBCClient
import Darwin

/// EOF/deadline closes a native typing session without touching a composer.
@MainActor enum NativeTypingSession {
    static func run(decoded: (NativeRequest) -> Void, progress: (String,Bool) -> Void) async throws {
        var input = Data(), byte: UInt8 = 0
        while read(STDIN_FILENO,&byte,1) == 1, byte != 10 {
            guard input.count < 65536 else { throw ActionFailure.invalid }; input.append(byte)
        }
        let request = try JSONDecoder().decode(NativeRequest.self,from:input); decoded(request)
        guard request.method == "typing.start" else { throw ActionFailure.invalid }
        let deadline = try request.validated().deadline!
        let flags = fcntl(STDIN_FILENO,F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK) == 0 else { throw ActionFailure.unavailable }
        func stopped() throws -> Bool {
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO,&byte,1)
            if count == 0 { return true }
            guard count == -1, errno == EAGAIN || errno == EWOULDBLOCK else { throw ActionFailure.invalid }
            return Date().timeIntervalSince1970*1000 >= deadline
        }
        let receipt = try await perform(request:request,stopped:stopped,progress:progress)
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:receipt) + Data([10]))
    }
    /// Fixture seam: explicit database, bridge and locks; no stdin or host access.
    static func perform(request: NativeRequest, environment: NativeWorkerEnvironment = .production,
                        stopped: () throws -> Bool, progress: (String,Bool) -> Void) async throws -> [String:Any] {
        guard request.method == "typing.start" else { throw ActionFailure.invalid }
        let parameters = try request.validated(), guid = parameters.message_guid!, deadline = parameters.deadline!
        let database = try MessagesDatabase(url:environment.databaseURL)
        try database.verify(chat:parameters.chat_guid,message:guid)
        guard Set(try database.unread(chat:parameters.chat_guid)).isSubset(of:Set(parameters.read_guids!)) else { throw ActionFailure.invalid }
        if try stopped() {
            return ["ok":true,"skipped":true]
        }
        let status = await Task.detached { BBCMessagesActions.bridgeStatus(environment) }.value
        guard status.object?["ready"]?.bool == true else { throw ActionFailure.unavailable }
        let target: [String:BBCJSONValue] = ["chat_guid":.string(parameters.chat_guid),"message_guid":.string(guid),"typing_id":.string(parameters.typing_id!),"deadline":.number(deadline)]
        func native(_ method: String) async throws {
            let lock = try await NativeOperationLock.acquire(name:"automation.lock",directory:environment.lockDirectory,timeout:environment.lockTimeout)
            defer { lock.release() }
            var fields = target; fields["method"] = .string(method)
            let packet = BBCJSONValue.object(fields)
            let reply = try await Task.detached { try NativeBridgeClient.request(packet,endpoint:environment.endpoint,timeout:environment.bridgeTimeout) }.value
            guard reply.object?["ok"]?.bool == true else { throw reply.object?["uncertain"]?.bool == true ? ActionFailure.uncertain : ActionFailure.unavailable }
        }
        var original: (any Error)?
        progress("typing_start",true)
        do {
            try await native("typing.start")
            progress("typing_wait",true)
            while try !stopped() { try await Task.sleep(for:.milliseconds(100)) }
        } catch { original = error }
        progress("typing_cleanup",true)
        try await native("typing.stop")
        if let original { throw original }
        return ["ok":true,"typing_id":parameters.typing_id!,"cleanup":"confirmed","confirmation":"native-state"]
    }
}
