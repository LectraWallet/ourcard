//
//  PassBuilder.swift
//  OurCard
//
//  Custom Wallet pass (.pkpass) styled like a card — VISUAL ONLY.
//
//  What this is:
//    * Builds a generic storeCard .pkpass bundle from the user's own art + text.
//    * Injects the bundle into /var/mobile/Library/Passes/ via the AirTraffic
//      write primitive (same bridge as card skins).
//
//  Hard limits (do not "fix" these in this module):
//    * The pass shows in the Wallet app's pass list at best. It NEVER appears
//      in the Apple Pay pay sheet — that lists only Secure-Enclave-provisioned
//      payment cards, which need bank/network tokenization.
//    * It cannot pay for anything. It has no PAN, no token, no barcode.
//    * The bundle is UNSIGNED (no Pass Type ID certificate, no signature).
//      Normal installs (Mail/Safari/AirDrop) will reject it. The injection
//      route skips the install flow, but passd may still refuse to load an
//      unsigned pass — pass registration is UNVERIFIED on-device. The user's
//      test iPhone decides.
//    * No balance field. A pass must never display a fake money balance.
//

import CryptoKit
import Foundation
import UIKit

public struct PassDesign {
    public var title: String      // e.g. "Midnight Card"
    public var name: String       // e.g. the user's name / handle
    public var art: UIImage       // card artwork
    public init(title: String, name: String, art: UIImage) {
        self.title = title
        self.name = name
        self.art = art
    }
}

public enum PassBuilderError: Error, LocalizedError {
    case bundleFailed
    public var errorDescription: String? {
        switch self {
        case .bundleFailed: return "Could not build the pass bundle."
        }
    }
}

public final class PassBuilder {
    public static let passTypeIdentifier = "pass.com.ourcard.custom"

    private let bridge = AirliftBridge.shared
    public init() {}

    public typealias LogFn = (String) -> Void

    // MARK: - Bundle build

    /// Builds the .pkpass bundle in a temp dir and returns its URL.
    /// Caller owns cleanup of the returned directory.
    public static func buildBundle(design: PassDesign) throws -> URL {
        let serial = UUID().uuidString.uppercased()
        let dirName = "\(passTypeIdentifier).\(serial).pkpass"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // pass.json — generic storeCard. No barcode, no balance, no payment data.
        let pass: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": passTypeIdentifier,
            "serialNumber": serial,
            "teamIdentifier": "OURCARD00", // placeholder; a real signed pass needs Apple's Pass Type ID
            "organizationName": "OurCard",
            "description": design.title.isEmpty ? "OurCard custom pass" : design.title,
            "backgroundColor": "rgb(8,8,10)",
            "foregroundColor": "rgb(255,255,255)",
            "labelColor": "rgb(170,170,180)",
            "storeCard": [
                "primaryFields": [
                    ["key": "name", "label": "NAME", "value": design.name.isEmpty ? "OurCard" : design.name],
                ],
                "secondaryFields": [
                    ["key": "title", "label": "", "value": design.title.isEmpty ? "Custom pass" : design.title],
                ],
                "backFields": [
                    ["key": "note", "label": "About",
                     "value": "Custom pass made with OurCard. Visual only — not a payment card and can't pay for anything."],
                ],
            ] as [String: Any],
        ]
        let passData = try JSONSerialization.data(withJSONObject: pass, options: [.prettyPrinted, .sortedKeys])
        try passData.write(to: dir.appendingPathComponent("pass.json"))

        // Images. Strip is the big card visual; logo/icon are small marks.
        var files: [String: Data] = [:]
        func add(_ name: String, _ image: UIImage?) {
            if let d = image?.pngData() { files[name] = d }
        }
        add("strip.png", aspectFill(design.art, to: CGSize(width: 375, height: 144)))
        add("strip@2x.png", aspectFill(design.art, to: CGSize(width: 750, height: 288)))
        add("strip@3x.png", aspectFill(design.art, to: CGSize(width: 1125, height: 432)))
        add("logo.png", aspectFill(design.art, to: CGSize(width: 160, height: 50)))
        add("logo@2x.png", aspectFill(design.art, to: CGSize(width: 320, height: 100)))
        add("logo@3x.png", aspectFill(design.art, to: CGSize(width: 480, height: 150)))
        add("icon.png", centerSquare(design.art, side: 29))
        add("icon@2x.png", centerSquare(design.art, side: 58))
        add("icon@3x.png", centerSquare(design.art, side: 87))
        add("background.png", solid(CGSize(width: 180, height: 180), color: UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)))
        add("background@2x.png", solid(CGSize(width: 360, height: 360), color: UIColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)))
        guard !files.isEmpty else { throw PassBuilderError.bundleFailed }
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent(name))
        }

        // manifest.json — SHA1 of every file except itself and the signature.
        var manifest: [String: String] = ["pass.json": sha1Hex(passData)]
        for (name, data) in files { manifest[name] = sha1Hex(data) }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))

        return dir
    }

    // MARK: - Install (experimental)

    /// Injects the built bundle into /var/mobile/Library/Passes/ on device.
    /// Pass registration with passd is UNVERIFIED — the pass may not appear in
    /// Wallet even if the files land. Reboot after installing and check Wallet.
    public func install(design: PassDesign, log: @escaping LogFn) async throws {
        let bundle = try Self.buildBundle(design: design)
        defer { try? FileManager.default.removeItem(at: bundle) }
        log("Built pass \(bundle.lastPathComponent.prefix(40))…")
        try await bridge.injectFolder(folderPath: bundle.path,
                                      targetParentDir: "/var/mobile/Library/Passes",
                                      destName: bundle.lastPathComponent,
                                      log: log)
        log("✅ Files injected. Reboot and check Wallet — if it doesn't appear, pass registration is the blocker (unverified).")
        log("It will only ever show in the Wallet pass list, never in the Apple Pay pay sheet, and it can't pay.")
    }

    // MARK: - Helpers

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func aspectFill(_ image: UIImage, to size: CGSize) -> UIImage? {
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
    }

    private static func centerSquare(_ image: UIImage, side: CGFloat) -> UIImage? {
        let s = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - s) / 2, y: (image.size.height - s) / 2)
        guard let cg = image.cgImage?.cropping(to: CGRect(origin: origin, size: CGSize(width: s, height: s))) else { return nil }
        let square = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            square.draw(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        }
    }

    private static func solid(_ size: CGSize, color: UIColor) -> UIImage? {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
