//
//  O5EarlyControlEnable.swift
//  OmnipodKit
//

import Foundation

/// Experimental, opt-in: enable the O5 Pod's CGM interface control once, right after
/// cannula insertion, while the Pod stays in Manual mode. The caller owns the serialized
/// Pod session; this never repeats setup.
///
/// With `desiredSensorType` 7 it also sets desired sensor type G7, as the official app
/// does when a Pod is activated with G7 selected: it reads `4.2` and writes only the
/// fields that differ. No sensor identity is sent; that is a separate step.
///
/// Every exchange is written to a durable per-Pod activation record before it is
/// sent. A missing, unreadable or interrupted record stops all further automatic
/// work, so an uncertain enable is never sent a second time.
enum O5EarlyControlEnable {
    private struct Exchange: Codable {
        let request: Data
        let responsePrefix: String
        let started: Date
        let startedUptime: TimeInterval
        var received: Date?
        var receivedUptime: TimeInterval?
        var response: Data?
    }
    private struct Journal: Codable {
        let schema: Int
        let id: String
        let target: String
        let firmware: String
        let bleFirmware: String
        let armed: Date
        let revisions: [String: String]
        var phase: String
        var exchanges: [Exchange] = []
        var reason: String?
        // nil: control only. 7: control and desired sensor type G7.
        var desiredSensorType: UInt8?
    }
    struct Stopped: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Early control enable stopped: \(reason). Cannula insertion may already be complete. The enable command will not be retried automatically. Review the activation record before continuing."
        }
    }

    static let enableRequest = Data("SE4.2=".utf8) + Data([0, 2, 4, 0])
    static let enableResponsePrefix = "ES4.2="

    /// The `4.2` write for the fields that differ: control (key 4) = 0 and/or desired
    /// sensor type (key 1). Both together are `00 04 04 00 01 07`.
    static func interfaceRequest(enableControl: Bool, desiredSensorType: UInt8?) -> Data {
        var pairs: [UInt8] = []
        if enableControl { pairs += [4, 0] }
        if let desiredSensorType { pairs += [1, desiredSensorType] }
        return Data("SE4.2=".utf8) + Data([0, UInt8(pairs.count)] + pairs)
    }

    // MARK: - Activation record storage (O5RecordLease)

    private static func root(_ override: URL?) throws -> URL {
        if let override { return override }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5EarlyControlEnable", isDirectory: true)
    }
    private static func lease(_ id: String, _ directory: URL?) throws -> O5RecordLease {
        guard UUID(uuidString: id) != nil else { throw Stopped(reason: "invalid activation record identifier") }
        return try O5RecordLease(directory: root(directory).appendingPathComponent(id, isDirectory: true))
    }
    private static func load(_ lease: O5RecordLease) throws -> Journal {
        guard try FileManager.default.attributesOfItem(atPath: lease.file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw Stopped(reason: "activation record is missing")
        }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: lease.file))
    }
    private static func save(_ journal: Journal, _ lease: O5RecordLease) throws {
        try lease.write(O5RecordLease.encode(journal))
    }

    // MARK: - Lifecycle

    /// Called only when a fresh PodState is created. The identifier must already be
    /// persisted in that PodState. A missing record is never recreated later.
    static func arm(id: String, target: String, firmware: String, bleFirmware: String,
                    desiredSensorType: UInt8? = nil, directory: URL? = nil) throws {
        do {
            let lease = try lease(id, directory)
            guard !FileManager.default.fileExists(atPath: lease.file.path), !target.isEmpty else {
                throw Stopped(reason: "activation record already exists or target is empty")
            }
            guard desiredSensorType == nil || desiredSensorType == 7 else {
                throw Stopped(reason: "only desired sensor type G7 (7) is supported")
            }
            try save(Journal(schema: 1, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware,
                             armed: Date(), revisions: O5RecordLease.revisions, phase: "armed",
                             desiredSensorType: desiredSensorType), lease)
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "activation record unavailable: \(error.localizedDescription)") }
    }

    /// Read-only check before priming, basal programming and insertion. A marked Pod
    /// with a missing or interrupted record cannot start the physical activation work.
    /// With `requireArmed`, a verified record also refuses to repeat that work.
    static func check(id: String, target: String, firmware: String, bleFirmware: String,
                      requireArmed: Bool = false, directory: URL? = nil) throws {
        do {
            let lease = try lease(id, directory)
            let journal = try admitted(lease, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware)
            guard !requireArmed || journal.phase == "armed" else {
                throw Stopped(reason: "control was already verified; physical setup must not be repeated")
            }
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "activation record unavailable: \(error.localizedDescription)") }
    }

    /// Any Pod firmware may attempt the enable; the record must match the Pod it was armed for.
    private static func admitted(_ lease: O5RecordLease, id: String, target: String,
                                 firmware: String, bleFirmware: String) throws -> Journal {
        let journal = try load(lease)
        guard journal.schema == 1, journal.id == id, journal.target == target,
              journal.firmware == firmware, journal.bleFirmware == bleFirmware else {
            throw Stopped(reason: "Pod or firmware does not match the activation record")
        }
        guard journal.phase == "armed" || journal.phase == "verified" else {
            throw Stopped(reason: journal.reason ?? "previous attempt was interrupted (\(journal.phase))")
        }
        guard journal.desiredSensorType == nil || journal.desiredSensorType == 7 else {
            throw Stopped(reason: "unsupported desired sensor type in the activation record")
        }
        return journal
    }

    /// The desired sensor type this record set and verified at activation, or nil if it
    /// set none or hasn't verified. Reads local evidence only.
    static func verifiedDesiredSensorType(id: String, target: String, firmware: String, bleFirmware: String,
                                          directory: URL? = nil) throws -> UInt8? {
        let journal = try admitted(lease(id, directory), id: id, target: target, firmware: firmware,
                                   bleFirmware: bleFirmware)
        return journal.phase == "verified" ? journal.desiredSensorType : nil
    }

    /// Runs after insertion is confirmed: status checks, the one enable (unless control is
    /// already enabled), then readback and status checks again. Reply bodies exclude their
    /// AID prefix; `detailedStatus` returns the 22-byte detailed status body. All closures
    /// run synchronously on the caller's session queue.
    static func finish(id: String, target: String, firmware: String, bleFirmware: String,
                       directory: URL? = nil,
                       send: (Data, String) throws -> Data,
                       detailedStatus: () throws -> Data) throws {
        do {
            try perform(id: id, target: target, firmware: firmware, bleFirmware: bleFirmware,
                        directory: directory, send: send, detailedStatus: detailedStatus)
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "activation record unavailable: \(error.localizedDescription)") }
    }

    private static func perform(id: String, target: String, firmware: String, bleFirmware: String,
                                directory: URL?, send: (Data, String) throws -> Data,
                                detailedStatus: () throws -> Data) throws {
        let lease = try lease(id, directory)
        var journal = try admitted(lease, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware)
        let previouslyVerified = journal.phase == "verified"
        let sensorType = journal.desiredSensorType
        // A crash during any attempt stops later automatic activation work.
        journal.phase = "checking"
        try save(journal, lease)
        func exchange(_ request: Data, _ prefix: String, mutation: Bool = false) throws -> Data {
            if mutation { journal.phase = "writePending" }
            journal.exchanges.append(Exchange(request: request, responsePrefix: prefix, started: Date(),
                startedUptime: ProcessInfo.processInfo.systemUptime))
            // Durable intent precedes every send, especially the one mutation.
            try save(journal, lease)
            let response = try prefix == "legacy-page-2" ? detailedStatus() : send(request, prefix)
            journal.exchanges[journal.exchanges.count - 1].response = response
            journal.exchanges[journal.exchanges.count - 1].received = Date()
            journal.exchanges[journal.exchanges.count - 1].receivedUptime = ProcessInfo.processInfo.systemUptime
            try save(journal, lease)
            return response
        }
        // With control enabled and no sensor configured, 3.12 reports CGM type 1
        // (seen on firmware 9.0.4 right after the enable); before that it is 0. With
        // desired type G7 it may report 7 instead; that hasn't been observed yet.
        let allowedCgmTypes: [UInt8] = sensorType == 7 ? [0, 1, 7] : [0, 1]
        @discardableResult
        func status() throws -> O5UnifiedAidStatus {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12="))
            let detailed = try O5DetailedStatusPage2(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2"))
            guard detailed.fault == 0, detailed.active, detailed.deliveryStatus == 1,
                  aid.algorithmReady, aid.podActive, aid.isManual, allowedCgmTypes.contains(aid.cgmType) else {
                throw Stopped(reason: "Pod is not ready, active, Manual, sensor-free and fault-free (CGM type \(aid.cgmType))")
            }
            return aid
        }
        // After desired type G7 is set, the CGM type and algorithm readiness in 3.12 haven't
        // been observed. They are recorded, not required: a stop here would only leave setup
        // unfinished. A fault, a delivery or mode change, or an inactive Pod still stops.
        func statusAfterG7Type() throws {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12="))
            let detailed = try O5DetailedStatusPage2(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2"))
            guard detailed.fault == 0, detailed.active, detailed.deliveryStatus == 1, aid.podActive, aid.isManual else {
                throw Stopped(reason: "Pod is not active, Manual and fault-free after setting desired type G7")
            }
        }
        func interface() throws -> O5CgmInterfaceStatus {
            let value = try O5CgmInterfaceStatus(exchange(Data("G4.2".utf8), "4.2="))
            let allowedDesired: [UInt8] = sensorType == 7 ? [0, 7] : [0]
            guard let desired = value.desiredSensorType, allowedDesired.contains(desired), let control = value.control,
                  [UInt8(0), 1, 2, 255].contains(control) else {
                throw Stopped(reason: "unexpected sensor type or interface control")
            }
            return value
        }
        do {
            let first = try status()
            let before = try interface()
            // A nonzero CGM type before the write is only consistent with control already enabled.
            guard first.cgmType == 0 || before.control == 0 else {
                throw Stopped(reason: "CGM type \(first.cgmType) reported while control is not enabled")
            }
            let enableControl = before.control != 0
            let setType = sensorType != nil && before.desiredSensorType != sensorType
            if enableControl || setType {
                guard !previouslyVerified else {
                    throw Stopped(reason: "control or desired sensor type changed after verification")
                }
                let request = interfaceRequest(enableControl: enableControl, desiredSensorType: setType ? sensorType : nil)
                let reply = try exchange(request, enableResponsePrefix, mutation: true)
                try O5AidReplyCheck.extendedSet(reply, responsePrefix: enableResponsePrefix)
            }
            let after = try interface()
            guard after.control == 0 else { throw Stopped(reason: "control enable readback mismatch") }
            if let sensorType {
                guard after.desiredSensorType == sensorType else {
                    throw Stopped(reason: "desired sensor type readback mismatch (\(after))")
                }
                // The identity is a separate step; none may be stored yet. The reply layout
                // with desired type G7 hasn't been observed, so only a stored pairing code or
                // serial stops; the reply itself is kept in the record.
                let reply = try exchange(Data("G4.1".utf8), "4.1=")
                if let info = try? O5G7SensorInfo(reply), info.pairingCode != nil || info.serialNumber != nil {
                    throw Stopped(reason: "the Pod already has a sensor identity")
                }
                try statusAfterG7Type()
            } else {
                try status()
            }
            journal.phase = "verified"
            try save(journal, lease)
        } catch {
            journal.phase = "stopped"
            let reason = (error as? Stopped)?.reason ?? error.localizedDescription
            journal.reason = reason
            // If this fails, the earlier durable checking/writePending record still
            // forbids another mutation. An uncertain outcome is never erased.
            try? save(journal, lease)
            throw Stopped(reason: reason)
        }
    }

    /// The record as JSON, for diagnostics. Reads local evidence only.
    static func record(id: String, directory: URL? = nil) throws -> String {
        let lease = try lease(id, directory)
        return String(decoding: try O5RecordLease.encode(load(lease)), as: UTF8.self)
    }
}
