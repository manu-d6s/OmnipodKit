//
//  O5EarlyControlEnable.swift
//  OmnipodKit
//

import Foundation

/// Experimental, opt-in: enable the O5 Pod's CGM interface control once, right after
/// cannula insertion, while the Pod stays in Manual mode. No sensor type or identity
/// is sent. The caller owns the serialized Pod session; this never repeats setup.
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
    }
    struct Stopped: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Early control enable stopped: \(reason). Cannula insertion may already be complete. The enable command will not be retried automatically. Review the activation record before continuing."
        }
    }

    static let enableRequest = Data("SE4.2=".utf8) + Data([0, 2, 4, 0])
    static let enableResponsePrefix = "ES4.2="

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
                    directory: URL? = nil) throws {
        do {
            let lease = try lease(id, directory)
            guard !FileManager.default.fileExists(atPath: lease.file.path), !target.isEmpty else {
                throw Stopped(reason: "activation record already exists or target is empty")
            }
            try save(Journal(schema: 1, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware,
                             armed: Date(), revisions: O5RecordLease.revisions, phase: "armed"), lease)
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
        return journal
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
        // (seen on firmware 9.0.4 right after the enable); before that it is 0.
        @discardableResult
        func status() throws -> O5UnifiedAidStatus {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12="))
            let detailed = try O5DetailedStatusPage2(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2"))
            guard detailed.fault == 0, detailed.active, detailed.deliveryStatus == 1,
                  aid.algorithmReady, aid.podActive, aid.isManual, aid.cgmType == 0 || aid.cgmType == 1 else {
                throw Stopped(reason: "Pod is not ready, active, Manual, sensor-free and fault-free (CGM type \(aid.cgmType))")
            }
            return aid
        }
        func interface() throws -> O5CgmInterfaceStatus {
            let value = try O5CgmInterfaceStatus(exchange(Data("G4.2".utf8), "4.2="))
            guard value.desiredSensorType == 0, let control = value.control,
                  [UInt8(0), 1, 2, 255].contains(control) else {
                throw Stopped(reason: "unexpected sensor type or interface control")
            }
            return value
        }
        do {
            let first = try status()
            let before = try interface()
            // Type 1 before the enable is only consistent with control already enabled.
            guard first.cgmType == 0 || before.control == 0 else {
                throw Stopped(reason: "CGM type 1 reported while control is not enabled")
            }
            if before.control != 0 {
                guard !previouslyVerified else {
                    throw Stopped(reason: "control changed after verification")
                }
                let reply = try exchange(enableRequest, enableResponsePrefix, mutation: true)
                try O5AidReplyCheck.extendedSet(reply, responsePrefix: enableResponsePrefix)
            }
            guard try interface().control == 0 else { throw Stopped(reason: "control enable readback mismatch") }
            try status()
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
