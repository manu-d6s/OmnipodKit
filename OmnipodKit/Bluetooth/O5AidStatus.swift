//
//  O5AidStatus.swift
//  OmnipodKit
//

import Foundation

enum O5AidStatusError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Invalid O5 AID status: \(reason)"
        }
    }
}

/// Bounds-checked big-endian reads; copying into an array also rebases Data slices.
private struct O5AidStatusReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw O5AidStatusError.malformed("truncated field at byte \(offset)")
        }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func number(_ count: Int) throws -> UInt32 {
        try take(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

/// Decoded `3.12` (UnifiedAidPodStatusCommand) response.
///
/// Layout (big-endian):
///   0  u16 length of the rest
///   2  s16 EGV in mg/dL (0 = none)
///   4  u32 EGV time (pod clock, seconds)
///   8  u16 TDI
///   10 u8  loop state (0 unknown, 1 open/Manual, 2 closed/Automated)
///   11 s32 IOB in micro-units (Int32.min = not provided)
///   15 u32 pod time (pod clock, seconds)
///   19 u8  status flags (bit 0 history record written on alarm, bit 1 history record requested)
///   20 u8  state flags (bit 0 algorithm ready, bit 1 pod active, bit 2 activity mode, bit 3 limited mode)
///   21 u8  CGM type (0 none, 4 G6, 7 G7, 2/3/5 Libre 2, 8–12 Libre 3)
///   22 u16 CGM data length
///   24     CGM data
struct O5UnifiedAidStatus: CustomStringConvertible {

    /// G7 CGM data (16 bytes)
    struct G7 {
        let sessionActivationTime: UInt32
        let sessionDuration: Int32
        let sensorTimestamp: Int32
        let algorithmState: UInt8
        let transmitterStatus: UInt8
        let trendRateRaw: Int8
        let trendRateValid: Bool

        var trendRate: Int8? { trendRateValid ? trendRateRaw : nil }
    }

    /// G6 CGM data (9 bytes)
    struct G6 {
        let activationTime: UInt32
        let trendRate: Int8
        let algorithmState: UInt8
        let transmitterStatus: UInt8
        let lifetime: Int16
    }

    static let cgmDataLengths: [UInt8: Int] = [0: 0, 4: 9, 7: 16, 2: 7, 3: 7, 5: 7, 8: 31, 9: 31, 10: 31, 11: 31, 12: 31]

    let egvRaw: Int16
    let egvTime: UInt32
    let totalDailyInsulin: UInt16
    let loopState: UInt8
    let iobRaw: Int32
    let podTime: UInt32
    let statusFlags: UInt8
    let stateFlags: UInt8
    let cgmType: UInt8
    let cgmData: Data
    let g7: G7?
    let g6: G6?

    var egv: Int16? { egvRaw == 0 ? nil : egvRaw }
    var iobMicroUnits: Int32? { iobRaw == Int32.min ? nil : iobRaw }
    var insulinOnBoard: Double? { iobMicroUnits.map { Double($0) / 1_000_000 } }
    var egvAge: TimeInterval? {
        guard egv != nil, egvTime > 0, podTime >= egvTime else { return nil }
        return TimeInterval(podTime - egvTime)
    }

    var isManualMode: Bool { loopState == 1 }
    var isAutomatedMode: Bool { loopState == 2 }
    var algorithmReady: Bool { stateFlags & 0x01 != 0 }
    var podActive: Bool { stateFlags & 0x02 != 0 }
    var activityMode: Bool { stateFlags & 0x04 != 0 }
    var limitedMode: Bool { stateFlags & 0x08 != 0 }
    var historyRecordWrittenOnAlarm: Bool { statusFlags & 0x01 != 0 }
    var historyRecordRequested: Bool { statusFlags & 0x02 != 0 }

    init(_ data: Data) throws {
        var r = O5AidStatusReader(data)
        let length = try r.number(2)
        guard Int(length) == r.remaining else {
            throw O5AidStatusError.malformed("length \(length) but \(r.remaining) bytes follow")
        }
        egvRaw = Int16(bitPattern: UInt16(try r.number(2)))
        egvTime = try r.number(4)
        totalDailyInsulin = UInt16(try r.number(2))
        loopState = UInt8(try r.number(1))
        iobRaw = Int32(bitPattern: try r.number(4))
        podTime = try r.number(4)
        statusFlags = UInt8(try r.number(1))
        stateFlags = UInt8(try r.number(1))
        guard stateFlags & 0xF0 == 0 else {
            throw O5AidStatusError.malformed("reserved state flags set")
        }
        cgmType = UInt8(try r.number(1))
        let cgmLength = Int(try r.number(2))
        guard cgmLength == r.remaining else {
            throw O5AidStatusError.malformed("CGM data length \(cgmLength) but \(r.remaining) bytes follow")
        }
        if let expected = O5UnifiedAidStatus.cgmDataLengths[cgmType], expected != cgmLength {
            throw O5AidStatusError.malformed("CGM data length \(cgmLength) doesn't match CGM type \(cgmType)")
        }
        cgmData = try r.take(cgmLength)

        var c = O5AidStatusReader(cgmData)
        if cgmType == 7 {
            g7 = try G7(
                sessionActivationTime: c.number(4),
                sessionDuration: Int32(bitPattern: c.number(4)),
                sensorTimestamp: Int32(bitPattern: c.number(4)),
                algorithmState: UInt8(c.number(1)),
                transmitterStatus: UInt8(c.number(1)),
                trendRateRaw: Int8(bitPattern: UInt8(c.number(1))),
                trendRateValid: c.number(1) == 1
            )
        } else {
            g7 = nil
        }
        if cgmType == 4 {
            g6 = try G6(
                activationTime: c.number(4),
                trendRate: Int8(bitPattern: UInt8(c.number(1))),
                algorithmState: UInt8(c.number(1)),
                transmitterStatus: UInt8(c.number(1)),
                lifetime: Int16(bitPattern: UInt16(c.number(2)))
            )
        } else {
            g6 = nil
        }
    }

    var description: String {
        let loop: String
        switch loopState {
        case 1: loop = "Manual"
        case 2: loop = "Automated"
        default: loop = "unknown (\(loopState))"
        }
        let egvText = egv.map { "\($0) mg/dL" + (egvAge.map { ", \(Int($0)) s old" } ?? "") } ?? "none"
        let iobText = insulinOnBoard.map { String(format: "%.2f U", $0) } ?? "not provided"
        var lines = [
            "Loop state: \(loop)",
            "Algorithm ready: \(algorithmReady), pod active: \(podActive), activity mode: \(activityMode), limited mode: \(limitedMode)",
            "IOB: \(iobText), TDI: \(totalDailyInsulin)",
            "EGV: \(egvText)",
            "CGM type: \(cgmType)",
        ]
        if let g7 = g7 {
            lines.append("G7 algorithm state: \(g7.algorithmState), transmitter status: \(g7.transmitterStatus), trend rate: \(g7.trendRate.map { String($0) } ?? "not valid")")
        } else if let g6 = g6 {
            lines.append("G6 algorithm state: \(g6.algorithmState), transmitter status: \(g6.transmitterStatus), trend rate: \(g6.trendRate)")
        } else if !cgmData.isEmpty {
            lines.append("CGM data: \(cgmData.hexadecimalString)")
        }
        return lines.joined(separator: "\n")
    }
}
