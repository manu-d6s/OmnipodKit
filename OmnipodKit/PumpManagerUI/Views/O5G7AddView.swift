//
//  O5G7AddView.swift
//  OmnipodKit
//

import SwiftUI
import LoopKitUI

/// Gives the active O5 Pod a Dexcom G7, or a new one in place of its current sensor.
/// It reads the Pod, offers the step that O5G7AddStep chooses, and reads the Pod again
/// after each step. Every write is confirmed first and goes to a Pod at most once.
struct O5G7AddView: View {
    var readStep: () async throws -> O5G7AddStep
    var setType: () async throws -> String
    var add: (_ pairingCode: String, _ serialNumber: String) async throws -> String
    var replace: (_ pairingCode: String, _ serialNumber: String) async throws -> String

    private enum Phase {
        case reading
        case readFailed(String)
        case step(O5G7AddStep)
        /// The sensor was added or replaced; the Pod's reply summary.
        case done(String)
    }

    @State private var phase = Phase.reading
    @State private var pairingCode = ""
    @State private var serialNumber = ""
    @State private var confirming: O5G7AddStep?
    @State private var running = false
    @State private var stepError: String?

    private var inputIsValid: Bool {
        O5G7IdentityFields.isValid(pairingCode: pairingCode, serialNumber: serialNumber)
    }

    var body: some View {
        List {
            if let stepError {
                Section {
                    Text(stepError).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch phase {
            case .reading:
                Section {
                    HStack {
                        Text(LocalizedString("Reading the Pod…", comment: "Add G7: reading the Pod"))
                        Spacer()
                        ProgressView()
                    }
                }
            case .readFailed(let message):
                Section(footer: Text(message)) {
                    Button(LocalizedString("Read the Pod Again", comment: "Add G7: retry reading the Pod")) { refresh() }
                }
            case .step(let step):
                stepSection(step)
            case .done(let summary):
                Section(footer: Text(summary)) {
                    Text(LocalizedString("The Pod took the sensor. It connects to the sensor by itself, and the first reading usually arrives within about 10 minutes.", comment: "Add G7: sensor sent and stored"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Add G7 Sensor", comment: "Title of the Add G7 screen"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await read() }
        .alert(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            confirmation(confirming)
        }
    }

    @ViewBuilder
    private func stepSection(_ step: O5G7AddStep) -> some View {
        switch step {
        case .setType:
            Section(header: Text(LocalizedString("Step 1 of 2", comment: "Add G7: first step header")),
                    footer: Text(LocalizedString("Start the sensor with the Dexcom app first. This step sets the Pod's sensor type to G7. The pairing code and serial number follow after a 15-minute wait, while the Pod runs its next status checks.", comment: "Add G7: set type explanation"))) {
                actionButton(LocalizedString("Set Sensor Type G7", comment: "Add G7: set type button"), disabled: false) {
                    confirming = .setType
                }
            }
        case .wait(let until):
            Section(header: Text(LocalizedString("Step 2 of 2", comment: "Add G7: second step header")),
                    footer: Text(String(format: LocalizedString("Sensor type G7 is set. The sensor can be added from %@.", comment: "Add G7: wait explanation (1: time)"), until.formatted(date: .omitted, time: .shortened)))) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = until.timeIntervalSince(context.date)
                    Button(remaining > 0
                           ? String(format: LocalizedString("Wait %@", comment: "Add G7: wait button (1: time left)"), Self.minutesAndSeconds(remaining))
                           : LocalizedString("Continue", comment: "Add G7: continue after the wait")) {
                        refresh()
                    }
                    .disabled(remaining > 0)
                }
            }
        case .add, .replace:
            let adding = step == .add
            Section(header: adding ? Text(LocalizedString("Step 2 of 2", comment: "Add G7: second step header")) : nil,
                    footer: Text(adding
                        ? LocalizedString("Enter the pairing code and serial number of the sensor that the Dexcom app started. Both are printed on the applicator. They can be sent to this Pod only once, so check them carefully.", comment: "Add G7: add explanation")
                        : LocalizedString("The Pod already has a sensor. Start the new sensor with the Dexcom app first, then enter its pairing code and serial number. The Pod forgets the current sensor. A new sensor can be sent to this Pod only once, so check them carefully.", comment: "Add G7: replace explanation"))) {
                O5G7IdentityFields(pairingCode: $pairingCode, serialNumber: $serialNumber)
                actionButton(adding ? LocalizedString("Add Sensor", comment: "Add G7: add button")
                                    : LocalizedString("Replace Sensor", comment: "Add G7: replace button"),
                             disabled: !inputIsValid) {
                    confirming = step
                }
            }
        case .unavailable(let reason):
            Section(footer: Text(reason)) {
                Text(LocalizedString("This Pod can't take a G7 now.", comment: "Add G7: step unavailable"))
            }
        }
    }

    private func actionButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if running {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(disabled || running)
    }

    private func confirmation(_ step: O5G7AddStep?) -> Alert {
        let once = LocalizedString("This can be sent to this Pod only once.", comment: "Add G7: confirmation note")
        let identity = String(format: LocalizedString("Pairing code %1$@, serial number %2$@. %3$@", comment: "Add G7: confirmation message (1: code, 2: serial, 3: once note)"),
                              pairingCode, serialNumber, once)
        let (title, message, button): (String, String, String)
        switch step {
        case .setType?:
            (title, message, button) = (LocalizedString("Set sensor type G7?", comment: "Add G7: set type confirmation title"), once,
                                        LocalizedString("Set", comment: "Add G7: confirm set type"))
        case .replace?:
            (title, message, button) = (LocalizedString("Replace the sensor?", comment: "Add G7: replace confirmation title"), identity,
                                        LocalizedString("Replace", comment: "Add G7: confirm replace"))
        default:
            (title, message, button) = (LocalizedString("Add this sensor?", comment: "Add G7: add confirmation title"), identity,
                                        LocalizedString("Add", comment: "Add G7: confirm add"))
        }
        return Alert(title: Text(title), message: Text(message),
                     primaryButton: .default(Text(button)) { if let step { run(step) } },
                     secondaryButton: .cancel())
    }

    private func refresh() {
        Task { @MainActor in await read() }
    }

    @MainActor
    private func read() async {
        phase = .reading
        do {
            phase = .step(try await readStep())
        } catch {
            phase = .readFailed(error.localizedDescription)
        }
    }

    private func run(_ step: O5G7AddStep) {
        running = true
        stepError = nil
        let code = pairingCode, serial = serialNumber
        Task { @MainActor in
            do {
                switch step {
                case .setType:
                    _ = try await setType()
                    await read()
                case .add:
                    phase = .done(try await add(code, serial))
                case .replace:
                    phase = .done(try await replace(code, serial))
                case .wait, .unavailable:
                    break
                }
            } catch {
                stepError = error.localizedDescription
                await read()
            }
            running = false
        }
    }

    private static func minutesAndSeconds(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
