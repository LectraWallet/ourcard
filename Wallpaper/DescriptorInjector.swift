//
//  DescriptorInjector.swift
//  OurCard
//
//  Injects wallpaper descriptor folders into the PosterBoard container.
//
//  Identifier hygiene (hard rule — learned the painful way):
//    * Every descriptor folder is renamed to a FRESH UPPERCASE UUID.
//    * Wallpaper.plist "identifier" and the numeric descriptor identifier are
//      randomized per flash (Int 10000...99999).
//    * NEVER reuse template IDs or IDs from a prior build — reusing an ID
//      that PosterBoard already tracks can orphan/delete the user's existing
//      wallpapers.
//  Mirrors AirCard's TendiesEngine (ios-app/TendiesEngine.swift ~lines 260-340,
//  updatePlistIdentifiers, injectDescriptorFolder).
//

import Foundation

public enum DescriptorInjectorError: Error, LocalizedError {
    case containerLookupFailed(String)
    public var errorDescription: String? {
        switch self {
        case .containerLookupFailed(let m): return "PosterBoard container lookup failed: \(m)"
        }
    }
}

public final class DescriptorInjector {
    private let bridge = AirliftBridge.shared

    public init() {}

    public typealias LogFn = (String) -> Void

    /// iOS major version of the connected device (parsed from the pairing-time
    /// device info is ideal; falls back to 18 for struct-version purposes).
    /// Kept injectable so the caller can supply the real value.
    public var deviceMajorVersion: Int = 18

    private var structVersion: Int { deviceMajorVersion <= 16 ? 59 : 61 }

    /// Flashes already-extracted descriptors into PosterBoard.
    public func flash(descriptors: [TendiesDescriptor], log: @escaping LogFn) async throws {
        let container: String
        do {
            container = try await bridge.findAppContainer(bundleID: "com.apple.PosterBoard")
        } catch {
            throw DescriptorInjectorError.containerLookupFailed(error.localizedDescription)
        }
        // al_find_app_container may return a file:// URL or trailing slash — normalize.
        let normalized = container
            .replacingOccurrences(of: "file://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for (i, desc) in descriptors.enumerated() {
            let targetUUID = UUID().uuidString.uppercased()   // FRESH per descriptor, per flash
            let randomizedID = Int.random(in: 10000...99999)
            log("[\(i + 1)/\(descriptors.count)] Descriptor \(targetUUID) (\(desc.ext))")

            randomizePlistIdentifiers(in: desc.url, randomizedID: randomizedID)

            let primaryParent =
                "\(normalized)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(desc.ext)/descriptors"
            try await bridge.injectFolder(folderPath: desc.url.path,
                                          targetParentDir: primaryParent,
                                          destName: targetUUID,
                                          log: log)

            // iOS 18+: dual-inject into the modern .Posters.<Name>App containers.
            if deviceMajorVersion >= 18 {
                let modernExt: String?
                switch desc.ext {
                case "com.apple.WallpaperKit.CollectionsPoster":
                    modernExt = "com.apple.Posters.CollectionsPosterApp"
                case "com.apple.MercuryPoster":
                    modernExt = "com.apple.Posters.MercuryPosterApp"
                default:
                    modernExt = nil
                }
                if let modernExt = modernExt {
                    let modernParent =
                        "\(normalized)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(modernExt)/descriptors"
                    try? await bridge.injectFolder(folderPath: desc.url.path,
                                                   targetParentDir: modernParent,
                                                   destName: targetUUID,
                                                   log: log)
                }
            }
        }

        try await writeRefreshFlags(container: normalized, log: log)
    }

    // MARK: - Plist identifier randomization

    /// Mirrors AirCard's updatePlistIdentifiers exactly, including its guards:
    /// skip entirely when suggestionMetadata exists (desync breaks PosterKit
    /// suggestion lookup); only overwrite descriptor.identifier when the
    /// content is a pure integer (Mercury/Unity/Kaleidoscope use string symbols
    /// like "v6x.colorA" that must NOT be touched).
    func randomizePlistIdentifiers(in folderURL: URL, randomizedID: Int) {
        let fm = FileManager.default
        let suggestionURL = folderURL.appendingPathComponent(
            "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if fm.fileExists(atPath: suggestionURL.path) { return }

        guard let enumerator = fm.enumerator(at: folderURL,
                                            includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name == "com.apple.posterkit.provider.descriptor.identifier" {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    try? "\(randomizedID)".data(using: .utf8)?.write(to: fileURL)
                }
            } else if name == "com.apple.posterkit.provider.contents.userInfo" {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any],
                   plist["wallpaperRepresentingIdentifier"] != nil {
                    plist["wallpaperRepresentingIdentifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            } else if name.hasSuffix("Wallpaper.plist") {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["identifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            }
        }
    }

    // MARK: - PosterBoard cache refresh flags

    /// Writes com.apple.PosterBoard.unprotectedUserDefaults.plist with the
    /// reset flags AirCard uses (TendiesEngine.swift ~347-370): forces
    /// PosterBoard to reset file protections, treat the locale as changed,
    /// and re-persist the known poster container bundle identifiers.
    func writeRefreshFlags(container: String, log: @escaping LogFn) async throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ourcard_pref_\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let dict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider",
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: stage.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist"))

        log("Forcing PosterBoard cache refresh…")
        try await bridge.writeDir(sourceDir: stage.path,
                                  targetDir: "\(container)/Library/Preferences",
                                  log: log)
        // Also visible to system daemons via the mobile global preferences dir.
        try? await bridge.writeDir(sourceDir: stage.path,
                                   targetDir: "/var/mobile/Library/Preferences",
                                   log: log)
    }
}
