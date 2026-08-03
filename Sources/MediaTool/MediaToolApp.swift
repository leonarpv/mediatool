import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var openedURLs: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.openedURLs = urls
        // Salvaguarda: si el sistema llegó a crear más de una ventana para
        // esta apertura de archivo, nos quedamos solo con la primera.
        DispatchQueue.main.async {
            let windows = NSApp.windows.filter { $0.isVisible }
            if windows.count > 1 {
                for window in windows.dropFirst() {
                    window.close()
                }
            }
        }
    }
}

@main
struct MediaToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

enum ProcessMode: String, CaseIterable, Identifiable {
    case compress = "Comprimir"
    case gif = "GIF"
    case both = "Ambos"
    var id: String { rawValue }
}

enum Quality: String, CaseIterable, Identifiable {
    case alta = "Alta"
    case media = "Media"
    case baja = "Baja"
    case personalizada = "Personalizada"
    var id: String { rawValue }

    var preset: (crf: Int, width: Int, fps: Int)? {
        switch self {
        case .alta: return (18, 720, 20)
        case .media: return (23, 480, 15)
        case .baja: return (28, 320, 10)
        case .personalizada: return nil
        }
    }
}

struct ContentView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var inputURLs: [URL] = []
    @State private var process: ProcessMode = .compress
    @State private var quality: Quality = .media
    @State private var customCRF: Double = 23
    @State private var customWidth: Double = 480
    @State private var customFPS: Double = 15
    @State private var prefix: String = ""
    @State private var deleteOriginal: Bool = false
    @State private var log: String = ""
    @State private var isRunning: Bool = false
    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Media Tool").font(.title2).bold()

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                    if inputURLs.isEmpty {
                        Text("Arrastra video(s)/GIF aquí, o haz clic para elegir")
                            .multilineTextAlignment(.center)
                    } else {
                        Text(inputURLs.map { $0.lastPathComponent }.joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { chooseFiles() }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                loadDroppedFiles(providers)
                return true
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Proceso").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $process) {
                    ForEach(ProcessMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Calidad").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if quality == .personalizada {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: $customCRF, in: 0...51) {
                        Text("CRF: \(Int(customCRF))  (menor = mejor calidad)")
                    }
                    Stepper(value: $customWidth, in: 120...1920, step: 20) {
                        Text("Ancho GIF: \(Int(customWidth)) px")
                    }
                    Stepper(value: $customFPS, in: 5...30) {
                        Text("FPS GIF: \(Int(customFPS))")
                    }
                }
                .padding(.leading, 4)
            }

            TextField("Prefijo (opcional)", text: $prefix)
                .textFieldStyle(.roundedBorder)

            Toggle("Eliminar archivo(s) original(es) tras comprimir", isOn: $deleteOriginal)

            HStack {
                Button(isRunning ? "Procesando…" : "Ejecutar") {
                    runPipeline()
                }
                .disabled(inputURLs.isEmpty || isRunning)
                .keyboardShortcut(.defaultAction)

                if isRunning {
                    ProgressView().scaleEffect(0.6)
                }
                Spacer()
                Button("Limpiar") {
                    inputURLs = []
                    log = ""
                }
                .disabled(isRunning)
            }

            ScrollView {
                Text(log.isEmpty ? "El resultado aparecerá aquí…" : log)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: appState.openedURLs) { newURLs in
            if !newURLs.isEmpty {
                inputURLs = newURLs
                log = ""
            }
        }
        .onAppear {
            if !appState.openedURLs.isEmpty {
                inputURLs = appState.openedURLs
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .gif]
        if panel.runModal() == .OK {
            inputURLs = panel.urls
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { inputURLs = urls }
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text + "\n"
        }
    }

    private func humanSize(_ bytes: Int64) -> String {
        var b = Double(bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var u = 0
        while b >= 1024 && u < units.count - 1 { b /= 1024; u += 1 }
        return String(format: "%.2f %@", b, units[u])
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func findFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return nil
    }

    private func outputDirectory() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let dir = desktop.appendingPathComponent("MediaTool Output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func runFFmpeg(_ ffmpegPath: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpegPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    appendLog(text)
                }
            }
            return task.terminationStatus == 0
        } catch {
            appendLog("❌ Error ejecutando ffmpeg: \(error.localizedDescription)")
            return false
        }
    }

    private func runPipeline() {
        guard let ffmpegPath = findFFmpeg() else {
            appendLog("❌ No se encontró ffmpeg. Instálalo con: brew install ffmpeg")
            return
        }

        isRunning = true
        log = ""
        let filesToProcess = inputURLs
        let proc = process
        let pfx = prefix
        let delOriginal = deleteOriginal

        let crf: Int, width: Int, fps: Int
        if let preset = quality.preset {
            (crf, width, fps) = preset
        } else {
            crf = Int(customCRF); width = Int(customWidth); fps = Int(customFPS)
        }

        let dir = outputDirectory()
        appendLog("📁 Carpeta de salida: \(dir.path)\n")

        DispatchQueue.global(qos: .userInitiated).async {
            for input in filesToProcess {
                let name = input.deletingPathExtension().lastPathComponent
                let ext = input.pathExtension
                let outname = pfx.isEmpty ? name : "\(pfx)_\(name)"
                let origBytes = fileSize(input)

                appendLog("📂 Procesando: \(input.lastPathComponent) (\(humanSize(origBytes)))")

                var compressedOutput: URL? = nil

                func report(_ label: String, _ out: URL) {
                    guard FileManager.default.fileExists(atPath: out.path) else {
                        appendLog("❌ Error: no se generó '\(out.lastPathComponent)'")
                        return
                    }
                    let newBytes = fileSize(out)
                    let diff = origBytes - newBytes
                    let pct = origBytes > 0 ? (Double(diff) / Double(origBytes)) * 100 : 0
                    appendLog("✅ \(label): \(out.lastPathComponent)")
                    appendLog("   Tamaño: \(humanSize(newBytes))  (original: \(humanSize(origBytes)), reducción: \(String(format: "%.1f", pct))%)")
                }

                if proc == .gif || proc == .both {
                    let palette = dir.appendingPathComponent("\(outname)_palette.png")
                    let out = dir.appendingPathComponent("\(outname).gif")
                    appendLog("🎬 Generando GIF (ancho=\(width)px, fps=\(fps))…")
                    runFFmpeg(ffmpegPath, ["-loglevel", "warning", "-y", "-i", input.path,
                                           "-vf", "fps=\(fps),scale=\(width):-1:flags=lanczos,palettegen",
                                           palette.path])
                    runFFmpeg(ffmpegPath, ["-loglevel", "warning", "-y", "-i", input.path, "-i", palette.path,
                                           "-filter_complex", "fps=\(fps),scale=\(width):-1:flags=lanczos[x];[x][1:v]paletteuse",
                                           out.path])
                    try? FileManager.default.removeItem(at: palette)
                    report("GIF generado", out)
                }

                if proc == .compress || proc == .both {
                    let out = dir.appendingPathComponent("\(outname)_compressed.\(ext)")
                    appendLog("🎞️ Comprimiendo (crf=\(crf))…")
                    let ok = runFFmpeg(ffmpegPath, ["-loglevel", "warning", "-y", "-i", input.path,
                                                    "-c:v", "libx264", "-c:a", "copy", "-crf", "\(crf)",
                                                    out.path])
                    if ok { compressedOutput = out }
                    report("Video comprimido", out)
                }

                if delOriginal, compressedOutput != nil {
                    try? FileManager.default.removeItem(at: input)
                    appendLog("🗑️ Original eliminado: \(input.lastPathComponent)")
                }

                appendLog("")
            }
            DispatchQueue.main.async {
                isRunning = false
            }
        }
    }
}
