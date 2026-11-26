//
//  O5PodGlucoseTests.swift
//  OmniTests
//

import XCTest
import LoopKit
@testable import OmnipodKit

final class O5PodGlucoseTests: XCTestCase {
    private let received = Date(timeIntervalSince1970: 1_800_000_000)

    /// A G3.12 reply with a G7 block. Field layout as in O5UnifiedAidStatus.
    private func aidStatus(egv: Int16, referenceTime: UInt32 = 1_000_000, podTime: UInt32 = 1_000_058,
                           cgmType: UInt8 = 7, algorithmState: UInt8? = 6,
                           trendRaw: Int8 = 0, trendValid: Bool = true) -> Data
    {
        func be<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var block = Data()
        if let algorithmState {
            block = be(UInt32(50)) + be(Int32(907_200)) + be(Int32(143_872))
            block += Data([algorithmState, 0, UInt8(bitPattern: trendRaw), trendValid ? 1 : 0])
        }
        var body = be(egv) + be(referenceTime) + be(UInt16(14)) + Data([1]) + be(Int32(0)) + be(podTime)
        body += Data([0, 3, cgmType]) + be(UInt16(block.count)) + block
        return be(UInt16(body.count)) + body
    }

    private func glucose(_ reply: Data) throws -> O5PodGlucose {
        O5PodGlucose(status: try O5UnifiedAidStatus(reply), receivedAt: received)
    }

    func testReadingIsTimedFromThePodClock() throws {
        let g = try glucose(aidStatus(egv: 123, referenceTime: 1_000_000, podTime: 1_000_058, trendRaw: -12))
        XCTAssertEqual(g.sensorState, .ok)
        XCTAssertTrue(g.hasValidSensorSession)
        let reading = try XCTUnwrap(g.reading)
        XCTAssertEqual(reading.glucose, 123)
        XCTAssertEqual(reading.date, received.addingTimeInterval(-58))
        XCTAssertEqual(reading.trendRate, -1.2)
        XCTAssertEqual(reading.trend, .down)
        XCTAssertNil(reading.condition)
        XCTAssertEqual(reading.syncIdentifier, "O5-G7 1000000")
    }

    func testLowAndHighMarkersAreClampedWithACondition() throws {
        let low = try XCTUnwrap(glucose(aidStatus(egv: 39)).reading)
        XCTAssertEqual(low.clampedGlucose, 40)
        XCTAssertEqual(low.condition, .belowRange)
        let high = try XCTUnwrap(glucose(aidStatus(egv: 401)).reading)
        XCTAssertEqual(high.clampedGlucose, 400)
        XCTAssertEqual(high.condition, .aboveRange)
        XCTAssertNil(try glucose(aidStatus(egv: 402)).reading)
    }

    func testUnknownOrInvalidTrendGivesNoTrend() throws {
        XCTAssertNil(try glucose(aidStatus(egv: 120, trendRaw: 127)).reading?.trendRate)
        XCTAssertNil(try glucose(aidStatus(egv: 120, trendRaw: 5, trendValid: false)).reading?.trendRate)
        XCTAssertEqual(try glucose(aidStatus(egv: 120, trendRaw: 35)).reading?.trend, .upUpUp)
        XCTAssertEqual(try glucose(aidStatus(egv: 120, trendRaw: 5)).reading?.trend, .flat)
    }

    func testNoSensorStates() throws {
        // CGM type 1 with EGV -9: no transmitter identity (captured after the early enable).
        let noIdentity = try glucose(aidStatus(egv: -9, cgmType: 1, algorithmState: nil))
        XCTAssertEqual(noIdentity.sensorState, .noSensor)
        XCTAssertFalse(noIdentity.hasValidSensorSession)
        // Desired type 7 with no data yet.
        XCTAssertEqual(try glucose(aidStatus(egv: -9, algorithmState: nil)).sensorState, .noSensor)
    }

    func testPairingAfterANewIdentity() throws {
        // EGV -3 and an unset G7 block, as right after an identity was accepted.
        let g = try glucose(aidStatus(egv: -3, algorithmState: 255))
        XCTAssertEqual(g.sensorState, .pairing)
        XCTAssertTrue(g.hasValidSensorSession)
        XCTAssertNil(g.reading)
    }

    func testGlucoseOutsideStateOkIsNotUsed() throws {
        // The first value can arrive while the Pod still reports state 255.
        XCTAssertNil(try glucose(aidStatus(egv: 110, algorithmState: 255)).reading)
        XCTAssertEqual(try glucose(aidStatus(egv: 110, algorithmState: 2)).sensorState, .warmup)
        XCTAssertNil(try glucose(aidStatus(egv: 110, algorithmState: 2)).reading)
        XCTAssertEqual(try glucose(aidStatus(egv: -2, algorithmState: 6)).sensorState, .temporaryIssue)
    }

    func testEndedSession() throws {
        // EGV -5 with G7 state 24 (expired), as seen when the old sensor's session had ended.
        let g = try glucose(aidStatus(egv: -5, algorithmState: 24))
        XCTAssertEqual(g.sensorState, .ended)
        XCTAssertFalse(g.hasValidSensorSession)
        XCTAssertNil(g.reading)
    }

    func testPodClockBehindTheReferenceGivesNoReading() throws {
        XCTAssertNil(try glucose(aidStatus(egv: 120, referenceTime: 1_000_100, podTime: 1_000_000)).reading)
    }
}
