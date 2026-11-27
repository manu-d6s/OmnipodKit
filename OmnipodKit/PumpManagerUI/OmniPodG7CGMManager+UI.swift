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

struct O5PodCGMLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}

extension O5PodGlucose.Session {
    /// Progress shown in the last 48 hours of the lifetime and through the grace period,
    /// as for a G7 read directly.
    func lifecycleProgress(ended: Bool, now: Date = Date()) -> DeviceLifecycleProgress? {
        if ended || now >= endsAt {
            return O5PodCGMLifecycleProgress(percentComplete: 1, progressState: .critical)
        }
        if now >= expiresAt {
            let remaining = endsAt.timeIntervalSince(now)
            return O5PodCGMLifecycleProgress(percentComplete: 1 - remaining / Self.gracePeriod, progressState: .critical)
        }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining < .hours(48) else { return nil }
        return O5PodCGMLifecycleProgress(percentComplete: 1 - remaining / lifetime,
                                         progressState: remaining < .hours(24) ? .warning : .normalCGM)
    }
}

extension OmniPodG7CGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? { nil }

    public var smallImage: UIImage? { nil }

    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, prefersToSkipUserInteraction: Bool) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let nav = CGMManagerSettingsNavigationViewController()
        let view = OmniPodG7CGMSetupView(
            onCancel: { [weak nav] in nav?.notifyComplete() },
            onContinue: { [weak nav] in
                guard let nav else { return }
                let manager = OmniPodG7CGMManager()
                nav.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
                nav.cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
                nav.notifyComplete()
            }
        )
        let hostingController = DismissibleHostingController(content: view, isModalInPresentation: true, colorPalette: colorPalette)
        hostingController.title = LocalizedString("Dexcom G7 via Omnipod 5", comment: "Title of the CGM that takes G7 readings from the Omnipod 5 Pod")
        nav.setViewControllers([hostingController], animated: false)
        nav.navigationBar.prefersLargeTitles = false
        return .userInteractionRequired(nav)
    }

    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> CGMManagerViewController {
        let view = OmniPodG7CGMSettingsView(cgmManager: self, displayGlucosePreference: displayGlucosePreference)
        let hostingController = DismissibleHostingController(content: view, isModalInPresentation: false, colorPalette: colorPalette)
        hostingController.title = localizedTitle
        hostingController.navigationItem.backButtonDisplayMode = .generic
        let nav = CGMManagerSettingsNavigationViewController(rootViewController: hostingController)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    public func unitDidChange(to displayGlucoseUnit: LoopUnit) {}

    public var cgmStatusBadge: DeviceStatusBadge? { nil }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        guard let glucose = O5PodCGMLink.shared.pump?.lockedPodGlucose.value, let session = glucose.session else { return nil }
        return session.lifecycleProgress(ended: glucose.latest?.sensorState == .ended)
    }

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
    @State private var holdsLink = BluetoothManager.holdO5LinkForCGM

    private var glucose: O5PodGlucoseState? { O5PodCGMLink.shared.pump?.lockedPodGlucose.value }

    var body: some View {
        List {
            Section(footer: Text(LocalizedString("Readings come from the Dexcom G7 that the Omnipod 5 Pod reads itself. Start the sensor with the Dexcom app, then give its pairing code and serial number to the Pod with Add G7 Sensor.", comment: "Explanation of the Pod-relayed G7 CGM"))) {
                row(LocalizedString("Pod", comment: "Label for the linked Pod"),
                    O5PodCGMLink.shared.pump == nil ? LocalizedString("None", comment: "No Pod linked") : LocalizedString("Omnipod 5", comment: "Linked Pod"))
                row(LocalizedString("Sensor", comment: "Label for the G7 state"), sensorStateText)
                if let reading = glucose?.latest?.reading {
                    row(LocalizedString("Last reading", comment: "Label for the latest reading"),
                        "\(displayGlucosePreference.format(LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(reading.clampedGlucose)))) · \(reading.date.formatted(date: .omitted, time: .shortened))")
                }
                if let session = glucose?.session {
                    row(LocalizedString("Sensor started", comment: "Label for when the G7 was started"),
                        session.activatedAt.formatted(date: .abbreviated, time: .shortened))
                    if session.expiresAt > Date() {
                        row(LocalizedString("Sensor expires", comment: "Label for when the G7 lifetime ends"),
                            session.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        row(LocalizedString("Grace period ends", comment: "Label for when the G7 stops after its grace period"),
                            session.endsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let date = glucose?.lastReadDate {
                    row(LocalizedString("Last read from Pod", comment: "Label for the last Pod read"), date.formatted(date: .omitted, time: .shortened))
                }
            }
            Section {
                NavigationLink(destination: O5G7AddView(
                    readStep: { try await Self.pump().o5G7AddStep() },
                    setType: { try await Self.pump().setO5G7DesiredType() },
                    add: { code, serial in try await Self.pump().sendO5G7IdentityBatchAfterType(pairingCode: code, serialNumber: serial) },
                    replace: { code, serial in try await Self.pump().replaceO5G7Identity(pairingCode: code, serialNumber: serial) })) {
                    Text(hasSensor ? LocalizedString("Replace G7 Sensor", comment: "Link to give the Pod a new G7")
                                   : LocalizedString("Add G7 Sensor", comment: "Link to give the Pod a G7"))
                }
                .disabled(O5PodCGMLink.shared.pump == nil)
            }
            Section(footer: Text(LocalizedString("Keeps the Pod connected while the phone is locked, so the Pod's notice of each new reading wakes the app at once. Takes effect when the app goes to the background. Experimental: if readings stop arriving while the phone is locked, turn this off.", comment: "Footer for the held Pod connection setting"))) {
                Toggle(LocalizedString("Experimental: hold Pod connection", comment: "Setting that keeps the Pod connected for its reading notices"),
                       isOn: Binding(get: { holdsLink }, set: { holdsLink = $0; BluetoothManager.holdO5LinkForCGM = $0 }))
                    .disabled(O5PodCGMLink.shared.pump == nil)
            }
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text(LocalizedString("Delete CGM", comment: "Button that removes the Pod-relayed CGM"))
                }
            }
        }
        .navigationBarItems(trailing: Button(LocalizedString("Done", comment: "Close the CGM settings")) { dismiss() })
        .confirmationDialog(LocalizedString("Stop using the Pod's G7 readings?", comment: "Delete confirmation title"),
                            isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(LocalizedString("Delete CGM", comment: "Confirm delete"), role: .destructive) {
                Task {
                    await cgmManager.delete()
                    await MainActor.run { dismiss() }
                }
            }
        }
    }

    private var hasSensor: Bool {
        ![nil, .noSensor].contains(glucose?.latest?.sensorState)
    }

    private static func pump() throws -> OmniPumpManager {
        guard let pump = O5PodCGMLink.shared.pump else { throw OmniPumpManagerError.noPodPaired }
        return pump
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

struct OmniPodG7CGMSetupView: View {
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        List {
            Section(footer: Text(LocalizedString("Start the sensor with the Dexcom app first. Then give its pairing code and serial number to the Pod with Add G7 Sensor in these CGM settings. The Pod reads the sensor from then on. The Pod must be an Omnipod 5 that was activated with the early control enable.", comment: "Setup explanation for the Pod-relayed G7 CGM"))) {
                Text(LocalizedString("Glucose readings will come from the Dexcom G7 that your Omnipod 5 Pod reads itself, instead of from a direct connection to the sensor.", comment: "Setup summary for the Pod-relayed G7 CGM"))
            }
            Section {
                Button(LocalizedString("Use the Pod's G7 Readings", comment: "Button that sets up the Pod-relayed G7 CGM"), action: onContinue)
            }
        }
        .navigationBarItems(leading: Button(LocalizedString("Cancel", comment: "Cancel CGM setup"), action: onCancel))
    }
}
