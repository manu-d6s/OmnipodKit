//
//  O5PodGlucose.swift
//  OmnipodKit
//

import Foundation
import LoopKit

/// The state of a Dexcom G7 that an O5 Pod reads itself, and its latest glucose,
/// taken from one G3.12 AID status reply.
struct O5PodGlucose: Equatable {
    enum SensorState: Equatable {
        /// No G7 is configured on the Pod, or it has no identity yet.
        case noSensor
        /// The Pod has an identity but no reading yet.
        case pairing
        case warmup
        case ok
        /// No usable reading right now, but more are expected.
        case temporaryIssue
        /// The session is over or failed; only a new sensor brings readings back.
        case ended
    }

    struct Reading: Equatable {
        /// Pod-clock seconds of the reading, unique per reading.
        let referenceTime: UInt32
        let date: Date
        /// mg/dL as the sensor reported it; 39 and 401 mark LOW and HIGH.
        let glucose: Int16
        /// mg/dL per minute.
        let trendRate: Double?

        static let minimum: Int16 = 40
        static let maximum: Int16 = 400

        var clampedGlucose: Int16 { min(max(glucose, Self.minimum), Self.maximum) }

        var condition: GlucoseCondition? {
            if glucose < Self.minimum { return .belowRange }
            if glucose > Self.maximum { return .aboveRange }
            return nil
        }

        var trend: GlucoseTrend? {
            guard let rate = trendRate, abs(rate) <= 8 else { return nil }
            switch rate {
            case ...(-3): return .downDownDown
            case ...(-2): return .downDown
            case ...(-1): return .down
            case ..<1: return .flat
            case ..<2: return .up
            case ..<3: return .upUp
            default: return .upUpUp
            }
        }

        var syncIdentifier: String { "O5-G7 \(referenceTime)" }
    }

    /// The G7 session in phone time, from the sensor's clock (time since it was started)
    /// and its session length, which includes the grace period after expiry.
    struct Session: Equatable {
        static let gracePeriod: TimeInterval = .hours(12)
        static let warmupDuration: TimeInterval = .minutes(27)

        let activatedAt: Date
        let length: TimeInterval

        var expiresAt: Date { activatedAt.addingTimeInterval(length - Self.gracePeriod) }
        var endsAt: Date { activatedAt.addingTimeInterval(length) }
        var warmupEndsAt: Date { activatedAt.addingTimeInterval(Self.warmupDuration) }
        /// The session without its grace period.
        var lifetime: TimeInterval { length - Self.gracePeriod }
    }

    static let g7SensorType: UInt8 = 7

    let sensorState: SensorState
    /// The G7 algorithm state byte, when the Pod reports a G7 block.
    let algorithmState: UInt8?
    /// A reading the app may use: a G7 glucose with the algorithm in state ok.
    let reading: Reading?
    /// The running session, while the sensor is past pairing and still in its session.
    /// Not derived once the session has ended, because the sensor clock then stops.
    let session: Session?

    /// - Parameter receivedAt: phone time when the reply arrived. Reading times are
    ///   converted from the Pod clock relative to this, so Pod clock offset does not matter.
    init(status: O5UnifiedAidStatus, receivedAt: Date) {
        guard status.cgmType == Self.g7SensorType, status.egvRaw != -9 else {
            sensorState = .noSensor
            algorithmState = nil
            reading = nil
            session = nil
            return
        }
        algorithmState = status.g7?.algorithmState
        sensorState = Self.sensorState(egvRaw: status.egvRaw, algorithmState: algorithmState)

        if sensorState == .ok, let glucose = status.egv, (39...401).contains(glucose),
           status.referenceTime > 0, status.podTime >= status.referenceTime
        {
            let age = TimeInterval(status.podTime - status.referenceTime)
            let rate = status.g7?.trendRate.flatMap { $0 == 127 ? nil : Double($0) / 10 }
            reading = Reading(referenceTime: status.referenceTime, date: receivedAt.addingTimeInterval(-age),
                              glucose: glucose, trendRate: rate)
        } else {
            reading = nil
        }

        // The sensor time belongs to the latest sensor data: the reading, or else the
        // reference time the Pod reports with it.
        let sensorDataDate: Date
        if let reading {
            sensorDataDate = reading.date
        } else if status.referenceTime > 0, status.podTime >= status.referenceTime {
            sensorDataDate = receivedAt.addingTimeInterval(-TimeInterval(status.podTime - status.referenceTime))
        } else {
            sensorDataDate = receivedAt
        }
        if [.warmup, .ok, .temporaryIssue].contains(sensorState), let g7 = status.g7,
           g7.sessionDuration > Int32(Session.gracePeriod), g7.sessionDuration <= Int32(TimeInterval.hours(24 * 30)),
           g7.sensorTimestamp >= 0, g7.sensorTimestamp <= g7.sessionDuration
        {
            session = Session(activatedAt: sensorDataDate.addingTimeInterval(-TimeInterval(g7.sensorTimestamp)),
                              length: TimeInterval(g7.sessionDuration))
        } else {
            session = nil
        }
    }

    private static func sensorState(egvRaw: Int16, algorithmState: UInt8?) -> SensorState {
        switch algorithmState {
        case 6?:
            return egvRaw > 0 ? .ok : .temporaryIssue
        case 2?:
            return .warmup
        case 1?, 15?, 16?, 17?, 19?, 20?, 21?, 22?, 24?, 25?, 26?, 27?, 28?, 29?:
            return .ended
        case nil, 255?:
            // No G7 state from the sensor yet: the Pod is still pairing.
            return egvRaw == -5 ? .ended : .pairing
        default:
            return egvRaw == -5 ? .ended : .temporaryIssue
        }
    }

    /// Whether more readings can come without the user starting a new sensor.
    var hasValidSensorSession: Bool {
        switch sensorState {
        case .noSensor, .ended: return false
        case .pairing, .warmup, .ok, .temporaryIssue: return true
        }
    }
}
