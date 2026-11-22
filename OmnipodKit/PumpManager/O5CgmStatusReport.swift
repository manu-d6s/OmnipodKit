//
//  O5CgmStatusReport.swift
//  OmnipodKit
//

import Foundation

/// Plain-text summary of the O5 AID status, CGM interface and sensor info replies,
/// for Pod Diagnostics. Each decoded section is followed by its raw reply, except the
/// sensor info, whose raw bytes would show the pairing code and serial number.
enum O5CgmStatusReport {
    static func text(status: Data, interface: Data, sensor: Data) -> String {
        var lines: [String] = []

        lines.append("AID status (G3.12)")
        do {
            let s = try O5UnifiedAidStatus(status)
            lines.append("CGM type: \(cgmTypeName(s.cgmType))")
            if let egv = s.egv {
                let age = s.egvAge.map { " (\(Int($0)) s old)" } ?? ""
                lines.append("Glucose: \(egv) mg/dL\(age)")
            } else {
                lines.append("Glucose: none (\(s.egvRaw)\(s.egvRaw == -9 ? ", no transmitter identity" : ""))")
            }
            if let g7 = s.g7 {
                lines.append("G7 algorithm state: \(g7.algorithmState), transmitter status: \(g7.transmitterStatus)")
                lines.append("G7 trend rate: \(g7.trendRate.map { String($0) } ?? "not valid")")
                lines.append("G7 session start: \(g7.sessionActivationTime), sensor time: \(g7.sensorTimestamp)")
            }
            lines.append("Mode: \(s.isManual ? "Manual" : "loop state \(s.loopState)")")
            lines.append("Ready: \(s.algorithmReady), active: \(s.podActive)")
            lines.append("Status flags: \(s.statusFlags), state flags: \(s.stateFlags), Pod time: \(s.podTime)")
        } catch {
            lines.append(error.localizedDescription)
        }
        lines.append("Raw: \(status.hexadecimalString)")

        lines.append("")
        lines.append("CGM interface (G4.2)")
        do {
            let i = try O5CgmInterfaceStatus(interface)
            lines.append("Control: \(controlName(i.control))")
            lines.append("Desired sensor type: \(i.desiredSensorType.map(cgmTypeName) ?? "absent")")
            lines.append("Allowed sensor type: \(i.allowedSensorType.map(cgmTypeName) ?? "absent")")
            lines.append("Interface version: \(i.managerVersion.map { String($0) } ?? "absent")")
        } catch {
            lines.append(error.localizedDescription)
        }
        lines.append("Raw: \(interface.hexadecimalString)")

        lines.append("")
        lines.append("Sensor info (G4.1)")
        do {
            let info = try O5G7SensorInfo(sensor)
            if info.isEmpty {
                lines.append("No sensor configured")
            } else {
                lines.append("Sensor type: \(info.sensorType.map(cgmTypeName) ?? "absent")")
                lines.append("Pairing code: \(info.pairingCode == nil ? "absent" : "set")")
                let serial = info.serialNumber.map { String(decoding: $0, as: UTF8.self) }
                lines.append("Serial number: \(serial.map { "ending in \($0.suffix(4))" } ?? "absent")")
            }
        } catch {
            lines.append(error.localizedDescription)
        }
        lines.append("Raw: \(sensor.count) bytes")

        return lines.joined(separator: "\n")
    }

    /// The original app's sensor type values: 0 none, 1 any, 4 G6, 7 G7.
    static func cgmTypeName(_ type: UInt8) -> String {
        switch type {
        case 0: return "0 (none)"
        case 1: return "1 (no information)"
        case 4: return "4 (G6)"
        case 7: return "7 (G7)"
        default: return "\(type)"
        }
    }

    static func controlName(_ control: UInt8?) -> String {
        switch control {
        case nil: return "absent"
        case 0: return "0 (enabled)"
        case 255: return "255 (default, not enabled)"
        case let value?: return "\(value)"
        }
    }
}
