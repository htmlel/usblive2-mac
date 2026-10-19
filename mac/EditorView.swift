// EditorView.swift - the Edit Recording window: preview, timeline, trim, crop,
// audio fix and export.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AVFoundation
import SwiftUI

struct EditorView: View {
    @ObservedObject var model = EditorModel.shared

    var body: some View {
        Group {
            if model.url == nil {
                EditorWelcome(model: model)
            } else {
                EditorMain(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .navigationTitle(model.url?.lastPathComponent ?? "Edit Recording")
        .onDisappear {
            // start fresh next time: back to the "choose a recording" screen
            model.unload()
            model.resetEdits()
        }
    }
}

// MARK: - welcome / file picker

struct EditorWelcome: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let recent = model.recentRecordings()
        VStack(spacing: 18) {
            Image(systemName: "scissors")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Edit a Recording")
                .font(.system(size: 22, weight: .semibold))
            Text("Trim the start and end, crop the picture, and fix one-sided audio.\nYour original file is never changed.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Recording…") { model.openPanel() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recent recordings")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearRecent() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            .help("Hide these from the list (files are not deleted)")
                    }
                    .padding(.horizontal, 4)
                    VStack(spacing: 2) {
                        ForEach(recent, id: \.self) { url in
                            RecentRow(url: url) { model.load(url) }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
                }
                .frame(width: 420)
                .padding(.top, 10)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hover.on ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// MARK: - main editor

struct EditorMain: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 14) {
                    ZStack {
                        Color.black
                        PlayerSurface(player: model.player)
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                            .overlay(CropOverlay(model: model))
                        if let error = model.loadError {
                            MessageCard(symbol: "exclamationmark.triangle", title: error,
                                        detail: "If it's still recording, stop the recording first.",
                                        buttonTitle: "Open Another…") { model.openPanel() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    TransportBar(model: model)
                }
                .padding(20)

                Divider()

                Inspector(model: model)
                    .frame(width: 280)
            }

            Divider()

            EditorTimeline(model: model)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }
}

/// AVPlayerLayer in a view, stretched to the 4:3 frame SwiftUI gives it.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func makeBackingLayer() -> CALayer {
        playerLayer
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

/// Darkens the parts of the picture that the crop will remove.
struct CropOverlay: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let vw = max(1, model.videoSize.width), vh = max(1, model.videoSize.height)
            let inner = CGRect(x: model.cropLeft / vw * w,
                               y: model.cropTop / vh * h,
                               width: max(0, (vw - model.cropLeft - model.cropRight) / vw * w),
                               height: max(0, (vh - model.cropTop - model.cropBottom) / vh * h))
            if model.hasCrop {
                ZStack {
                    Path { p in
                        p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                        p.addRect(inner)
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    Path { p in p.addRect(inner) }
                        .stroke(Color.yellow, lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.setMarkIn()
            } label: {
                Label("Mark In", systemImage: "arrow.right.to.line")
            }
            .keyboardShortcut("i", modifiers: [])
            .help("Start the yellow selection at the playhead (I)")

            Button {
                model.splitAtPlayhead()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .keyboardShortcut("s", modifiers: [])
            .help("Split the video at the playhead (S)")

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(preciseTime(model.displayTime))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text("frame \(model.frameNumber(model.displayTime))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .trailing)

            TransportButton(symbol: "backward.end.fill", help: "Go to clip start") {
                model.goToTrimStart()
            }
            TransportButton(symbol: "backward.frame.fill", help: "Back one frame (←)   ⇧← back one second") {
                model.step(frames: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 32)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            TransportButton(symbol: "forward.frame.fill", help: "Forward one frame (→)   ⇧→ forward one second") {
                model.step(frames: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            TransportButton(symbol: "forward.end.fill", help: "Go to clip end") {
                model.goToTrimEnd()
            }

            Text(preciseTime(model.displayDuration))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Spacer()

            Button {
                model.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!model.canDelete)
            .help("Cut out the yellow selection; the parts on either side join up (Delete)")

            Button {
                model.setMarkOut()
            } label: {
                Label("Mark Out", systemImage: "arrow.left.to.line")
            }
            .keyboardShortcut("o", modifiers: [])
            .help("End the yellow selection at the playhead (O)")
        }
        .font(.system(size: 13))
        // one-second jumps (⇧← / ⇧→), no visible buttons needed
        .background(
            HStack {
                Button("") { model.jump(seconds: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { model.jump(seconds: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { model.clearRange() }
                    .keyboardShortcut("x", modifiers: [])
                Button("") { model.clearRange() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}

struct TransportButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
        }
        .help(help)
    }
}

// MARK: - inspector

struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection(title: "Selection", symbol: "timeline.selection") {
                    if let range = model.markedRange {
                        TrimRow(label: "Start", time: range.lowerBound, frame: model.frameNumber(range.lowerBound),
                                minus: { n in model.nudgeSelectionStart(frames: -n) },
                                plus: { n in model.nudgeSelectionStart(frames: n) },
                                toPlayhead: { model.setMarkIn() })
                        TrimRow(label: "End", time: range.upperBound, frame: model.frameNumber(range.upperBound),
                                minus: { n in model.nudgeSelectionEnd(frames: -n) },
                                plus: { n in model.nudgeSelectionEnd(frames: n) },
                                toPlayhead: { model.setMarkOut() })
                        HStack {
                            Text("Length")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(preciseTime(range.upperBound - range.lowerBound))
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                        }
                        HStack {
                            Button(role: .destructive) {
                                model.removeMarkedRange()
                            } label: {
                                Label("Delete Selection", systemImage: "trash")
                            }
                            Spacer()
                            Button("Clear") { model.clearRange() }
                        }
                        .controlSize(.small)
                    } else {
                        Text("Drag across the pictures on the timeline to select a section, or press I at the start and O at the end. It turns yellow. Press Delete to cut it out; the parts on either side join with a hard cut.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                InspectorSection(title: "Cut & Join", symbol: "scissors") {
                    CutJoinPanel(model: model)
                }

                InspectorSection(title: "Crop Picture", symbol: "crop") {
                    CropSlider(title: "Top", value: $model.cropTop, maximum: model.videoSize.height / 3)
                    CropSlider(title: "Bottom", value: $model.cropBottom, maximum: model.videoSize.height / 3)
                    CropSlider(title: "Left", value: $model.cropLeft, maximum: model.videoSize.width / 3)
                    CropSlider(title: "Right", value: $model.cropRight, maximum: model.videoSize.width / 3)
                    if model.hasCrop {
                        Button("Reset Crop") {
                            model.cropTop = 0; model.cropBottom = 0; model.cropLeft = 0; model.cropRight = 0
                        }
                        .controlSize(.small)
                    }
                }

                InspectorSection(title: "Audio", symbol: "speaker.wave.2") {
                    Picker("Audio", selection: $model.audioFix) {
                        ForEach(AudioFix.allCases, id: \.rawValue) { fix in
                            Text(fix.title).tag(fix.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text((AudioFix(rawValue: model.audioFix) ?? .original).detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let hint = model.audioHint {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                            Text(hint).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.yellow.opacity(0.12)))
                    }
                }

                ExportBox(model: model)

                HStack {
                    Button("Open Another…") { model.openPanel() }
                    Spacer()
                    Button("Reset All") { model.resetEdits() }
                }
                .controlSize(.small)
            }
            .padding(18)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
            content
        }
    }
}

struct TrimRow: View {
    let label: String
    let time: Double
    let frame: Int
    let minus: (Int) -> Void        // called with how many frames to move
    let plus: (Int) -> Void
    let toPlayhead: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(preciseTime(time))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text("frame \(frame)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RepeatButton(symbol: "minus",
                         help: "\(label) one frame earlier. Hold to keep moving.",
                         action: minus)
            RepeatButton(symbol: "plus",
                         help: "\(label) one frame later. Hold to keep moving.",
                         action: plus)
            Button(action: toPlayhead) { Image(systemName: "scope").frame(width: 14) }
                .controlSize(.small)
                .help("Set \(label.lowercased()) to the playhead")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}

/// Drives press-and-hold repeating: one step on press, then after a short
/// pause keeps stepping, faster the longer it is held.
final class RepeatDriver: ObservableObject {
    @Published var pressed = false
    private var timer: Timer?
    private var ticks = 0

    func start(_ action: @escaping (Int) -> Void) {
        stop()
        pressed = true
        ticks = 0
        action(1)                                   // a click moves exactly one frame
        let delay = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.beginRepeating(action)
        }
        RunLoop.main.add(delay, forMode: .common)   // .common: keeps firing while the mouse is held
        timer = delay
    }

    private func beginRepeating(_ action: @escaping (Int) -> Void) {
        let repeating = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            // speed up: 1 frame per step for ~1 s, then 3, then 10 after ~3 s
            let step = self.ticks < 30 ? 1 : (self.ticks < 90 ? 3 : 10)
            action(step)
        }
        RunLoop.main.add(repeating, forMode: .common)
        timer = repeating
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressed = false
    }
}

struct RepeatButton: View {
    let symbol: String
    let help: String
    let action: (Int) -> Void
    @StateObject private var driver = RepeatDriver()

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14, height: 14)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(driver.pressed ? 0.30 : 0.14)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !driver.pressed { driver.start(action) }
                    }
                    .onEnded { _ in driver.stop() }
            )
            .onDisappear { driver.stop() }
            .help(help)
    }
}

struct TimeBadge: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(preciseTime(value))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CropSlider: View {
    let title: String
    @Binding var value: Double
    let maximum: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 48, alignment: .leading)
            Slider(value: $value, in: 0...max(1, maximum), step: 2)
                .controlSize(.small)
            Text("\(Int(value)) px")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct ExportBox: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isExporting {
                ProgressView(value: model.exportProgress) {
                    Text("Exporting… \(Int(model.exportProgress * 100))%")
                        .font(.system(size: 12))
                }
                Button("Cancel") { model.cancelExport() }
                    .controlSize(.small)
            } else {
                Button {
                    model.export()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                Text("Choose where to save the new file. The original isn't changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let result = model.exportResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
            }
            if let error = model.exportError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}

// MARK: - timeline

struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    @StateObject private var drag = ClipDrag()

    private let rulerHeight: CGFloat = 18
    private let laneHeight: CGFloat = 24
    private let thumbHeight: CGFloat = 56
    private let waveHeight: CGFloat = 34
    private let gap: CGFloat = 6
    private var totalHeight: CGFloat { rulerHeight + laneHeight + thumbHeight + 2 * waveHeight + 4 * gap }
    /// where the pictures and sound start (below the ruler and the parts bar)
    private var mediaTop: CGFloat { rulerHeight + laneHeight + 2 * gap }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Drag across the pictures to select a section (yellow). Delete cuts it out and the rest joins up. Your original file is never changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $model.zoom, in: 1...16)
                    .controlSize(.small)
                    .frame(width: 160)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f×", model.zoom))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }

            GeometryReader { outer in
                let width = max(1, outer.size.width * CGFloat(model.zoom))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: model.zoom > 1.01) {
                        editedTracks(width: width)
                        .frame(width: width, height: totalHeight)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.scrollTick) { _, _ in
                        proxy.scrollTo("playhead", anchor: .center)
                    }
                }
            }
            .frame(height: totalHeight + 16)
        }
    }

    // MARK: shared pieces

    /// time ruler: click or drag on it to move the playhead
    private func ruler(width: CGFloat, scale: CGFloat) -> some View {
        TimeRuler(total: model.viewDuration)
            .frame(width: width, height: rulerHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { value in
                model.pause()
                model.seekView(model.snap(Double(max(0, value.location.x) / max(0.0001, scale))))
            })
            .help("Click or drag here to move the playhead")
    }

    /// drag across the pictures/sound to select; a plain click moves the playhead
    private func selectGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if !drag.selecting && abs(value.location.x - value.startLocation.x) < 4 { return }
                if !drag.selecting { drag.selecting = true; model.pause() }
                let s = max(0.0001, scale)
                let t0 = Double(value.startLocation.x / s)
                let t1 = Double(value.location.x / s)
                model.setSelection(t0, t1)
                model.seekView(model.snap(min(max(0, t1), model.viewDuration)))
            }
            .onEnded { value in
                if !drag.selecting {
                    model.clearRange()
                    model.pause()
                    model.seekView(model.snap(Double(max(0, value.location.x) / max(0.0001, scale))))
                }
                drag.selecting = false
            }
    }

    /// the yellow selection box with handles on both edges
    @ViewBuilder
    private func selectionLayer(scale: CGFloat) -> some View {
        if let range = model.markedRange, drag.id == nil {
            let rx = CGFloat(range.lowerBound) * scale
            let rw = max(6, CGFloat(range.upperBound - range.lowerBound) * scale)
            let boxHeight = totalHeight - rulerHeight - gap
            ZStack(alignment: .top) {
                Rectangle().fill(Color.yellow.opacity(0.22))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                if rw > 120 {
                    Text("Delete cuts out \(preciseTime(range.upperBound - range.lowerBound))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow))
                        .padding(.top, laneHeight + gap + 4)
                }
            }
            .frame(width: rw, height: boxHeight)
            .offset(x: rx, y: rulerHeight + gap)
            .allowsHitTesting(false)

            TrimHandle(edge: .leading)
                .frame(width: 14, height: boxHeight)
                .offset(x: rx, y: rulerHeight + gap)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { value in
                    model.pause()
                    model.setSelectionStart(Double(value.location.x / max(0.0001, scale)))
                })
                .help("Drag to change where the selection starts")
            TrimHandle(edge: .trailing)
                .frame(width: 14, height: boxHeight)
                .offset(x: rx + rw - 14, y: rulerHeight + gap)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { value in
                    model.pause()
                    model.setSelectionEnd(Double(value.location.x / max(0.0001, scale)))
                })
                .help("Drag to change where the selection ends")
        }
    }

    /// playhead line and the invisible scroll anchor laid out at it
    @ViewBuilder
    private func playhead(x playX: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: totalHeight)
            .offset(x: playX - 1)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .allowsHitTesting(false)
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, playX), height: 1)
            Color.clear.frame(width: 1, height: 1).id("playhead")
        }
        .allowsHitTesting(false)
    }

    // MARK: the timeline

    /// The edited video: only kept parts, laid end to end.
    @ViewBuilder
    private func editedTracks(width: CGFloat) -> some View {
        let segs = model.outputSegments
        let starts = model.editStarts(segs)
        let total = max(0.001, model.editDuration)
        let scale = width / CGFloat(total)
        let playX = CGFloat(model.editTime(fromSource: model.currentTime)) * scale
        let dropX = dropPosition(segs: segs, starts: starts, scale: scale, width: width)

        ZStack(alignment: .topLeading) {
            VStack(spacing: gap) {
                ruler(width: width, scale: scale)

                // parts bar: click to select a part, drag to move it, markers choose the join
                ZStack(alignment: .topLeading) {
                    ForEach(segs.indices, id: \.self) { k in
                        let seg = segs[k]
                        let sx = CGFloat(starts[k]) * scale
                        let sw = max(2, CGFloat(seg.length) * scale)
                        let dragging = drag.id == seg.pieceID
                        EditedChip(number: k + 1, length: seg.length,
                                   selected: model.selectedPiece == seg.pieceID, width: sw)
                            .frame(width: max(1, sw - 2), height: laneHeight)
                            .offset(x: sx + 1 + (dragging ? drag.dx : 0))
                            .shadow(color: .black.opacity(dragging ? 0.6 : 0), radius: 6)
                            .opacity(dragging ? 0.85 : 1)
                            .zIndex(dragging ? 2 : 0)
                            .onTapGesture {
                                model.pause()
                                model.seek(to: seg.start)
                                model.selectedPiece = seg.pieceID
                                model.setSelection(starts[k], starts[k] + seg.length)
                            }
                            .gesture(DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if drag.id != seg.pieceID { drag.id = seg.pieceID; model.pause() }
                                    drag.dx = value.translation.width
                                }
                                .onEnded { _ in
                                    let target = dropTarget(segs: segs, starts: starts, scale: scale)
                                    let id = seg.pieceID
                                    drag.id = nil
                                    drag.dx = 0
                                    model.movePart(id, before: target)
                                })
                            .contextMenu {
                                Button("Delete Part") { model.toggleRemoved(seg.pieceID) }
                                if k + 1 < segs.count {
                                    Button("Move Later") { model.movePart(seg.pieceID, before: k + 2 < segs.count ? segs[k + 2].pieceID : nil) }
                                }
                                if k > 0 {
                                    Button("Move Earlier") { model.movePart(seg.pieceID, before: segs[k - 1].pieceID) }
                                }
                            }
                    }
                    if drag.id == nil {
                        ForEach(Array(segs.indices.dropFirst()), id: \.self) { k in
                            if let piece = model.pieces.first(where: { $0.id == segs[k].pieceID }) {
                                JoinMenu(model: model, piece: piece)
                                    .offset(x: CGFloat(starts[k]) * scale - 11, y: 1)
                            }
                        }
                    }
                }
                .frame(width: width, height: laneHeight, alignment: .topLeading)

                // pictures and sound: drag across to select
                VStack(spacing: gap) {
                    ThumbnailStrip(images: model.editThumbnails.isEmpty ? model.thumbnails : model.editThumbnails)
                        .frame(height: thumbHeight)
                    segmentWaveforms(model.waveLeft, segs: segs, starts: starts, scale: scale, width: width,
                                     label: "L", color: Color(red: 0.35, green: 0.65, blue: 1.0))
                    segmentWaveforms(model.waveRight, segs: segs, starts: starts, scale: scale, width: width,
                                     label: "R", color: Color(red: 0.35, green: 0.85, blue: 0.6))
                }
                .contentShape(Rectangle())
                .gesture(selectGesture(scale: scale))
            }

            // hard cuts between parts
            ForEach(Array(segs.indices.dropFirst()), id: \.self) { k in
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 2, height: totalHeight - mediaTop)
                    .offset(x: CGFloat(starts[k]) * scale - 1, y: mediaTop)
                    .allowsHitTesting(false)
            }

            selectionLayer(scale: scale)

            // where a dragged part will land
            if let dropX {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: totalHeight)
                    .offset(x: dropX - 1.5)
                    .allowsHitTesting(false)
            }

            playhead(x: playX)
        }
        .coordinateSpace(name: "timeline")
    }

    /// the part a dragged part should be placed before (nil = at the end)
    private func dropTarget(segs: [OutputSegment], starts: [Double], scale: CGFloat) -> UUID? {
        guard let id = drag.id, let k = segs.firstIndex(where: { $0.pieceID == id }) else { return nil }
        let center = (CGFloat(starts[k]) + CGFloat(segs[k].length) / 2) * scale + drag.dx
        for (j, seg) in segs.enumerated() where j != k {
            let mid = (CGFloat(starts[j]) + CGFloat(seg.length) / 2) * scale
            if center < mid { return seg.pieceID }
        }
        return nil
    }

    /// x of the insertion line while a part is being dragged
    private func dropPosition(segs: [OutputSegment], starts: [Double], scale: CGFloat, width: CGFloat) -> CGFloat? {
        guard drag.id != nil else { return nil }
        if let target = dropTarget(segs: segs, starts: starts, scale: scale),
           let j = segs.firstIndex(where: { $0.pieceID == target }) {
            return CGFloat(starts[j]) * scale
        }
        return width
    }

    /// each kept part's slice of the recording's waveform, side by side
    private func segmentWaveforms(_ peaks: [Float], segs: [OutputSegment], starts: [Double],
                                  scale: CGFloat, width: CGFloat, label: String, color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
            ForEach(segs.indices, id: \.self) { k in
                Canvas { context, size in
                    let slice = slicePeaks(peaks, segs[k])
                    guard !slice.isEmpty else { return }
                    let barWidth = size.width / CGFloat(slice.count)
                    let mid = size.height / 2
                    var path = Path()
                    for (i, peak) in slice.enumerated() {
                        let h = max(1, CGFloat(peak) * size.height * 0.95)
                        path.addRect(CGRect(x: CGFloat(i) * barWidth, y: mid - h / 2,
                                            width: max(1, barWidth * 0.8), height: h))
                    }
                    context.fill(path, with: .color(color))
                }
                .frame(width: max(1, CGFloat(segs[k].length) * scale), height: waveHeight)
                .offset(x: CGFloat(starts[k]) * scale)
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .frame(height: waveHeight)
        }
        .frame(width: width, height: waveHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func slicePeaks(_ peaks: [Float], _ seg: OutputSegment) -> [Float] {
        guard !peaks.isEmpty, model.duration > 0 else { return [] }
        let n = peaks.count
        let a = max(0, min(n - 1, Int(seg.start / model.duration * Double(n))))
        let b = max(a + 1, min(n, Int((seg.end / model.duration * Double(n)).rounded(.up))))
        return Array(peaks[a..<b])
    }

}

/// time labels along the top of the timeline
struct TimeRuler: View {
    let total: Double

    var body: some View {
        Canvas { context, size in
            guard total > 0, size.width > 0 else { return }
            let scale = size.width / CGFloat(total)
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let step = steps.first(where: { CGFloat($0) * scale >= 70 }) ?? 3600
            var t = 0.0
            while t <= total {
                let x = CGFloat(t) * scale
                context.fill(Path(CGRect(x: x, y: size.height - 7, width: 1, height: 7)),
                             with: .color(.secondary))
                let minor = CGFloat(step / 2) * scale
                context.fill(Path(CGRect(x: x + minor, y: size.height - 3, width: 1, height: 3)),
                             with: .color(.secondary.opacity(0.6)))
                context.draw(Text(Self.label(t)).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: size.height / 2 - 2), anchor: .leading)
                t += step
            }
        }
        .background(Color.white.opacity(0.04))
    }

    static func label(_ t: Double) -> String {
        let whole = Int(t)
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        if t != t.rounded() { return String(format: "%d:%04.1f", whole / 60, t.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// the part being dragged to a new position on the Edited timeline
final class ClipDrag: ObservableObject {
    @Published var id: UUID?
    @Published var dx: CGFloat = 0
    var selecting = false
}

struct EditedChip: View {
    let number: Int
    let length: Double
    let selected: Bool
    let width: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.35))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1)
            HStack(spacing: 4) {
                if width > 34 {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if width > 22 {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold))
                }
                if width > 110 {
                    Text(preciseTime(length))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .help("Part \(number). Click to select, Delete removes it. Drag to move it. Right-click for more.")
    }
}

struct PartChip: View {
    let piece: Piece
    let selected: Bool
    let width: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(piece.kept ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1)
            if width > 70 {
                Text(piece.kept ? preciseTime(piece.end - piece.start) : "Removed")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(piece.kept ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .help(piece.kept ? "Click to select; right-click for options" : "Removed part: select it and press Delete to restore")
    }
}

/// The marker on a join: click to choose how the two parts are joined.
struct JoinMenu: View {
    @ObservedObject var model: EditorModel
    let piece: Piece

    var body: some View {
        let current = Transition(rawValue: piece.transitionIn) ?? .cut
        Menu {
            ForEach(Transition.allCases, id: \.rawValue) { t in
                Button {
                    model.setTransition(t, for: piece.id)
                } label: {
                    Label(t.title + (t == current ? "  ✓" : ""), systemImage: t.symbol)
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 10, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .background(Circle().fill(current == .cut ? Color.white.opacity(0.85) : Color.yellow))
        .foregroundStyle(Color.black)
        .help("Join: \(current.title). Click to change.")
    }
}

struct CutJoinPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let segments = model.outputSegments
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    model.splitAtPlayhead()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                Button {
                    model.deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!model.canDelete)
                Spacer()
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
            }
            .controlSize(.small)

            Text("Joins")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Joins", selection: $model.defaultTransition) {
                ForEach(Transition.allCases, id: \.rawValue) { t in
                    Text(t.title).tag(t.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                Text("Fade length")
                    .font(.system(size: 12))
                Slider(value: $model.transitionLength, in: 0.25...2.0, step: 0.25)
                    .controlSize(.small)
                Text(String(format: "%.2f s", model.transitionLength))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Button("Apply to All Joins") { model.applyTransitionToAll() }
                .controlSize(.small)
                .disabled(!model.hasSplits)

            Toggle("Fade in from black at the start", isOn: $model.fadeIn)
            Toggle("Fade out to black at the end", isOn: $model.fadeOut)

            HStack {
                Text("\(segments.count) part\(segments.count == 1 ? "" : "s") kept")
                Spacer()
                Text("Total \(preciseTime(model.outputLength))")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))

            Text("Parts join with a hard cut. Click the marker between two parts to change it to a Crossfade or Fade to Black. Drag a part by its bar to move it. Click a part's bar to select the whole part.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}

struct TrimHandle: View {
    let edge: HorizontalEdge

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.yellow)
            Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.7))
        }
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }
}

struct ThumbnailStrip: View {
    let images: [CGImage]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if images.isEmpty {
                    Rectangle().fill(Color.white.opacity(0.06))
                } else {
                    ForEach(0..<images.count, id: \.self) { i in
                        Image(decorative: images[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width / CGFloat(images.count), height: geo.size.height)
                            .clipped()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct WaveformTrack: View {
    let peaks: [Float]
    let label: String
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                let mid = size.height / 2
                var path = Path()
                for (i, peak) in peaks.enumerated() {
                    let h = max(1, CGFloat(peak) * size.height * 0.95)
                    path.addRect(CGRect(x: CGFloat(i) * barWidth, y: mid - h / 2,
                                        width: max(1, barWidth * 0.8), height: h))
                }
                context.fill(path, with: .color(color))
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 1:23.45 style time for editing (hundredths of a second)
func preciseTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let whole = Int(t)
    let hundredths = min(99, Int(((t - Double(whole)) * 100).rounded(.down)))
    if whole >= 3600 {
        return String(format: "%d:%02d:%02d.%02d", whole / 3600, whole / 60 % 60, whole % 60, hundredths)
    }
    return String(format: "%d:%02d.%02d", whole / 60, whole % 60, hundredths)
}
