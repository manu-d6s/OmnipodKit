//
//  O5G7TypeExperiment.swift
//  OmnipodKit
//

import Foundation

/// Experimental, for a Pod whose control was enabled at activation without a sensor type
/// and that rejected the official add-G7 batch with `ES4.1=-18`. It tests whether the
/// missing desired sensor type causes that rejection, changing nothing else:
///
/// 1. `setDesiredType`: write desired sensor type 7 alone (`SE4.2=00 02 01 07`) and read
///    back desired type 7, control still enabled and no sensor info.
/// 2. `sendIdentityBatch`: only after step 1 verified, send the same batch as before,
///    `SE4.2=00 02 04 00,SE4.1=<identity>`, once, then read back control, desired type,
///    sensor info and status.
///
/// On a Pod whose activation already set and verified desired type 7 (the early enable
/// with G7), step 2 runs without step 1. That is the official add-G7 batch on a Pod
/// activated with G7 selected but no identity.
///
/// 3. `replaceIdentity`: on a Pod that already has a G7 identity, send the same batch with
///    a different sensor's identity, as the official app does when a new G7 is added to a
///    running Pod, then read back the new identity. Independent of steps 1 and 2.
///
/// Each step has its own per-Pod record. Every exchange is saved before it is sent. A
/// step that reached its write is never sent again for that Pod, whatever the outcome; a
/// step that stopped before its write is kept as an earlier attempt and may be run again.
enum O5G7TypeExperiment {
    private struct Exchange: Codable {
        let request: Data
        let responsePrefix: String
        let started: Date
        var received: Date?
        var response: Data?
    }
    private struct Record: Codable {
        let schema: Int
        let step: String
        let target: String
        let firmware: String
        let bleFirmware: String
        let pairingCode: String?
        let serialNumber: String?
        let created: Date
        let revisions: [String: String]
        var phase: String
        var exchanges: [Exchange] = []
        var observations: [String] = []
        var reason: String?
    }
    struct Stopped: LocalizedError {
        let step: String
        let reason: String
        var errorDescription: String? {
            "G7 type experiment (\(step)) stopped: \(reason). If its write had already been sent, this step won't be sent again for this Pod. The record is in Pump Manager Details."
        }
    }

    static let typeStep = "set desired type"
    static let batchStep = "identity batch"
    static let replaceStep = "replace identity"
    /// Desired sensor type (key 1) = 7, G7. Control is already enabled, so only the
    /// differing field is written, as the official app does.
    static let desiredTypeRequest = Data("SE4.2=".utf8) + Data([0, 2, 1, 7])
    static let desiredTypeResponsePrefix = "ES4.2="

    // MARK: - Records

    private static func lease(_ target: String, _ fileName: String, _ directory: URL?) throws -> O5RecordLease {
        guard !target.isEmpty else { throw O5RecordError("the Pod has no identity") }
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5G7TypeExperiment", isDirectory: true)
        let name = String(target.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return try O5RecordLease(directory: root.appendingPathComponent(name, isDirectory: true), fileName: fileName)
    }
    private static func load(_ lease: O5RecordLease) throws -> Record? {
        guard FileManager.default.fileExists(atPath: lease.file.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: lease.file))
    }
    private static func save(_ record: Record, _ lease: O5RecordLease) throws {
        try lease.write(O5RecordLease.encode(record))
    }
    private static func stoppedBeforeTheWrite(_ record: Record) -> Bool {
        ["checking", "stopped"].contains(record.phase)
            && !record.exchanges.contains { $0.request.starts(with: Data("SE".utf8)) }
    }

    /// Every step's record as JSON, earlier attempts included, or nil if nothing was run.
    static func record(target: String, directory: URL? = nil) throws -> String? {
        var parts: [String] = []
        for (step, file) in [(typeStep, "type.json"), (batchStep, "batch.json"), (replaceStep, "replace.json")] {
            let lease = try lease(target, file, directory)
            if let current = try load(lease) {
                parts.append("\(step):\n" + String(decoding: try O5RecordLease.encode(current), as: UTF8.self))
            }
            let stem = file.replacingOccurrences(of: ".json", with: "")
            let earlier = ((try? FileManager.default.contentsOfDirectory(at: lease.directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("\(stem)-attempt-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in earlier {
                parts.append("\(step), earlier attempt (\(url.lastPathComponent)):\n"
                             + ((try? String(contentsOf: url, encoding: .utf8)) ?? "unreadable"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func phase(of file: String, target: String, directory: URL?) throws -> String? {
        try load(lease(target, file, directory))?.phase
    }

    /// The step 1 stop reason of builds before the placeholder fix. It was only reached after
    /// the type write's reply passed and G4.2 read back desired type 7 with control enabled.
    static let placeholderStopReason = "sensor info appeared after the type write"

    private static func stoppedOnPlaceholder(target: String, directory: URL?) throws -> Bool {
        guard let record = try load(lease(target, "type.json", directory)) else { return false }
        return record.phase == "stopped" && record.reason == placeholderStopReason
    }

    // MARK: - Running one step

    /// Opens the step's record: refuses if an earlier attempt reached its write, sets
    /// aside one that stopped before it, then creates a fresh record.
    private static func begin(step: String, file: String, target: String, firmware: String, bleFirmware: String,
                              pairingCode: String?, serialNumber: String?, directory: URL?) throws -> (O5RecordLease, Record) {
        do {
            let lease = try lease(target, file, directory)
            if let existing = try load(lease) {
                guard stoppedBeforeTheWrite(existing) else {
                    throw Stopped(step: step, reason: "already run for this Pod (\(existing.phase))")
                }
                let stem = file.replacingOccurrences(of: ".json", with: "")
                let archive = lease.directory.appendingPathComponent("\(stem)-attempt-\(Int(existing.created.timeIntervalSince1970)).json")
                try FileManager.default.moveItem(at: lease.file, to: archive)
            }
            let record = Record(schema: 1, step: step, target: target, firmware: firmware, bleFirmware: bleFirmware,
                                pairingCode: pairingCode, serialNumber: serialNumber, created: Date(),
                                revisions: O5RecordLease.revisions, phase: "checking")
            try save(record, lease)
            return (lease, record)
        } catch let error as Stopped { throw error }
        catch { throw Stopped(step: step, reason: "record unavailable: \(error.localizedDescription)") }
    }

    /// The common reads and the exchange journal for one step. `body` gets helpers that
    /// save each request before sending it and its reply right after.
    private static func run(step: String, lease: O5RecordLease, record initial: Record,
                            send: (Data, String) throws -> Data, detailedStatus: () throws -> Data,
                            body: (_ steps: Steps) throws -> String) throws -> String {
        var record = initial
        do {
            // The helpers only live for this call; nothing outlives `body`.
            return try withoutActuallyEscaping(send) { send in
                try withoutActuallyEscaping(detailedStatus) { detailedStatus in
                    let steps = Steps(
                        exchange: { request, prefix, mutation in
                            if mutation { record.phase = "writePending" }
                            record.exchanges.append(Exchange(request: request, responsePrefix: prefix, started: Date()))
                            try save(record, lease)
                            let response = try prefix == "legacy-page-2" ? detailedStatus() : send(request, prefix)
                            record.exchanges[record.exchanges.count - 1].response = response
                            record.exchanges[record.exchanges.count - 1].received = Date()
                            try save(record, lease)
                            return response
                        },
                        setPhase: { phase in record.phase = phase; try save(record, lease) },
                        observe: { note in record.observations.append(note); try save(record, lease) })
                    return try body(steps)
                }
            }
        } catch {
            record.phase = "stopped"
            let reason = (error as? Stopped)?.reason ?? error.localizedDescription
            record.reason = reason
            // If this fails, the earlier durable record still blocks a repeat of the write.
            try? save(record, lease)
            throw Stopped(step: step, reason: reason)
        }
    }

    private struct Steps {
        let exchange: (_ request: Data, _ prefix: String, _ mutation: Bool) throws -> Data
        let setPhase: (_ phase: String) throws -> Void
        let observe: (_ note: String) throws -> Void

        func status(_ step: String) throws -> O5UnifiedAidStatus {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12=", false))
            let detailed = try O5DetailedStatusPage2(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2", false))
            // Scheduled or temporary basal only: no bolus running, not suspended.
            guard detailed.fault == 0, detailed.active, [UInt8(1), 2].contains(detailed.deliveryStatus),
                  aid.algorithmReady, aid.podActive, aid.isManual else {
                throw Stopped(step: step, reason: "Pod is not ready, active, Manual and fault-free with only basal running")
            }
            return aid
        }
        func interface() throws -> O5CgmInterfaceStatus {
            try O5CgmInterfaceStatus(exchange(Data("G4.2".utf8), "4.2=", false))
        }
        func sensorInfo() throws -> O5G7SensorInfo {
            try O5G7SensorInfo(exchange(Data("G4.1".utf8), "4.1=", false))
        }
    }

    // MARK: - Step 1: desired type

    /// Runs on the caller's Pod session queue. Returns a summary.
    static func setDesiredType(target: String, firmware: String, bleFirmware: String, directory: URL? = nil,
                               send: (Data, String) throws -> Data,
                               detailedStatus: () throws -> Data) throws -> String {
        let step = typeStep
        let (lease, record) = try begin(step: step, file: "type.json", target: target, firmware: firmware,
                                        bleFirmware: bleFirmware, pairingCode: nil, serialNumber: nil, directory: directory)
        return try run(step: step, lease: lease, record: record, send: send, detailedStatus: detailedStatus) { s in
            let before = try s.status(step)
            guard before.cgmType == 0 || before.cgmType == 1 else {
                throw Stopped(step: step, reason: "unexpected CGM type \(before.cgmType)")
            }
            let interface = try s.interface()
            guard interface.control == 0, interface.desiredSensorType == 0 else {
                throw Stopped(step: step, reason: "expected control enabled and desired type 0 (\(interface))")
            }
            guard try s.sensorInfo().isEmpty else { throw Stopped(step: step, reason: "the Pod already has sensor info") }

            let reply = try s.exchange(desiredTypeRequest, desiredTypeResponsePrefix, true)
            try O5AidReplyCheck.extendedSet(reply, responsePrefix: desiredTypeResponsePrefix)
            try s.setPhase("sent")

            let after = try s.interface()
            guard after.desiredSensorType == 7, after.control == 0 else {
                throw Stopped(step: step, reason: "readback is not desired type 7 with control enabled (\(after))")
            }
            // The Pod creates a placeholder G7 record once the type is set; only an identity stops.
            let info = try s.sensorInfo()
            guard !info.hasIdentity else { throw Stopped(step: step, reason: "a sensor identity appeared after the type write") }
            try s.observe("G4.1 after the type write: \(info.isPlaceholder ? "placeholder G7 record" : "empty")")
            let status = try s.status(step)
            try s.observe("CGM type after the type write: \(status.cgmType)")
            try s.setPhase("verified")
            return "Desired type 7 set and read back. CGM type \(O5CgmStatusReport.cgmTypeName(status.cgmType)). Wait a few minutes and read the status before sending the identity batch."
        }
    }

    // MARK: - Step 2: identity batch

    /// Runs on the caller's Pod session queue, only after step 1 verified. Returns a summary.
    static func sendIdentityBatch(target: String, firmware: String, bleFirmware: String,
                                  pairingCode: String, serialNumber: String,
                                  typeSetAtActivation: Bool = false, directory: URL? = nil,
                                  send: (Data, String) throws -> Data,
                                  detailedStatus: () throws -> Data) throws -> String {
        let step = batchStep
        let batch: Data
        do {
            batch = try O5G7Identity.batchRequest(pairingCode: pairingCode, serialNumber: serialNumber)
        } catch {
            throw Stopped(step: step, reason: (error as? O5G7Identity.Stopped)?.reason ?? error.localizedDescription)
        }
        let typePhase: String?
        do {
            typePhase = try phase(of: "type.json", target: target, directory: directory)
        } catch {
            throw Stopped(step: step, reason: "record unavailable: \(error.localizedDescription)")
        }
        // Builds before the placeholder fix stopped step 1 on the placeholder record, after the
        // type write was accepted and read back as 7. That record counts as verified.
        let typeStoppedOnPlaceholder: Bool
        do {
            typeStoppedOnPlaceholder = try stoppedOnPlaceholder(target: target, directory: directory)
        } catch {
            throw Stopped(step: step, reason: "record unavailable: \(error.localizedDescription)")
        }
        guard typePhase == "verified" || typeStoppedOnPlaceholder || typeSetAtActivation else {
            throw Stopped(step: step, reason: "desired type G7 has not been verified for this Pod (step 1 or at activation)")
        }
        let (lease, record) = try begin(step: step, file: "batch.json", target: target, firmware: firmware,
                                        bleFirmware: bleFirmware, pairingCode: pairingCode, serialNumber: serialNumber,
                                        directory: directory)
        return try run(step: step, lease: lease, record: record, send: send, detailedStatus: detailedStatus) { s in
            _ = try s.status(step)
            let interface = try s.interface()
            guard interface.control == 0, interface.desiredSensorType == 7 else {
                throw Stopped(step: step, reason: "expected control enabled and desired type 7 (\(interface))")
            }
            guard try !s.sensorInfo().hasIdentity else { throw Stopped(step: step, reason: "the Pod already has a sensor identity") }

            let reply = try s.exchange(batch, O5G7Identity.batchResponsePrefix, true)
            let results: (enable: Data, identity: Data)
            do {
                results = try O5G7Identity.batchResults(reply)
            } catch {
                throw Stopped(step: step, reason: (error as? O5G7Identity.Stopped)?.reason ?? error.localizedDescription)
            }
            try O5AidReplyCheck.extendedSet(results.enable, responsePrefix: "ES4.2=")
            try O5AidReplyCheck.extendedSet(results.identity, responsePrefix: "ES4.1=")
            try s.setPhase("sent")

            // The enable member writes control only; check it left the desired type alone.
            let after = try s.interface()
            try s.observe("after the batch: \(after)")
            guard try s.sensorInfo().matches(pairingCode: pairingCode, serialNumber: serialNumber) else {
                throw Stopped(step: step, reason: "the Pod did not read back the identity sent")
            }
            let status = try s.status(step)
            try s.observe("CGM type after the batch: \(status.cgmType), glucose \(status.egv.map { String($0) } ?? "none")")
            guard after.control == 0, after.desiredSensorType == 7 else {
                throw Stopped(step: step, reason: "identity stored, but the interface reads back \(after)")
            }
            try s.setPhase("stored")
            return "Identity accepted and stored. CGM type \(O5CgmStatusReport.cgmTypeName(status.cgmType)). Glucose: \(status.egv.map { "\($0) mg/dL" } ?? "none yet"). Use Read O5 CGM Status to follow the sensor."
        }
    }

    // MARK: - Step 3: replace the identity

    /// Runs on the caller's Pod session queue. Returns a summary.
    static func replaceIdentity(target: String, firmware: String, bleFirmware: String,
                                pairingCode: String, serialNumber: String, directory: URL? = nil,
                                send: (Data, String) throws -> Data,
                                detailedStatus: () throws -> Data) throws -> String {
        let step = replaceStep
        let batch: Data
        do {
            batch = try O5G7Identity.batchRequest(pairingCode: pairingCode, serialNumber: serialNumber)
        } catch {
            throw Stopped(step: step, reason: (error as? O5G7Identity.Stopped)?.reason ?? error.localizedDescription)
        }
        let (lease, record) = try begin(step: step, file: "replace.json", target: target, firmware: firmware,
                                        bleFirmware: bleFirmware, pairingCode: pairingCode, serialNumber: serialNumber,
                                        directory: directory)
        return try run(step: step, lease: lease, record: record, send: send, detailedStatus: detailedStatus) { s in
            let before = try s.status(step)
            guard before.cgmType == 7 else {
                throw Stopped(step: step, reason: "expected CGM type 7, G7 (CGM type \(before.cgmType))")
            }
            let interface = try s.interface()
            guard interface.control == 0, interface.desiredSensorType == 7 else {
                throw Stopped(step: step, reason: "expected control enabled and desired type 7 (\(interface))")
            }
            let current = try s.sensorInfo()
            guard current.hasIdentity else {
                throw Stopped(step: step, reason: "the Pod has no sensor identity to replace")
            }
            // Re-sending the stored identity has unknown effects; this step only changes it.
            guard !current.matches(pairingCode: pairingCode, serialNumber: serialNumber) else {
                throw Stopped(step: step, reason: "the Pod already has this identity")
            }

            let reply = try s.exchange(batch, O5G7Identity.batchResponsePrefix, true)
            let results: (enable: Data, identity: Data)
            do {
                results = try O5G7Identity.batchResults(reply)
            } catch {
                throw Stopped(step: step, reason: (error as? O5G7Identity.Stopped)?.reason ?? error.localizedDescription)
            }
            try O5AidReplyCheck.extendedSet(results.enable, responsePrefix: "ES4.2=")
            try O5AidReplyCheck.extendedSet(results.identity, responsePrefix: "ES4.1=")
            try s.setPhase("sent")

            let after = try s.interface()
            try s.observe("after the batch: \(after)")
            guard try s.sensorInfo().matches(pairingCode: pairingCode, serialNumber: serialNumber) else {
                throw Stopped(step: step, reason: "the Pod did not read back the new identity")
            }
            let status = try s.status(step)
            try s.observe("CGM type after the batch: \(status.cgmType), glucose \(status.egv.map { String($0) } ?? "none")")
            guard after.control == 0, after.desiredSensorType == 7 else {
                throw Stopped(step: step, reason: "new identity stored, but the interface reads back \(after)")
            }
            try s.setPhase("replaced")
            return "New identity accepted and stored in place of the previous one. CGM type \(O5CgmStatusReport.cgmTypeName(status.cgmType)). Glucose: \(status.egv.map { "\($0) mg/dL" } ?? "none yet"). Use Read O5 CGM Status to follow the new sensor."
        }
    }
}
