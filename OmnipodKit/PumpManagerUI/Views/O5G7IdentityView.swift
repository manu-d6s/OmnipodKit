//
//  O5G7IdentityView.swift
//  OmnipodKit
//

import SwiftUI
import LoopKitUI

/// Experimental: enter a Dexcom G7 pairing code and serial number and send them to the
/// active O5 Pod once. See O5G7Identity.
struct O5G7IdentityView: View {
    var send: (_ pairingCode: String, _ serialNumber: String) async throws -> String

    @State private var pairingCode = ""
    @State private var serialNumber = ""
    @State private var confirming = false
    @State private var sending = false
    @State private var result = ""

    private var inputIsValid: Bool {
        pairingCode.count == 4 && serialNumber.count == 12
            && (pairingCode + serialNumber).allSatisfy { $0.isASCII && $0.isNumber }
    }

    var body: some View {
        List {
            Section(footer: Text("Sends the sensor identity to the Pod once, the way the Omnipod 5 app adds a G7 to an active Pod. Only for a Pod whose control was enabled during activation. Once the identity has been sent it can't be sent again for this Pod, and the Pod may fault.")) {
                TextField("Pairing code (4 digits)", text: $pairingCode)
                    .keyboardType(.numberPad)
                TextField("Serial number (12 digits)", text: $serialNumber)
                    .keyboardType(.numberPad)
            }
            Section {
                Button(action: { confirming = true }) {
                    HStack {
                        Text(sending ? "Sending…" : "Send G7 Identity")
                        if sending {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!inputIsValid || sending || !result.isEmpty)
            }
            if !result.isEmpty {
                Section {
                    Text(result).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle("Send G7 Identity")
        .alert(isPresented: $confirming) {
            Alert(
                title: Text("Send the G7 identity?"),
                message: Text("Once sent, the identity won't be sent again for this Pod."),
                primaryButton: .destructive(Text("Send")) { start() },
                secondaryButton: .cancel()
            )
        }
    }

    private func start() {
        sending = true
        let code = pairingCode, serial = serialNumber
        Task { @MainActor in
            do {
                result = try await send(code, serial)
            } catch {
                result = error.localizedDescription
            }
            sending = false
        }
    }
}
