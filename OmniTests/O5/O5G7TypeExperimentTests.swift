//
//  O5G7TypeExperimentTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5G7TypeExperimentTests: XCTestCase {
    private var root: URL!
    private let target = "pod-A:1:2:ble"
    private var requests: [Data] = []
    // Simulated Pod, as after the early enable and a rejected add-G7 batch.
    private var control: UInt8 = 0
    private var desired: UInt8 = 0
    private var cgm: UInt8 = 1
    private var mode: UInt8 = 1
    private var fault: UInt8 = 0
    private var delivery: UInt8 = 2
    private var stored: (code: String, serial: String)?
    // The Pod creates a placeholder G7 record once desired type 7 is set.
    private var typeCreatesPlaceholder = true
    private var afterType: (() -> Void)?
    private var typeReply = "0"
    private var typeApplies = true
    private var batchReply = "0,ES4.1=0"
    // The identity the batch under test carries.
    private var sent: (code: String, serial: String) = ("1234", "123456789012")
    private var batchStores = true
    private var batchClearsDesiredType = false
    private var failNext: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var writes: [Data] { requests.filter { $0.starts(with: Data("SE".utf8)) } }
    private let typeWrite = Data("SE4.2=".utf8) + Data([0, 2, 1, 7])
    private var batch: Data {
        Data("SE4.2=".utf8) + Data([0, 2, 4, 0]) + Data(",SE4.1=".utf8) + Data([0, 18, 2])
            + Data(sent.code.utf8) + Data([3]) + Data(sent.serial.utf8)
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
        let key = String(decoding: request.prefix(5), as: UTF8.self)
        if let failNext, key.hasPrefix(failNext) { self.failNext = nil; throw URLError(.timedOut) }
        switch key {
        case "G3.12": return aidStatus()
        case "G4.2": return interface()
        case "G4.1": return sensorInfo()
        default:
            XCTAssertEqual(prefix, "ES4.2=")
            if request == typeWrite {
                if typeApplies { desired = 7; if typeCreatesPlaceholder { stored = ("0000", "000000000000") } }
                afterType?()
                return Data(typeReply.utf8)
            }
            XCTAssertEqual(request, batch)
            if batchStores { stored = sent }
            if batchClearsDesiredType { desired = 0 }
            return Data(batchReply.utf8)
        }
    }
    private func detailed() throws -> Data {
        var bytes = Data(repeating: 0, count: 22)
        bytes[0] = 2; bytes[1] = 8; bytes[2] = delivery; bytes[8] = fault
        return bytes
    }
    @discardableResult
    private func setType() throws -> String {
        try O5G7TypeExperiment.setDesiredType(target: target, firmware: "9.0.4", bleFirmware: "5.0.2",
            directory: root, send: send, detailedStatus: detailed)
    }
    @discardableResult
    private func sendBatch(code: String = "1234", serial: String = "123456789012",
                           typeSetAtActivation: Bool = false) throws -> String {
        try O5G7TypeExperiment.sendIdentityBatch(target: target, firmware: "9.0.4", bleFirmware: "5.0.2",
            pairingCode: code, serialNumber: serial, typeSetAtActivation: typeSetAtActivation,
            directory: root, send: send, detailedStatus: detailed)
    }
    private func phase(_ file: String) throws -> String? {
        let url = root.appendingPathComponent("pod-A-1-2-ble").appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["phase"] as? String
    }
    private func names(_ list: [Data]) -> [String] {
        list.map { $0 == typeWrite ? "type" : ($0.starts(with: Data("SE".utf8)) ? "batch" : String(decoding: $0, as: UTF8.self)) }
    }

    // MARK: - Step 1

    func testTypeStepWritesOnlyTheDesiredTypeAndVerifiesIt() throws {
        let summary = try setType()
        XCTAssertEqual(writes, [typeWrite])
        XCTAssertEqual(names(requests), ["G3.12", "G4.2", "G4.1", "type", "G4.2", "G4.1", "G3.12"])
        XCTAssertEqual(try phase("type.json"), "verified")
        XCTAssertTrue(summary.hasPrefix("Desired type 7 set"))
    }

    func testTypeStepRunsOnce() throws {
        try setType()
        requests.removeAll()
        XCTAssertThrowsError(try setType())
        XCTAssertTrue(requests.isEmpty)
    }

    func testTypeStepConditionsStopBeforeTheWrite() throws {
        let cases: [(String, () -> Void)] = [
            ("control not enabled", { self.control = 255 }),
            ("desired type already set", { self.desired = 7 }),
            ("sensor info present", { self.stored = ("1111", "111111111111") }),
            ("not Manual", { self.mode = 2 }),
            ("bolus running", { self.delivery = 5 }),
            ("faulted", { self.fault = 0xe2 }),
        ]
        for (index, (name, change)) in cases.enumerated() {
            control = 0; desired = 0; cgm = 1; mode = 1; delivery = 2; fault = 0; stored = nil
            change()
            requests.removeAll()
            XCTAssertThrowsError(try O5G7TypeExperiment.setDesiredType(target: "pod-\(index)", firmware: "9.0.4",
                bleFirmware: "5.0.2", directory: root, send: send, detailedStatus: detailed), name)
            XCTAssertTrue(writes.isEmpty, name)
        }
    }

    func testRejectedOrLostTypeWriteIsNeverRepeated() throws {
        typeReply = "-17"; typeApplies = false
        XCTAssertThrowsError(try setType())
        XCTAssertEqual(try phase("type.json"), "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try setType())
        XCTAssertTrue(requests.isEmpty)

        try FileManager.default.removeItem(at: root)
        typeReply = "0"; typeApplies = true; failNext = "SE4.2"
        XCTAssertThrowsError(try setType())
        XCTAssertEqual(try phase("type.json"), "stopped") // the write was sent; its reply was lost
        requests.removeAll()
        XCTAssertThrowsError(try setType())
        XCTAssertTrue(requests.isEmpty)
    }

    func testTypeReadbackMismatchStops() throws {
        typeApplies = false
        XCTAssertThrowsError(try setType())
        XCTAssertEqual(try phase("type.json"), "stopped")
    }

    func testTypeStepStoppedBeforeTheWriteMayRunAgain() throws {
        failNext = "G3.12"
        XCTAssertThrowsError(try setType())
        XCTAssertTrue(writes.isEmpty)
        try setType()
        XCTAssertEqual(writes, [typeWrite])
        XCTAssertEqual(try phase("type.json"), "verified")
        XCTAssertTrue(try XCTUnwrap(try O5G7TypeExperiment.record(target: target, directory: root)).contains("earlier attempt"))
    }

    // MARK: - Step 2

    func testBatchNeedsAVerifiedTypeStep() throws {
        desired = 7
        XCTAssertThrowsError(try sendBatch())
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(try phase("batch.json"))
    }

    func testBatchAfterTheTypeStepStoresTheIdentity() throws {
        try setType()
        requests.removeAll()
        let summary = try sendBatch()
        XCTAssertEqual(writes, [batch])
        XCTAssertEqual(names(requests), ["G3.12", "G4.2", "G4.1", "batch", "G4.2", "G4.1", "G3.12"])
        XCTAssertEqual(try phase("batch.json"), "stored")
        XCTAssertTrue(summary.hasPrefix("Identity accepted"))
    }

    func testRejectedBatchIsNeverRepeated() throws {
        try setType()
        batchReply = "0,ES4.1=-18"; batchStores = false
        XCTAssertThrowsError(try sendBatch()) { XCTAssertTrue($0.localizedDescription.contains("-18")) }
        XCTAssertEqual(try phase("batch.json"), "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try sendBatch())
        XCTAssertTrue(requests.isEmpty)
    }

    func testBatchThatResetsTheDesiredTypeIsRecordedAsSuch() throws {
        try setType()
        batchClearsDesiredType = true
        XCTAssertThrowsError(try sendBatch()) { XCTAssertTrue($0.localizedDescription.contains("identity stored")) }
        XCTAssertEqual(try phase("batch.json"), "stopped")
        let record = try XCTUnwrap(try O5G7TypeExperiment.record(target: target, directory: root))
        XCTAssertTrue(record.contains("Desired sensor: 0"))
    }

    func testBatchConditionsStopBeforeTheWrite() throws {
        try setType()
        stored = ("1111", "111111111111")
        XCTAssertThrowsError(try sendBatch())
        XCTAssertEqual(writes, [typeWrite])
        stored = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("pod-A-1-2-ble").appendingPathComponent("batch.json"))
        desired = 0
        XCTAssertThrowsError(try sendBatch())
        XCTAssertEqual(writes, [typeWrite])
    }

    func testLostBatchReplyIsNotRepeated() throws {
        try setType()
        failNext = "SE4.2"
        XCTAssertThrowsError(try sendBatch())
        XCTAssertEqual(try phase("batch.json"), "stopped") // the batch was sent; its reply was lost
        requests.removeAll()
        XCTAssertThrowsError(try sendBatch())
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidInputSendsNothing() throws {
        try setType()
        requests.removeAll()
        XCTAssertThrowsError(try sendBatch(code: "12a4"))
        XCTAssertThrowsError(try sendBatch(serial: "1"))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(try phase("batch.json"))
    }

    // MARK: - Desired type set at activation

    func testBatchRunsWithoutStepOneWhenTheTypeWasSetAtActivation() throws {
        desired = 7
        try sendBatch(typeSetAtActivation: true)
        XCTAssertEqual(writes, [batch])
        XCTAssertNil(try phase("type.json"))
        XCTAssertEqual(try phase("batch.json"), "stored")
    }
    func testBatchStillRefusesWithoutStepOneOrActivationType() throws {
        desired = 7
        XCTAssertThrowsError(try sendBatch())
        XCTAssertTrue(requests.isEmpty)
    }
    func testActivationTypeStillRequiresTypeSevenOnThePod() throws {
        desired = 0
        XCTAssertThrowsError(try sendBatch(typeSetAtActivation: true))
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - Placeholder record

    private func recordText() throws -> String {
        try XCTUnwrap(try O5G7TypeExperiment.record(target: target, directory: root))
    }

    func testTypeStepAcceptsThePlaceholderRecord() throws {
        try setType()
        XCTAssertEqual(try phase("type.json"), "verified")
        XCTAssertTrue(try recordText().contains("placeholder G7 record"))
    }

    func testIdentityAppearingAfterTheTypeWriteStops() throws {
        afterType = { self.stored = ("1111", "111111111111") }
        XCTAssertThrowsError(try setType()) { XCTAssertTrue($0.localizedDescription.contains("sensor identity appeared")) }
        XCTAssertEqual(try phase("type.json"), "stopped")
    }

    func testBatchRunsOverThePlaceholderRecord() throws {
        try setType()
        requests.removeAll()
        try sendBatch()
        XCTAssertEqual(writes, [batch])
        XCTAssertEqual(try phase("batch.json"), "stored")
    }

    /// A type.json as written by a build before the placeholder fix.
    private func writeOldTypeRecord(reason: String) throws {
        let dir = root.appendingPathComponent("pod-A-1-2-ble")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["schema": 1, "step": O5G7TypeExperiment.typeStep, "target": target,
            "firmware": "9.0.4", "bleFirmware": "5.0.2", "created": 0, "revisions": [String: String](),
            "phase": "stopped", "exchanges": [Any](), "observations": [Any](), "reason": reason]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("type.json"))
    }

    func testBatchRunsAfterStep1StoppedOnThePlaceholder() throws {
        try writeOldTypeRecord(reason: O5G7TypeExperiment.placeholderStopReason)
        desired = 7; stored = ("0000", "000000000000")
        try sendBatch()
        XCTAssertEqual(writes, [batch])
        XCTAssertEqual(try phase("batch.json"), "stored")
    }

    func testBatchRefusesAStep1StoppedForAnotherReason() throws {
        try writeOldTypeRecord(reason: "readback is not desired type 7 with control enabled")
        desired = 7; stored = ("0000", "000000000000")
        XCTAssertThrowsError(try sendBatch())
        XCTAssertTrue(requests.isEmpty)
    }

    func testBatchStopsOnAStoredIdentity() throws {
        try setType()
        stored = ("1111", "111111111111")
        XCTAssertThrowsError(try sendBatch())
        XCTAssertEqual(writes, [typeWrite])
    }

    // MARK: - Step 3: replace the identity

    /// A Pod receiving one G7, and a second sensor's identity to replace it with.
    private func podWithSensor() {
        control = 0; desired = 7; cgm = 7; mode = 1; delivery = 2; fault = 0
        stored = ("1234", "123456789012")
        sent = ("5678", "567856785678")
    }
    @discardableResult
    private func replace(target: String? = nil) throws -> String {
        try O5G7TypeExperiment.replaceIdentity(target: target ?? self.target, firmware: "9.0.4", bleFirmware: "5.0.2",
            pairingCode: sent.code, serialNumber: sent.serial, directory: root, send: send, detailedStatus: detailed)
    }

    func testReplaceStoresTheNewIdentity() throws {
        podWithSensor()
        let summary = try replace()
        XCTAssertEqual(writes, [batch])
        XCTAssertEqual(names(requests), ["G3.12", "G4.2", "G4.1", "batch", "G4.2", "G4.1", "G3.12"])
        XCTAssertEqual(try phase("replace.json"), "replaced")
        XCTAssertEqual(stored?.code, "5678")
        XCTAssertTrue(summary.hasPrefix("New identity accepted"))
        XCTAssertTrue(try recordText().contains(O5G7TypeExperiment.replaceStep))
    }

    func testReplaceRunsAfterStepTwoStoredTheFirstIdentity() throws {
        desired = 7
        try sendBatch(typeSetAtActivation: true)
        cgm = 7; sent = ("5678", "567856785678")
        requests.removeAll()
        try replace()
        XCTAssertEqual(writes, [batch])
        XCTAssertEqual(try phase("batch.json"), "stored")
        XCTAssertEqual(try phase("replace.json"), "replaced")
    }

    func testReplaceRunsOnce() throws {
        podWithSensor()
        try replace()
        requests.removeAll()
        sent = ("9999", "999999999999")
        XCTAssertThrowsError(try replace())
        XCTAssertTrue(requests.isEmpty)
    }

    func testReplaceNeverResendsTheStoredIdentity() throws {
        podWithSensor()
        sent = stored!
        XCTAssertThrowsError(try replace()) { XCTAssertTrue($0.localizedDescription.contains("already has this identity")) }
        XCTAssertTrue(writes.isEmpty)
        // Stopped before the write, so it may run again with a different identity.
        sent = ("5678", "567856785678")
        try replace()
        XCTAssertEqual(writes, [batch])
    }

    func testReplaceConditionsStopBeforeTheWrite() throws {
        let cases: [(String, () -> Void)] = [
            ("no identity", { self.stored = nil }),
            ("placeholder record", { self.stored = ("0000", "000000000000") }),
            ("no G7 configured", { self.cgm = 1 }),
            ("control not enabled", { self.control = 255 }),
            ("desired type not G7", { self.desired = 0 }),
            ("not Manual", { self.mode = 2 }),
            ("bolus running", { self.delivery = 5 }),
            ("faulted", { self.fault = 0xe2 }),
        ]
        for (index, (name, change)) in cases.enumerated() {
            podWithSensor()
            change()
            requests.removeAll()
            XCTAssertThrowsError(try replace(target: "pod-\(index)"), name)
            XCTAssertTrue(writes.isEmpty, name)
        }
    }

    func testRejectedReplacementIsNeverRepeated() throws {
        podWithSensor()
        batchReply = "0,ES4.1=-18"; batchStores = false
        XCTAssertThrowsError(try replace()) { XCTAssertTrue($0.localizedDescription.contains("-18")) }
        XCTAssertEqual(try phase("replace.json"), "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try replace())
        XCTAssertTrue(requests.isEmpty)
    }

    func testLostReplacementReplyIsNotRepeated() throws {
        podWithSensor()
        failNext = "SE4.2"
        XCTAssertThrowsError(try replace())
        XCTAssertEqual(try phase("replace.json"), "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try replace())
        XCTAssertTrue(requests.isEmpty)
    }

    func testReplacementNotReadBackStops() throws {
        podWithSensor()
        batchStores = false
        XCTAssertThrowsError(try replace()) { XCTAssertTrue($0.localizedDescription.contains("did not read back the new identity")) }
        XCTAssertEqual(try phase("replace.json"), "stopped")
    }

    func testInvalidReplacementInputSendsNothing() throws {
        podWithSensor()
        sent = ("12a4", "567856785678")
        XCTAssertThrowsError(try replace())
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(try phase("replace.json"))
    }
}
