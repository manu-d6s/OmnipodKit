//
//  O5G7Add.swift
//  OmnipodKit
//

import Foundation

/// The next step that gives an O5 Pod a Dexcom G7, chosen from what the Pod reports and from
/// the per-Pod step records of O5G7TypeExperiment. The steps themselves keep every check:
/// each reads the Pod again before its write, and each write goes to a Pod at most once.
///
/// A Pod without an identity first gets desired sensor type G7, then, after a wait that covers
/// the next Pod ticks, the identity batch. A Pod with an identity has it replaced by a new one.
enum O5G7AddStep: Equatable {
    /// Write desired sensor type G7 (O5G7TypeExperiment step 1).
    case setType
    /// Desired type G7 is verified; the identity may be sent from `until`.
    case wait(until: Date)
    /// Send the identity batch (step 2).
    case add
    /// Send the batch with a new sensor's identity (step 3).
    case replace
    case unavailable(String)

    /// Time between the type write and the identity batch, covering the Pod's next two
    /// 5-minute ticks.
    static let waitAfterType: TimeInterval = 15 * 60

    /// What the Pod reports, read with G4.2 and G4.1.
    struct PodReport: Equatable {
        var control: UInt8?
        var desiredSensorType: UInt8?
        var hasIdentity: Bool
    }

    static func next(pod: PodReport, progress: O5G7TypeExperiment.Progress, typeSetAtActivation: Bool,
                     now: Date) -> O5G7AddStep {
        guard pod.control == 0 else {
            return .unavailable(LocalizedString("This Pod's CGM control was not enabled during activation, so it can't take a G7. When pairing the next Pod, turn on \"Experimental: enable control during activation\".", comment: "Add G7 unavailable: control not enabled"))
        }
        if pod.hasIdentity {
            guard progress.replaceAvailable else {
                return .unavailable(LocalizedString("This Pod has already been given a new sensor once. Use the new sensor with the next Pod.", comment: "Add G7 unavailable: replace already sent to this Pod"))
            }
            return .replace
        }
        guard progress.batchAvailable else {
            return .unavailable(LocalizedString("A G7 was already sent to this Pod once, and the Pod doesn't hold it. Use the sensor with the next Pod.", comment: "Add G7 unavailable: identity already sent but not stored"))
        }
        switch pod.desiredSensorType {
        case 0?:
            guard progress.typeAvailable else {
                return .unavailable(LocalizedString("Setting the G7 sensor type was already tried on this Pod and not confirmed. Use the sensor with the next Pod.", comment: "Add G7 unavailable: type write already sent but not verified"))
            }
            return .setType
        case 7?:
            if typeSetAtActivation { return .add }
            guard let written = progress.typeVerifiedWriteDate else {
                return .unavailable(LocalizedString("The Pod reports sensor type G7, but this app didn't confirm setting it. Use the sensor with the next Pod.", comment: "Add G7 unavailable: type G7 not verified"))
            }
            let until = written.addingTimeInterval(waitAfterType)
            return now < until ? .wait(until: until) : .add
        default:
            return .unavailable(String(format: LocalizedString("The Pod reports an unexpected sensor type (%@).", comment: "Add G7 unavailable: unexpected desired sensor type (1: the type)"),
                                       pod.desiredSensorType.map { String($0) } ?? "none"))
        }
    }
}
