//
//  O5G7TypeExperimentView.swift
//  OmnipodKit
//

import SwiftUI
import LoopKitUI

/// Experimental: the steps of O5G7TypeExperiment, each confirmed separately.
struct O5G7TypeExperimentView: View {
    var setType: () async throws -> String
    var sendBatch: (_ pairingCode: String, _ serialNumber: String) async throws -> String
    var replaceIdentity: (_ pairingCode: String, _ serialNumber: String) async throws -> String

    private enum Pending { case type, batch, replace }

    @State private var pairingCode = ""
    @State private var serialNumber = ""
    @State private var confirming: Pending?
    @State private var running: Pending?
    @State private var typeResult = ""
    @State private var batchResult = ""
    @State private var replaceResult = ""

    private var inputIsValid: Bool {
        O5G7IdentityFields.isValid(pairingCode: pairingCode, serialNumber: serialNumber)
    }

    var body: some View {
        List {
            Section(header: Text("Step 1"), footer: Text("Writes desired sensor type G7 and reads it back. Only for a Pod whose control was enabled during activation, without a sensor type. Once the write is sent it isn't sent again for this Pod, and the Pod may fault.")) {
                button(running == .type ? "Setting…" : "Set Desired Type G7", disabled: running != nil || !typeResult.isEmpty) {
                    confirming = .type
                }
                if !typeResult.isEmpty {
                    Text(typeResult).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(header: Text("Step 2"), footer: Text("Only after step 1 was verified, or when desired type G7 was set during activation (then skip step 1). Sends the same batch as the add-G7 attempt, enable plus identity, once. Wait a few minutes after step 1 and read the status first.")) {
                O5G7IdentityFields(pairingCode: $pairingCode, serialNumber: $serialNumber)
                button(running == .batch ? "Sending…" : "Send Identity Batch",
                       disabled: !inputIsValid || running != nil || !batchResult.isEmpty) {
                    confirming = .batch
                }
                if !batchResult.isEmpty {
                    Text(batchResult).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(header: Text("Replace the sensor"), footer: Text("For a Pod that already receives a G7: enter the new sensor's pairing code and serial above. Sends the same batch with the new identity, as the official app does for a new sensor, once per Pod. Never re-sends the stored identity. The Pod may fault.")) {
                button(running == .replace ? "Replacing…" : "Replace G7 Identity",
                       disabled: !inputIsValid || running != nil || !replaceResult.isEmpty) {
                    confirming = .replace
                }
                if !replaceResult.isEmpty {
                    Text(replaceResult).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle("G7 Type, Then Identity")
        .alert(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            let step = confirming
            return Alert(
                title: Text(step == .type ? "Set desired type G7?" : step == .batch ? "Send the identity batch?" : "Replace the G7 identity?"),
                message: Text("Once sent, this step won't be sent again for this Pod."),
                primaryButton: .destructive(Text(step == .type ? "Set" : step == .batch ? "Send" : "Replace")) { if let step { start(step) } },
                secondaryButton: .cancel()
            )
        }
    }

    private func button(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if running != nil && title.hasSuffix("…") {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(disabled)
    }

    private func start(_ step: Pending) {
        running = step
        let code = pairingCode, serial = serialNumber
        Task { @MainActor in
            let text: String
            do {
                switch step {
                case .type: text = try await setType()
                case .batch: text = try await sendBatch(code, serial)
                case .replace: text = try await replaceIdentity(code, serial)
                }
            } catch {
                text = error.localizedDescription
            }
            switch step {
            case .type: typeResult = text
            case .batch: batchResult = text
            case .replace: replaceResult = text
            }
            running = nil
        }
    }
}
