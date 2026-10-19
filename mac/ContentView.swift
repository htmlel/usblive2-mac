// ContentView.swift - the main window.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model = CaptureModel.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface()
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .ignoresSafeArea()
                .opacity(model.connection == .running ? 1 : 0)

            StateOverlay(model: model)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    if model.isRecording {
                        RecordingPill(seconds: model.recordingTime)
                    }
                    if model.connection == .running {
                        StatusPill(model: model)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .opacity(model.controlsVisible || model.isRecording ? 1 : 0)

                Spacer()

                if let toast = model.toast {
                    ToastView(toast: toast, model: model)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ControlBar(model: model)
                    .padding(.bottom, 22)
                    .opacity(model.controlsVisible ? 1 : 0)
                    .offset(y: model.controlsVisible ? 0 : 16)
                    .allowsHitTesting(model.controlsVisible)
            }
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        }
        .frame(minWidth: 640, minHeight: 480)
        .ignoresSafeArea()
        .background(WindowShape())
        .onContinuousHover { phase in
            if case .active = phase { model.pokeControls() }
        }
        .onTapGesture(count: 2) { model.toggleFullScreen() }
        .preferredColorScheme(.dark)
        .onAppear { model.startIfNeeded() }
    }
}

// MARK: - floating control bar

struct ControlBar: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            Picker("Input", selection: $model.input) {
                Text("Composite").tag(0)
                Text("S-Video").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Video input (⌘1 / ⌘2)")

            BarDivider()

            RecordButton(model: model)

            IconButton(symbol: "camera", help: "Take snapshot (⇧⌘S)") {
                model.takeSnapshot()
            }
            .disabled(model.connection != .running)

            BarDivider()

            HStack(spacing: 8) {
                IconButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           help: model.muted ? "Unmute (⌥⌘M)" : "Mute (⌥⌘M)") {
                    model.muted.toggle()
                }
                .frame(width: 22)
                Slider(value: $model.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 84)
                LevelMeter(level: model.audioLevel)
            }

            BarDivider()

            IconButton(symbol: "scissors", help: "Edit a recording (⇧⌘E)") {
                openWindow(id: "editor")
            }

            IconButton(symbol: "slider.horizontal.3", help: "Picture & display settings") {
                model.settingsOpen.toggle()
            }
            .popover(isPresented: $model.settingsOpen, arrowEdge: .top) {
                SettingsPanel(model: model)
            }

            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen (⌃⌘F)") {
                model.toggleFullScreen()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onHover { inside in model.pointerOverControls = inside }
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 20)
    }
}

/// Hover flag kept in a reference type (assignable from view closures).
final class HoverState: ObservableObject {
    @Published var on = false
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hover.on ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

struct RecordButton: View {
    @ObservedObject var model: CaptureModel
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    RoundedRectangle(cornerRadius: model.isRecording ? 3 : 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: model.isRecording ? 10 : 16, height: model.isRecording ? 10 : 16)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isRecording)
                if model.isRecording {
                    Text(timeString(model.recordingTime))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
            .opacity(hover.on ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .disabled(model.connection != .running || model.isFinishingRecording)
        .onHover { hover.on = $0 }
        .help(model.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(level > 0.9 ? Color.red : (level > 0.6 ? Color.yellow : Color.green))
                    .frame(width: max(0, min(1, CGFloat(level))) * geo.size.width)
            }
        }
        .frame(width: 34, height: 4)
        .animation(.linear(duration: 0.1), value: level)
        .help("Audio level")
    }
}

// MARK: - pills, overlays, toasts

struct StatusPill: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.hasSignal ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.input == 0 ? "Composite" : "S-Video")
            if model.hasSignal {
                Text("·").foregroundStyle(.secondary)
                Text(model.signalFormat)
                Text("·").foregroundStyle(.secondary)
                Text(String(format: "%.2f fps", model.fps)).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct RecordingPill: View {
    let seconds: Double

    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.4), value: Int(context.date.timeIntervalSinceReferenceDate * 2))
            }
            Text("REC")
                .fontWeight(.bold)
            Text(timeString(seconds)).monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct StateOverlay: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        switch model.connection {
        case .starting, .stopped:
            MessageCard(symbol: nil, title: "Connecting…",
                        detail: "Starting the USB-Live2")
        case .notFound:
            MessageCard(symbol: "cable.connector",
                        title: "Connect your USB-Live2",
                        detail: "Plug it in and it will be found automatically.")
        case .disconnected:
            MessageCard(symbol: "cable.connector.slash",
                        title: "USB-Live2 disconnected",
                        detail: "Reconnect it to continue.")
        case .failed:
            MessageCard(symbol: "exclamationmark.triangle",
                        title: "Couldn't start the USB-Live2",
                        detail: "Try unplugging it and plugging it back in.",
                        buttonTitle: "Try Again") { model.retryNow() }
        case .running:
            if !model.hasSignal {
                MessageCard(symbol: "tv.slash",
                            title: "No Signal",
                            detail: "Check that your source is on and connected to the \(model.input == 0 ? "yellow composite" : "S-Video") input.",
                            buttonTitle: model.input == 0 ? "Switch to S-Video" : "Switch to Composite") {
                    model.toggleInput()
                }
            }
        }
    }
}

struct MessageCard: View {
    let symbol: String?
    let title: String
    let detail: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title)
                .font(.system(size: 19, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct ToastView: View {
    let toast: Toast
    @ObservedObject var model: CaptureModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.symbol.hasPrefix("exclamation") ? Color.yellow : Color.green)
            Text(toast.message)
            if let url = toast.fileURL {
                if url.pathExtension.lowercased() == "mp4" {
                    Button("Edit") {
                        EditorModel.shared.load(url)
                        openWindow(id: "editor")
                    }
                    .buttonStyle(.link)
                }
                Button("Show in Finder") { model.revealInFinder(url) }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

// MARK: - settings popover

struct SettingsPanel: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Picture")
            AdjustRow(title: "Brightness", symbol: "sun.max", value: $model.brightness, range: 0...255)
            AdjustRow(title: "Contrast", symbol: "circle.lefthalf.filled", value: $model.contrast, range: 0...127)
            AdjustRow(title: "Saturation", symbol: "drop", value: $model.saturation, range: 0...127)
            AdjustRow(title: "Hue", symbol: "paintpalette", value: $model.hue, range: -128...127)
            HStack {
                Spacer()
                Button("Reset Picture") { model.resetPicture() }
                    .controlSize(.small)
            }

            Divider()

            SectionHeader(title: "Display")
            VStack(alignment: .leading, spacing: 6) {
                Text("Deinterlace")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Picker("Deinterlace", selection: $model.deinterlace) {
                    ForEach(Deinterlace.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(deinterlaceHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Crop edges", isOn: $model.crop)
                .disabled(model.isRecording)
                .help("Trims the dark borders at the edges of the picture")

            Divider()

            SectionHeader(title: "Video Standard")
            Picker("Standard", selection: $model.pal) {
                Text("NTSC").tag(false)
                Text("PAL").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRecording)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var deinterlaceHint: String {
        switch Deinterlace(rawValue: model.deinterlace) ?? .blend {
        case .off: return "Shows the raw interlaced picture."
        case .blend: return "Removes combing on motion. 30 fps."
        case .smooth: return "Full 60 fps motion. Best for games."
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }
}

struct AdjustRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

func timeString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - window shape

/// Keeps the window's content at exactly 4:3 so the picture fills it with no
/// black bars (the video also runs up under the hidden title bar).
struct WindowShape: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AspectLockView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AspectLockView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 4, height: 3)
        let width = window.contentView?.frame.width ?? 960
        window.setContentSize(NSSize(width: width, height: (width * 3 / 4).rounded()))
    }
}
