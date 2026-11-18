//
//  O5AidStatusTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class O5AidStatusTests: XCTestCase {

    // Example values: EGV 123, Automated, ready and active, G7 with trend -12
    private let g7Status = Data(hexadecimalString:
        "0026" + "007b" + "65001000" + "0028" + "02" + "000005dc" + "65001020" + "00" + "03" + "07" + "0010" +
        "65000000" + "000d2f00" + "00001c20" + "06" + "00" + "f4" + "01")!

    // No CGM: no EGV, Manual, IOB not provided
    private let noCgmStatus = Data(hexadecimalString:
        "0016" + "0000" + "00000000" + "0000" + "01" + "80000000" + "00001000" + "00" + "03" + "00" + "0000")!

    func testG7Status() throws {
        let status = try O5UnifiedAidStatus(g7Status)
        XCTAssertEqual(status.egv, 123)
        XCTAssertEqual(status.egvAge, 32)
        XCTAssertEqual(status.totalDailyInsulin, 40)
        XCTAssertTrue(status.isAutomatedMode)
        XCTAssertFalse(status.isManualMode)
        XCTAssertEqual(status.iobMicroUnits, 1500)
        XCTAssertEqual(status.insulinOnBoard!, 0.0015, accuracy: 0.000001)
        XCTAssertTrue(status.algorithmReady)
        XCTAssertTrue(status.podActive)
        XCTAssertFalse(status.activityMode)
        XCTAssertFalse(status.limitedMode)
        XCTAssertEqual(status.cgmType, 7)
        XCTAssertNil(status.g6)

        let g7 = try XCTUnwrap(status.g7)
        XCTAssertEqual(g7.sessionActivationTime, 0x65000000)
        XCTAssertEqual(g7.sessionDuration, 864000)
        XCTAssertEqual(g7.sensorTimestamp, 7200)
        XCTAssertEqual(g7.algorithmState, 6)
        XCTAssertEqual(g7.transmitterStatus, 0)
        XCTAssertEqual(g7.trendRate, -12)
    }

    func testStatusWithoutCgm() throws {
        let status = try O5UnifiedAidStatus(noCgmStatus)
        XCTAssertNil(status.egv)
        XCTAssertNil(status.egvAge)
        XCTAssertTrue(status.isManualMode)
        XCTAssertNil(status.iobMicroUnits)
        XCTAssertNil(status.insulinOnBoard)
        XCTAssertEqual(status.cgmType, 0)
        XCTAssertTrue(status.cgmData.isEmpty)
        XCTAssertNil(status.g7)
        XCTAssertNil(status.g6)
    }

    func testInvalidG7TrendRate() throws {
        var data = g7Status
        data[data.count - 1] = 0
        let status = try O5UnifiedAidStatus(data)
        XCTAssertNil(status.g7?.trendRate)
    }

    func testDecodesFromDataSlice() throws {
        let response = Data("3.12=".utf8) + g7Status
        let status = try O5UnifiedAidStatus(response.dropFirst(5))
        XCTAssertEqual(status.egv, 123)
    }

    func testRejectsLengthMismatch() {
        XCTAssertThrowsError(try O5UnifiedAidStatus(g7Status.dropLast()))
        XCTAssertThrowsError(try O5UnifiedAidStatus(g7Status + Data([0x00])))
        XCTAssertThrowsError(try O5UnifiedAidStatus(Data([0x00])))
    }

    func testRejectsReservedStateFlags() {
        var data = noCgmStatus
        data[20] = 0x13
        XCTAssertThrowsError(try O5UnifiedAidStatus(data))
    }

    func testRejectsCgmDataLengthForType() {
        var data = noCgmStatus
        data[21] = 7 // G7 needs 16 bytes of CGM data
        XCTAssertThrowsError(try O5UnifiedAidStatus(data))
    }
}
