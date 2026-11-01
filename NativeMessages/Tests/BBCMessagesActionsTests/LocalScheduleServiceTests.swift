import Foundation
import XCTest
import BBCClient
@testable import BBCMessagesActions

@MainActor final class LocalScheduleServiceTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = UUID()
        var active = true
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var calls: [BBCJSONValue] = []
        func service(execute: (@MainActor (BBCJSONValue) async throws -> BBCJSONValue)? = nil,
                     mediaExpiresAt: (@MainActor (String) throws -> Date)? = nil) throws -> LocalScheduleService {
            try LocalScheduleService(directory: directory, isKeyActive: { $0 == self.owner && self.active }, execute: execute ?? { request in
                self.calls.append(request)
                return .object(["ok": .bool(true), "guid": .string(UUID().uuidString)])
            }, now: { self.date }, mediaExpiresAt: mediaExpiresAt)
        }
        var create: [String: BBCJSONValue] {
            ["send_at": .string(ISO8601DateFormatter().string(from: date.addingTimeInterval(60))),
             "message": .object(["to": .string("fixture@example.test"), "text": .string("scheduled fixture")])]
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
    private func state(_ service: LocalScheduleService, owner: UUID, id: UUID) throws -> String? {
        try service.handle(method: "schedule.get", params: ["schedule_id": .string(id.uuidString)], keyID: owner).object?["state"]?.string
    }

    func testCreateIdentityAndOwnerSurviveRestartWithoutDuplicateCreation() throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let operation = UUID(), request = fixture.create
        let first: BBCJSONValue
        do {
            let service = try fixture.service()
            first = try service.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: operation)
        }
        let restored = try fixture.service()
        XCTAssertEqual(try restored.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: operation), first)
        let list = try restored.handle(method: "schedule.list", params: [:], keyID: fixture.owner)
        guard case .array(let records) = list.object?["schedules"] else { return XCTFail("Expected schedule records") }
        XCTAssertEqual(records.count, 1)
        XCTAssertThrowsError(try restored.handle(method: "schedule.get", params: ["schedule_id": .string(operation.uuidString)], keyID: UUID()))
        var conflicting = request; conflicting["message"] = .object(["to": .string("fixture@example.test"), "text": .string("different")])
        XCTAssertThrowsError(try restored.handle(method: "schedule.create", params: conflicting, keyID: fixture.owner, operationID: operation))
    }
    func testDueSendPersistsReceiptAndCannotDispatchTwiceAfterRestart() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let id = UUID()
        do {
            let service = try fixture.service()
            _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
            service.start(polling: false)
            await service.tick(); XCTAssertTrue(fixture.calls.isEmpty)
            fixture.date.addTimeInterval(61)
            await service.tick(); await service.tick()
            XCTAssertEqual(fixture.calls.count, 1)
            XCTAssertEqual(fixture.calls[0].object?["params"]?.object?["service"]?.string, "imessage")
            XCTAssertEqual(fixture.calls[0].object?["params"]?.object?["allow_sms_fallback"]?.bool, false)
            XCTAssertEqual(try state(service, owner: fixture.owner, id: id), "sent")
            service.stop()
        }
        let restored = try fixture.service(); restored.start(polling: false); await restored.tick()
        XCTAssertEqual(fixture.calls.count, 1)
    }
    func testUpdateAndCancelApplyBeforeDispatch() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let service = try fixture.service(), cancelled = UUID(), updated = UUID()
        _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: cancelled)
        _ = try service.handle(method: "schedule.cancel", params: ["schedule_id": .string(cancelled.uuidString)], keyID: fixture.owner, operationID: UUID())
        _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: updated)
        _ = try service.handle(method: "schedule.update", params: ["schedule_id": .string(updated.uuidString),
            "send_at": .string(ISO8601DateFormatter().string(from: fixture.date.addingTimeInterval(120))),
            "message": .object(["to": .string("fixture@example.test"), "text": .string("updated fixture")])], keyID: fixture.owner, operationID: UUID())
        fixture.date.addTimeInterval(61); service.start(polling: false); await service.tick()
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.date.addTimeInterval(60); await service.tick()
        XCTAssertEqual(fixture.calls.count, 1)
        XCTAssertEqual(fixture.calls[0].object?["params"]?.object?["text"]?.string, "updated fixture")
        XCTAssertEqual(try state(service, owner: fixture.owner, id: cancelled), "cancelled")
    }
    func testInterruptedDispatchBecomesUncertainAndNeverReplays() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let id = UUID()
        do {
            let service = try fixture.service()
            _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
            let file = fixture.directory.appendingPathComponent("schedules.json")
            var records = try JSONDecoder().decode([LocalScheduleService.Record].self, from: Data(contentsOf: file))
            records[0].state = "dispatching"
            try JSONEncoder().encode(records).write(to: file)
        }
        let restored = try fixture.service()
        XCTAssertEqual(try state(restored, owner: fixture.owner, id: id), "uncertain")
        restored.start(polling: false); fixture.date.addTimeInterval(61); await restored.tick()
        XCTAssertTrue(fixture.calls.isEmpty)
    }
    func testUncertainNativeResultCannotBeReplayed() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let id = UUID()
        do {
            let service = try fixture.service { request in
                fixture.calls.append(request)
                throw ActionFailure.uncertain
            }
            _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
            fixture.date.addTimeInterval(61); service.start(polling: false); await service.tick(); await service.tick()
            XCTAssertEqual(fixture.calls.count, 1)
            XCTAssertEqual(try state(service, owner: fixture.owner, id: id), "uncertain")
            service.stop()
        }
        let restored = try fixture.service(); restored.start(polling: false); await restored.tick()
        XCTAssertEqual(fixture.calls.count, 1)
    }
    func testStopAndRevocationBlockNewDispatches() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let service = try fixture.service(), id = UUID()
        _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
        fixture.date.addTimeInterval(61); service.start(polling: false); service.stop(); await service.tick()
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.active = false; service.start(polling: false); await service.tick()
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.active = true
        XCTAssertEqual(try state(service, owner: fixture.owner, id: id), "cancelled")
    }
    func testInflightSendRejectsCancellationAndUpdate() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        var resume: CheckedContinuation<BBCJSONValue, Never>?
        let service = try fixture.service { request in
            fixture.calls.append(request)
            return await withCheckedContinuation { resume = $0 }
        }, id = UUID()
        _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
        fixture.date.addTimeInterval(61); service.start(polling: false)
        let sending = Task { await service.tick() }
        while resume == nil { await Task.yield() }
        XCTAssertEqual(try state(service, owner: fixture.owner, id: id), "dispatching")
        XCTAssertThrowsError(try service.handle(method: "schedule.cancel", params: ["schedule_id": .string(id.uuidString)], keyID: fixture.owner, operationID: UUID()))
        XCTAssertThrowsError(try service.handle(method: "schedule.update", params: ["schedule_id": .string(id.uuidString), "send_at": fixture.create["send_at"]!], keyID: fixture.owner, operationID: UUID()))
        service.stop(); resume?.resume(returning: .object(["ok": .bool(true)])); await sending.value
        XCTAssertEqual(try state(service, owner: fixture.owner, id: id), "sent")
        XCTAssertEqual(fixture.calls.count, 1)
    }
    func testStopAndRestartCannotRunTwoDispatchLoops() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        var resume: CheckedContinuation<BBCJSONValue, Never>?
        let service = try fixture.service { request in
            fixture.calls.append(request)
            if fixture.calls.count == 1 { return await withCheckedContinuation { resume = $0 } }
            return .object(["ok": .bool(true)])
        }
        for _ in 0..<2 { _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: UUID()) }
        fixture.date.addTimeInterval(61); service.start(polling: false)
        let original = Task { await service.tick() }
        while resume == nil { await Task.yield() }
        service.stop(); service.start(polling: false); await service.tick()
        XCTAssertEqual(fixture.calls.count, 1)
        resume?.resume(returning: .object(["ok": .bool(true)])); await original.value
        XCTAssertEqual(fixture.calls.count, 1, "An old activation must not pick up another due send")
        await service.tick(); await service.tick()
        XCTAssertEqual(fixture.calls.count, 2)
    }
    func testScheduleIdentityIsScopedToItsCreatingKey() throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let service = try LocalScheduleService(directory: fixture.directory, isKeyActive: { _ in true }, execute: { _ in .null }, now: { fixture.date })
        let id = UUID(), otherOwner = UUID()
        _ = try service.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: id)
        XCTAssertThrowsError(try service.handle(method: "schedule.get", params: ["schedule_id": .string(id.uuidString)], keyID: otherOwner))
        let second = try service.handle(method: "schedule.create", params: fixture.create, keyID: otherOwner, operationID: id)
        XCTAssertEqual(second.object?["schedule_id"]?.string, id.uuidString)
        let list = try service.handle(method: "schedule.list", params: [:], keyID: otherOwner)
        guard case .array(let records) = list.object?["schedules"] else { return XCTFail("Expected records") }
        XCTAssertEqual(records.count, 1)
    }
    func testCompetingStoreOwnerCannotReplaceInflightSchedules() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        var resume: CheckedContinuation<BBCJSONValue, Never>?
        var service: LocalScheduleService? = try fixture.service { request in
            fixture.calls.append(request)
            return await withCheckedContinuation { resume = $0 }
        }
        let first = UUID(), second = UUID()
        _ = try service!.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: first)
        _ = try service!.handle(method: "schedule.create", params: fixture.create, keyID: fixture.owner, operationID: second)
        fixture.date.addTimeInterval(61); service!.start(polling: false)
        let sending = Task { [current = service!] in await current.tick() }
        while resume == nil { await Task.yield() }
        service!.stop()
        service = nil // The in-flight tick still owns the store and its lock.
        XCTAssertThrowsError(try fixture.service()) { XCTAssertEqual($0 as? ActionFailure, .busy) }
        resume?.resume(returning: .object(["ok": .bool(true)])); await sending.value
        let replacement = try fixture.service()
        XCTAssertEqual(try state(replacement, owner: fixture.owner, id: first), "sent")
        XCTAssertEqual(try state(replacement, owner: fixture.owner, id: second), "pending")
        _ = try replacement.handle(method: "schedule.cancel", params: ["schedule_id": .string(second.uuidString)], keyID: fixture.owner, operationID: UUID())
        replacement.start(polling: false); await replacement.tick()
        XCTAssertEqual(fixture.calls.count, 1)
    }
    func testMediaScheduleRejectsExpirationAndMultipartUsesNativeRoute() async throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let media = UUID().uuidString
        var request = fixture.create
        request["message"] = .object(["to": .string("fixture@example.test"), "media_id": .string(media)])
        do {
            let service = try fixture.service(mediaExpiresAt: { _ in fixture.date.addingTimeInterval(60) })
            XCTAssertThrowsError(try service.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: UUID()))
        }
        let multipart = try fixture.service(mediaExpiresAt: { _ in fixture.date.addingTimeInterval(120) }), id = UUID()
        request["message"] = .object(["chat_guid": .string("any;-;fixture@example.test"), "text": .string("caption"),
            "media_ids": .array([.string(media)]), "effect": .string("com.apple.messages.effect.CKConfettiEffect")])
        _ = try multipart.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: id)
        fixture.date.addTimeInterval(61); multipart.start(polling: false); await multipart.tick()
        XCTAssertEqual(fixture.calls.first?.object?["method"]?.string, "messages.multipart")
        XCTAssertEqual(fixture.calls.first?.object?["params"]?.object?["text"]?.string, "caption")
    }
    func testPastDateAndArbitraryMethodsCannotBeScheduled() throws {
        let fixture = Fixture(); defer { fixture.cleanup() }
        let service = try fixture.service()
        var request = fixture.create
        request["send_at"] = .string(ISO8601DateFormatter().string(from: fixture.date))
        XCTAssertThrowsError(try service.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: UUID()))
        request = fixture.create
        request["message"] = .object(["method": .string("tapback"), "to": .string("fixture@example.test"), "text": .string("fixture")])
        XCTAssertThrowsError(try service.handle(method: "schedule.create", params: request, keyID: fixture.owner, operationID: UUID()))
    }
}
