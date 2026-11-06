//
//  OurCardApp.swift
//  OurCard
//
//  Minimal SwiftUI shell wiring the modules together:
//    Pair → (Wallpapers | Card Skins) → Respring
//
//  This is intentionally thin: all privileged work lives in Exploit/,
//  Wallpaper/, Card/, and Respring/. No placeholder bodies anywhere in the
//  critical path.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct OurCardApp: App {
    @StateObject private var pairing = PairingManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pairing)
                .onAppear { _ = pairing.restoreSavedPairing() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        NavigationView {
            List {
                Section("Device") {
                    PairingRow()
                    Text("Requires: iOS 27+, Developer Mode, loopback VPN (10.7.0.1).")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Customize") {
                    NavigationLink("Wallpapers (.tendies)", destination: WallpaperView())
                    NavigationLink("Card skins (appearance only)", destination: CardSkinView())
                    NavigationLink("Custom pass card (Wallet list only)", destination: PassCardView())
                }
                Section("Finish") {
                    Button("Respring to apply") {
                        Task { await NeoSpring.respring() }
                    }
                    Button("Restart device") {
                        Task { await NeoSpring.restartDevice() }
                    }
                    Button("Open Wallpaper settings") {
                        NeoSpring.openWallpaperSettings()
                    }
                }
                Section("Danger zone") {
                    Button("Delete pairing", role: .destructive) {
                        pairing.deletePairing()
                    }
                }
            }
            .navigationTitle("OurCard")
        }
    }
}

struct PairingRow: View {
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        switch pairing.state {
        case .idle:
            Button("Pair with this iPhone") { pairing.startPairing() }
        case .advertising(let pin):
            VStack(alignment: .leading) {
                Text("Open Settings › Privacy & Security › Developer Mode")
                if let pin = pin {
                    Text("Enter PIN: \(pin)").font(.title).monospaced()
                } else {
                    ProgressView()
                }
            }
        case .paired(let name):
            Label("Paired (\(name))", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let msg):
            VStack(alignment: .leading) {
                Text("Pairing failed").foregroundColor(.red)
                Text(msg).font(.caption)
                Button("Try again") { pairing.startPairing() }
            }
        }
    }
}

// MARK: - Wallpapers

struct WallpaperView: View {
    @State private var log: [String] = []
    @State private var busy = false
    @State private var showImporter = false
    @State private var setSelected = false
    @State private var confirmDBOverwrite = false

    var body: some View {
        VStack {
            List(log, id: \.self) { Text($0).font(.caption).monospaced() }
            Toggle("Set as selected wallpaper", isOn: $setSelected)
                .padding(.horizontal)
            Toggle("Allow PosterBoard DB overwrite (advanced)", isOn: $confirmDBOverwrite)
                .padding(.horizontal)
            Text("DB overwrite needs a DB imported from a backup of THIS device (see README). Without it, descriptors are injected + refresh flags written.")
                .font(.caption).foregroundColor(.secondary).padding(.horizontal)
            Button(busy ? "Flashing…" : "Import .tendies and flash") {
                showImporter = true
            }.disabled(busy).padding()
        }
        .navigationTitle("Wallpapers")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "tendies") ?? .zip],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            flash(url: url)
        }
    }

    private func append(_ s: String) {
        // FFI log callbacks fire on Rust threads — always hop to main for @State.
        if Thread.isMainThread { log.append(s) }
        else { DispatchQueue.main.async { self.log.append(s) } }
    }

    private func flash(url: URL) {
        DispatchQueue.main.async { self.busy = true }
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            let injector = DescriptorInjector()
            do {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                let (stageDir, descriptors) = try TendiesImporter.importTendies(at: url)
                defer { try? FileManager.default.removeItem(at: stageDir) }
                append("Found \(descriptors.count) descriptor(s).")
                try await injector.flash(descriptors: descriptors, log: append)
                // SQLite registration: fail-safe seam. Without an imported DB
                // this logs the fallback and returns .descriptorsOnly.
                let db = PosterBoardDB()
                for d in descriptors {
                    let container = try await AirliftBridge.shared.findAppContainer(bundleID: "com.apple.PosterBoard")
                    let targetUUID = UUID().uuidString.uppercased()
                    _ = await db.register(uuid: targetUUID,
                                          providerId: d.ext,
                                          setSelected: setSelected,
                                          container: container,
                                          structVersion: 61, // iOS 27; 59 only for ≤16
                                          reader: OnDeviceDatabaseReader(),
                                          userConfirmedOverwrite: confirmDBOverwrite,
                                          log: append)
                }
                append("Done. Respring to apply.")
            } catch {
                append("❌ \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Card skins

struct CardSkinView: View {
    @State private var log: [String] = []
    @State private var busy = false
    @State private var cardID = ""
    @State private var discovered: [String] = []
    @State private var showImagePicker = false
    @State private var pendingImage: UIImage?
    @State private var scanning = false

    var body: some View {
        VStack {
            List(log, id: \.self) { Text($0).font(.caption).monospaced() }
            TextField("Card ID (paste manually)", text: $cardID)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
                .autocapitalization(.none).disableAutocorrection(true)
            if !discovered.isEmpty {
                Picker("Discovered", selection: $cardID) {
                    ForEach(discovered, id: \.self) { Text($0.prefix(16)) }
                }.pickerStyle(.menu).padding(.horizontal)
            }
            HStack {
                Button(scanning ? "Stop scan" : "Scan for cards") { toggleScan() }
                Button(busy ? "Flashing…" : "Choose art & flash") { showImagePicker = true }
                    .disabled(busy || cardID.isEmpty)
            }.padding()
            Text("Appearance only. Name, network marks, balance and payments are system-controlled and untouched.")
                .font(.caption).foregroundColor(.secondary).padding(.horizontal)
        }
        .navigationTitle("Card skins")
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $pendingImage) { flash(image: $0) }
        }
    }

    private func append(_ s: String) {
        if Thread.isMainThread { log.append(s) }
        else { DispatchQueue.main.async { self.log.append(s) } }
    }

    private func toggleScan() {
        if scanning {
            CardSkinEngine().stopDiscovery()
            DispatchQueue.main.async { self.scanning = false }
            return
        }
        DispatchQueue.main.async { self.scanning = true }
        append("Bring up Apple Pay (double-click side button)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CardSkinEngine().startDiscovery { id in
                    if !discovered.contains(id) {
                        discovered.append(id)
                        if cardID.isEmpty { cardID = id }
                        append("Found card: \(id.prefix(16))…")
                    }
                }
            } catch {
                append("❌ Scan failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self.scanning = false }
        }
    }

    private func flash(image: UIImage) {
        DispatchQueue.main.async { self.busy = true }
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                try await CardSkinEngine().flash(cardID: cardID, image: image, log: append)
            } catch {
                append("❌ \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Image picker

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
                parent.onPick(img)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Custom pass card (visual-only .pkpass)

struct PassCardView: View {
    @State private var log: [String] = []
    @State private var busy = false
    @State private var title = ""
    @State private var name = ""
    @State private var art: UIImage?
    @State private var showImagePicker = false

    var body: some View {
        VStack {
            // Live preview: the art as a card, title + name overlaid.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.03, green: 0.03, blue: 0.04))
                if let art {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                VStack(alignment: .leading) {
                    Text(title.isEmpty ? "Your card" : title)
                        .font(.headline).foregroundColor(.white)
                        .shadow(radius: 4)
                    Spacer()
                    Text(name.isEmpty ? "Your name" : name)
                        .font(.subheadline).foregroundColor(.white)
                        .shadow(radius: 4)
                }
                .padding()
            }
            .frame(height: 190)
            .padding(.horizontal)

            TextField("Card title", text: $title)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
            TextField("Name on card", text: $name)
                .textFieldStyle(.roundedBorder).padding(.horizontal)

            HStack {
                Button("Choose art") { showImagePicker = true }
                Button(busy ? "Installing…" : "Build & install pass") { install() }
                    .disabled(busy || art == nil)
            }.padding()

            List(log, id: \.self) { Text($0).font(.caption).monospaced() }

            Text("Shows in Wallet's pass list only — never in the Apple Pay pay sheet, and it can't pay. Confirmed on-device: Wallet ignores unsigned passes, so a new pass will not appear even after a reboot. Only a pass signed with an Apple Pass Type ID (paid developer account) can register. To change how a card looks, use Card skins on a card you already have.")
                .font(.caption).foregroundColor(.secondary).padding(.horizontal)
        }
        .navigationTitle("Custom pass card")
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $art) { img in art = img }
        }
    }

    private func append(_ s: String) {
        if Thread.isMainThread { log.append(s) }
        else { DispatchQueue.main.async { self.log.append(s) } }
    }

    private func install() {
        guard let art else { return }
        DispatchQueue.main.async { self.busy = true }
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                try await PassBuilder().install(
                    design: PassDesign(title: title, name: name, art: art), log: append)
            } catch {
                append("❌ \(error.localizedDescription)")
            }
        }
    }
}
