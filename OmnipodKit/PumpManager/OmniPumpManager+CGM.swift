//
//  OmniPumpManager+CGM.swift
//  OmnipodKit
//

import Foundation
import HealthKit
import LoopKit

/// What the Pod last reported about its G7, and the newest reading already passed on.
struct O5PodGlucoseState {
    var latest: O5PodGlucose?
    var lastReadDate: Date?
    var lastPublishedReferenceTime: UInt32?
    /// The sensor's session, kept once it has ended and cleared when a sensor is paired.
    /// Its start stays as first derived: each read derives it again, a few seconds apart.
    var session: O5PodGlucose.Session?

    mutating func update(_ glucose: O5PodGlucose, readAt: Date) {
        latest = glucose
        lastReadDate = readAt
        if let new = glucose.session {
            if let old = session, abs(new.activatedAt.timeIntervalSince(old.activatedAt)) < .hours(1) {
                session = O5PodGlucose.Session(activatedAt: old.activatedAt, length: new.length)
            } else {
                session = new
            }
        } else if [.noSensor, .pairing].contains(glucose.sensorState) {
            session = nil
        }
    }
}

/// The pump manager and the CGM manager that serves its Pod's G7 readings find each
/// other here. The app creates each of them on its own, in either order.
final class O5PodCGMLink {
    static let shared = O5PodCGMLink()

    private let lock = NSLock()
    private weak var _pump: OmniPumpManager?
    private weak var _cgm: OmniPodG7CGMManager?

    var pump: OmniPumpManager? {
        get { lock.withLock { _pump } }
        set { lock.withLock { _pump = newValue } }
    }

    var cgm: OmniPodG7CGMManager? {
        get { lock.withLock { _cgm } }
        set { lock.withLock { _cgm = newValue } }
    }
}

extension OmniPumpManager {
    /// Whether the app uses this Pod's G7 readings as its CGM.
    var podServesAsCGM: Bool {
        state.podType.isO5 && O5PodCGMLink.shared.cgm?.isInUse == true
    }

    var podCGMStatus: CGMManagerStatus {
        let glucose = lockedPodGlucose.value
        return CGMManagerStatus(hasValidSensorSession: glucose.latest?.hasValidSensorSession ?? false,
                                lastCommunicationDate: glucose.lastReadDate,
                                device: device(for: state))
    }

    /// Reads G3.12 for the CGM and returns its reading if it was not passed on before.
    func fetchPodGlucose(completion: @escaping (CGMReadingResult) -> Void) {
        guard state.podType.isO5, hasActivePod, let podState = state.podState, !podState.isFaulted,
              podState.unacknowledgedCommand == nil else {
            completion(.noData)
            return
        }
        runSession(withName: "Read Pod glucose") { result in
            switch result {
            case .success(let session):
                do {
                    let reply = try session.sendO5AidCommand((data: Data("G3.12".utf8), responsePrefix: "3.12="))
                    let samples = self.processPodGlucose(reply, receivedAt: self.dateGenerator())
                    completion(samples.isEmpty ? .noData : .newData(samples))
                } catch {
                    completion(.error(error))
                }
            case .failure(let error):
                completion(.error(error))
            }
        }
    }

    /// Passes a reading from a G3.12 read made for another reason on to the CGM manager.
    func publishPodGlucose(from reply: Data, receivedAt: Date) {
        let samples = processPodGlucose(reply, receivedAt: receivedAt)
        if !samples.isEmpty {
            O5PodCGMLink.shared.cgm?.deliver(.newData(samples))
        }
    }

    /// Records the Pod's G7 state and returns its reading if it has not been passed on yet.
    private func processPodGlucose(_ reply: Data, receivedAt: Date) -> [NewGlucoseSample] {
        let status: O5UnifiedAidStatus
        do {
            status = try O5UnifiedAidStatus(reply)
        } catch {
            log.error("Unreadable G3.12 reply: %{public}@", String(describing: error))
            return []
        }
        let glucose = O5PodGlucose(status: status, receivedAt: receivedAt)

        var previous = O5PodGlucoseState()
        var newReading: O5PodGlucose.Reading?
        lockedPodGlucose.mutate { value in
            previous = value
            value.update(glucose, readAt: receivedAt)
            if let reading = glucose.reading, reading.referenceTime != value.lastPublishedReferenceTime {
                value.lastPublishedReferenceTime = reading.referenceTime
                newReading = reading
            }
        }

        if previous.latest?.hasValidSensorSession != glucose.hasValidSensorSession {
            O5PodCGMLink.shared.cgm?.statusDidChange(podCGMStatus)
        }

        guard let reading = newReading else { return [] }
        return [NewGlucoseSample(
            date: reading.date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(reading.clampedGlucose)),
            condition: reading.condition,
            trend: reading.trend,
            trendRate: reading.trendRate.map { HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: reading.syncIdentifier,
            device: device(for: state)
        )]
    }
}
