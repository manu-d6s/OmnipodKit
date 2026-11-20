//
//  O5AidStatusReplies.swift
//  OmnipodKit
//

import Foundation

/// Strict decoders for the O5 replies read around the early control enable.
/// They only decode; they never send anything or make a provisioning decision.
enum O5AidStatusReplyError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Invalid O5 reply: \(reason)"
        }
    }
}

/// Bounds-checked big-endian reads over a copy of the reply (also rebases Data slices).
private struct O5AidReplyReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw O5AidStatusReplyError.malformed("truncated field at byte \(offset)")
        }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func number(_ count: Int) throws -> UInt32 {
        try take(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// A two-byte body length that must match the rest of the reply exactly.
    mutating func lengthPrefix() throws {
        let length = try number(2)
        guard length <= 32767, Int(length) == remaining else {
            throw O5AidStatusReplyError.malformed("declared body length does not match the reply")
        }
    }
}

private func o5Number(_ data: Data?) -> UInt32? {
    data.map { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
}

/// Key-value attribute replies: a length prefix, then (key, value) pairs whose widths
/// are known per key. Unknown keys cannot be skipped because entries carry no length.
private func o5Fields(_ data: Data, widths: [UInt8: Int]) throws -> [UInt8: Data] {
    var reader = O5AidReplyReader(data)
    try reader.lengthPrefix()
    var fields: [UInt8: Data] = [:]
    var actualMask: UInt32 = 0
    while reader.remaining > 0 {
        let key = UInt8(try reader.number(1))
        guard let width = widths[key] else {
            throw O5AidStatusReplyError.malformed("unknown key \(key)")
        }
        guard fields[key] == nil else {
            throw O5AidStatusReplyError.malformed("duplicate key \(key)")
        }
        fields[key] = try reader.take(width)
        actualMask |= UInt32(1) << key
    }
    guard let mask = o5Number(fields[0]), mask == UInt32.max || mask == actualMask else {
        throw O5AidStatusReplyError.malformed("missing or inconsistent attribute mask")
    }
    return fields
}

/// The G4.2 CGM interface reply.
struct O5CgmInterfaceStatus: CustomStringConvertible {
    let attributeMask: UInt32
    // Raw enum bytes keep unknown values and distinguish absent from zero.
    let desiredSensorType: UInt8?
    let allowedSensorType: UInt8?
    let managerVersion: UInt8?
    let control: UInt8?

    init(_ data: Data) throws {
        let fields = try o5Fields(data, widths: [0: 4, 1: 1, 2: 1, 3: 1, 4: 1])
        attributeMask = o5Number(fields[0])!
        desiredSensorType = fields[1]?.first
        allowedSensorType = fields[2]?.first
        managerVersion = fields[3]?.first
        control = fields[4]?.first
    }

    var description: String {
        func display(_ value: UInt8?) -> String { value.map { String($0) } ?? "absent" }
        return "Desired sensor: \(display(desiredSensorType)); allowed sensor: \(display(allowedSensorType)); interface version: \(display(managerVersion)); control: \(display(control))"
    }
}

/// The G3.12 unified AID status reply. Only the fields the early control enable
/// checks are kept, but the whole reply is validated.
struct O5UnifiedAidStatus {
    let loopState: UInt8
    let statusFlags: UInt8
    let stateFlags: UInt8
    let cgmType: UInt8

    var algorithmReady: Bool { stateFlags & 1 != 0 }
    var podActive: Bool { stateFlags & 2 != 0 }
    var isManual: Bool { loopState == 1 }

    init(_ data: Data) throws {
        var r = O5AidReplyReader(data)
        try r.lengthPrefix()
        _ = try r.number(2) // EGV
        _ = try r.number(4) // EGV reference time
        _ = try r.number(2) // total daily insulin
        loopState = UInt8(try r.number(1))
        _ = try r.number(4) // IOB
        _ = try r.number(4) // Pod time
        statusFlags = UInt8(try r.number(1))
        stateFlags = UInt8(try r.number(1))
        guard stateFlags & 0xf0 == 0 else { throw O5AidStatusReplyError.malformed("reserved AID state flags") }
        cgmType = UInt8(try r.number(1))
        let length = Int(try r.number(2))
        guard length == r.remaining else { throw O5AidStatusReplyError.malformed("CGM data length mismatch") }
        let knownLengths: [UInt8: Int] = [0: 0, 4: 9, 7: 16, 2: 7, 3: 7, 5: 7,
                                          8: 31, 9: 31, 10: 31, 11: 31, 12: 31]
        if let expected = knownLengths[cgmType], expected != length {
            throw O5AidStatusReplyError.malformed("CGM data size disagrees with sensor type")
        }
    }
}

/// The 22-byte detailed status (pod info page 2) body, as in `DetailedStatus.data`.
struct O5DetailedStatusPage2 {
    let progress: UInt8
    let fault: UInt8
    let deliveryStatus: UInt8

    init(_ data: Data) throws {
        let b = Array(data)
        guard b.count == 22, b[0] == 2 else { throw O5AidStatusReplyError.malformed("detailed status page") }
        progress = b[1]
        fault = b[8]
        deliveryStatus = b[2] & 0x0f
    }

    var active: Bool { progress == 8 || progress == 9 }
}
