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
    private func phase() throws -> String? {
        let json = try XCTUnwrap(try O5G7Identity.record(target: target, directory: root))
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["phase"] as? String
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
}
