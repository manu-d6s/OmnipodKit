//
//  O5G7TypeExperimentView.swift
//  OmnipodKit
//

import SwiftUI
import LoopKitUI

/// Experimental: the two steps of O5G7TypeExperiment, each confirmed separately.
struct O5G7TypeExperimentView: View {
    var setType: () async throws -> String
    var sendBatch: (_ pairingCode: String, _ serialNumber: String) async throws -> String

    private enum Pending { case type, batch }

    @State private var pairingCode = ""
    @State private var serialNumber = ""
    @State private var confirming: Pending?
    @State private var running: Pending?
    @State private var typeResult = ""
    @State private var batchResult = ""

    private var inputIsValid: Bool {
        pairingCode.count == 4 && serialNumber.count == 12
            && (pairingCode + serialNumber).allSatisfy { $0.isASCII && $0.isNumber }
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
            Section(header: Text("Step 2"), footer: Text("Only after step 1 was verified. Sends the same batch as the add-G7 attempt, enable plus identity, once. Wait a few minutes after step 1 and read the status first.")) {
                TextField("Pairing code (4 digits)", text: $pairingCode)
                    .keyboardType(.numberPad)
                TextField("Serial number (12 digits)", text: $serialNumber)
                    .keyboardType(.numberPad)
                button(running == .batch ? "Sending…" : "Send Identity Batch",
                       disabled: !inputIsValid || running != nil || !batchResult.isEmpty) {
                    confirming = .batch
                }
                if !batchResult.isEmpty {
                    Text(batchResult).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle("G7 Type, Then Identity")
        .alert(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            let step = confirming
            return Alert(
                title: Text(step == .type ? "Set desired type G7?" : "Send the identity batch?"),
                message: Text("Once sent, this step won't be sent again for this Pod."),
                primaryButton: .destructive(Text(step == .type ? "Set" : "Send")) { if let step { start(step) } },
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
                text = step == .type ? try await setType() : try await sendBatch(code, serial)
            } catch {
                text = error.localizedDescription
            }
            if step == .type { typeResult = text } else { batchResult = text }
            running = nil
        }
    }
}
