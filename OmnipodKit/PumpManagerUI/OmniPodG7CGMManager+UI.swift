//
//  OmniPodG7CGMManager+UI.swift
//  OmnipodKit
//

import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

struct O5PodCGMStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

extension OmniPodG7CGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? { nil }

    public var smallImage: UIImage? { nil }

    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, prefersToSkipUserInteraction: Bool) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .createdAndOnboarded(OmniPodG7CGMManager())
    }

    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> CGMManagerViewController {
        let view = OmniPodG7CGMSettingsView(cgmManager: self, displayGlucosePreference: displayGlucosePreference)
        let hostingController = DismissibleHostingController(content: view, isModalInPresentation: false, colorPalette: colorPalette)
        hostingController.navigationItem.backButtonDisplayMode = .generic
        let nav = CGMManagerSettingsNavigationViewController(rootViewController: hostingController)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    public func unitDidChange(to displayGlucoseUnit: HKUnit) {}

    public var cgmStatusBadge: DeviceStatusBadge? { nil }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? { nil }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        guard O5PodCGMLink.shared.pump != nil else {
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("No Pod", comment: "CGM status when no Omnipod 5 pump is set up"),
                                           imageName: "exclamationmark.circle.fill", state: .warning)
        }
        switch O5PodCGMLink.shared.pump?.lockedPodGlucose.value.latest?.sensorState {
        case nil, .ok?:
            return nil
        case .noSensor?:
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("No Sensor", comment: "CGM status when the Pod has no G7"),
                                           imageName: "dot.radiowaves.left.and.right", state: .warning)
        case .pairing?:
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("Pairing", comment: "CGM status while the Pod pairs with the G7"),
                                           imageName: "dot.radiowaves.left.and.right", state: .normalCGM)
        case .warmup?:
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("Warmup", comment: "CGM status while the G7 warms up"),
                                           imageName: "clock", state: .normalCGM)
        case .temporaryIssue?:
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("No Reading", comment: "CGM status when the G7 has no current reading"),
                                           imageName: "exclamationmark.circle.fill", state: .warning)
        case .ended?:
            return O5PodCGMStatusHighlight(localizedMessage: LocalizedString("Sensor Ended", comment: "CGM status when the G7 session is over"),
                                           imageName: "exclamationmark.circle.fill", state: .critical)
        }
    }
}

struct OmniPodG7CGMSettingsView: View {
    let cgmManager: OmniPodG7CGMManager
    let displayGlucosePreference: DisplayGlucosePreference

    @Environment(\.dismissAction) private var dismiss
    @State private var showingDeleteConfirmation = false

    private var glucose: O5PodGlucoseState? { O5PodCGMLink.shared.pump?.lockedPodGlucose.value }

    var body: some View {
        List {
            Section(footer: Text(LocalizedString("Readings come from the Dexcom G7 that the Omnipod 5 Pod reads itself. Start the sensor with the Dexcom app, then give its pairing code and serial number to the Pod.", comment: "Explanation of the Pod-relayed G7 CGM"))) {
                row(LocalizedString("Pod", comment: "Label for the linked Pod"),
                    O5PodCGMLink.shared.pump == nil ? LocalizedString("None", comment: "No Pod linked") : LocalizedString("Omnipod 5", comment: "Linked Pod"))
                row(LocalizedString("Sensor", comment: "Label for the G7 state"), sensorStateText)
                if let reading = glucose?.latest?.reading {
                    row(LocalizedString("Last reading", comment: "Label for the latest reading"),
                        "\(displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(reading.clampedGlucose)))) · \(reading.date.formatted(date: .omitted, time: .shortened))")
                }
                if let date = glucose?.lastReadDate {
                    row(LocalizedString("Last read from Pod", comment: "Label for the last Pod read"), date.formatted(date: .omitted, time: .shortened))
                }
            }
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text(LocalizedString("Delete CGM", comment: "Button that removes the Pod-relayed CGM"))
                }
            }
        }
        .navigationTitle(cgmManager.localizedTitle)
        .confirmationDialog(LocalizedString("Stop using the Pod's G7 readings?", comment: "Delete confirmation title"),
                            isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(LocalizedString("Delete CGM", comment: "Confirm delete"), role: .destructive) {
                cgmManager.delete {
                    DispatchQueue.main.async { dismiss() }
                }
            }
        }
    }

    private var sensorStateText: String {
        switch glucose?.latest?.sensorState {
        case nil: return LocalizedString("Unknown", comment: "G7 state not read yet")
        case .noSensor?: return LocalizedString("No sensor", comment: "Pod has no G7")
        case .pairing?: return LocalizedString("Pairing", comment: "Pod pairing with the G7")
        case .warmup?: return LocalizedString("Warmup", comment: "G7 warming up")
        case .ok?: return LocalizedString("OK", comment: "G7 working")
        case .temporaryIssue?: return LocalizedString("No current reading", comment: "G7 temporarily without reading")
        case .ended?: return LocalizedString("Ended", comment: "G7 session over")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
