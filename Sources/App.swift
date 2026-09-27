import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct Vid2TuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vid2Tune", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
                .frame(minWidth: 580, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 540)
        .commands {
            CommandGroup(replacing: .help) {
                if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
                    Button("Third-Party Licenses") { NSWorkspace.shared.open(notices) }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not by the SwiftUI scene) so files dropped on the Dock icon can reach it.
    let store = JobStore()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        store.addFiles(urls, options: .fromDefaults())
    }
}

extension ConvertOptions {
    static let defaultOutputPath = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vid2Tune").path

    /// The options currently chosen in the window (the same UserDefaults keys its @AppStorage uses).
    static func fromDefaults() -> ConvertOptions {
        let d = UserDefaults.standard
        return ConvertOptions(
            outputDir: URL(fileURLWithPath: d.string(forKey: "outputPath") ?? defaultOutputPath),
            format: AudioFormat(rawValue: d.string(forKey: "format") ?? "") ?? .mp3,
            quality: (Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .k320).rawValue,
            embedArtwork: d.object(forKey: "embedArtwork") as? Bool ?? true)
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case best = "0", k320 = "320K", k256 = "256K", k192 = "192K", k128 = "128K"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "Best (VBR)"
        case .k320: return "320 kbps"
        case .k256: return "256 kbps"
        case .k192: return "192 kbps"
        case .k128: return "128 kbps"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @AppStorage("outputPath") private var outputPath = ConvertOptions.defaultOutputPath
    @AppStorage("quality") private var quality = Quality.k320
    @AppStorage("embedArtwork") private var embedArtwork = true
    @AppStorage("format") private var format = AudioFormat.mp3

    @StateObject private var ui = UIState()
    @FocusState private var inputFocused: Bool

    private var options: ConvertOptions {
        ConvertOptions(outputDir: URL(fileURLWithPath: outputPath),
                       format: format,
                       quality: quality.rawValue,
                       embedArtwork: embedArtwork)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.toolsMissing.isEmpty { missingToolsBanner }
            else if store.ytdlpIsStale || store.updateState != .idle { staleBanner }
            controls
            Divider()
            jobList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if ui.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("Drop links or files to convert", systemImage: "arrow.down.circle")
                        .font(.title2.weight(.semibold)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $ui.isDropTargeted, perform: handleDrop)
        .onAppear { inputFocused = true }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vid2Tune").font(.title2.bold())
                Text("Convert video to audio").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 12)
    }

    private var missingToolsBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Missing \(store.toolsMissing.joined(separator: " and "))").bold()
                Text("Vid2Tune needs these installed. In Terminal, run:")
                    .foregroundStyle(.secondary)
                Text("brew install \(store.toolsMissing.joined(separator: " "))")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Check Again") { store.recheckTools() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                switch store.updateState {
                case .updating:
                    Text("Updating yt-dlp…").bold()
                    Text("This can take a minute.").font(.callout).foregroundStyle(.secondary)
                case .failed(let message):
                    Text("Update failed").bold()
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                case .idle:
                    Text("yt-dlp \(store.ytdlpVersion ?? "") is out of date").bold()
                    Text("Sites like YouTube change often; old versions fail with “403 Forbidden”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.updateState == .updating {
                ProgressView().controlSize(.small)
            } else {
                Button("Update yt-dlp") { store.updateYtdlp() }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Paste a video link — YouTube, Vimeo, SoundCloud, TikTok…", text: $ui.input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($inputFocused)
                    .onSubmit(convert)
                Button(action: pasteAndConvert) {
                    Image(systemName: "doc.on.clipboard")
                }
                .controlSize(.large)
                .help("Paste from clipboard and convert")
                Button("Convert", action: convert)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.input.trimmingCharacters(in: .whitespaces).isEmpty || store.ytdlp == nil)
            }
            if let inputError = ui.inputError {
                Text(inputError).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                Picker("Format", selection: $format) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if format == .mp3 {
                    Picker("Quality", selection: $quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                Toggle("Album art", isOn: format.supportsArtwork ? $embedArtwork : .constant(false))
                    .disabled(!format.supportsArtwork)
                    .help(format.supportsArtwork ? "Embed the video thumbnail as cover art" : "WAV files can't hold album art")
                Spacer()
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Text("Save to:").foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: outputPath))
                } label: {
                    Label(abbreviated(outputPath), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Open in Finder")
                Button("Change…", action: chooseFolder).controlSize(.small)
                Spacer()
            }
            .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var jobList: some View {
        if store.jobs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No conversions yet").font(.headline).foregroundStyle(.secondary)
                Text("Paste a link above, or drag a link or video file onto this window.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.jobs) { job in
                    JobRow(job: job,
                           onRetry: { store.run(job, options: options) },
                           onRemove: { store.remove(job) })
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            let active = store.jobs.filter { $0.status.isActive }.count
            Text(active > 0 ? "\(active) converting…" : "\(store.jobs.count) item\(store.jobs.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear Finished") { store.clearFinished() }
                .disabled(!store.jobs.contains { !$0.status.isActive })
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func convert() {
        let text = ui.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if store.add(text, options: options) == 0 {
            ui.inputError = "That doesn't look like a link. Try something like https://youtu.be/…"
        } else {
            ui.inputError = nil
            ui.input = ""
        }
    }

    private func pasteAndConvert() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            ui.inputError = "The clipboard doesn't contain a link."
            return
        }
        ui.input = text
        convert()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: outputPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if url.isFileURL {
                            store.addFiles([url], options: options)
                        } else {
                            store.add(url.absoluteString, options: options)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async { store.add(text, options: options) }
                }
            }
        }
        return handled
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Transient view state. Kept in an ObservableObject rather than @State so the app
/// builds with the Command Line Tools alone (the @State macro plugin ships only with Xcode).
final class UIState: ObservableObject {
    @Published var input = ""
    @Published var inputError: String?
    @Published var isDropTargeted = false
}

struct JobRow: View {
    @ObservedObject var job: Job
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title ?? job.displaySource)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.tail)
                if job.title != nil {
                    Text(job.displaySource).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                statusDetail
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 6)
        .contextMenu {
            if let source = job.sourceFile {
                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
            } else {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.url, forType: .string)
                }
            }
            if !existingFiles.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(existingFiles) }
            }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    /// Saved files that are still where Vid2Tune put them (history can outlive the files).
    private var existingFiles: [URL] {
        job.files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .queued, .downloading, .converting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusDetail: some View {
        switch job.status {
        case .queued:
            Text("Starting…").font(.caption).foregroundStyle(.secondary)
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        case .converting:
            Text("Converting to \(job.format?.label ?? "audio")…").font(.caption).foregroundStyle(.secondary)
        case .done where !job.files.isEmpty && existingFiles.isEmpty:
            Text("File moved or deleted").font(.caption).foregroundStyle(.secondary)
        case .done:
            Text(job.files.count > 1 ? "\(job.files.count) files saved" : "Saved \(job.files.first?.lastPathComponent ?? "file")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch job.status {
            case .queued, .downloading, .converting:
                iconButton("xmark.circle", help: "Cancel") { job.cancel() }
            case .done:
                let files = existingFiles
                if !files.isEmpty {
                    iconButton("play.circle", help: "Play") {
                        NSWorkspace.shared.open(files[0])
                    }
                    iconButton("magnifyingglass.circle", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(files)
                    }
                } else if !job.files.isEmpty {
                    iconButton("arrow.clockwise.circle", help: "Download again", action: onRetry)
                }
                iconButton("trash.circle", help: "Remove from list", action: onRemove)
            case .failed, .cancelled:
                iconButton("arrow.clockwise.circle", help: "Retry", action: onRetry)
                iconButton("trash.circle", help: "Remove from list", action: onRemove)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
