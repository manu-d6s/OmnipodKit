//
//  O5G7Identity.swift
//  OmnipodKit
//

import Foundation

/// Experimental, one shot per Pod: give an O5 Pod the identity of a Dexcom G7 sensor,
/// using the same operation the official app uses to add a G7 to an active Pod:
/// one batch `SE4.2=00 02 04 00,SE4.1=<identity>` (control enable without a desired
/// sensor type, then the sensor identity), followed by status reads.
///
/// Only for a Pod whose CGM interface control is already enabled (the early control
/// enable at activation) and that has no sensor configured. Every exchange is saved to
/// a per-Pod record before it is sent. Once a record exists the identity is never sent
/// again for that Pod, whatever the outcome, so a rejected or uncertain attempt can't
/// be repeated by accident. "stored" means the Pod read the identity back; it doesn't
/// mean glucose has been received.
enum O5G7Identity {
    private struct Exchange: Codable {
        let request: Data
        let responsePrefix: String
        let started: Date
        var received: Date?
        var response: Data?
    }
    private struct Record: Codable {
        let schema: Int
        let target: String
        let firmware: String
        let bleFirmware: String
        let pairingCode: String
        let serialNumber: String
        let created: Date
        let revisions: [String: String]
        var phase: String
        var exchanges: [Exchange] = []
        var reason: String?
    }
    struct Stopped: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "G7 sensor identity stopped: \(reason). It will not be sent again for this Pod. The record is in Pump Manager Details."
        }
    }

    static let batchResponsePrefix = "ES4.2="

    /// `SE4.1=` with the G7 pairing code (key 2) and serial number (key 3).
    static func identityRequest(pairingCode: String, serialNumber: String) throws -> Data {
        func digits(_ value: String, _ count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard digits(pairingCode, 4), digits(serialNumber, 12) else {
            throw Stopped(reason: "the pairing code must be 4 digits and the serial number 12 digits")
        }
        return Data("SE4.1=".utf8) + Data([0, 18, 2]) + Data(pairingCode.utf8) + Data([3]) + Data(serialNumber.utf8)
    }

    /// The control enable and the identity in one application batch.
    static func batchRequest(pairingCode: String, serialNumber: String) throws -> Data {
        O5EarlyControlEnable.enableRequest + Data([0x2c]) + (try identityRequest(pairingCode: pairingCode, serialNumber: serialNumber))
    }

    /// Splits the batch reply body (after `ES4.2=`) into the two result codes.
    static func batchResults(_ body: Data) throws -> (enable: Data, identity: Data) {
        // Both members are decimal result codes, so splitting on the comma is safe.
        let members = Array(Data(batchResponsePrefix.utf8) + body)
            .split(separator: 0x2c, omittingEmptySubsequences: false).map { Data($0) }
        let enablePrefix = Data("ES4.2=".utf8), identityPrefix = Data("ES4.1=".utf8)
        guard members.count == 2, members[0].starts(with: enablePrefix), members[1].starts(with: identityPrefix) else {
            throw Stopped(reason: "unexpected batch reply \(body.hexadecimalString)")
        }
        return (Data(members[0].dropFirst(enablePrefix.count)), Data(members[1].dropFirst(identityPrefix.count)))
    }

    // MARK: - Record storage

    private static func lease(_ target: String, _ directory: URL?) throws -> O5RecordLease {
        guard !target.isEmpty else { throw Stopped(reason: "the Pod has no identity") }
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5G7Identity", isDirectory: true)
        let name = String(target.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return try O5RecordLease(directory: root.appendingPathComponent(name, isDirectory: true), fileName: "identity.json")
    }
    private static func load(_ lease: O5RecordLease) throws -> Record? {
        guard FileManager.default.fileExists(atPath: lease.file.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: lease.file))
    }
    private static func save(_ record: Record, _ lease: O5RecordLease) throws {
        try lease.write(O5RecordLease.encode(record))
    }

    /// The record as JSON, for diagnostics, or nil if nothing was attempted for this Pod.
    static func record(target: String, directory: URL? = nil) throws -> String? {
        let lease = try lease(target, directory)
        return try load(lease).map { String(decoding: try O5RecordLease.encode($0), as: UTF8.self) }
    }

    // MARK: - Send

    /// Runs on the caller's Pod session queue. Reply bodies exclude their AID prefix;
    /// `detailedStatus` returns the 22-byte detailed status body. Returns a summary.
    static func send(target: String, firmware: String, bleFirmware: String,
                     pairingCode: String, serialNumber: String, directory: URL? = nil,
                     send: (Data, String) throws -> Data,
                     detailedStatus: () throws -> Data) throws -> String {
        let batch = try batchRequest(pairingCode: pairingCode, serialNumber: serialNumber)
        let lease: O5RecordLease
        do {
            lease = try self.lease(target, directory)
            if let existing = try load(lease) {
                throw Stopped(reason: "already attempted for this Pod (\(existing.phase))")
            }
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "record unavailable: \(error.localizedDescription)") }

        var record = Record(schema: 1, target: target, firmware: firmware, bleFirmware: bleFirmware,
                            pairingCode: pairingCode, serialNumber: serialNumber, created: Date(),
                            revisions: O5RecordLease.revisions, phase: "checking")
        do {
            try save(record, lease)
        } catch {
            throw Stopped(reason: "record unavailable: \(error.localizedDescription)")
        }

        func exchange(_ request: Data, _ prefix: String, mutation: Bool = false) throws -> Data {
            if mutation { record.phase = "writePending" }
            record.exchanges.append(Exchange(request: request, responsePrefix: prefix, started: Date()))
            // Durable intent precedes every send, especially the batch.
            try save(record, lease)
            let response = try prefix == "legacy-page-2" ? detailedStatus() : send(request, prefix)
            record.exchanges[record.exchanges.count - 1].response = response
            record.exchanges[record.exchanges.count - 1].received = Date()
            try save(record, lease)
            return response
        }
        func status() throws -> O5UnifiedAidStatus {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12="))
            let detailed = try O5DetailedStatusPage2(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2"))
            // Scheduled or temporary basal only: no bolus running, not suspended.
            guard detailed.fault == 0, detailed.active, [UInt8(1), 2].contains(detailed.deliveryStatus),
                  aid.algorithmReady, aid.podActive, aid.isManual else {
                throw Stopped(reason: "Pod is not ready, active, Manual and fault-free with only basal running")
            }
            return aid
        }
        func interface() throws -> O5CgmInterfaceStatus {
            try O5CgmInterfaceStatus(exchange(Data("G4.2".utf8), "4.2="))
        }
        func sensorInfo() throws -> O5G7SensorInfo {
            try O5G7SensorInfo(exchange(Data("G4.1".utf8), "4.1="))
        }

        do {
            let before = try status()
            guard before.cgmType == 0 || before.cgmType == 1 else {
                throw Stopped(reason: "a sensor is already configured (CGM type \(before.cgmType))")
            }
            let control = try interface()
            guard control.control == 0, control.desiredSensorType == 0 else {
                throw Stopped(reason: "CGM interface control is not enabled without a sensor type (\(control))")
            }
            guard try sensorInfo().isEmpty else {
                throw Stopped(reason: "the Pod already has sensor info")
            }

            let reply = try exchange(batch, batchResponsePrefix, mutation: true)
            let results = try batchResults(reply)
            try O5AidReplyCheck.extendedSet(results.enable, responsePrefix: "ES4.2=")
            try O5AidReplyCheck.extendedSet(results.identity, responsePrefix: "ES4.1=")
            record.phase = "sent"
            try save(record, lease)

            guard try interface().control == 0 else { throw Stopped(reason: "control is no longer enabled") }
            guard try sensorInfo().matches(pairingCode: pairingCode, serialNumber: serialNumber) else {
                throw Stopped(reason: "the Pod did not read back the identity sent")
            }
            let after = try status()
            record.phase = "stored"
            try save(record, lease)
            return "Identity stored. CGM type \(O5CgmStatusReport.cgmTypeName(after.cgmType)). Glucose: \(after.egv.map { "\($0) mg/dL" } ?? "none yet"). Use Read O5 CGM Status to follow the sensor."
        } catch {
            record.phase = "stopped"
            let reason = (error as? Stopped)?.reason ?? error.localizedDescription
            record.reason = reason
            // If this fails, the earlier durable record still blocks another attempt.
            try? save(record, lease)
            throw Stopped(reason: reason)
        }
    }
}
