//
//  TendiesImporter.swift
//  OurCard
//
//  Imports a .tendies archive (a zip) from the Files app / share sheet,
//  extracts it with the Rust core, and locates wallpaper descriptor folders.
//
//  A descriptor folder is a directory that is not a container bookkeeping
//  name and contains either Wallpaper.plist or the posterkit descriptor
//  identifier file. Mirrors AirCard's findDescriptorsWithExtensions /
//  isDescriptorFolder (ios-app/TendiesEngine.swift).
//

import Foundation
import UniformTypeIdentifiers

public struct TendiesDescriptor {
    /// Local staging URL of the descriptor folder (already extracted).
    public let url: URL
    /// Poster extension bundle id, e.g. "com.apple.WallpaperKit.CollectionsPoster".
    public let ext: String
}

public enum TendiesImporterError: Error, LocalizedError {
    case notAZip
    case extractionFailed
    case noDescriptorsFound

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "Selected file is not a .tendies archive."
        case .extractionFailed: return "Failed to extract the .tendies archive."
        case .noDescriptorsFound: return "No wallpaper descriptors found in the archive."
        }
    }
}

public final class TendiesImporter {
    private static let ignoredNames: Set<String> = [
        "container", "library", "application support", "prbposterextensiondatastore",
        "extensions", "descriptors", "ordered-descriptors",
        "mercury-descriptors", "mercurydescriptors",
        "video-descriptors", "videodescriptors", "__macosx"
    ]

    /// Maps a descriptor folder to its poster extension by inspecting the
    /// folder's provenance files. Falls back to CollectionsPoster.
    public static func extensionForDescriptor(at url: URL) -> String {
        let fm = FileManager.default
        // Heuristic 1: explicit extension marker some packers include.
        if let marker = try? String(contentsOf: url.appendingPathComponent("posterExtension.txt"),
                                    encoding: .utf8) {
            let t = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // Heuristic 2: Mercury-style dynamic descriptors.
        if fm.fileExists(atPath: url.appendingPathComponent("com.apple.MercuryPoster.descriptor").path) {
            return "com.apple.MercuryPoster"
        }
        // Default: the classic collections/photo provider.
        return "com.apple.WallpaperKit.CollectionsPoster"
    }

    public static func isDescriptorFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let name = url.lastPathComponent.lowercased()
        guard !name.hasPrefix("."), !ignoredNames.contains(name) else { return false }
        let hasPlist = fm.fileExists(atPath: url.appendingPathComponent("Wallpaper.plist").path)
        let hasIdent = fm.fileExists(atPath: url.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier").path)
        return hasPlist || hasIdent
    }

    /// Extracts `archiveURL` (a .tendies zip) and returns found descriptors.
    /// The caller owns the returned staging directory and must delete it.
    public static func importTendies(at archiveURL: URL) throws -> (stageDir: URL, descriptors: [TendiesDescriptor]) {
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory.appendingPathComponent("ourcard_tendies_\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        do {
            try AirliftBridge.shared.unzip(archivePath: archiveURL.path, destDir: stageDir.path)
        } catch {
            try? fm.removeItem(at: stageDir)
            throw TendiesImporterError.extractionFailed
        }

        var found: [TendiesDescriptor] = []
        if let enumerator = fm.enumerator(at: stageDir,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) {
            for case let itemURL as URL in enumerator {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, isDescriptorFolder(itemURL) {
                    found.append(TendiesDescriptor(url: itemURL,
                                                   ext: extensionForDescriptor(at: itemURL)))
                    enumerator.skipDescendants()
                }
            }
        }
        // Also accept a descriptor at the archive root itself.
        if found.isEmpty, isDescriptorFolder(stageDir) {
            found.append(TendiesDescriptor(url: stageDir, ext: extensionForDescriptor(at: stageDir)))
            return (stageDir, found) // caller deletes stageDir after flashing
        }
        guard !found.isEmpty else {
            try? fm.removeItem(at: stageDir)
            throw TendiesImporterError.noDescriptorsFound
        }
        return (stageDir, found)
    }
}
