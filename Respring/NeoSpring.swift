//
//  NeoSpring.swift
//  OurCard
//
//  Respring via the NeoSpring WebKit crash (credit: @neonmodder123 & @skadz108).
//  Copied from AirCard's RespringHelper.swift, which credits the same authors.
//  A respring (SpringBoard restart) is how injected wallpapers/card art get
//  picked up without a full reboot.
//

import Foundation
import SwiftUI
import WebKit

public enum NeoSpring {
    /// The crash page, verbatim from AirCard's RespringHelper (credit preserved).
    public static let html = """
<!DOCTYPE html>
<html>
    <body>
        <!-- big credit to @neonmodder123 & @skadz108 (neospring) -->
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
            const frame = document.getElementById('frame');
            const funfun = `
                <html>
                <body>
                    <script>
                        const container = document.createElement('div');
                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                        document.body.appendChild(container);

                        for (let i = 0; i < 500; i++) {
                            let d = document.createElement('div');
                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                            container.appendChild(d);
                        }

                        setInterval(() => {
                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                            let x = new Uint8Array(1024 * 1024 * 10);
                            crypto.getRandomValues(x);
                        }, 0);
                    <\\/script>
                </body>
                </html>
            `;

            frame.srcdoc = funfun;
        </script>
    </body>
</html>
"""

    /// True respring: the NeoSpring WebKit crash restarts SpringBoard
    /// without rebooting the phone. (The old tunnel path sent Diagnostics
    /// Relay "Restart", which is a FULL device reboot, not a respring —
    /// it now lives in restartDevice() below, honestly labelled.)
    public static func respring() async -> Bool {
        triggerWebKitRespring()
        return true // the crash either resprings or it doesn't; no callback exists
    }

    /// Full device reboot via Diagnostics Relay "Restart".
    /// Useful after file injects: passd rescans passes at boot.
    public static func restartDevice() async -> Bool {
        await AirliftBridge.shared.respring()
    }

    /// Attaches a full-screen WKWebView running the crash page to the key window.
    public static func triggerWebKitRespring() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
            else { return }
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let webView = WKWebView(frame: window.bounds, configuration: config)
            webView.isOpaque = true
            webView.backgroundColor = .black
            window.addSubview(webView)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Opens Settings › Wallpaper so the user can pick newly injected posters.
    public static func openWallpaperSettings() {
        for s in ["prefs:root=WALLPAPER", "App-prefs:root=WALLPAPER",
                  "prefs:root=Wallpaper", UIApplication.openSettingsURLString] {
            if let url = URL(string: s) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
    }
}

/// SwiftUI wrapper (mirrors AirCard's NeoSpringView).
public struct NeoSpringView: UIViewRepresentable {
    public init() {}
    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: config)
    }
    public func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(NeoSpring.html, baseURL: nil)
    }
}
