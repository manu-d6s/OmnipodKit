//
//  PodDiagnosticsView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/PodDiagnosticsView.swift
//  Created by Joseph Moran on 11/25/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit


protocol DiagnosticCommands {
    func playTestBeeps() async throws
    func readPulseLog() async throws -> String
    func readPulseLogPlus() async throws -> String
    func readActivationTime() async throws -> String
    func readTriggeredAlerts() async throws -> String
    func getDetailedStatus() async throws -> DetailedStatus
    func pumpManagerDetails() -> String
    var isO5Pod: Bool { get }
    var podDataLogURL: URL? { get }
    func readO5CgmStatus() async throws -> String
    func sendO5G7Identity(pairingCode: String, serialNumber: String) async throws -> String
    func setO5G7DesiredType() async throws -> String
    func sendO5G7IdentityBatchAfterType(pairingCode: String, serialNumber: String) async throws -> String
}

struct PodDiagnosticsView: View  {

    var title: String

    var diagnosticCommands: DiagnosticCommands
    var podOk: Bool
    var noPod: Bool

    @AppStorage(O5PodDataLog.enabledKey) private var podDataLogEnabled = false

    var body: some View {
        List {
            NavigationLink(destination: ReadPodStatusView(getDetailedStatus: diagnosticCommands.getDetailedStatus)) {
                FrameworkLocalText("Read Pod Status", comment: "Text for read pod status navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            if diagnosticCommands.isO5Pod {
                NavigationLink(destination: ReadPodInfoView(
                    title: LocalizedString("Read O5 CGM Status", comment: "Text for read O5 CGM status title"),
                    actionString: LocalizedString("Reading O5 CGM Status...", comment: "Text for read O5 CGM status action"),
                    failedString: LocalizedString("Failed to read O5 CGM status", comment: "Alert title for error when reading O5 CGM status"),
                    action: { try await diagnosticCommands.readO5CgmStatus() }))
                {
                    FrameworkLocalText("Read O5 CGM Status", comment: "Text for read O5 CGM status navigation link")
                        .foregroundColor(Color.primary)
                }
                .disabled(noPod)

                Toggle("Research: Log Pod Data", isOn: $podDataLogEnabled)
                if let url = diagnosticCommands.podDataLogURL {
                    ShareLink(item: url) {
                        Text("Share Pod Data Log").foregroundColor(Color.primary)
                    }
                }

                NavigationLink(destination: O5G7IdentityView(send: { code, serial in
                    try await diagnosticCommands.sendO5G7Identity(pairingCode: code, serialNumber: serial)
                })) {
                    FrameworkLocalText("Experimental: Send G7 Identity", comment: "Text for the experimental send G7 identity navigation link")
                        .foregroundColor(Color.primary)
                }
                .disabled(!podOk)

                NavigationLink(destination: O5G7TypeExperimentView(
                    setType: { try await diagnosticCommands.setO5G7DesiredType() },
                    sendBatch: { code, serial in
                        try await diagnosticCommands.sendO5G7IdentityBatchAfterType(pairingCode: code, serialNumber: serial)
                    })) {
                    FrameworkLocalText("Experimental: G7 Type, Then Identity", comment: "Text for the experimental G7 type experiment navigation link")
                        .foregroundColor(Color.primary)
                }
                .disabled(!podOk)
            }

            NavigationLink(destination: PlayTestBeepsView(playTestBeeps: {
                try await diagnosticCommands.playTestBeeps()
            })) {
                FrameworkLocalText("Play Test Beeps", comment: "Text for play test beeps navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(!podOk)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Pulse Log", comment: "Text for read pulse log title"),
                actionString: LocalizedString("Reading Pulse Log...", comment: "Text for read pulse log action"),
                failedString: LocalizedString("Failed to read pulse log", comment: "Alert title for error when reading pulse log"),
                action: { try await diagnosticCommands.readPulseLog() }))
            {
                FrameworkLocalText("Read Pulse Log", comment: "Text for read pulse log navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Pulse Log Plus", comment: "Text for read pulse log plus title"),
                actionString: LocalizedString("Reading Pulse Log Plus...", comment: "Text for read pulse log plus action"),
                failedString: LocalizedString("Failed to read pulse log plus", comment: "Alert title for error when reading pulse log plus"),
                action: { try await diagnosticCommands.readPulseLogPlus() }))
            {
                FrameworkLocalText("Read Pulse Log Plus", comment: "Text for read pulse log plus navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Activation Time", comment: "Text for read activation time title"),
                actionString: LocalizedString("Reading Activation Time...", comment: "Text for read activation time action"),
                failedString: LocalizedString("Failed to read activation time", comment: "Alert title for error when reading activation time"),
                action: { try await diagnosticCommands.readActivationTime() }))
            {
                FrameworkLocalText("Read Activation Time", comment: "Text for read activation time navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Triggered Alerts", comment: "Text for read triggered alerts title"),
                actionString: LocalizedString("Reading Triggered Alerts...", comment: "Text for read triggered alerts action"),
                failedString: LocalizedString("Failed to read triggered alerts", comment: "Alert title for error when reading triggered alerts"),
                action: { try await diagnosticCommands.readTriggeredAlerts() }))
            {
                FrameworkLocalText("Read Triggered Alerts", comment: "Text for read triggered alerts navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: PumpManagerDetailsView() { diagnosticCommands.pumpManagerDetails() })
            {
                FrameworkLocalText("Pump Manager Details", comment: "Text for pump manager details navigation link")
                    .foregroundColor(Color.primary)
            }

        }
        .insetGroupedListStyle()
        .navigationTitle(title)
    }
}
