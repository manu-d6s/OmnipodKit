//
//  O5G7IdentityFields.swift
//  OmnipodKit
//

import SwiftUI

/// Entry fields for a Dexcom G7 pairing code and serial number.
struct O5G7IdentityFields: View {
    @Binding var pairingCode: String
    @Binding var serialNumber: String

    var body: some View {
        TextField(LocalizedString("Pairing code (4 digits)", comment: "Placeholder for the G7 pairing code"), text: $pairingCode)
            .keyboardType(.numberPad)
        TextField(LocalizedString("Serial number (12 digits)", comment: "Placeholder for the G7 serial number"), text: $serialNumber)
            .keyboardType(.numberPad)
    }

    static func isValid(pairingCode: String, serialNumber: String) -> Bool {
        pairingCode.count == 4 && serialNumber.count == 12
            && (pairingCode + serialNumber).allSatisfy { $0.isASCII && $0.isNumber }
    }
}
