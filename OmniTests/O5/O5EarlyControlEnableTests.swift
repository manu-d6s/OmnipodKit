//
//  O5EarlyControlEnableTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5EarlyControlEnableTests: XCTestCase {
    private var root: URL!
    private var id: String!
    private var requests: [Data] = []
    private var control: UInt8 = 255
    private var desired: UInt8 = 0
    private var ready = true
    private var active = true
    private var mode: UInt8 = 1
    private var cgm: UInt8 = 0
    private var fault: UInt8 = 0
    private var delivery: UInt8 = 1
    private var progress: UInt8 = 8
    private var reject: String?
    private var failureIndex: Int?
    private var mutationHook: (() throws -> Void)?
    private var interfaceHook: (() throws -> Void)?
    private var ignoreWrite = false
    private var afterWrite: (() -> Void)?
    private var expectedWrite = Data("SE4.2=".utf8) + Data([0, 2, 4, 0])
    private var typeApplies = true
    private var sensorInfo = Data([0, 0])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        id = UUID().uuidString
        try O5EarlyControlEnable.arm(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2", directory: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var file: URL { root.appendingPathComponent(id).appendingPathComponent("activation.json") }
    private func snapshot() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }
    private func setPhase(_ phase: String) throws {
        var value = try snapshot(); value["phase"] = phase
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }
    private func aidStatus() -> Data {
        var bytes = Data(repeating: 0, count: 24)
        bytes[1] = 22; bytes[10] = mode; bytes[20] = (ready ? 1 : 0) | (active ? 2 : 0); bytes[21] = cgm
        return bytes
    }
    private func interface() -> Data { Data([0, 9, 0, 0, 0, 0, 0x13, 1, desired, 4, control]) }
    private func send(_ request: Data, _ prefix: String) throws -> Data {
        requests.append(request)
        if failureIndex == requests.count { throw URLError(.timedOut) }
        switch String(decoding: request, as: UTF8.self) {
        case "G3.12": return aidStatus()
        case "G4.2":
            try interfaceHook?()
            return interface()
        case "G4.1": return sensorInfo
        default:
            XCTAssertEqual(request, expectedWrite)
            XCTAssertEqual(prefix, "ES4.2=")
            XCTAssertEqual(try snapshot()["phase"] as? String, "writePending")
            let entries = try XCTUnwrap(snapshot()["exchanges"] as? [[String: Any]])
            XCTAssertNil(entries.last?["response"])
            try mutationHook?()
            if !ignoreWrite {
                if request.suffix(2) == Data([1, 7]) {
                    if typeApplies { desired = 7 }
                    if request.count == 12 { control = 0 } // control and type together
                } else {
                    control = 0
                }
            }
            afterWrite?()
            return Data((reject ?? "0").utf8)
        }
    }
    private func detailed() throws -> Data {
        var bytes = Data(repeating: 0, count: 22)
        bytes[0] = 2; bytes[1] = progress; bytes[2] = delivery; bytes[8] = fault
        return bytes
    }
    private func finish(target: String = "pod-A", firmware: String = "9.0.4") throws {
        try O5EarlyControlEnable.finish(id: id, target: target, firmware: firmware, bleFirmware: "5.0.2",
            directory: root, send: send, detailedStatus: detailed)
    }
    private var writes: [Data] { requests.filter { $0.starts(with: Data("S".utf8)) } }

    func testOnlyOneExactControlWriteAndDurableEvidence() throws {
        try finish()
        XCTAssertEqual(writes, [Data("SE4.2=".utf8) + Data([0, 2, 4, 0])])
        XCTAssertEqual(requests.filter { $0.first != 83 }.map { String(decoding: $0, as: UTF8.self) },
            ["G3.12", "G4.2", "G4.2", "G3.12"])
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
        XCTAssertTrue(try O5EarlyControlEnable.record(id: id, directory: root).contains("verified"))
        XCTAssertEqual(desired, 0)
    }
    func testAlreadyEnabledSkipsMutation() throws {
        control = 0; try finish(); XCTAssertTrue(writes.isEmpty)
    }
    func testConfirmedResultCanBeRecheckedAfterRestartWithoutWrite() throws {
        try finish(); requests.removeAll(); try finish(); XCTAssertTrue(writes.isEmpty)
    }
    func testChangedControlAfterVerifiedNeverReenabled() throws {
        try finish(); control = 255; requests.removeAll()
        XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }
    func testEveryInterruptedPhaseStopsBeforeTransport() throws {
        for phase in ["checking", "writePending", "stopped", "unknown"] {
            try setPhase(phase); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
        }
    }
    func testMissingRecordNeverRecreatedForMarkedPod() throws {
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testCorruptRecordNeverSends() throws {
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
    }
    func testWrongPodAndFirmwareNeverSend() throws {
        XCTAssertThrowsError(try finish(target: "pod-B"))
        XCTAssertThrowsError(try finish(firmware: "12.0.0"))
        XCTAssertTrue(requests.isEmpty)
    }
    func testOtherFirmwareStillAttemptsTheEnable() throws {
        id = UUID().uuidString
        try O5EarlyControlEnable.arm(id: id, target: "pod-A", firmware: "10.1.0", bleFirmware: "6.0.0", directory: root)
        XCTAssertNoThrow(try O5EarlyControlEnable.check(id: id, target: "pod-A", firmware: "10.1.0",
                                                        bleFirmware: "6.0.0", requireArmed: true, directory: root))
        try O5EarlyControlEnable.finish(id: id, target: "pod-A", firmware: "10.1.0", bleFirmware: "6.0.0",
            directory: root, send: send, detailedStatus: detailed)
        XCTAssertEqual(writes, [Data("SE4.2=".utf8) + Data([0, 2, 4, 0])])
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
        XCTAssertThrowsError(try O5EarlyControlEnable.check(id: id, target: "pod-A", firmware: "9.0.4",
                                                            bleFirmware: "5.0.2", directory: root))
    }
    func testTypeOneAfterTheEnableIsAccepted() throws {
        afterWrite = { self.cgm = 1 }
        try finish()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
    }
    func testTypeOneWhileControlIsNotEnabledStopsBeforeWrite() throws {
        cgm = 1
        XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }
    func testOtherCgmTypesStopBeforeWrite() throws {
        for type: UInt8 in [7, 4] {
            cgm = type; control = 0; try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
        }
    }
    /// The replies of the first early enable on a worn Pod (firmware 9.0.4 / BLE 5.0.2,
    /// 2026-11-20), two minutes after insertion. The final 3.12 reports CGM type 1.
    func testCapturedFirstPodRepliesVerify() throws {
        let replies: [String: [String]] = [
            "G3.12": ["0016000000000000000e01800000006b00c1d00003000000",
                      "0016fff76b00c1d1000e01000000006b00c1d10003010000"],
            "G4.2": ["000d00ffffffff01000201030104ff", "000d00ffffffff0100020103010400"],
        ]
        var served: [String: Int] = [:]
        var detailedReads = 0
        let detailedReplies = ["02080100000c003700000003ff000200000000005710",
                               "02080100000c003700000003ff000200000000001057"]
        try O5EarlyControlEnable.finish(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2",
            directory: root,
            send: { request, prefix in
                self.requests.append(request)
                if request.starts(with: Data("SE4.2=".utf8)) { return Data("0".utf8) }
                let key = String(decoding: request, as: UTF8.self)
                let index = served[key, default: 0]
                served[key] = index + 1
                return Data(hexadecimalString: replies[key]![index])!
            },
            detailedStatus: {
                defer { detailedReads += 1 }
                return Data(hexadecimalString: detailedReplies[detailedReads])!
            })
        XCTAssertEqual(writes, [Data("SE4.2=".utf8) + Data([0, 2, 4, 0])])
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
    }
    func testCannotRearmOrOverwriteAttempt() throws {
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try O5EarlyControlEnable.arm(id: id, target: "pod-B", firmware: "9.0.4", bleFirmware: "5.0.2", directory: root))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testNonManualAndUnreadyStatusesStopBeforeWrite() throws {
        for field in 0..<5 {
            ready = true; active = true; mode = 1; delivery = 1; fault = 0
            if field == 0 { ready = false }
            if field == 1 { active = false }
            if field == 2 { mode = 2 }
            if field == 3 { delivery = 0 }
            if field == 4 { fault = 226 }
            try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
        }
    }
    func testWrongProgressStopsBeforeWrite() throws {
        progress = 7; XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }
    func testUnexpectedSensorOrControlStopsBeforeWrite() throws {
        for (type, value): (UInt8, UInt8) in [(7, 255), (0, 3), (0, 254)] {
            desired = type; control = value; try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
        }
    }
    func testRejectionStopsAndCannotRetryMutation() throws {
        reject = "-18"; XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testEveryTransportTimeoutStopsAndNoRetry() throws {
        for index in 1...5 {
            control = 255; failureIndex = index; try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish())
            let count = requests.count
            XCTAssertThrowsError(try finish()); XCTAssertEqual(requests.count, count)
        }
    }
    func testLostResponseAfterAppliedWriteCannotBeResent() throws {
        mutationHook = { self.control = 0; throw URLError(.timedOut) }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(control, 0); XCTAssertEqual(writes.count, 1)
        mutationHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testVerificationFailureStopsWithoutRetry() throws {
        ignoreWrite = true
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testPostWriteFaultAndModeChangeStop() throws {
        afterWrite = { self.fault = 226 }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        fault = 0; control = 255; try setPhase("armed"); requests.removeAll()
        afterWrite = { self.mode = 2 }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testConcurrentAttemptCannotAcquireLeaseOrSend() throws {
        mutationHook = {
            XCTAssertThrowsError(try self.finish())
        }
        try finish(); XCTAssertEqual(writes.count, 1)
    }
    func testJournalFailureBeforeSendPreventsWrite() throws {
        // Turn the destination into a directory before the write-intent save.
        // Loading the required journal must fail before any transport call.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
    }
    func testPersistenceFailureAfterPrereadNeverReleasesWrite() throws {
        let directory = file.deletingLastPathComponent()
        interfaceHook = {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try finish())
        XCTAssertTrue(writes.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try snapshot()["phase"] as? String, "checking")
        interfaceHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }

    func testPersistenceFailureAfterAppliedWriteRetainsDurableIntent() throws {
        let directory = file.deletingLastPathComponent()
        mutationHook = {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try finish())
        XCTAssertEqual(control, 0); XCTAssertEqual(writes.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try snapshot()["phase"] as? String, "writePending")
        mutationHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }

    func testVerifiedRecordPermitsReadRecoveryButRejectsRepeatedPhysicalSetup() throws {
        try O5EarlyControlEnable.check(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2",
            requireArmed: true, directory: root)
        try finish()
        try O5EarlyControlEnable.check(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2", directory: root)
        XCTAssertThrowsError(try O5EarlyControlEnable.check(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2",
            requireArmed: true, directory: root))
        XCTAssertEqual(writes.count, 1)
    }


    // MARK: - With desired sensor type G7

    private func armG7() throws {
        id = UUID().uuidString
        try O5EarlyControlEnable.arm(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2",
                                     desiredSensorType: 7, directory: root)
    }
    private var g7Requests: [String] {
        requests.filter { $0.first != 83 }.map { String(decoding: $0, as: UTF8.self) }
    }

    func testInterfaceRequestMatchesTheOfficialFieldOrder() {
        XCTAssertEqual(O5EarlyControlEnable.interfaceRequest(enableControl: true, desiredSensorType: 7),
                       Data("SE4.2=".utf8) + Data([0, 4, 4, 0, 1, 7]))
        XCTAssertEqual(O5EarlyControlEnable.interfaceRequest(enableControl: false, desiredSensorType: 7),
                       Data("SE4.2=".utf8) + Data([0, 2, 1, 7]))
        XCTAssertEqual(O5EarlyControlEnable.interfaceRequest(enableControl: true, desiredSensorType: nil),
                       O5EarlyControlEnable.enableRequest)
    }
    func testG7WritesControlAndTypeTogetherOnce() throws {
        try armG7()
        expectedWrite = Data("SE4.2=".utf8) + Data([0, 4, 4, 0, 1, 7])
        try finish()
        XCTAssertEqual(writes, [expectedWrite])
        XCTAssertEqual(g7Requests, ["G3.12", "G4.2", "G4.2", "G4.1", "G3.12"])
        XCTAssertEqual((control, desired), (0, 7))
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
        XCTAssertEqual(try O5EarlyControlEnable.verifiedDesiredSensorType(id: id, target: "pod-A",
            firmware: "9.0.4", bleFirmware: "5.0.2", directory: root), 7)
    }
    func testG7WithControlAlreadyEnabledWritesOnlyTheType() throws {
        try armG7()
        control = 0
        expectedWrite = Data("SE4.2=".utf8) + Data([0, 2, 1, 7])
        try finish()
        XCTAssertEqual(writes, [expectedWrite])
        XCTAssertEqual(desired, 7)
    }
    func testG7AlreadySetSkipsTheWrite() throws {
        try armG7()
        control = 0; desired = 7; cgm = 1
        try finish()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
    }
    func testG7AcceptsCgmTypeSevenAfterTheWrite() throws {
        try armG7()
        expectedWrite = Data("SE4.2=".utf8) + Data([0, 4, 4, 0, 1, 7])
        afterWrite = { self.cgm = 7 }
        try finish()
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
    }
    func testControlOnlyStillStopsOnCgmTypeSeven() throws {
        afterWrite = { self.cgm = 7 }
        XCTAssertThrowsError(try finish())
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try snapshot()["phase"] as? String, "stopped")
    }
    func testG7StopsWhenTheTypeDoesNotReadBack() throws {
        try armG7()
        expectedWrite = Data("SE4.2=".utf8) + Data([0, 4, 4, 0, 1, 7])
        typeApplies = false
        XCTAssertThrowsError(try finish())
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try snapshot()["phase"] as? String, "stopped")
        requests.removeAll()
        XCTAssertThrowsError(try finish())
        XCTAssertTrue(requests.isEmpty)
    }
    func testG7StopsWhenSensorInfoIsPresent() throws {
        try armG7()
        expectedWrite = Data("SE4.2=".utf8) + Data([0, 4, 4, 0, 1, 7])
        let body = Data([0, 0, 0, 0, 0x0f, 1, 7, 2]) + Data("1234".utf8) + Data([3]) + Data("123456789012".utf8)
        sensorInfo = Data([0, UInt8(body.count)]) + body
        XCTAssertThrowsError(try finish())
        XCTAssertEqual(try snapshot()["phase"] as? String, "stopped")
    }
    func testOnlyG7CanBeArmed() {
        XCTAssertThrowsError(try O5EarlyControlEnable.arm(id: UUID().uuidString, target: "pod-A", firmware: "9.0.4",
            bleFirmware: "5.0.2", desiredSensorType: 4, directory: root))
    }
    func testControlOnlyRecordReportsNoDesiredType() throws {
        try finish()
        XCTAssertNil(try O5EarlyControlEnable.verifiedDesiredSensorType(id: id, target: "pod-A",
            firmware: "9.0.4", bleFirmware: "5.0.2", directory: root))
    }
}
