//
//  O5PodDataLogTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5PodDataLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func lines(_ target: String) throws -> [[String: Any]] {
        O5PodDataLog.flush()
        let text = try String(contentsOf: O5PodDataLog.fileURL(target: target, directory: root), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testHeaderIsWrittenOncePerPod() throws {
        O5PodDataLog.append(target: "pod-A:1:2:ble", header: ["firmware": "9.0.4"], entry: ["kind": "status"], directory: root)
        O5PodDataLog.append(target: "pod-A:1:2:ble", header: ["firmware": "other"], entry: ["kind": "command"], directory: root)
        O5PodDataLog.append(target: "pod-B:1:2:ble", header: ["firmware": "9.0.4"], entry: ["kind": "status"], directory: root)
        let a = try lines("pod-A:1:2:ble")
        XCTAssertEqual(a.map { $0["kind"] as? String }, ["header", "status", "command"])
        XCTAssertEqual(a[0]["firmware"] as? String, "9.0.4")
        XCTAssertNotNil(a[1]["phoneTime"] as? String)
        XCTAssertEqual(try lines("pod-B:1:2:ble").count, 2)
    }

    func testEmptyTargetWritesNothing() throws {
        O5PodDataLog.append(target: "", header: [:], entry: ["kind": "status"], directory: root)
        O5PodDataLog.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testBolusFieldsIncludeTheO5Split() throws {
        let bolus = BolusExtraCommand(units: 1.5, bolusInfo: BolusInfo(mealUnits: 1.0, correctionUnits: 0.5))
        let fields = try XCTUnwrap(O5PodDataLog.commandFields([bolus]))
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0]["type"] as? String, "bolus")
        XCTAssertEqual(fields[0]["units"] as? Double, 1.5)
        XCTAssertEqual(fields[0]["mealUnits"] as? Double, 1.0)
        XCTAssertEqual(fields[0]["correctionUnits"] as? Double, 0.5)
    }

    func testTempBasalAndCancelFields() throws {
        let temp = TempBasalExtraCommand(rate: 0.5, duration: .hours(1), podType: dashType)
        let cancel = CancelDeliveryCommand(nonce: 0, deliveryType: .tempBasal, beepType: .noBeepCancel)
        let fields = try XCTUnwrap(O5PodDataLog.commandFields([cancel, temp]))
        XCTAssertEqual(fields.map { $0["type"] as? String }, ["cancelDelivery", "tempBasal"])
        XCTAssertEqual(fields[1]["durationSeconds"] as? Double, 3600)
        let segments = try XCTUnwrap(fields[1]["segments"] as? [[String: Double]])
        XCTAssertTrue(segments.allSatisfy { $0["unitsPerHour"] == 0.5 })
    }

    func testNonDeliveryBlocksAreNotCommands() {
        XCTAssertNil(O5PodDataLog.commandFields([GetStatusCommand()]))
    }

    func testStatusFieldsKeepTheRawResponse() throws {
        let status = try StatusResponse(encodedData: Data(hexadecimalString: "1d19050ec82c08376f9801dc")!)
        let fields = O5PodDataLog.statusFields(status)
        // StatusResponse.data excludes the 2-byte CRC.
        XCTAssertEqual(fields["raw"] as? String, "1d19050ec82c08376f98")
        XCTAssertEqual(fields["insulinDelivered"] as? Double, status.insulinDelivered)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: fields))
    }

    func testAidStatusFieldsFromARealReply() {
        // Status read 6 of the 2026-11-20 Pod.
        let reply = Data(hexadecimalString: "0016fff76b0189d3000e01000250ef6b018a890003010000")!
        let fields = O5PodDataLog.aidStatusFields(reply)
        XCTAssertEqual(fields["podTime"] as? Int, 1795263113)
        XCTAssertEqual(fields["egvRefTime"] as? Int, 1795262931)
        XCTAssertEqual(fields["iobRaw"] as? Int, 151791)
        XCTAssertEqual(fields["cgmType"] as? Int, 1)
    }

    func testUndecodableAidStatusKeepsRawOnly() {
        let fields = O5PodDataLog.aidStatusFields(Data([1, 2, 3]))
        XCTAssertEqual(fields["raw"] as? String, "010203")
        XCTAssertNil(fields["podTime"])
    }

    func testInvalidNumbersAreSkippedInsteadOfCrashing() throws {
        XCTAssertThrowsError(try O5PodDataLog.line(["value": Double.nan]))
        XCTAssertThrowsError(try O5PodDataLog.line(["value": Double.infinity]))
        O5PodDataLog.append(target: "pod-A", header: [:], entry: ["kind": "command", "units": Double.nan], directory: root)
        O5PodDataLog.append(target: "pod-A", header: [:], entry: ["kind": "status"], directory: root)
        XCTAssertEqual(try lines("pod-A").map { $0["kind"] as? String }, ["header", "status"])
    }
}
