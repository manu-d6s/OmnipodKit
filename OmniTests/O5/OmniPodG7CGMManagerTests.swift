//
//  OmniPodG7CGMManagerTests.swift
//  OmniTests
//

import XCTest
import LoopKit
import RileyLinkBLEKit
@testable import OmnipodKit

final class OmniPodG7CGMManagerTests: XCTestCase {
    /// A host delegate that, like Trio's, requires its calls on its own queue.
    private final class Delegate: CGMManagerDelegate {
        let queue: DispatchQueue
        nonisolated(unsafe) var readingResults: [CGMReadingResult] = []

        nonisolated init(queue: DispatchQueue) { self.queue = queue }

        nonisolated func startDateToFilterNewData(for manager: CGMManager) -> Date? {
            dispatchPrecondition(condition: .onQueue(queue))
            return nil
        }
        nonisolated func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
            dispatchPrecondition(condition: .onQueue(queue))
            readingResults.append(readingResult)
        }
        nonisolated func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
        func cgmManagerWantsDeletion(_ manager: CGMManager) async {}
        nonisolated func cgmManagerDidUpdateState(_ manager: CGMManager) {}
        nonisolated func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
        nonisolated func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
        nonisolated func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?,
                                       type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
        func issueAlert(_ alert: Alert) async {}
        func retractAlert(identifier: Alert.Identifier) async {}
        nonisolated func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
        nonisolated func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
        nonisolated func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
        nonisolated func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    }

    /// Stands in for the RileyLink Bluetooth provider, which needs a Bluetooth background mode.
    private final class DeviceProvider: RileyLinkDeviceProvider {
        weak var delegate: RileyLinkDeviceProviderDelegate?
        var idleListeningState: RileyLinkBluetoothDevice.IdleListeningState = .disabled
        var idleListeningEnabled: Bool { false }
        var timerTickEnabled = false
        var connectingCount: Int { 0 }
        func deprioritize(_ device: RileyLinkDevice, completion: (() -> Void)?) { completion?() }
        func assertIdleListening(forcingRestart: Bool) {}
        func getDevices(_ completion: @escaping ([RileyLinkDevice]) -> Void) { completion([]) }
        func connect(_ device: RileyLinkDevice) {}
        func disconnect(_ device: RileyLinkDevice) {}
        func setScanningEnabled(_ enabled: Bool) {}
        func shouldConnect(to deviceID: String) -> Bool { false }
        var debugDescription: String { "DeviceProvider" }
    }

    /// A pump manager without a Pod. Eros, because the BLE Pod types create a Bluetooth central
    /// with state restoration, which the test host doesn't allow. The CGM manager reads its glucose
    /// state and asks it to read the Pod, which it declines without an O5 Pod.
    private func makePump() -> OmniPumpManager {
        let state = OmniPumpManagerState(isOnboarded: true, podState: nil, timeZone: .current,
            basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1, startTime: 0, podType: erosType)]),
            maxBasalRateUnitsPerHour: 10, maxBolusUnits: 10, insulinType: .novolog,
            podType: erosType, podKeepAlive: .disabled, controllerId: 1, podId: 2)
        return OmniPumpManager(state: state, rileyLinkDeviceProvider: DeviceProvider())
    }

    /// Hosts such as Trio call fetchNewDataIfNeeded on the delegate queue. The manager must
    /// not wait on that queue, which would trap in libdispatch.
    func testFetchOnTheDelegateQueueWithAPumpLinked() throws {
        let pump = makePump()
        XCTAssertTrue(O5PodCGMLink.shared.pump === pump)
        let queue = DispatchQueue(label: "OmniPodG7CGMManagerTests.delegateQueue")
        let delegate = Delegate(queue: queue)
        let cgm = OmniPodG7CGMManager()
        cgm.delegateQueue = queue
        cgm.cgmManagerDelegate = delegate

        let fetched = expectation(description: "fetch completes")
        queue.async {
            cgm.fetchNewDataIfNeeded { result in
                if case .noData = result {} else { XCTFail("expected no data without a Pod, got \(result)") }
                fetched.fulfill()
            }
        }
        wait(for: [fetched], timeout: 5)
        withExtendedLifetime(pump) {}
    }

    func testGlucoseNudgeIsRecognised() {
        XCTAssertTrue(BlePodProfile.isGlucoseNudge(Data([0x0C, 0x00])))
        XCTAssertTrue(BlePodProfile.isGlucoseNudge(Data([0x0C, 0x00, 0x01])))
        XCTAssertTrue(BlePodProfile.isGlucoseNudge(Data([0xFF, 0x0C, 0x00]).dropFirst()))
        XCTAssertFalse(BlePodProfile.isGlucoseNudge(Data([0x0C])))
        XCTAssertFalse(BlePodProfile.isGlucoseNudge(Data([0x0C, 0x01])))
        XCTAssertFalse(BlePodProfile.isGlucoseNudge(Data([PodCommand.SUCCESS.rawValue, 0x00])))
        XCTAssertFalse(BlePodProfile.isGlucoseNudge(Data()))
    }
}
