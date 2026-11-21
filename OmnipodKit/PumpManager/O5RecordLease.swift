//
//  O5RecordLease.swift
//  OmnipodKit
//

import Foundation
import Darwin

struct O5RecordError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// One record directory per Pod, held under an exclusive lock while in use.
/// Records are written atomically and fsynced before anything is sent to the Pod.
final class O5RecordLease {
    let directory: URL
    let file: URL
    private var lock: Int32 = -1

    init(directory: URL, fileName: String = "activation.json") throws {
        self.directory = directory
        self.file = directory.appendingPathComponent(fileName)
        try Self.makePrivateDirectory(directory)
        lock = open(directory.appendingPathComponent("record.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw O5RecordError("activation record cannot be opened") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); lock = -1
            throw O5RecordError("activation record is in use")
        }
    }
    deinit { if lock >= 0 { close(lock) } }

    /// Owner-only, file-protected and excluded from backups, so a restored
    /// backup cannot bring back a record for a Pod it doesn't describe.
    private static func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw O5RecordError("activation record location is not a directory")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(url.path, 0o700) == 0 else { throw O5RecordError("activation record permissions") }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #endif
    }

    /// Atomic, fsynced replacement of the record.
    func write(_ data: Data) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw O5RecordError("activation record cannot be written") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        #endif
        guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else {
            throw O5RecordError("activation record cannot be written")
        }
        let parent = open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw O5RecordError("activation record cannot be written") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw O5RecordError("activation record cannot be written") }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// The installed app and OmnipodKit revisions, from Trio's BuildDetails.plist.
    static var revisions: [String: String] {
        let details = Bundle.main.url(forResource: "BuildDetails", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] } ?? [:]
        let modules = details["com-trio-submodules"] as? [String: [String: Any]]
        return [
            "hostBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "hostTrioCommitSHA": details["com-trio-commit-sha"] as? String ?? "unknown",
            "hostTrioBranch": details["com-trio-branch"] as? String ?? "unknown",
            "hostBuildDate": details["com-trio-build-date"] as? String ?? "unknown",
            "hostOmnipodKitCommitSHA": modules?["OmnipodKit"]?["commit_sha"] as? String ?? "unknown",
            "hostOmnipodKitBranch": modules?["OmnipodKit"]?["branch"] as? String ?? "unknown",
        ]
    }
}
