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
}

struct O5PodGlucoseDisplay: GlucoseDisplayable {
    let isStateValid: Bool
    let trendType: GlucoseTrend?
    let trendRate: HKQuantity?
    let isLocal = true
    let glucoseRangeCategory: GlucoseRangeCategory? = nil

    init(_ glucose: O5PodGlucose) {
        isStateValid = glucose.sensorState == .ok
        trendType = glucose.reading?.trend
        trendRate = glucose.reading?.trendRate.map { HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) }
    }
}

/// An O5 Pod that reads a Dexcom G7 itself serves as the app's CGM. Readings come from the
/// G3.12 AID status, read after each pump status and on request.
extension OmniPumpManager: CGMManager {
    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { cgmDelegate.delegate }
        set { cgmDelegate.delegate = newValue }
    }

    /// The Pod does not wake the app by itself; the pump heartbeat does that.
    public var providesBLEHeartbeat: Bool { false }

    public var managedDataInterval: TimeInterval? { nil }

    public var shouldSyncToRemoteService: Bool { true }

    public var glucoseDisplay: GlucoseDisplayable? {
        lockedPodGlucose.value.latest.map(O5PodGlucoseDisplay.init)
    }

    public var cgmManagerStatus: CGMManagerStatus {
        let glucose = lockedPodGlucose.value
        return CGMManagerStatus(hasValidSensorSession: glucose.latest?.hasValidSensorSession ?? false,
                                lastCommunicationDate: glucose.lastReadDate,
                                device: device(for: state))
    }

    /// Whether the app uses this Pod as its CGM.
    var podServesAsCGM: Bool {
        state.podType.isO5 && cgmDelegate.delegate != nil
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        guard podServesAsCGM, hasActivePod, let podState = state.podState, !podState.isFaulted,
              podState.unacknowledgedCommand == nil else {
            completion(.noData)
            return
        }
        let newerThan = cgmDelegate.call { $0?.startDateToFilterNewData(for: self) }
        if let newerThan, newerThan.timeIntervalSince(dateGenerator()) > -.minutes(4.5) {
            completion(.noData)
            return
        }

        runSession(withName: "Read Pod glucose") { result in
            switch result {
            case .success(let session):
                do {
                    let reply = try session.sendO5AidCommand((data: Data("G3.12".utf8), responsePrefix: "3.12="))
                    let samples = self.processPodGlucose(reply, receivedAt: self.dateGenerator())
                        .filter { newerThan == nil || $0.date > newerThan! }
                    completion(samples.isEmpty ? .noData : .newData(samples))
                } catch {
                    completion(.error(error))
                }
            case .failure(let error):
                completion(.error(error))
            }
        }
    }

    /// Passes a reading from a G3.12 read made for another reason on to the CGM delegate.
    func publishPodGlucose(from reply: Data, receivedAt: Date) {
        let samples = processPodGlucose(reply, receivedAt: receivedAt)
        if !samples.isEmpty {
            cgmDelegate.notify { delegate in
                delegate?.cgmManager(self, hasNew: .newData(samples))
            }
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
            value.latest = glucose
            value.lastReadDate = receivedAt
            if let reading = glucose.reading, reading.referenceTime != value.lastPublishedReferenceTime {
                value.lastPublishedReferenceTime = reading.referenceTime
                newReading = reading
            }
        }

        if previous.latest?.hasValidSensorSession != glucose.hasValidSensorSession {
            let status = cgmManagerStatus
            cgmDelegate.notify { delegate in
                delegate?.cgmManager(self, didUpdate: status)
            }
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
