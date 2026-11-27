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
                           trendRaw: Int8 = 0, trendValid: Bool = true,
                           sessionLength: Int32 = 907_200, sensorTime: Int32 = 143_872) -> Data
    {
        func be<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var block = Data()
        if let algorithmState {
            block = be(UInt32(50)) + be(sessionLength) + be(sensorTime)
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

    // MARK: - Session

    func testSessionComesFromTheSensorClockAtTheReading() throws {
        let g = try glucose(aidStatus(egv: 120, referenceTime: 1_000_000, podTime: 1_000_058))
        let session = try XCTUnwrap(g.session)
        let activated = received.addingTimeInterval(-58 - 143_872)
        XCTAssertEqual(session.activatedAt, activated)
        XCTAssertEqual(session.expiresAt, activated.addingTimeInterval(864_000))
        XCTAssertEqual(session.endsAt, activated.addingTimeInterval(907_200))
        XCTAssertEqual(session.lifetime, 864_000)
    }

    func testSessionWithoutAReadingUsesTheReferenceTime() throws {
        let warmup = try glucose(aidStatus(egv: -3, referenceTime: 1_000_000, podTime: 1_000_100, algorithmState: 2, sensorTime: 600))
        XCTAssertEqual(warmup.sensorState, .warmup)
        XCTAssertEqual(warmup.session?.activatedAt, received.addingTimeInterval(-100 - 600))
        XCTAssertEqual(warmup.session?.warmupEndsAt, received.addingTimeInterval(-700 + 27 * 60))
    }

    func testNoSessionWhilePairingOrEndedOrUnset() throws {
        XCTAssertNil(try glucose(aidStatus(egv: -3, algorithmState: 255)).session)
        XCTAssertNil(try glucose(aidStatus(egv: -5, algorithmState: 24, sensorTime: 912_170)).session)
        XCTAssertNil(try glucose(aidStatus(egv: 120, sessionLength: -1, sensorTime: -1)).session)
        XCTAssertNil(try glucose(aidStatus(egv: 120, sensorTime: 907_201)).session)
        XCTAssertNil(try glucose(aidStatus(egv: 120, cgmType: 1, algorithmState: nil)).session)
    }

    func testStateKeepsTheSessionAfterItEndsAndClearsItForANewSensor() throws {
        var state = O5PodGlucoseState()
        state.update(try glucose(aidStatus(egv: 120)), readAt: received)
        let session = try XCTUnwrap(state.session)
        state.update(try glucose(aidStatus(egv: -5, algorithmState: 24, sensorTime: 912_170)), readAt: received)
        XCTAssertEqual(state.session, session)
        state.update(try glucose(aidStatus(egv: -3, algorithmState: 255)), readAt: received)
        XCTAssertNil(state.session)
    }

    func testStateKeepsTheFirstDerivedStart() throws {
        var state = O5PodGlucoseState()
        state.update(try glucose(aidStatus(egv: 120, referenceTime: 1_000_000, podTime: 1_000_058)), readAt: received)
        let first = try XCTUnwrap(state.session?.activatedAt)
        // The next read derives a start 3 s later; a new sensor's start is far from it.
        state.update(try glucose(aidStatus(egv: 121, referenceTime: 1_000_000, podTime: 1_000_055)), readAt: received)
        XCTAssertEqual(state.session?.activatedAt, first)
        state.update(try glucose(aidStatus(egv: 122, sensorTime: 600)), readAt: received)
        XCTAssertNotEqual(state.session?.activatedAt, first)
    }

    func testLifecycleProgressLikeADirectG7() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = O5PodGlucose.Session(activatedAt: start, length: 907_200)
        let lifetime: TimeInterval = 864_000
        XCTAssertNil(session.lifecycleProgress(ended: false, now: start.addingTimeInterval(lifetime - 49 * 3600)))
        let day2 = session.lifecycleProgress(ended: false, now: start.addingTimeInterval(lifetime - 30 * 3600))
        XCTAssertEqual(day2?.progressState, .normalCGM)
        XCTAssertEqual(day2?.percentComplete ?? 0, 1 - 30 * 3600 / lifetime, accuracy: 1e-9)
        XCTAssertEqual(session.lifecycleProgress(ended: false, now: start.addingTimeInterval(lifetime - 3600))?.progressState, .warning)
        let grace = session.lifecycleProgress(ended: false, now: start.addingTimeInterval(lifetime + 3 * 3600))
        XCTAssertEqual(grace?.progressState, .critical)
        XCTAssertEqual(grace?.percentComplete ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(session.lifecycleProgress(ended: true, now: start)?.percentComplete, 1)
    }
}
