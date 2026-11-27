//
//  O5G7AddTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5G7AddTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fresh = O5G7TypeExperiment.Progress(typeVerifiedWriteDate: nil, typeAvailable: true,
                                                     batchAvailable: true, replaceAvailable: true)

    private func next(control: UInt8? = 0, desired: UInt8? = 0, identity: Bool = false,
                      progress: O5G7TypeExperiment.Progress? = nil, atActivation: Bool = false) -> O5G7AddStep {
        O5G7AddStep.next(pod: .init(control: control, desiredSensorType: desired, hasIdentity: identity),
                         progress: progress ?? fresh, typeSetAtActivation: atActivation, now: now)
    }

    private func isUnavailable(_ step: O5G7AddStep) -> Bool {
        if case .unavailable = step { return true }
        return false
    }

    func testControlNotEnabledIsUnavailable() {
        XCTAssertTrue(isUnavailable(next(control: 255)))
        XCTAssertTrue(isUnavailable(next(control: nil)))
        XCTAssertTrue(isUnavailable(next(control: 255, desired: 7, identity: true)))
    }

    func testNewPodStartsWithTheTypeWrite() {
        XCTAssertEqual(next(), .setType)
    }

    func testTypeWriteThatReachedThePodIsNotOfferedAgain() {
        var progress = fresh
        progress.typeAvailable = false
        XCTAssertTrue(isUnavailable(next(progress: progress)))
    }

    func testIdentityWaitsFifteenMinutesAfterTheTypeWrite() {
        var progress = fresh
        progress.typeAvailable = false
        progress.typeVerifiedWriteDate = now.addingTimeInterval(-60)
        XCTAssertEqual(next(desired: 7, progress: progress), .wait(until: now.addingTimeInterval(14 * 60)))
        progress.typeVerifiedWriteDate = now.addingTimeInterval(-15 * 60)
        XCTAssertEqual(next(desired: 7, progress: progress), .add)
    }

    func testTypeSetAtActivationNeedsNoWait() {
        XCTAssertEqual(next(desired: 7, atActivation: true), .add)
    }

    func testUnverifiedDesiredTypeIsUnavailable() {
        XCTAssertTrue(isUnavailable(next(desired: 7)))
        XCTAssertTrue(isUnavailable(next(desired: 3)))
        XCTAssertTrue(isUnavailable(next(desired: nil)))
    }

    func testIdentityBatchIsOfferedOnce() {
        var progress = fresh
        progress.typeVerifiedWriteDate = now.addingTimeInterval(-3600)
        progress.batchAvailable = false
        XCTAssertTrue(isUnavailable(next(desired: 7, progress: progress)))
    }

    func testPodWithASensorOffersReplaceOnce() {
        var progress = fresh
        progress.batchAvailable = false
        XCTAssertEqual(next(desired: 7, identity: true, progress: progress), .replace)
        progress.replaceAvailable = false
        XCTAssertTrue(isUnavailable(next(desired: 7, identity: true, progress: progress)))
    }
}
