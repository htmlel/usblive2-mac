// CaptureModel.swift - app state, settings and actions; talks to the C engine.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Combine
import Foundation

enum Connection: Int32 {
    case stopped = 0, starting = 1, running = 2, notFound = 3, failed = 4, disconnected = 5
}

enum Deinterlace: Int, CaseIterable {
    case off = 0, blend = 1, smooth = 2

    var title: String {
        switch self {
        case .off: return "Off"
        case .blend: return "Blend"
        case .smooth: return "Smooth"
        }
    }
}

struct Toast: Equatable {
    let id = UUID()
    let symbol: String
    let message: String
    let fileURL: URL?
}

final class CaptureModel: ObservableObject {
    static let shared = CaptureModel()

    // live status (from the engine)
    @Published private(set) var connection: Connection = .stopped
    @Published private(set) var hasSignal = false
    @Published private(set) var signalFormat = ""
    @Published private(set) var fps: Double = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: Double = 0
    @Published private(set) var isFinishingRecording = false

    // UI state
    @Published var controlsVisible = true
    @Published var settingsOpen = false { didSet { pokeControls() } }
    @Published var pointerOverControls = false
    @Published var toast: Toast?

    // settings (persisted)
    @Published var input: Int { didSet { save("input", input); eng_set_input(Int32(input)) } }
    @Published var deinterlace: Int { didSet { save("deinterlace", deinterlace); eng_set_deinterlace(Int32(deinterlace)) } }
    @Published var crop: Bool { didSet { save("crop", crop); eng_set_crop(crop ? 1 : 0) } }
    @Published var pal: Bool { didSet { if pal != oldValue { save("pal", pal); restart() } } }
    @Published var brightness: Double { didSet { save("brightness", brightness); applyPicture() } }
    @Published var contrast: Double { didSet { save("contrast", contrast); applyPicture() } }
    @Published var saturation: Double { didSet { save("saturation", saturation); applyPicture() } }
    @Published var hue: Double { didSet { save("hue", hue); applyPicture() } }
    @Published var volume: Double { didSet { save("volume", volume); applyVolume() } }
    @Published var muted: Bool { didSet { applyVolume() } }

    static let defaultBrightness = 128.0
    static let defaultContrast = 64.0
    static let defaultSaturation = 64.0
    static let defaultHue = 0.0

    private let audio = AudioOutput()
    private var timer: Timer?
    private var lastPoke = Date()
    private var nextRetry = Date.distantPast
    private var toastWork: DispatchWorkItem?
    private var started = false
    private var liveActivity: NSObjectProtocol?      // keeps capture at full speed (no App Nap)
    private var recordingActivity: NSObjectProtocol? // also keeps the Mac awake while recording

    private init() {
        let d = UserDefaults.standard
        input = d.object(forKey: "input") as? Int ?? 0
        deinterlace = d.object(forKey: "deinterlace") as? Int ?? Deinterlace.blend.rawValue
        crop = d.object(forKey: "crop") as? Bool ?? false
        pal = d.object(forKey: "pal") as? Bool ?? false
        brightness = d.object(forKey: "brightness") as? Double ?? Self.defaultBrightness
        contrast = d.object(forKey: "contrast") as? Double ?? Self.defaultContrast
        saturation = d.object(forKey: "saturation") as? Double ?? Self.defaultSaturation
        hue = d.object(forKey: "hue") as? Double ?? Self.defaultHue
        volume = d.object(forKey: "volume") as? Double ?? 0.8
        muted = true    // always start muted: a camera mic + speakers can feed back
    }

    // MARK: lifecycle

    func startIfNeeded() {
        guard !started else { return }
        started = true
        // capture must keep running at full speed even when the window is hidden
        liveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Capturing live video from the USB-Live2")
        audio.start()
        applyVolume()
        restart()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func shutdown() {
        _ = eng_record_stop()
        eng_stop()
        audio.stop()
    }

    private func restart() {
        guard started else { return }
        eng_set_deinterlace(Int32(deinterlace))
        eng_set_crop(crop ? 1 : 0)
        eng_set_picture(Int32(brightness), Int32(contrast), Int32(saturation), Int32(hue))
        _ = eng_start(Int32(input), pal ? 1 : 0, engineVideoCallback, nil)
        nextRetry = Date().addingTimeInterval(2)
    }

    private func poll() {
        var st = eng_status()
        eng_get_status(&st)

        let newConnection = Connection(rawValue: st.state) ?? .stopped
        if newConnection != connection { connection = newConnection }
        let signal = st.state == Connection.running.rawValue && st.signal != 0
        if signal != hasSignal { hasSignal = signal }
        let formatName = Self.formatName(Int(st.format), pal: st.pal != 0)
        if formatName != signalFormat { signalFormat = formatName }
        if abs(st.fps - fps) > 0.05 { fps = st.fps }
        audioLevel = st.audio_level   // shown even when muted, so you can see sound is arriving
        if (st.recording != 0) != isRecording { isRecording = st.recording != 0 }
        recordingTime = st.rec_seconds

        // keep looking for the device while it is unplugged
        switch newConnection {
        case .notFound, .disconnected, .failed, .stopped:
            if Date() >= nextRetry {
                nextRetry = Date().addingTimeInterval(2)
                _ = eng_start(Int32(input), pal ? 1 : 0, engineVideoCallback, nil)
            }
        default:
            break
        }

        // fade the controls out when the pointer is idle
        let pinned = settingsOpen || pointerOverControls || connection != .running || !hasSignal
        if controlsVisible && !pinned && Date().timeIntervalSince(lastPoke) > 3 {
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private static func formatName(_ code: Int, pal: Bool) -> String {
        switch code {
        case 1: return "NTSC"
        case 2: return "NTSC-J"
        case 3: return "NTSC 4.43"
        case 4: return "PAL"
        case 5: return "PAL-M"
        case 6: return "PAL-N"
        case 7: return "PAL-Nc"
        case 8: return "PAL-60"
        case 12: return "SECAM"
        default: return pal ? "PAL" : "NTSC"
        }
    }

    func pokeControls() {
        lastPoke = Date()
        if !controlsVisible { controlsVisible = true }
    }

    // MARK: actions

    func retryNow() {
        nextRetry = .distantPast
    }

    func toggleInput() {
        input = input == 0 ? 1 : 0
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard connection == .running else { return }
        guard eng_ffmpeg_available() != 0 else {
            show(Toast(symbol: "exclamationmark.triangle.fill",
                       message: "Recording needs ffmpeg. In Terminal: brew install ffmpeg", fileURL: nil))
            return
        }
        let url = Self.folder(.moviesDirectory).appendingPathComponent("USB-Live2 \(Self.stamp()).mp4")
        if eng_record_start(url.path) == 0 {
            isRecording = true
            recordingURL = url
            // don't let the Mac sleep in the middle of a tape
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording video from the USB-Live2")
        } else {
            show(Toast(symbol: "exclamationmark.triangle.fill", message: "Couldn't start recording", fileURL: nil))
        }
    }

    private var recordingURL: URL?

    private func stopRecording() {
        let url = recordingURL
        isFinishingRecording = true
        // ffmpeg needs a moment to finish the file; don't block the UI
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = eng_record_stop() == 0
            DispatchQueue.main.async {
                if let activity = self.recordingActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self.recordingActivity = nil
                }
                self.isFinishingRecording = false
                self.isRecording = false
                if ok {
                    self.show(Toast(symbol: "checkmark.circle.fill", message: "Recording saved to Movies", fileURL: url))
                } else {
                    self.show(Toast(symbol: "exclamationmark.triangle.fill",
                                    message: "Recording may be incomplete (see the .log file in Movies)", fileURL: url))
                }
            }
        }
    }

    func takeSnapshot() {
        let url = Self.folder(.picturesDirectory).appendingPathComponent("USB-Live2 \(Self.stamp()).png")
        if FrameSink.shared.savePNG(to: url) {
            show(Toast(symbol: "camera.fill", message: "Snapshot saved to Pictures", fileURL: url))
        }
    }

    func resetPicture() {
        brightness = Self.defaultBrightness
        contrast = Self.defaultContrast
        saturation = Self.defaultSaturation
        hue = Self.defaultHue
    }

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: helpers

    private func show(_ newToast: Toast) {
        toast = newToast
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func applyPicture() {
        eng_set_picture(Int32(brightness.rounded()), Int32(contrast.rounded()),
                        Int32(saturation.rounded()), Int32(hue.rounded()))
    }

    private func applyVolume() {
        audio.volume = muted ? 0 : Float(volume)
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func folder(_ dir: FileManager.SearchPathDirectory) -> URL {
        let url = FileManager.default.urls(for: dir, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
