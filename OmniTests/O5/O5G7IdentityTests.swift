//
//  O5G7IdentityTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5G7IdentityTests: XCTestCase {
    private var root: URL!
    private let target = "pod-A:1:2:ble"
    private var requests: [Data] = []
    // Simulated Pod, as after the early control enable.
    private var control: UInt8 = 0
    private var desired: UInt8 = 0
    private var cgm: UInt8 = 1
    private var mode: UInt8 = 1
    private var fault: UInt8 = 0
    private var delivery: UInt8 = 2
    private var stored: (code: String, serial: String)?
    private var batchReply = "0,ES4.1=0"
    private var batchFailure: Error?
    private var storeOnBatch = true

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var batches: [Data] { requests.filter { $0.starts(with: Data("SE".utf8)) } }
    private var expectedBatch: Data {
        Data("SE4.2=".utf8) + Data([0, 2, 4, 0]) + Data(",SE4.1=".utf8) + Data([0, 18, 2])
            + Data("1234".utf8) + Data([3]) + Data("123456789012".utf8)
    }

    private func aidStatus() -> Data {
        var bytes = Data(repeating: 0, count: 24)
        bytes[1] = 22; bytes[10] = mode; bytes[20] = 3; bytes[21] = cgm
        return bytes
    }
    private func interface() -> Data { Data([0, 9, 0, 0, 0, 0, 0x13, 1, desired, 4, control]) }
    private func sensorInfo() -> Data {
        guard let stored else { return Data([0, 0]) }
        let body = Data([0x00, 0x00, 0x00, 0x00, 0x0f, 0x01, 0x07, 0x02]) + Data(stored.code.utf8)
            + Data([0x03]) + Data(stored.serial.utf8)
        return Data([0x00, UInt8(body.count)]) + body
    }
    private func send(_ request: Data, _ prefix: String) throws -> Data {
        requests.append(request)
        switch String(decoding: request.prefix(5), as: UTF8.self) {
        case "G3.12": return aidStatus()
        case "G4.2": return interface()
        case "G4.1": return sensorInfo()
        default:
            XCTAssertEqual(prefix, "ES4.2=")
            if storeOnBatch { stored = ("1234", "123456789012") }
            if let batchFailure { throw batchFailure }
            return Data(batchReply.utf8)
        }
    }
    private func detailed() throws -> Data {
        var bytes = Data(repeating: 0, count: 22)
        bytes[0] = 2; bytes[1] = 8; bytes[2] = delivery; bytes[8] = fault
        return bytes
    }
    @discardableResult
    private func sendIdentity(code: String = "1234", serial: String = "123456789012") throws -> String {
        try O5G7Identity.send(target: target, firmware: "9.0.4", bleFirmware: "5.0.2",
            pairingCode: code, serialNumber: serial, directory: root, send: send, detailedStatus: detailed)
    }
    /// The phase of the current record (earlier attempts are separate files).
    private func phase() throws -> String? {
        XCTAssertNotNil(try O5G7Identity.record(target: target, directory: root))
        let file = root.appendingPathComponent("pod-A-1-2-ble").appendingPathComponent("identity.json")
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["phase"] as? String
    }

    func testSendsTheOfficialBatchOnceAndReadsTheIdentityBack() throws {
        let summary = try sendIdentity()
        XCTAssertEqual(batches, [expectedBatch])
        XCTAssertEqual(requests.map { $0.starts(with: Data("SE".utf8)) ? "batch" : String(decoding: $0, as: UTF8.self) },
                       ["G3.12", "G4.2", "G4.1", "batch", "G4.2", "G4.1", "G3.12"])
        XCTAssertEqual(try phase(), "stored")
        XCTAssertTrue(summary.hasPrefix("Identity stored"))
    }

    func testIdentityRequestLayout() throws {
        let request = try O5G7Identity.identityRequest(pairingCode: "1234", serialNumber: "123456789012")
        XCTAssertEqual(request.count, 26)
        XCTAssertEqual(request.hexadecimalString, "5345342e313d00120231323334033132333435363738393031 32".replacingOccurrences(of: " ", with: ""))
    }

    func testNeverSentTwiceForAPod() throws {
        try sendIdentity()
        requests.removeAll()
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertTrue(requests.isEmpty)
    }

    /// The Oct 19 reply to this batch on a Pod enabled late, just before the identity.
    func testRejectedIdentityStopsAndIsNotRetried() throws {
        batchReply = "0,ES4.1=-18"; storeOnBatch = false
        XCTAssertThrowsError(try sendIdentity()) { error in
            XCTAssertTrue(error.localizedDescription.contains("-18"))
        }
        XCTAssertEqual(try phase(), "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectedEnableMemberStops() throws {
        batchReply = "-17,ES4.1=0"
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertEqual(try phase(), "stopped")
    }

    func testLostBatchReplyIsNotRetried() throws {
        batchFailure = URLError(.timedOut)
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertEqual(batches.count, 1)
        requests.removeAll()
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertTrue(requests.isEmpty)
    }

    func testMalformedBatchReplyStops() throws {
        batchReply = "0"
        XCTAssertThrowsError(try sendIdentity())
        XCTAssertEqual(try phase(), "stopped")
    }

    func testDifferentIdentityReadBackStops() throws {
        // The Pod reports success but reads back another serial.
        storeOnBatch = false
        XCTAssertThrowsError(try O5G7Identity.send(target: target, firmware: "9.0.4", bleFirmware: "5.0.2",
            pairingCode: "1234", serialNumber: "123456789012", directory: root,
            send: { request, prefix in
                if request.starts(with: Data("SE".utf8)) { self.stored = ("1234", "123456789099") }
                return try self.send(request, prefix)
            },
            detailedStatus: detailed))
        XCTAssertEqual(try phase(), "stopped")
    }

    func testConditionsThatStopBeforeTheBatch() throws {
        let cases: [(String, () -> Void)] = [
            ("control not enabled", { self.control = 255 }),
            ("desired type set", { self.desired = 7 }),
            ("sensor already configured", { self.cgm = 7 }),
            ("identity already stored", { self.stored = ("1111", "111111111111") }),
            ("not Manual", { self.mode = 2 }),
            ("suspended", { self.delivery = 0 }),
            ("bolus running", { self.delivery = 5 }),
            ("faulted", { self.fault = 0xe2 }),
        ]
        for (index, (name, change)) in cases.enumerated() {
            control = 0; desired = 0; cgm = 1; mode = 1; delivery = 2; fault = 0; stored = nil
            change()
            requests.removeAll()
            XCTAssertThrowsError(try O5G7Identity.send(target: "pod-\(index)", firmware: "9.0.4", bleFirmware: "5.0.2",
                pairingCode: "1234", serialNumber: "123456789012", directory: root,
                send: send, detailedStatus: detailed), name)
            XCTAssertTrue(batches.isEmpty, name)
        }
    }

    func testInvalidInputSendsNothingAndLeavesNoRecord() throws {
        XCTAssertThrowsError(try sendIdentity(code: "12a4"))
        XCTAssertThrowsError(try sendIdentity(serial: "12345"))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(try O5G7Identity.record(target: target, directory: root))
    }

    func testScheduledBasalAlsoAllowed() throws {
        delivery = 1; cgm = 0
        try sendIdentity()
        XCTAssertEqual(batches.count, 1)
    }

    // MARK: - A stop before the write allows a new attempt

    private var recordDirectory: URL { root.appendingPathComponent("pod-A-1-2-ble") }

    /// Writes a record as the app would have left it.
    private func writeRecord(phase: String, exchanges: [(request: Data, prefix: String, response: Data?)]) throws {
        let record: [String: Any] = [
            "schema": 1, "target": target, "firmware": "9.0.4", "bleFirmware": "5.0.2",
            "pairingCode": "1234", "serialNumber": "123456789012", "created": 785_000_000.0,
            "revisions": [String: String](), "phase": phase, "reason": "Incorrect Response",
            "exchanges": exchanges.map { e -> [String: Any] in
                var entry: [String: Any] = ["request": e.request.base64EncodedString(),
                                            "responsePrefix": e.prefix, "started": 785_000_001.0]
                if let response = e.response { entry["response"] = response.base64EncodedString() }
                return entry
            },
        ]
        try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: recordDirectory.appendingPathComponent("identity.json"))
    }

    func testFailedFirstReadAllowsANewAttempt() throws {
        var failFirstRead = true
        XCTAssertThrowsError(try O5G7Identity.send(target: target, firmware: "9.0.4", bleFirmware: "5.0.2",
            pairingCode: "1234", serialNumber: "123456789012", directory: root,
            send: { request, prefix in
                if failFirstRead { failFirstRead = false; throw URLError(.timedOut) }
                return try self.send(request, prefix)
            },
            detailedStatus: detailed))
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(try phase(), "stopped")

        try sendIdentity()
        XCTAssertEqual(batches, [expectedBatch])
        XCTAssertEqual(try phase(), "stored")
        let record = try XCTUnwrap(try O5G7Identity.record(target: target, directory: root))
        XCTAssertTrue(record.contains("Earlier attempt (identity-attempt-"))
    }

    /// The first attempt on the worn Pod (2026-11-21): the first G3.12 read failed with
    /// "Incorrect Response" and nothing else was sent.
    func testCapturedFailedFirstReadAllowsANewAttempt() throws {
        try writeRecord(phase: "stopped", exchanges: [(Data("G3.12".utf8), "3.12=", nil)])
        try sendIdentity()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(try phase(), "stored")
    }

    func testCrashDuringTheReadsAllowsANewAttempt() throws {
        try writeRecord(phase: "checking", exchanges: [(Data("G3.12".utf8), "3.12=", aidStatus()),
                                                       (Data("G4.2".utf8), "4.2=", nil)])
        try sendIdentity()
        XCTAssertEqual(batches.count, 1)
    }

    func testAnyRecordThatReachedTheBatchStillBlocks() throws {
        for (phase, response) in [("writePending", nil), ("stopped", Data("0,ES4.1=-18".utf8)),
                                  ("sent", Data("0,ES4.1=0".utf8)), ("stopped", nil)] as [(String, Data?)] {
            try? FileManager.default.removeItem(at: recordDirectory)
            try writeRecord(phase: phase, exchanges: [(Data("G3.12".utf8), "3.12=", aidStatus()),
                                                      (expectedBatch, "ES4.2=", response)])
            requests.removeAll()
            XCTAssertThrowsError(try sendIdentity(), phase)
            XCTAssertTrue(requests.isEmpty, phase)
        }
    }

    func testOtherPhasesWithoutABatchStillBlock() throws {
        for phase in ["writePending", "sent", "stored", "unknown"] {
            try? FileManager.default.removeItem(at: recordDirectory)
            try writeRecord(phase: phase, exchanges: [(Data("G3.12".utf8), "3.12=", aidStatus())])
            requests.removeAll()
            XCTAssertThrowsError(try sendIdentity(), phase)
            XCTAssertTrue(requests.isEmpty, phase)
        }
    }
}
