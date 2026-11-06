//
//  PosterBoardDB.swift
//  OurCard
//
//  Nugget's SQLite registration recipe, adapted for the on-device world.
//
//  THE CORE CONSTRAINT: the AirTraffic exploit is WRITE-ONLY. On-device we
//  cannot read PosterBoard's database back, which means we cannot compute
//  the next posterId / roleSortKey ourselves. AirCard's answer is to skip
//  SQLite registration entirely (descriptor copy + refresh flags only).
//
//  OurCard's answer is a fail-safe seam:
//    * DatabaseReader protocol. OnDeviceDatabaseReader always reports
//      .unreadableOnDevice (honest: the primitive cannot read).
//    * ImportedDatabaseReader reads a DB the user imported through the Files
//      app / share sheet — e.g. one pulled from a device backup and prepared
//      by the Windows Studio companion (desktop CAN read backups).
//    * register() applies Nugget's exact insert recipe to a COPY of a
//      readable original, then writes the whole modified DB to its absolute
//      on-device path via the exploit.
//    * If no readable DB is available, register() FAILS SAFE: it logs a clear
//      line and returns .descriptorsOnly. DescriptorInjector has already
//      written the descriptor folders + refresh flags, so the wallpaper may
//      still be selectable in Settings › Wallpaper — it just isn't guaranteed
//      to appear in the gallery.
//
//  HARD RULE: never write a database file we could not read first. The write
//  path requires a verified-readable original plus explicit user confirmation,
//  because a corrupt PosterBoard DB breaks the wallpaper gallery until the
//  device is restored from backup.
//

import Foundation
import SQLite3

public enum PosterBoardDBError: Error, LocalizedError {
    case unreadableOnDevice
    case openFailed(String)
    case schemaUnexpected(String)
    case userDeclined

    public var errorDescription: String? {
        switch self {
        case .unreadableOnDevice:
            return "PosterBoard database cannot be read on-device (exploit is write-only)."
        case .openFailed(let m): return "Could not open database copy: \(m)"
        case .schemaUnexpected(let m): return "Database schema unexpected: \(m)"
        case .userDeclined: return "User declined the database overwrite."
        }
    }
}

/// Outcome of a registration attempt.
public enum PosterRegistration {
    /// Rows were inserted into a verified-readable DB copy and written to the device.
    case registered(posterId: Int)
    /// No readable DB: descriptors were still injected + refresh flags written.
    case descriptorsOnly(reason: String)
}

public protocol DatabaseReader {
    /// Returns a local, readable URL of PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3,
    /// or throws PosterBoardDBError.unreadableOnDevice.
    func readableDatabaseURL() throws -> URL
}

/// On-device reality: the write-only primitive cannot read the DB. Always fails safe.
public struct OnDeviceDatabaseReader: DatabaseReader {
    public init() {}
    public func readableDatabaseURL() throws -> URL {
        throw PosterBoardDBError.unreadableOnDevice
    }
}

/// Reads a DB the user imported via Files/share sheet (e.g. prepared by the
/// Windows Studio from a device backup of THIS device).
public struct ImportedDatabaseReader: DatabaseReader {
    public let importedURL: URL
    public init(importedURL: URL) { self.importedURL = importedURL }
    public func readableDatabaseURL() throws -> URL {
        guard FileManager.default.fileExists(atPath: importedURL.path) else {
            throw PosterBoardDBError.openFailed("imported file missing")
        }
        return importedURL
    }
}

public final class PosterBoardDB {
    private let bridge = AirliftBridge.shared
    public init() {}

    /// Absolute on-device path of the PosterBoard SQLite store.
    /// (nugget: src/tweaks/posterboard/posterboard_tweak.py:325)
    public static func deviceDBPath(container: String, structVersion: Int) -> String {
        let c = container
            .replacingOccurrences(of: "file://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(c)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
    }

    /// Nugget's recipe (src/tweaks/posterboard/pb_config_manager.py::update_sqlite):
    /// seq+1 → poster(posterId, UUID, providerId);
    /// posterAttributes(posterUUID, PRPosterRoleLockScreen, SELECTED=1) when set-as-selected;
    /// posterAttributes(..., PRPosterRoleAttributeTypeUsageMetadata, JSON payload);
    /// posterRoleMembership(posterUUID, PRPosterRoleLockScreen, maxSortKey+1);
    /// bump sqlite_sequence.
    public func register(
        uuid: String,
        providerId: String,
        setSelected: Bool,
        container: String,
        structVersion: Int,
        reader: DatabaseReader,
        userConfirmedOverwrite: Bool,
        log: @escaping (String) -> Void
    ) async -> PosterRegistration {
        let originalURL: URL
        do {
            originalURL = try reader.readableDatabaseURL()
        } catch {
            let reason = "No readable PosterBoard DB (\(error.localizedDescription)). " +
                "Wrote descriptor folders + refresh flags only; open Settings › Wallpaper to select it manually."
            log("⚠️ \(reason)")
            return .descriptorsOnly(reason: reason)
        }

        guard userConfirmedOverwrite else {
            let reason = "Database overwrite declined by user; descriptors-only fallback used."
            log("⚠️ \(reason)")
            return .descriptorsOnly(reason: reason)
        }

        do {
            let staged = try buildModifiedCopy(original: originalURL, uuid: uuid,
                                               providerId: providerId, setSelected: setSelected)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            let stageDir = staged.deletingLastPathComponent()
            let dbPath = Self.deviceDBPath(container: container, structVersion: structVersion)
            let targetDir = (dbPath as NSString).deletingLastPathComponent
            log("Writing modified PosterBoard database…")
            try await bridge.writeDir(sourceDir: stageDir.path, targetDir: targetDir, log: log)
            log("✅ PosterBoard database updated.")
            return .registered(posterId: -1) // exact id is inside the staged copy; re-read on next import
        } catch {
            let reason = "Database modification failed (\(error.localizedDescription)); descriptors-only fallback used."
            log("⚠️ \(reason)")
            return .descriptorsOnly(reason: reason)
        }
    }

    // MARK: - SQLite surgery (all on a private copy; original never touched)

    private func buildModifiedCopy(original: URL, uuid: String,
                                   providerId: String, setSelected: Bool) throws -> URL {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ourcard_pbdb_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let staged = workDir.appendingPathComponent("PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3")
        try fm.copyItem(at: original, to: staged)

        var db: OpaquePointer?
        guard sqlite3_open_v2(staged.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = db else {
            throw PosterBoardDBError.openFailed("sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        func intQuery(_ sql: String, fallback: Int) throws -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
                throw PosterBoardDBError.schemaUnexpected(sql)
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
            return fallback
        }
        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw PosterBoardDBError.schemaUnexpected(msg)
            }
        }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

        let seq = try intQuery("SELECT seq FROM sqlite_sequence WHERE name='poster'", fallback: -1)
        guard seq >= 0 else { throw PosterBoardDBError.schemaUnexpected("missing sqlite_sequence row for 'poster'") }
        let maxSort = try intQuery(
            "SELECT COALESCE(MAX(roleSortKey), \(seq)) FROM posterRoleMembership WHERE roleId='PRPosterRoleLockScreen'",
            fallback: seq)
        let newId = seq + 1
        let now = Date().timeIntervalSince1970
        let payload = "{\"creationDate\":\(now),\"extensionAvailable\":true,\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\",\"lastActivatedDate\":\(now + 0.0001),\"lastSelectedDate\":\(now + 0.00001)}"

        // Mirror Nugget: clear the currently-selected marker first.
        try exec("DELETE FROM posterAttributes WHERE roleId='PRPosterRoleLockScreen' AND attributeIdentifier='SELECTED' AND attributePayload='1'")
        try exec("INSERT INTO poster (posterId, UUID, providerId) VALUES (\(newId), '\(esc(uuid))', '\(esc(providerId))')")
        if setSelected {
            try exec("INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES ('\(esc(uuid))', 'PRPosterRoleLockScreen', 'SELECTED', '1')")
        }
        try exec("INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES ('\(esc(uuid))', 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', '\(esc(payload))')")
        try exec("INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES ('\(esc(uuid))', 'PRPosterRoleLockScreen', \(maxSort + 1))")
        try exec("UPDATE sqlite_sequence SET seq=\(newId) WHERE name='poster'")
        return staged
    }
}
