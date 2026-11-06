//
//  CardSkinEngine.swift
//  OurCard
//
//  Apple Wallet card artwork re-skinning — APPEARANCE ONLY.
//
//  Scope (hard boundary):
//    * Replaces the *background artwork files* inside an existing pass folder:
//      /var/mobile/Library/Passes/Cards/<cardId>.pkpass
//    * Card name, network marks, balances, and transaction ability are
//      rendered/provisioned by the system and Secure Enclave — this engine
//      cannot and does not touch them. There are no PAN, token, or
//      provisioning code paths anywhere in this module.
//    * Adding a card to the Apple Pay *pay sheet* is impossible without bank
//      tokenization; this engine only re-skins cards the user already has.
//
//  Mirrors AirCard (ios-app/Models.swift::prepareAllCardSkins ~308-336 and
//  AppViewModel card flash ~750-870):
//    cardBackgroundCombined@3x.png 1536x969, @2x 1024x646, plus
//    diffuse/background/strip variants and PDF variants for transit passes,
//    then cache invalidation by writing "corrupted" FrontFace/Preview/
//    PlaceHolder leaves into <id>.cache and <id>.pkcache.
//

import Foundation
import UIKit

public enum CardSkinError: Error, LocalizedError {
    case imageLoadFailed
    case skinPrepFailed
    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return "Could not load the source image."
        case .skinPrepFailed: return "Could not prepare card skins."
        }
    }
}

public final class CardSkinEngine {
    private let bridge = AirliftBridge.shared
    public init() {}

    public typealias LogFn = (String) -> Void

    // MARK: - Card ID discovery

    /// Live detection: stream syslog over RSD and match AirCard's card regexes
    /// (AppViewModel.swift::cardRegexes ~360-370). The user brings up Apple Pay
    /// (double-click side button) and we sniff the pass identifiers from
    /// passd/PDPassLibrary log lines. Runs until `stop()` is called.
    public static let syslogPatterns: [String] = [
        "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\\\)|,|$)",
        "/([-A-Za-z0-9_+=]{20,44})\\.(?:pkpass|cache|pkcache)",
        "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])",
        "PDCardFileManager: writing card\\s+([A-Za-z0-9+/_-]+={0,2})(?=\\s|\\)|,|$)",
        "PDPassLibrary: wrote pass\\s+([A-Za-z0-9+/_-]+={0,2})(?=\\s|\\)|,|$)",
        "VerificationCheck\\.([A-Za-z0-9+/_-]+={0,2})(?=\\s|\\)|,|$)",
    ]

    private var regexes: [NSRegularExpression] {
        Self.syslogPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Streams syslog and calls `onCardID` for each newly seen pass identifier.
    /// BLOCKS until stopDiscovery() — call off the main thread.
    public func startDiscovery(onCardID: @escaping (String) -> Void) throws {
        var seen = Set<String>()
        let rx = regexes
        try bridge.startSyslogStream { line in
            for r in rx {
                let ns = line as NSString
                for m in r.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    guard m.numberOfRanges > 1 else { continue }
                    let id = ns.substring(with: m.range(at: 1))
                    if !id.isEmpty, seen.insert(id).inserted {
                        DispatchQueue.main.async { onCardID(id) }
                    }
                }
            }
        }
    }

    public func stopDiscovery() { bridge.stopSyslogStream() }

    /// Sanitizes a card identifier for use in temp paths (mirrors AirCard).
    public static func cleanCardId(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    // MARK: - Skin preparation (mirrors ImageEngine.prepareAllCardSkins)

    public static func prepareAllCardSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalize(image, maxDimension: 2560)
        var skins: [String: Data] = [:]

        if let d3 = png(resize(normalized, to: CGSize(width: 1536, height: 969))) {
            skins["cardBackgroundCombined@3x.png"] = d3
            skins["diffuse@3x.png"] = d3
            skins["background@3x.png"] = d3
            skins["strip@3x.png"] = d3
        }
        if let d2 = png(resize(normalized, to: CGSize(width: 1024, height: 646))) {
            skins["cardBackgroundCombined@2x.png"] = d2
            skins["diffuse@2x.png"] = d2
            skins["background@2x.png"] = d2
            skins["strip@2x.png"] = d2
        }
        // Vector PDF variants for Suica / transit passes.
        let rect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdf = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: rect)
        }
        skins["cardBackgroundCombined.pdf"] = pdf
        skins["background.pdf"] = pdf
        skins["strip.pdf"] = pdf
        return skins
    }

    private static func normalize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let s = max(image.size.width, image.size.height)
        guard s > maxDimension else { return image }
        let scale = maxDimension / s
        return resize(image, to: CGSize(width: image.size.width * scale,
                                       height: image.size.height * scale)) ?? image
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage? {
        UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func png(_ image: UIImage?) -> Data? {
        image?.pngData()
    }

    // MARK: - Flash

    /// Re-skins one existing card. `cardID` may be pasted manually or come
    /// from startDiscovery.
    public func flash(cardID: String, image: UIImage, log: @escaping LogFn) async throws {
        let skins = Self.prepareAllCardSkins(from: image)
        guard !skins.isEmpty else { throw CardSkinError.skinPrepFailed }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ourcard_card_\(Self.cleanCardId(cardID))_\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for (name, data) in skins {
            try? data.write(to: stage.appendingPathComponent(name))
        }

        let target = "/var/mobile/Library/Passes/Cards/\(cardID).pkpass"
        log("Injecting skins into \(cardID.prefix(12))…")
        try await bridge.writeDir(sourceDir: stage.path, targetDir: target, log: log)

        // Invalidate pass render caches so Wallet re-renders the artwork.
        let inv = fm.temporaryDirectory.appendingPathComponent("ourcard_inv_\(UUID().uuidString)")
        try? fm.createDirectory(at: inv, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: inv) }
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: inv.appendingPathComponent(leaf))
        }
        for ext in [".cache", ".pkcache"] {
            try? await bridge.writeDir(sourceDir: inv.path,
                                       targetDir: "/var/mobile/Library/Passes/Cards/\(cardID)\(ext)")
        }
        log("✅ Card re-skinned. Force-close the Wallet app to see it.")
    }
}
