//
//  O5CgmStatusReportTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5CgmStatusReportTests: XCTestCase {
    // First worn Pod after the early enable (firmware 9.0.4 / BLE 5.0.2, 2026-11-20).
    private let statusAfterEnable = Data(hexadecimalString: "0016fff76b00c1d1000e01000000006b00c1d10003010000")!
    private let interfaceAfterEnable = Data(hexadecimalString: "000d00ffffffff0100020103010400")!
    private let emptySensorInfo = Data([0, 0])

    /// A G7 sensor info reply with mask, type, pairing code and serial (keys 0–3).
    private func g7SensorInfo(code: String, serial: String) -> Data {
        var body = Data([0x00, 0x00, 0x00, 0x00, 0x0f, 0x01, 0x07, 0x02]) + Data(code.utf8)
        body += Data([0x03]) + Data(serial.utf8)
        return Data([0x00, UInt8(body.count)]) + body
    }

    func testCapturedRepliesAfterEarlyEnable() throws {
        let status = try O5UnifiedAidStatus(statusAfterEnable)
        XCTAssertEqual(status.cgmType, 1)
        XCTAssertNil(status.egv)
        XCTAssertEqual(status.egvRaw, -9)
        XCTAssertTrue(status.isManual && status.algorithmReady && status.podActive)
        XCTAssertEqual(try O5CgmInterfaceStatus(interfaceAfterEnable).control, 0)

        let text = O5CgmStatusReport.text(status: statusAfterEnable, interface: interfaceAfterEnable, sensor: emptySensorInfo)
        XCTAssertTrue(text.contains("CGM type: 1 (no information)"))
        XCTAssertTrue(text.contains("Glucose: none (-9, no transmitter identity)"))
        XCTAssertTrue(text.contains("Control: 0 (enabled)"))
        XCTAssertTrue(text.contains("No sensor configured"))
    }

    func testSensorInfoDecodesAndReportHidesTheIdentity() throws {
        let reply = g7SensorInfo(code: "1234", serial: "123456789012")
        let info = try O5G7SensorInfo(reply)
        XCTAssertFalse(info.isEmpty)
        XCTAssertEqual(info.sensorType, 7)
        XCTAssertTrue(info.matches(pairingCode: "1234", serialNumber: "123456789012"))
        XCTAssertFalse(info.matches(pairingCode: "1234", serialNumber: "123456789013"))

        let text = O5CgmStatusReport.text(status: statusAfterEnable, interface: interfaceAfterEnable, sensor: reply)
        XCTAssertTrue(text.contains("Pairing code: set"))
        XCTAssertTrue(text.contains("ending in 9012"))
        XCTAssertFalse(text.contains("1234"))
        XCTAssertFalse(text.contains("12345678"))
    }

    func testSensorInfoForAnotherSensorTypeIsRejected() {
        var reply = g7SensorInfo(code: "1234", serial: "123456789012")
        reply[8] = 4
        XCTAssertThrowsError(try O5G7SensorInfo(reply))
    }

    func testMalformedRepliesAreReportedNotTrusted() {
        let text = O5CgmStatusReport.text(status: Data([0, 1, 0]), interface: Data([0]), sensor: Data([0, 3, 9]))
        XCTAssertEqual(text.components(separatedBy: "Invalid O5 reply").count - 1, 3)
    }
}
