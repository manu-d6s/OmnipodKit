//
//  O5PodDataLog.swift
//  OmnipodKit
//

import Foundation
import os.log

/// Research logging, off by default: a JSON-lines file per Pod with every delivery command
/// sent to the Pod, every status response, and (O5) a `G3.12` read after each fetched pump
/// status. Read-only towards the Pod. Logging failures are written to the system log and
/// otherwise ignored; they never affect a command.
enum O5PodDataLog {
    static let enabledKey = "O5PodDataLog.enabled"
    private static let log = OSLog(category: "O5PodDataLog")

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5PodDataLog", isDirectory: true)
    }

    static func fileURL(target: String, directory: URL? = nil) throws -> URL {
        let name = String(target.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return try (directory ?? self.directory()).appendingPathComponent("\(name).jsonl")
    }

    /// Appends one entry. The first entry for a Pod is preceded by `header`.
    static func append(target: String, header: @autoclosure () -> [String: Any], entry: [String: Any],
                       directory: URL? = nil, now: Date = Date()) {
        guard !target.isEmpty else { return }
        do {
            let url = try fileURL(target: target, directory: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = Data()
            if !FileManager.default.fileExists(atPath: url.path) {
                lines += try line(["kind": "header", "phoneTime": timestamp(now)].merging(header()) { a, _ in a })
            }
            lines += try line(["phoneTime": timestamp(now)].merging(entry) { a, _ in a })
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lines)
            } else {
                try lines.write(to: url, options: .atomic)
            }
        } catch {
            os_log("Pod data log write failed: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    struct InvalidEntry: Error {}

    /// JSONSerialization raises an uncatchable exception for invalid input, such as NaN or
    /// infinite numbers, so every entry is validated first and skipped if invalid.
    static func line(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw InvalidEntry() }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Entries

    /// The delivery-related blocks in a message, or nil if it has none.
    static func commandFields(_ blocks: [MessageBlock]) -> [[String: Any]]? {
        var out: [[String: Any]] = []
        for block in blocks {
            switch block {
            case let bolus as BolusExtraCommand:
                var fields: [String: Any] = ["type": "bolus", "units": bolus.units,
                                             "extendedUnits": bolus.extendedUnits,
                                             "extendedDuration": bolus.extendedDuration,
                                             "secondsBetweenPulses": bolus.timeBetweenPulses]
                if let info = bolus.bolusInfo {
                    fields["mealUnits"] = info.mealUnits
                    fields["correctionUnits"] = info.correctionUnits
                    fields["bolusSource"] = Int(info.bolusSource)
                }
                out.append(fields)
            case let temp as TempBasalExtraCommand:
                out.append(["type": "tempBasal", "segments": rateSegments(temp.rateEntries),
                            "durationSeconds": temp.rateEntries.reduce(0) { $0 + $1.duration }])
            case let basal as BasalScheduleExtraCommand:
                out.append(["type": "basalSchedule", "segments": rateSegments(basal.rateEntries),
                            "currentEntryIndex": Int(basal.currentEntryIndex)])
            case let cancel as CancelDeliveryCommand:
                out.append(["type": "cancelDelivery", "deliveryType": String(describing: cancel.deliveryType)])
            default:
                continue
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func rateSegments(_ entries: [RateEntry]) -> [[String: Double]] {
        entries.map { ["unitsPerHour": $0.rate, "seconds": $0.duration] }
    }

    static func statusFields(_ status: StatusResponse) -> [String: Any] {
        ["deliveryStatus": String(describing: status.deliveryStatus),
         "podProgress": String(describing: status.podProgressStatus),
         "timeActiveSeconds": status.timeActive,
         "insulinDelivered": status.insulinDelivered,
         "bolusNotDelivered": status.bolusNotDelivered,
         "reservoirLevel": status.reservoirLevel,
         "lastProgrammingMessageSeqNum": Int(status.lastProgrammingMessageSeqNum),
         "raw": status.data.hexadecimalString]
    }

    /// The raw `3.12` reply and its main fields. Undecodable replies keep only the raw hex.
    static func aidStatusFields(_ reply: Data) -> [String: Any] {
        var fields: [String: Any] = ["kind": "aidStatus", "raw": reply.hexadecimalString]
        if let status = try? O5UnifiedAidStatus(reply) {
            fields["podTime"] = Int(status.podTime)
            fields["egvRefTime"] = Int(status.referenceTime)
            fields["iobRaw"] = Int(status.iobRaw)
            fields["egvRaw"] = Int(status.egvRaw)
            fields["tdi"] = Int(status.totalDailyInsulin)
            fields["loopState"] = Int(status.loopState)
            fields["cgmType"] = Int(status.cgmType)
        }
        return fields
    }
}
