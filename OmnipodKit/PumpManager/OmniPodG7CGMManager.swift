//
//  OmniPodG7CGMManager.swift
//  OmnipodKit
//

import Foundation
import HealthKit
import LoopKit

/// The CGM the app sees when it takes glucose from a Dexcom G7 that its Omnipod 5 Pod
/// reads itself. It holds no device state of its own: readings, sensor state and Pod
/// communication all come from the app's OmniPumpManager.
public final class OmniPodG7CGMManager: CGMManager {
    public static let pluginIdentifier = "OmnipodG7"

    public var localizedTitle: String {
        LocalizedString("Dexcom G7 via Omnipod 5", comment: "Title of the CGM that takes G7 readings from the Omnipod 5 Pod")
    }

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public init() {
        O5PodCGMLink.shared.cgm = self
    }

    public convenience init?(rawState: RawStateValue) {
        self.init()
    }

    public var rawState: RawStateValue { [:] }

    public var isOnboarded: Bool { true }

    public var inSignalLoss: Bool { false }

    public var isInoperable: Bool { cgmManagerStatus.isInoperable }

    public var debugDescription: String {
        let glucose = O5PodCGMLink.shared.pump?.lockedPodGlucose.value
        return [
            "## OmniPodG7CGMManager",
            "pump: \(O5PodCGMLink.shared.pump == nil ? "none" : "linked")",
            "sensorState: \(glucose?.latest.map { String(describing: $0.sensorState) } ?? "unknown")",
            "lastReadDate: \(String(describing: glucose?.lastReadDate))",
            "sensorActivatedAt: \(String(describing: glucose?.session?.activatedAt))",
            "sensorExpiresAt: \(String(describing: glucose?.session?.expiresAt))",
        ].joined(separator: "\n")
    }

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set {
            delegate.delegate = newValue
            O5PodCGMLink.shared.cgm = self
        }
    }

    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    /// The Pod does not wake the app by itself; the pump heartbeat does that.
    public var providesBLEHeartbeat: Bool { false }

    public var managedDataInterval: TimeInterval? { nil }

    public var shouldSyncToRemoteService: Bool { true }

    public var glucoseDisplay: GlucoseDisplayable? {
        O5PodCGMLink.shared.pump?.lockedPodGlucose.value.latest.map(O5PodGlucoseDisplay.init)
    }

    public var cgmManagerStatus: CGMManagerStatus {
        O5PodCGMLink.shared.pump?.podCGMStatus ?? CGMManagerStatus(hasValidSensorSession: false, device: nil)
    }

    /// Whether the app has this manager set up as its CGM.
    var isInUse: Bool { delegate.delegate != nil }

    // MARK: - Sensor session

    var session: O5PodGlucose.Session? { O5PodCGMLink.shared.pump?.lockedPodGlucose.value.session }

    public var sensorActivatedAt: Date? { session?.activatedAt }

    /// End of the sensor's lifetime, before the grace period.
    public var sensorExpiresAt: Date? { session?.expiresAt }

    /// End of the grace period, when the sensor stops sending readings.
    public var sensorEndsAt: Date? { session?.endsAt }

    /// End of warmup, while the sensor is warming up.
    public var sensorFinishesWarmupAt: Date? {
        O5PodCGMLink.shared.pump?.lockedPodGlucose.value.latest?.sensorState == .warmup ? session?.warmupEndsAt : nil
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        readPod(skippingReadingsNewerThan: .minutes(4.5), completion)
    }

    /// Reads the Pod's glucose and passes a new reading to the delegate. The Pod reads the G7 every
    /// 5 minutes, so the Pod session is skipped while its latest reading is newer than `age`.
    /// Hosts call this on the delegate queue, so nothing here may wait on that queue.
    func readPod(skippingReadingsNewerThan age: TimeInterval, _ completion: @escaping (CGMReadingResult) -> Void) {
        guard let pump = O5PodCGMLink.shared.pump else {
            completion(.noData)
            return
        }
        if let latest = pump.lockedPodGlucose.value.latest?.reading?.date, latest.timeIntervalSinceNow > -age {
            completion(.noData)
            return
        }
        pump.fetchPodGlucose { result in
            // New readings go to the delegate, as those from the pump's status reads do;
            // hosts may ignore the result passed to the completion.
            if case .newData = result {
                self.deliver(result)
                completion(.noData)
            } else {
                completion(result)
            }
        }
    }

    func deliver(_ result: CGMReadingResult) {
        delegate.notify { delegate in
            delegate?.cgmManager(self, hasNew: result)
        }
    }

    func statusDidChange(_ status: CGMManagerStatus) {
        delegate.notify { delegate in
            delegate?.cgmManager(self, didUpdate: status)
        }
    }

    // MARK: - AlertResponder, AlertSoundVendor

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {}

    public func getSoundBaseURL() -> URL? { nil }

    public func getSounds() -> [Alert.Sound] { [] }
}

struct O5PodGlucoseDisplay: GlucoseDisplayable {
    let isStateValid: Bool
    let trendType: GlucoseTrend?
    let trendRate: LoopQuantity?
    let isLocal = true
    let glucoseRangeCategory: GlucoseRangeCategory? = nil

    init(_ glucose: O5PodGlucose) {
        isStateValid = glucose.sensorState == .ok
        trendType = glucose.reading?.trend
        trendRate = glucose.reading?.trendRate.map { LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) }
    }
}
