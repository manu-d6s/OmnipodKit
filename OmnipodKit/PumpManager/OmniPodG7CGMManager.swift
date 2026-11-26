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

    public var debugDescription: String {
        let glucose = O5PodCGMLink.shared.pump?.lockedPodGlucose.value
        return [
            "## OmniPodG7CGMManager",
            "pump: \(O5PodCGMLink.shared.pump == nil ? "none" : "linked")",
            "sensorState: \(glucose?.latest.map { String(describing: $0.sensorState) } ?? "unknown")",
            "lastReadDate: \(String(describing: glucose?.lastReadDate))",
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

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        guard let pump = O5PodCGMLink.shared.pump else {
            completion(.noData)
            return
        }
        let newerThan = delegate.call { $0?.startDateToFilterNewData(for: self) }
        if let newerThan, newerThan.timeIntervalSinceNow > -.minutes(4.5) {
            completion(.noData)
            return
        }
        pump.fetchPodGlucose(newerThan: newerThan, completion: completion)
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

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }

    public func getSounds() -> [Alert.Sound] { [] }
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
