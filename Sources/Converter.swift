import Foundation
import AppKit
import Combine

/// Locates the command-line tools Vid2Tune drives. Release builds carry their own copies
/// (installed into `managedDir`); otherwise Homebrew locations are checked explicitly,
/// since GUI apps get a minimal PATH.
enum Tools {
    static let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// ~/Library/Application Support/Vid2Tune/bin — where bundled tools are run from.
    static let managedDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vid2Tune/bin", isDirectory: true)

    static func find(_ name: String) -> String? {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in [managedDir.path] + extraPaths + envPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func isManaged(_ path: String) -> Bool { path.hasPrefix(managedDir.path + "/") }

    /// Copies the tools bundled in Contents/Resources/bin into `managedDir`.
    ///
    /// They can't run from inside the app: when the app is downloaded, macOS quarantines
    /// every file in it, and quarantined unsigned tools are blocked outright. Copies we own
    /// can have the quarantine flag removed, and yt-dlp's self-updater can replace its copy.
    static func installBundled() {
        let fm = FileManager.default
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin"),
              let names = try? fm.contentsOfDirectory(atPath: bundled.path) else { return }
        try? fm.createDirectory(at: managedDir, withIntermediateDirectories: true)

        let stamp = managedDir.appendingPathComponent(".installed-from")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let sameApp = (try? String(contentsOf: stamp, encoding: .utf8)) == appVersion

        for name in names where !name.hasSuffix(".version") {
            let src = bundled.appendingPathComponent(name)
            let dst = managedDir.appendingPathComponent(name)
            let exists = fm.fileExists(atPath: dst.path)
            if name == "yt-dlp", exists {
                // Keep a copy the user has updated since; only replace it with a newer bundled one.
                let bundledVersion = try? String(contentsOf: bundled.appendingPathComponent("yt-dlp.version"), encoding: .utf8)
                let installedVersion = try? String(contentsOf: managedDir.appendingPathComponent("yt-dlp.version"), encoding: .utf8)
                if let b = bundledVersion, let i = installedVersion, b.trimmed <= i.trimmed { continue }
            } else if exists && sameApp {
                continue
            }
            try? fm.removeItem(at: dst)
            guard (try? fm.copyItem(at: src, to: dst)) != nil else { continue }
            removexattr(dst.path, "com.apple.quarantine", 0)
            if name == "yt-dlp",
               let v = try? String(contentsOf: bundled.appendingPathComponent("yt-dlp.version"), encoding: .utf8) {
                recordYtdlpVersion(v)
            }
        }
        try? appVersion.write(to: stamp, atomically: true, encoding: .utf8)
    }

    /// Remembers which yt-dlp version is in `managedDir` (it changes when the user updates it).
    static func recordYtdlpVersion(_ version: String) {
        try? version.trimmed.write(to: managedDir.appendingPathComponent("yt-dlp.version"),
                                   atomically: true, encoding: .utf8)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, wav, aiff
    var id: String { rawValue }
    var label: String { self == .aiff ? "AIFF" : rawValue.uppercased() }
    /// yt-dlp can't write AIFF, so AIFF is extracted as FLAC (which keeps tags and art)
    /// and then converted with ffmpeg.
    var ytdlpFormat: String { self == .aiff ? "flac" : rawValue }
    /// WAV has no standard place for cover art; yt-dlp refuses to embed it.
    var supportsArtwork: Bool { self != .wav }
    var fileExtension: String { self == .aiff ? "aif" : rawValue }
}

struct ConvertOptions {
    var outputDir: URL
    var format: AudioFormat
    var quality: String      // yt-dlp --audio-quality value for MP3, e.g. "0" or "320K"
    var embedArtwork: Bool
}

final class Job: ObservableObject, Identifiable {
    enum Status: Equatable {
        case queued
        case downloading(Double)
        case converting
        case done
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .downloading, .converting: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let url: String
    @Published var title: String?
    @Published var status: Status = .queued
    @Published var files: [URL] = []

    private var process: Process?
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var lastError: String?
    private var wasCancelled = false
    private(set) var format: AudioFormat?
    private var ffmpegPath: String?

    // Local-file conversions run ffmpeg directly instead of yt-dlp.
    private var fileOutput: URL?
    private var fileDuration: Double?
    private var ffmpegLog: [String] = []

    /// Dropped/opened files are stored as file:// URLs.
    var isFile: Bool { url.hasPrefix("file://") }
    var sourceFile: URL? { isFile ? URL(string: url) : nil }
    /// What to show under the title: the link, or the file's path.
    var displaySource: String {
        guard let sourceFile else { return url }
        return (sourceFile.path as NSString).abbreviatingWithTildeInPath
    }

    /// Called on the main thread whenever a run ends (done, failed or cancelled).
    var onFinish: (() -> Void)?

    init(url: String) { self.url = url }

    init(record: HistoryRecord) {
        url = record.url
        title = record.title
        files = record.files.map { URL(fileURLWithPath: $0) }
        switch record.state {
        case .done: status = .done
        case .failed: status = .failed(Self.friendlyError(record.message, code: 1))
        case .cancelled: status = .cancelled
        }
    }

    var record: HistoryRecord {
        let state: HistoryRecord.State
        var message: String?
        switch status {
        case .done: state = .done
        case .failed(let m): state = .failed; message = m
        default: state = .cancelled
        }
        return HistoryRecord(url: url, title: title, files: files.map(\.path), state: state, message: message)
    }

    func start(ytdlp: String?, ffmpeg: String?, options: ConvertOptions) {
        try? FileManager.default.createDirectory(at: options.outputDir, withIntermediateDirectories: true)

        status = .downloading(0)
        files = []
        lastError = nil
        wasCancelled = false
        outBuffer = Data()
        errBuffer = Data()
        format = options.format
        ffmpegPath = ffmpeg
        fileOutput = nil
        fileDuration = nil
        ffmpegLog = []

        if isFile {
            startFile(options: options)
            return
        }
        guard let ytdlp else { end(.failed("yt-dlp isn't installed")); return }

        var args = [
            "--no-update", "--newline", "--no-colors", "--no-simulate", "--progress",
            "-x", "--audio-format", options.format.ytdlpFormat,
            "--embed-metadata",
            "--progress-template", "download:[VT]%(progress._percent_str)s",
            "--print", "before_dl:[VTTITLE]%(title)s",
            "--print", "after_move:[VTFILE]%(filepath)s",
            "-P", options.outputDir.path,
            "-o", "%(title)s.%(ext)s",
            "--no-playlist",
        ]
        if options.format == .mp3 { args += ["--audio-quality", options.quality] }
        if options.embedArtwork && options.format.supportsArtwork { args += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg] }
        // YouTube needs a JavaScript runtime. Deno is used if installed; the bundled QuickJS covers everyone else.
        if let qjs = Tools.find("qjs") { args += ["--js-runtimes", "quickjs:\(qjs)"] }
        args += ["--", Self.downloadURL(for: url)]
        launch(ytdlp, args)
    }

    /// Converts a local audio/video file with ffmpeg, keeping its tags.
    private func startFile(options: ConvertOptions) {
        guard let ffmpegPath else { end(.failed("ffmpeg isn't installed")); return }
        guard let src = sourceFile, FileManager.default.fileExists(atPath: src.path) else {
            end(.failed("The original file was moved or deleted."))
            return
        }
        let name = src.deletingPathExtension().lastPathComponent
        title = name
        let dst = Self.uniqueURL(in: options.outputDir, name: name, ext: options.format.fileExtension)
        fileOutput = dst

        var args = ["-hide_banner", "-nostdin", "-nostats", "-progress", "pipe:1",
                    "-i", src.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"]
        switch options.format {
        case .mp3:
            args += ["-c:a", "libmp3lame"]
            args += options.quality == "0" ? ["-q:a", "0"] : ["-b:a", options.quality.lowercased()]
            args += ["-id3v2_version", "3"]
        case .wav:
            args += ["-c:a", "pcm_s16le"]
        case .aiff:
            args += ["-c:a", "pcm_s16be", "-write_id3v2", "1", "-id3v2_version", "3"]
        }
        args.append(dst.path)
        launch(ffmpegPath, args)
    }

    /// "Name.mp3", or "Name 2.mp3" etc. so a conversion never overwrites an existing file
    /// (including the source, when converting into the folder it came from).
    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private func launch(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Tools.extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d, stderr: false) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d, stderr: true) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = out.fileHandleForReading.readDataToEndOfFile()
            let restErr = err.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.consume(restOut + Data([0x0A]), stderr: false)
                self.consume(restErr + Data([0x0A]), stderr: true)
                self.finish(code: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            end(.failed("Couldn't launch \(URL(fileURLWithPath: exe).lastPathComponent): \(error.localizedDescription)"))
        }
    }

    /// vimeo.com pages now require a login, but the embed player serves public (and
    /// unlisted, via their hash) videos anonymously, so route Vimeo links through it.
    static func downloadURL(for link: String) -> String {
        guard let comps = URLComponents(string: link),
              let host = comps.host?.lowercased(),
              host == "vimeo.com" || host == "www.vimeo.com" else { return link }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard let idIndex = parts.lastIndex(where: { $0.allSatisfy(\.isNumber) }) else { return link }
        var embed = "https://player.vimeo.com/video/\(parts[idIndex])"
        if idIndex + 1 < parts.count, parts[idIndex + 1].allSatisfy(\.isHexDigit) {
            embed += "?h=\(parts[idIndex + 1])"
        } else if let h = comps.queryItems?.first(where: { $0.name == "h" })?.value {
            embed += "?h=\(h)"
        }
        return embed
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        wasCancelled = true
        process.terminate()
    }

    // MARK: - Output parsing

    private func consume(_ data: Data, stderr: Bool) {
        if stderr { errBuffer.append(data) } else { outBuffer.append(data) }
        while true {
            let buf = stderr ? errBuffer : outBuffer
            guard let nl = buf.firstIndex(of: 0x0A) else { break }
            let lineData = buf[buf.startIndex..<nl]
            let rest = Data(buf[buf.index(after: nl)...])
            if stderr { errBuffer = rest } else { outBuffer = rest }
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { handle(line, stderr: stderr) }
        }
    }

    private func handle(_ line: String, stderr: Bool) {
        if isFile { handleFFmpeg(line, stderr: stderr); return }
        if stderr {
            if line.hasPrefix("ERROR:") {
                lastError = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            }
            return
        }
        if line.hasPrefix("[VTTITLE]") {
            title = String(line.dropFirst("[VTTITLE]".count))
        } else if line.hasPrefix("[VTFILE]") {
            files.append(URL(fileURLWithPath: String(line.dropFirst("[VTFILE]".count))))
        } else if line.hasPrefix("[VT]") {
            let pct = line.dropFirst("[VT]".count)
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let value = Double(pct) {
                status = value >= 100 ? .converting : .downloading(value / 100)
            }
        }
    }

    private func handleFFmpeg(_ line: String, stderr: Bool) {
        if stderr {
            ffmpegLog = Array((ffmpegLog + [line]).suffix(30))
            // "  Duration: 00:02:28.44, start: ..." gives the length for the progress bar.
            if fileDuration == nil, line.hasPrefix("Duration:"),
               let stamp = line.dropFirst("Duration:".count).split(separator: ",").first {
                let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 { fileDuration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
            }
        } else if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)),
                  let total = fileDuration, total > 0 {
            status = .downloading(min(max(us / 1_000_000 / total, 0), 1))
        }
    }

    private func finishFile(code: Int32) {
        if wasCancelled || code != 0, let out = fileOutput {
            try? FileManager.default.removeItem(at: out)
        }
        if wasCancelled {
            end(.cancelled)
        } else if code == 0, let out = fileOutput {
            files = [out]
            end(.done)
        } else {
            let log = ffmpegLog.joined(separator: "\n")
            if log.contains("matches no streams") || log.contains("does not contain any stream") {
                end(.failed("This file doesn't contain any audio."))
            } else if log.contains("Invalid data found") {
                end(.failed("This file isn't a format Vid2Tune can read."))
            } else {
                end(.failed(ffmpegLog.last ?? "ffmpeg exited with code \(code)"))
            }
        }
    }

    private func finish(code: Int32) {
        process = nil
        if isFile { finishFile(code: code); return }
        if wasCancelled {
            end(.cancelled)
        } else if code != 0 {
            end(.failed(Self.friendlyError(lastError, code: code)))
        } else if format == .aiff {
            status = .converting
            convertToAIFF(remaining: files, converted: [])
        } else {
            end(.done)
        }
    }

    private func end(_ final: Status) {
        status = final
        onFinish?()
    }

    /// Turns yt-dlp's error text into something a person can act on.
    static func friendlyError(_ raw: String?, code: Int32) -> String {
        guard let raw else { return "Conversion failed (yt-dlp exit code \(code))." }
        let lower = raw.lowercased()
        if lower.contains("drm") || lower.contains("unsupported url") {
            return "This source isn't supported."
        }
        if raw.contains("403") && !raw.contains("Update yt-dlp") { return raw + " — yt-dlp is probably out of date; use Update yt-dlp." }
        return raw
    }

    /// Converts the FLAC files yt-dlp produced into 16-bit AIFF one at a time, keeping
    /// tags and cover art (as ID3), then deletes the FLACs.
    private func convertToAIFF(remaining: [URL], converted: [URL]) {
        guard let src = remaining.first else {
            files = converted
            end(.done)
            return
        }
        guard let ffmpegPath else { end(.failed("ffmpeg isn't installed")); return }
        let dst = src.deletingPathExtension().appendingPathExtension("aif")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-v", "error", "-y", "-i", src.path, "-map", "0",
                       "-c:a", "pcm_s16be", "-c:v", "copy",
                       "-write_id3v2", "1", "-id3v2_version", "3", dst.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if self.wasCancelled {
                    try? FileManager.default.removeItem(at: dst)
                    self.end(.cancelled)
                } else if proc.terminationStatus != 0 {
                    let last = message.split(separator: "\n").last.map(String.init) ?? "ffmpeg error"
                    self.end(.failed("Couldn't convert to AIFF: \(last)"))
                } else {
                    try? FileManager.default.removeItem(at: src)
                    self.convertToAIFF(remaining: Array(remaining.dropFirst()), converted: converted + [dst])
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            end(.failed("Couldn't launch ffmpeg: \(error.localizedDescription)"))
        }
    }
}

/// What's saved to disk for each item in the list.
struct HistoryRecord: Codable {
    enum State: String, Codable { case done, failed, cancelled }
    var url: String
    var title: String?
    var files: [String]
    var state: State
    var message: String?
}

final class JobStore: ObservableObject {
    @Published var jobs: [Job] = []
    @Published private(set) var ytdlp = Tools.find("yt-dlp")
    @Published private(set) var ffmpeg = Tools.find("ffmpeg")
    private var subscriptions: [UUID: AnyCancellable] = [:]

    enum UpdateState: Equatable { case idle, updating, failed(String) }
    @Published private(set) var ytdlpVersion: String?
    @Published private(set) var updateState: UpdateState = .idle

    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vid2Tune", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        Tools.installBundled()   // quick file copies; must happen before the tools are located
        recheckTools()
        loadHistory()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.jobs.forEach { $0.cancel() }
            self.saveHistory()
        }
    }

    // MARK: History

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let records = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        jobs = records.map(Job.init(record:))
        jobs.forEach(track)
    }

    /// Saves the list, newest first. In-progress items are saved as cancelled so they can be retried.
    func saveHistory() {
        guard let data = try? JSONEncoder().encode(jobs.map(\.record)) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func track(_ job: Job) {
        subscriptions[job.id] = job.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        job.onFinish = { [weak self] in self?.saveHistory() }
    }

    /// yt-dlp versions are dates (YYYY.MM.DD). Sites like YouTube change often enough
    /// that anything older than ~60 days frequently fails with HTTP 403.
    var ytdlpIsStale: Bool {
        guard let v = ytdlpVersion else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: String(v.prefix(10))) else { return false }
        return Date().timeIntervalSince(date) > 60 * 86400
    }

    func refreshVersion() {
        guard let ytdlp else { ytdlpVersion = nil; return }
        Self.run(ytdlp, ["--version"]) { [weak self] code, output in
            let version = code == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            self?.ytdlpVersion = version
            if let version, Tools.isManaged(ytdlp) { Tools.recordYtdlpVersion(version) }
        }
    }

    /// Updates yt-dlp with Homebrew when that's how it was installed, otherwise with its self-updater.
    func updateYtdlp() {
        guard let ytdlp, updateState != .updating else { return }
        updateState = .updating
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: ytdlp)) ?? ytdlp
        let viaBrew = resolved.contains("Cellar") || ytdlp.hasPrefix("/opt/homebrew/")
        let (exe, args): (String?, [String]) = viaBrew
            ? (Tools.find("brew"), ["upgrade", "yt-dlp"])
            : (ytdlp, ["-U"])
        guard let exe else { updateState = .failed("Homebrew not found"); return }
        Self.run(exe, args) { [weak self] code, output in
            guard let self else { return }
            if code == 0 {
                self.updateState = .idle
                self.refreshVersion()
            } else {
                let last = output.split(separator: "\n").last.map(String.init) ?? "exit code \(code)"
                self.updateState = .failed(last)
            }
        }
    }

    /// Runs a tool off the main thread and reports its exit code and combined output on the main thread.
    private static func run(_ exe: String, _ args: [String], completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (Tools.extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var code: Int32 = -1
            var data = Data()
            do {
                try p.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                code = p.terminationStatus
            } catch {
                data = Data(error.localizedDescription.utf8)
            }
            let output = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { completion(code, output) }
        }
    }

    var toolsMissing: [String] {
        var missing: [String] = []
        if ytdlp == nil { missing.append("yt-dlp") }
        if ffmpeg == nil { missing.append("ffmpeg") }
        return missing
    }

    func recheckTools() {
        ytdlp = Tools.find("yt-dlp")
        ffmpeg = Tools.find("ffmpeg")
        refreshVersion()
    }

    /// Adds every link found in `text` (space- or newline-separated). Returns how many were queued.
    @discardableResult
    func add(_ text: String, options: ConvertOptions) -> Int {
        let links = text
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap(Self.normalize)
        for link in links {
            let job = Job(url: link)
            track(job)
            jobs.insert(job, at: 0)
            run(job, options: options)
        }
        return links.count
    }

    func run(_ job: Job, options: ConvertOptions) {
        job.start(ytdlp: ytdlp, ffmpeg: ffmpeg, options: options)
    }

    /// Queues local audio/video files (dropped on the window or opened via the Dock icon).
    func addFiles(_ urls: [URL], options: ConvertOptions) {
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let job = Job(url: url.absoluteString)
            track(job)
            jobs.insert(job, at: 0)
            run(job, options: options)
        }
    }

    func remove(_ job: Job) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        subscriptions[job.id] = nil
        saveHistory()
    }

    func clearFinished() {
        jobs.removeAll { !$0.status.isActive }
        subscriptions = subscriptions.filter { id, _ in jobs.contains { $0.id == id } }
        saveHistory()
    }

    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let candidate = s.contains("://") ? s : "https://" + s
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") else { return nil }
        return candidate
    }
}
