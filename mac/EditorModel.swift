// EditorModel.swift - state for the Edit Recording window: loading a recording,
// thumbnails + waveforms for the timeline, trim/crop/audio settings, export.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

enum AudioFix: Int, CaseIterable {
    case original = 0, leftToBoth = 1, rightToBoth = 2, mixToMono = 3

    var title: String {
        switch self {
        case .original: return "Original"
        case .leftToBoth: return "Left → Both"
        case .rightToBoth: return "Right → Both"
        case .mixToMono: return "Mix to Mono"
        }
    }

    var detail: String {
        switch self {
        case .original: return "Keep the audio as recorded."
        case .leftToBoth: return "Use the left channel on both sides."
        case .rightToBoth: return "Use the right channel on both sides."
        case .mixToMono: return "Blend both channels into centred sound."
        }
    }

    /// ffmpeg audio filter, nil = leave as is
    var filter: String? {
        switch self {
        case .original: return nil
        case .leftToBoth: return "pan=stereo|c0=c0|c1=c0"
        case .rightToBoth: return "pan=stereo|c0=c1|c1=c1"
        case .mixToMono: return "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1"
        }
    }
}

/// How two kept parts are joined.
enum Transition: Int, CaseIterable {
    case cut = 0, crossfade = 1, fadeToBlack = 2

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .crossfade: return "Crossfade"
        case .fadeToBlack: return "Fade to Black"
        }
    }

    var symbol: String {
        switch self {
        case .cut: return "scissors"
        case .crossfade: return "square.on.square"
        case .fadeToBlack: return "circle.lefthalf.filled"
        }
    }

    /// ffmpeg xfade transition name (nil = straight cut)
    var xfade: String? {
        switch self {
        case .cut: return nil
        case .crossfade: return "fade"
        case .fadeToBlack: return "fadeblack"
        }
    }
}

/// What the timeline shows: the edited video (kept parts joined end to end)
/// or the whole original recording with removed parts greyed out.
enum TimelineMode: Int {
    case edited = 0, full = 1
}

/// A stretch of the source video between two split points.
struct Piece: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var kept = true
    /// how this part is joined to the kept part before it
    var transitionIn = Transition.cut.rawValue
}

/// A part that ends up in the export, with times in the source video.
struct OutputSegment {
    let pieceID: UUID
    let start: Double
    let end: Double
    let transitionIn: Transition
    var length: Double { end - start }
}

/// keeps the tail of ffmpeg's error output (thread-safe)
final class ErrorLog {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 { data = data.suffix(8_192) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    // the loaded recording
    @Published private(set) var url: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSize = CGSize(width: 720, height: 480)
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var waveLeft: [Float] = []
    @Published private(set) var waveRight: [Float] = []
    @Published private(set) var audioHint: String?
    @Published private(set) var loadError: String?

    // precise editing
    @Published private(set) var frameRate: Double = 30000.0 / 1001.0
    @Published var zoom: Double = 1 { didSet { scrollTick += 1 } }
    @Published private(set) var scrollTick = 0       // asks the timeline to follow the playhead
    var frameDuration: Double { 1.0 / max(1, frameRate) }

    // playback
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false

    // edits
    @Published var trimStart: Double = 0 { didSet { scheduleRebuild(); clearMarks() } }
    @Published var trimEnd: Double = 0 { didSet { scheduleRebuild(); clearMarks() } }
    @Published var cropTop: Double = 0
    @Published var cropBottom: Double = 0
    @Published var cropLeft: Double = 0
    @Published var cropRight: Double = 0
    @Published var audioFix: Int = AudioFix.original.rawValue

    // splicing: the video split into parts; removed parts are left out and
    // the kept parts are joined with a cut or a fade
    @Published var pieces: [Piece] = [] { didSet { scheduleRebuild(); clearMarks() } }
    /// the yellow selection (what Delete removes), in the current view's time:
    /// in edited-video time
    @Published var markIn: Double?
    @Published var markOut: Double?
    @Published var selectedPiece: UUID?
    @Published var defaultTransition = Transition.cut.rawValue
    @Published var transitionLength: Double = 1.0
    @Published var fadeIn = false
    @Published var fadeOut = false
    @Published private(set) var hasAudio = true

    // edited view: the player plays a composition of just the kept parts
    @Published var timelineMode = TimelineMode.edited {
        didSet { if oldValue != timelineMode { clearMarks(); switchPlayerItem() } }
    }
    @Published private(set) var editThumbnails: [CGImage] = []
    private var sourceAsset: AVURLAsset?
    private var sourceVideoTrack: AVAssetTrack?
    private var sourceAudioTrack: AVAssetTrack?
    private var rebuildWork: DispatchWorkItem?
    private var lastSignature = ""
    private var suppressTimeUpdates = false
    private var editThumbID = UUID()

    // undo / redo of cuts and trims
    private struct Snapshot {
        var pieces: [Piece]
        var trimStart: Double
        var trimEnd: Double
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCheckpointKey = ""
    private var lastCheckpointTime = Date.distantPast
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // export
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var exportResult: URL?
    @Published private(set) var exportError: String?

    static let thumbnailCount = 24
    static let waveformBuckets = 600

    private var timeObserver: Any?
    private var loadID = UUID()
    private var exportProcess: Process?

    // MARK: loading

    func load(_ newURL: URL) {
        unload()
        let id = UUID()
        loadID = id
        url = newURL
        loadError = nil
        exportResult = nil
        exportError = nil
        audioHint = nil
        thumbnails = []
        waveLeft = []
        waveRight = []
        hasAudio = true
        resetEdits()

        let newPlayer = AVPlayer(url: newURL)
        player = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            guard let self, !self.suppressTimeUpdates else { return }
            if self.timelineMode == .edited && self.player?.currentItem?.asset is AVComposition {
                let t = time.seconds
                self.currentTime = self.sourceTime(fromEdit: t)
                if self.isPlaying && t >= self.editDuration - 0.03 { self.pause() }
                return
            }
            self.currentTime = time.seconds
            guard self.isPlaying, self.trimEnd > 0 else { return }
            // jump over removed parts, stop after the last kept part
            if let next = self.playableStart(atOrAfter: time.seconds) {
                if next > time.seconds + 0.05 { self.seek(to: next) }
            } else {
                self.pause()
                self.seek(to: self.trimEnd)
            }
        }

        let asset = AVURLAsset(url: newURL)
        Task {
            do {
                let seconds = try await asset.load(.duration).seconds
                var size = CGSize(width: 720, height: 480)
                var fps: Double = 30000.0 / 1001.0
                let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                if let track = videoTrack {
                    size = try await track.load(.naturalSize)
                    let nominal = Double(try await track.load(.nominalFrameRate))
                    if nominal > 1 { fps = nominal }
                }
                await MainActor.run {
                    guard self.loadID == id else { return }
                    self.duration = seconds
                    self.trimStart = 0
                    self.trimEnd = seconds
                    self.videoSize = size
                    self.frameRate = fps
                    self.zoom = 1
                    self.pieces = [Piece(start: 0, end: seconds)]
                    self.selectedPiece = nil
                    self.sourceAsset = asset
                    self.sourceVideoTrack = videoTrack
                    self.sourceAudioTrack = audioTrack
                    self.clearUndo()
                    if self.timelineMode == .edited { self.rebuildComposition(force: true) }
                }
                await self.makeThumbnails(asset: asset, duration: seconds, id: id)
            } catch {
                await MainActor.run {
                    if self.loadID == id { self.loadError = "Couldn't open this file." }
                }
            }
        }
        Task.detached(priority: .userInitiated) {
            await self.makeWaveform(asset: asset, id: id)
        }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        url = nil
        duration = 0
        currentTime = 0
        thumbnails = []
        editThumbnails = []
        waveLeft = []
        waveRight = []
        audioHint = nil
        loadError = nil
        sourceAsset = nil
        sourceVideoTrack = nil
        sourceAudioTrack = nil
        rebuildWork?.cancel()
        lastSignature = ""
        suppressTimeUpdates = false
        if !isExporting {
            exportResult = nil
            exportError = nil
        }
        loadID = UUID()
    }

    func resetEdits() {
        trimStart = 0
        trimEnd = duration
        cropTop = 0
        cropBottom = 0
        cropLeft = 0
        cropRight = 0
        audioFix = AudioFix.original.rawValue
        zoom = 1
        pieces = duration > 0 ? [Piece(start: 0, end: duration)] : []
        selectedPiece = nil
        defaultTransition = Transition.cut.rawValue
        transitionLength = 1.0
        fadeIn = false
        fadeOut = false
        clearUndo()
    }

    private func makeThumbnails(asset: AVURLAsset, duration: Double, id: UUID) async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 160, height: 120)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: max(0.5, duration / Double(Self.thumbnailCount) / 2),
                               preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var images: [CGImage] = []
        for i in 0..<Self.thumbnailCount {
            let t = duration * (Double(i) + 0.5) / Double(Self.thumbnailCount)
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                images.append(result.image)
            }
            // show them as they arrive
            if i % 4 == 3 || i == Self.thumbnailCount - 1 {
                let snapshot = images
                await MainActor.run {
                    if self.loadID == id { self.thumbnails = snapshot }
                }
            }
        }
    }

    /// Reads the whole audio track once and keeps the peak level of each
    /// channel per timeline bucket.
    private func makeWaveform(asset: AVURLAsset, id: UUID) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                await MainActor.run {
                    if self.loadID == id {
                        self.audioHint = "This recording has no audio."
                        self.hasAudio = false
                    }
                }
                return
            }
            let seconds = try await asset.load(.duration).seconds
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return }

            let buckets = Self.waveformBuckets
            let framesPerBucket = max(1, Int(seconds * 48_000) / buckets)
            var left = [Float](repeating: 0, count: buckets)
            var right = [Float](repeating: 0, count: buckets)
            var frameIndex = 0
            var samples = [Int16]()

            while let sampleBuffer = output.copyNextSampleBuffer() {
                if self.loadID != id { reader.cancelReading(); return }
                guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / 2
                if samples.count < count { samples = [Int16](repeating: 0, count: count) }
                samples.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress {
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                    }
                }
                var i = 0
                while i + 1 < count {
                    let bucket = min(buckets - 1, frameIndex / framesPerBucket)
                    let l = abs(Float(samples[i])) / 32768
                    let r = abs(Float(samples[i + 1])) / 32768
                    if l > left[bucket] { left[bucket] = l }
                    if r > right[bucket] { right[bucket] = r }
                    frameIndex += 1
                    i += 2
                }
            }

            let maxL = left.max() ?? 0
            let maxR = right.max() ?? 0
            var hint: String?
            var suggestion: AudioFix?
            if maxL > 0.02 && maxR < 0.005 {
                hint = "The right channel is silent. Left → Both will put the sound on both sides."
                suggestion = .leftToBoth
            } else if maxR > 0.02 && maxL < 0.005 {
                hint = "The left channel is silent. Right → Both will put the sound on both sides."
                suggestion = .rightToBoth
            } else if maxL < 0.005 && maxR < 0.005 {
                hint = "This recording sounds silent."
            }
            await MainActor.run {
                guard self.loadID == id else { return }
                self.waveLeft = left
                self.waveRight = right
                self.audioHint = hint
                if let suggestion { self.audioFix = suggestion.rawValue }
            }
        } catch {
            await MainActor.run { if self.loadID == id { self.audioHint = "Couldn't read the audio." } }
        }
    }

    // MARK: playback

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if isEditedPlayback {
            if editTime(fromSource: currentTime) >= editDuration - 0.05 { seekEdited(0) }
        } else if currentTime < trimStart || currentTime >= trimEnd - 0.05 {
            seek(to: trimStart)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        var t = min(max(0, seconds), duration)
        if isEditedPlayback {
            // only kept parts exist in the edited video
            let e = editTime(fromSource: t)
            t = sourceTime(fromEdit: e)
            player?.seek(to: CMTime(seconds: e, preferredTimescale: 60000),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player?.seek(to: CMTime(seconds: t, preferredTimescale: 60000),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }
        currentTime = t
        // the part under the playhead is the one Remove / Restore acts on
        if let id = pieceID(at: t), id != selectedPiece { selectedPiece = id }
    }

    /// seek by a position in the edited video
    func seekEdited(_ e: Double) {
        seek(to: sourceTime(fromEdit: min(max(0, e), editDuration)))
    }

    /// rounds a time to the nearest frame boundary
    func snap(_ t: Double) -> Double {
        (t / frameDuration).rounded() * frameDuration
    }

    func frameNumber(_ t: Double) -> Int {
        Int((t / frameDuration).rounded())
    }

    func setTrimStart(_ t: Double) {
        checkpoint("trimStart")
        trimStart = min(max(0, snap(t)), max(0, trimEnd - frameDuration))
        seek(to: trimStart)
    }

    func setTrimEnd(_ t: Double) {
        checkpoint("trimEnd")
        trimEnd = max(min(duration, snap(t)), trimStart + frameDuration)
        seek(to: trimEnd)
    }

    func markStart() { setTrimStart(currentTime) }
    func markEnd() { setTrimEnd(currentTime) }

    /// move the playhead by whole frames (negative = back)
    func step(frames: Int) {
        pause()
        if isEditedPlayback {
            seekEdited(snap(editTime(fromSource: currentTime)) + Double(frames) * frameDuration)
        } else {
            seek(to: snap(currentTime) + Double(frames) * frameDuration)
        }
        scrollTick += 1
    }

    /// move the playhead by seconds
    func jump(seconds: Double) {
        pause()
        if isEditedPlayback {
            seekEdited(snap(editTime(fromSource: currentTime) + seconds))
        } else {
            seek(to: snap(currentTime + seconds))
        }
        scrollTick += 1
    }

    func nudgeStart(frames: Int) {
        pause()
        setTrimStart(trimStart + Double(frames) * frameDuration)
        scrollTick += 1
    }

    func nudgeEnd(frames: Int) {
        pause()
        setTrimEnd(trimEnd + Double(frames) * frameDuration)
        scrollTick += 1
    }

    func goToTrimStart() { pause(); seek(to: trimStart); scrollTick += 1 }
    func goToTrimEnd() { pause(); seek(to: trimEnd); scrollTick += 1 }

    // MARK: splicing

    /// Splits the part under the playhead into two.
    func splitAtPlayhead() {
        let t = snap(currentTime)
        guard let i = pieces.firstIndex(where: { t > $0.start + frameDuration && t < $0.end - frameDuration })
        else { return }
        checkpoint(nil)
        let old = pieces[i]
        var first = old
        first.end = t
        var second = Piece(start: t, end: old.end)
        second.kept = old.kept
        second.transitionIn = defaultTransition
        pieces.replaceSubrange(i...i, with: [first, second])
        selectedPiece = second.id
        pause()
    }

    func toggleRemoved(_ id: UUID) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        // keep at least one part in the video
        if pieces[i].kept && pieces.filter({ $0.kept }).count <= 1 { return }
        checkpoint(nil)
        pieces[i].kept.toggle()
    }

    func toggleSelectedRemoved() {
        if let id = selectedPiece ?? pieceID(at: currentTime) { toggleRemoved(id) }
    }

    /// the part that contains time t
    func pieceID(at t: Double) -> UUID? {
        if let piece = pieces.first(where: { t >= $0.start && t < $0.end }) { return piece.id }
        return pieces.last?.id
    }

    /// true once the video has been split into more than one part
    var canRemoveParts: Bool { pieces.count > 1 }

    /// Removes the split at the start of this part (merges it into the one before).
    func joinWithPrevious(_ id: UUID) {
        guard let i = pieces.firstIndex(where: { $0.id == id }), i > 0,
              abs(pieces[i - 1].end - pieces[i].start) < 0.0005 else { return }
        checkpoint(nil)
        pieces[i - 1].end = pieces[i].end
        if selectedPiece == id { selectedPiece = pieces[i - 1].id }
        pieces.remove(at: i)
    }

    func setTransition(_ transition: Transition, for id: UUID) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(nil)
        pieces[i].transitionIn = transition.rawValue
    }

    func applyTransitionToAll() {
        checkpoint(nil)
        for i in pieces.indices { pieces[i].transitionIn = defaultTransition }
    }

    var isSelectedRemoved: Bool {
        let id = selectedPiece ?? pieceID(at: currentTime)
        return pieces.first(where: { $0.id == id })?.kept == false
    }

    var hasSplits: Bool { pieces.count > 1 }

    /// The kept parts inside the trim range, in order, as they will be exported.
    var outputSegments: [OutputSegment] {
        var result: [OutputSegment] = []
        for piece in pieces where piece.kept {
            let start = max(piece.start, trimStart)
            let end = min(piece.end, trimEnd)
            guard end - start >= frameDuration else { continue }
            result.append(OutputSegment(pieceID: piece.id, start: start, end: end,
                                        transitionIn: Transition(rawValue: piece.transitionIn) ?? .cut))
        }
        return result
    }

    // MARK: the yellow selection (what Delete removes)

    private func clearMarks() {
        if markIn != nil { markIn = nil }
        if markOut != nil { markOut = nil }
    }

    /// length of the timeline currently shown
    var viewDuration: Double { timelineMode == .edited ? editDuration : duration }

    /// playhead position on the timeline currently shown
    var viewTime: Double { timelineMode == .edited ? editTime(fromSource: currentTime) : currentTime }

    func seekView(_ t: Double) {
        if timelineMode == .edited { seekEdited(t) } else { seek(to: t) }
    }

    /// I: start the selection at the playhead
    func setMarkIn() {
        let t = snap(viewTime)
        markIn = t
        if let out = markOut, out <= t { markOut = nil }
    }

    /// O: end the selection at the playhead
    func setMarkOut() {
        let t = snap(viewTime)
        markOut = t
        if let inn = markIn, inn >= t { markIn = nil }
    }

    /// X / Esc: clear the selection
    func clearRange() { clearMarks() }

    /// the selection, filling in a missing end with the start/end of the video
    var markedRange: ClosedRange<Double>? {
        guard markIn != nil || markOut != nil else { return nil }
        let a = markIn ?? 0
        let b = markOut ?? viewDuration
        return b - a >= frameDuration ? a...b : nil
    }

    /// drag across the timeline to select
    func setSelection(_ a: Double, _ b: Double) {
        let lo = snap(min(max(0, min(a, b)), viewDuration))
        let hi = snap(min(max(0, max(a, b)), viewDuration))
        markIn = lo
        markOut = hi
    }

    /// move the selection's left edge (and show that frame)
    func setSelectionStart(_ t: Double) {
        let end = markedRange?.upperBound ?? viewDuration
        let v = min(max(0, snap(t)), end - frameDuration)
        markIn = v
        if markOut == nil { markOut = end }
        seekView(v)
    }

    /// move the selection's right edge (and show that frame)
    func setSelectionEnd(_ t: Double) {
        let start = markedRange?.lowerBound ?? 0
        let v = max(min(viewDuration, snap(t)), start + frameDuration)
        markOut = v
        if markIn == nil { markIn = start }
        seekView(max(start, v - frameDuration))
    }

    func nudgeSelectionStart(frames: Int) {
        pause()
        setSelectionStart((markedRange?.lowerBound ?? viewTime) + Double(frames) * frameDuration)
        scrollTick += 1
    }

    func nudgeSelectionEnd(frames: Int) {
        pause()
        setSelectionEnd((markedRange?.upperBound ?? viewTime) + Double(frames) * frameDuration)
        scrollTick += 1
    }

    /// Splits the part containing recording time t (no-op at an existing split).
    private func split(atSource t: Double) {
        guard let i = pieces.firstIndex(where: { t > $0.start + frameDuration / 2 && t < $0.end - frameDuration / 2 })
        else { return }
        let old = pieces[i]
        var first = old
        first.end = t
        var second = Piece(start: t, end: old.end)
        second.kept = old.kept
        second.transitionIn = Transition.cut.rawValue
        pieces.replaceSubrange(i...i, with: [first, second])
    }

    /// Deletes the yellow selection. What is left closes up and plays as a hard
    /// cut (change the join marker to fade instead).
    func removeMarkedRange() {
        guard let range = markedRange else { return }
        let a = range.lowerBound, b = range.upperBound
        let half = frameDuration / 2
        pause()
        if timelineMode == .edited {
            if b - a >= editDuration - frameDuration { return }   // would remove everything
            checkpoint(nil)
            let sa = sourceTime(fromEdit: a)
            let sb = sourceTime(fromEdit: b)
            split(atSource: sa)
            split(atSource: sb)
            let segs = outputSegments
            let starts = editStarts(segs)
            var ids = Set<UUID>()
            for (k, seg) in segs.enumerated() {
                let e0 = starts[k], e1 = starts[k] + seg.length
                if e0 >= a - half && e1 <= b + half { ids.insert(seg.pieceID) }
            }
            for i in pieces.indices where ids.contains(pieces[i].id) { pieces[i].kept = false }
            clearMarks()
            seekEdited(a)
        } else {
            // something has to be left over
            guard outputSegments.contains(where: { $0.start < a - half || $0.end > b + half }) else { return }
            checkpoint(nil)
            split(atSource: a)
            split(atSource: b)
            for i in pieces.indices where pieces[i].start >= a - half && pieces[i].end <= b + half {
                pieces[i].kept = false
            }
            clearMarks()
            // show the result with the gap closed
            timelineMode = .edited
            seek(to: b)
        }
        scrollTick += 1
    }

    /// Delete key: remove the selection if there is one, else the selected part.
    func deleteSelection() {
        if markedRange != nil {
            removeMarkedRange()
        } else if timelineMode == .full {
            toggleSelectedRemoved()
        }
    }

    var canDelete: Bool { markedRange != nil || (timelineMode == .full && canRemoveParts) }

    /// Moves a kept part so it plays before the kept part `before` (nil = at the end).
    func movePart(_ id: UUID, before target: UUID?) {
        guard id != target, let from = pieces.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(nil)
        var list = pieces
        let piece = list.remove(at: from)
        if let target, let to = list.firstIndex(where: { $0.id == target }) {
            list.insert(piece, at: to)
        } else {
            list.append(piece)
        }
        guard list.map(\.id) != pieces.map(\.id) else { undoStack.removeLast(); canUndo = !undoStack.isEmpty; return }
        pieces = list
        selectedPiece = id
        pause()
        if let seg = outputSegments.first(where: { $0.pieceID == id }) { seek(to: seg.start) }
        scrollTick += 1
    }

    /// pieces whose start is a join point in the output (they follow another kept part)
    var joinPieceIDs: Set<UUID> {
        var ids = Set<UUID>()
        var seenKept = false
        for piece in pieces {
            let inRange = min(piece.end, trimEnd) - max(piece.start, trimStart) >= frameDuration
            guard piece.kept, inRange else { continue }
            if seenKept { ids.insert(piece.id) }
            seenKept = true
        }
        return ids
    }

    /// Where playback should continue from: t itself if it is inside a kept
    /// part, else the start of the next kept part; nil if nothing is left.
    func playableStart(atOrAfter t: Double) -> Double? {
        for seg in outputSegments.sorted(by: { $0.start < $1.start }) {
            if t < seg.start { return seg.start }
            if t < seg.end - 0.02 { return t }
        }
        return nil
    }

    var outputLength: Double {
        Self.buildGraph(segments: outputSegments, transitionLength: transitionLength,
                        fadeIn: false, fadeOut: false, crop: nil, audioFilter: nil, audio: false).length
    }

    /// Builds the ffmpeg filter graph that cuts out the segments, joins them
    /// (concat for cuts, xfade/acrossfade for fades) and applies the fades,
    /// crop and audio fix. Returns the graph and the output length.
    static func buildGraph(segments: [OutputSegment], transitionLength: Double,
                           fadeIn: Bool, fadeOut: Bool, crop: String?, audioFilter: String?,
                           audio: Bool) -> (graph: String, length: Double) {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        guard let first = segments.first else { return ("", 0) }
        var parts: [String] = []
        for (i, seg) in segments.enumerated() {
            // each part is its own input (-ss/-t), so ffmpeg seeks straight to it
            _ = seg
            parts.append("[\(i):v]setpts=PTS-STARTPTS,settb=AVTB[v\(i)]")
            if audio {
                parts.append("[\(i):a]asetpts=PTS-STARTPTS[a\(i)]")
            }
        }
        var v = "v0", a = "a0"
        var length = first.length
        for k in 1..<max(1, segments.count) {
            let seg = segments[k]
            let d = min(transitionLength, length - 0.1, seg.length - 0.1)
            if let name = seg.transitionIn.xfade, d >= 0.1 {
                parts.append("[\(v)][v\(k)]xfade=transition=\(name):duration=\(f(d)):offset=\(f(length - d))[vj\(k)]")
                if audio { parts.append("[\(a)][a\(k)]acrossfade=d=\(f(d))[aj\(k)]") }
                length += seg.length - d
            } else {
                parts.append("[\(v)][v\(k)]concat=n=2:v=1:a=0[vj\(k)]")
                if audio { parts.append("[\(a)][a\(k)]concat=n=2:v=0:a=1[aj\(k)]") }
                length += seg.length
            }
            v = "vj\(k)"
            a = "aj\(k)"
        }
        let fadeLength = min(1.0, length / 3)
        var vf: [String] = []
        var af: [String] = []
        if fadeIn {
            vf.append("fade=t=in:st=0:d=\(f(fadeLength))")
            af.append("afade=t=in:st=0:d=\(f(fadeLength))")
        }
        if fadeOut {
            vf.append("fade=t=out:st=\(f(length - fadeLength)):d=\(f(fadeLength))")
            af.append("afade=t=out:st=\(f(length - fadeLength)):d=\(f(fadeLength))")
        }
        if let crop { vf.append(crop) }
        if let audioFilter { af.append(audioFilter) }
        parts.append("[\(v)]\(vf.isEmpty ? "null" : vf.joined(separator: ","))[vout]")
        if audio { parts.append("[\(a)]\(af.isEmpty ? "anull" : af.joined(separator: ","))[aout]") }
        return (parts.joined(separator: ";"), length)
    }

    // MARK: edited video (kept parts joined end to end)

    var isEditedPlayback: Bool {
        timelineMode == .edited && player?.currentItem?.asset is AVComposition
    }

    /// length of the edited video (parts joined with straight cuts)
    var editDuration: Double {
        outputSegments.reduce(0) { $0 + $1.length }
    }

    /// position in the edited video for a time in the recording; times inside
    /// removed parts map to the start of the next kept part
    func editTime(fromSource s: Double) -> Double {
        let segs = outputSegments
        var acc = 0.0
        for seg in segs {
            if s >= seg.start && s < seg.end { return acc + (s - seg.start) }
            acc += seg.length
        }
        // not in the edit: go to the next kept part after the one containing s
        let kept = Set(segs.map { $0.pieceID })
        let starts = editStarts(segs)
        if let i = pieces.firstIndex(where: { s >= $0.start && s < $0.end }) {
            for piece in pieces[(i + 1)...] where kept.contains(piece.id) {
                if let k = segs.firstIndex(where: { $0.pieceID == piece.id }) { return starts[k] }
            }
            // a trimmed-off part of a kept piece: its own segment
            if let k = segs.firstIndex(where: { $0.pieceID == pieces[i].id }) {
                return s < segs[k].start ? starts[k] : starts[k] + segs[k].length - frameDuration
            }
        }
        return acc
    }

    func sourceTime(fromEdit e: Double) -> Double {
        let segs = outputSegments
        var acc = 0.0
        for seg in segs {
            if e < acc + seg.length { return seg.start + max(0, e - acc) }
            acc += seg.length
        }
        return segs.last?.end ?? 0
    }

    /// where each kept part starts in the edited video
    func editStarts(_ segs: [OutputSegment]) -> [Double] {
        var acc = 0.0
        return segs.map { seg in
            defer { acc += seg.length }
            return acc
        }
    }

    private func scheduleRebuild() {
        guard timelineMode == .edited, sourceVideoTrack != nil else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildComposition() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Builds a composition of just the kept parts so playback runs straight
    /// from one into the next (joins preview as cuts; fades are added on export).
    private func rebuildComposition(force: Bool = false) {
        guard let player, let videoTrack = sourceVideoTrack else { return }
        let segs = outputSegments
        let signature = segs.map { String(format: "%.4f-%.4f", $0.start, $0.end) }.joined(separator: ",")
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        let compAudio = sourceAudioTrack == nil ? nil :
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for seg in segs {
            let range = CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: 60000),
                                    duration: CMTime(seconds: seg.length, preferredTimescale: 60000))
            do {
                try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
                if let compAudio, let audioTrack = sourceAudioTrack {
                    try compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
                }
            } catch {
                continue
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        let wasPlaying = isPlaying
        if wasPlaying { player.pause() }
        suppressTimeUpdates = true
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        // stay on the same moment (or the next kept part, if it was removed)
        let e = editTime(fromSource: currentTime)
        currentTime = sourceTime(fromEdit: e)
        if let id = pieceID(at: currentTime) { selectedPiece = id }
        player.seek(to: CMTime(seconds: e, preferredTimescale: 60000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.suppressTimeUpdates = false
                if wasPlaying { self?.player?.play() }
            }
        }
        makeEditThumbnails(composition)
    }

    private func switchPlayerItem() {
        guard let player, let asset = sourceAsset else { return }
        pause()
        if timelineMode == .edited {
            rebuildComposition(force: true)
        } else {
            suppressTimeUpdates = true
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.suppressTimeUpdates = false }
            }
        }
        scrollTick += 1
    }

    /// thumbnails of the edited video, so the strip matches what plays
    private func makeEditThumbnails(_ composition: AVComposition) {
        let id = UUID()
        editThumbID = id
        let total = composition.duration.seconds
        guard total > 0 else { editThumbnails = []; return }
        Task {
            let generator = AVAssetImageGenerator(asset: composition)
            generator.maximumSize = CGSize(width: 160, height: 120)
            let tolerance = CMTime(seconds: max(0.2, total / Double(Self.thumbnailCount) / 2),
                                   preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            var images: [CGImage] = []
            for i in 0..<Self.thumbnailCount {
                if self.editThumbID != id { return }
                let t = total * (Double(i) + 0.5) / Double(Self.thumbnailCount)
                if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    images.append(result.image)
                }
            }
            let finished = images
            await MainActor.run {
                if self.editThumbID == id { self.editThumbnails = finished }
            }
        }
    }

    var displayTime: Double { isEditedPlayback ? editTime(fromSource: currentTime) : currentTime }
    var displayDuration: Double { isEditedPlayback ? editDuration : duration }

    // MARK: undo / redo

    /// Saves the current cuts and trims before a change. Repeated changes of
    /// the same kind within a second (holding −/+) count as one step.
    private func checkpoint(_ key: String?) {
        if let key, key == lastCheckpointKey, Date().timeIntervalSince(lastCheckpointTime) < 1.0 {
            lastCheckpointTime = Date()
            return
        }
        lastCheckpointKey = key ?? ""
        lastCheckpointTime = Date()
        undoStack.append(Snapshot(pieces: pieces, trimStart: trimStart, trimEnd: trimEnd))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(pieces: pieces, trimStart: trimStart, trimEnd: trimEnd))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(pieces: pieces, trimStart: trimStart, trimEnd: trimEnd))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        pause()
        lastCheckpointKey = ""
        pieces = snapshot.pieces
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func clearUndo() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCheckpointKey = ""
        canUndo = false
        canRedo = false
    }

    // MARK: export

    var hasCrop: Bool { cropTop + cropBottom + cropLeft + cropRight > 0 }

    func export() {
        guard let input = url, !isExporting else { return }
        guard let pathPointer = eng_ffmpeg_path() else {
            exportError = "Exporting needs ffmpeg. In Terminal: brew install ffmpeg"
            return
        }
        let ffmpeg = String(cString: pathPointer)
        let segments = outputSegments
        guard !segments.isEmpty else {
            exportError = "Every part has been removed, so there's nothing to export."
            return
        }
        guard let output = chooseExportLocation(for: input) else { return }

        var cropFilter: String?
        if hasCrop {
            // even sizes/offsets keep 4:2:0 video happy
            func even(_ v: Double) -> Int { Int(v) & ~1 }
            let w = Int(videoSize.width), h = Int(videoSize.height)
            let x = even(cropLeft), y = even(cropTop)
            let cw = even(Double(w - x - Int(cropRight)))
            let ch = even(Double(h - y - Int(cropBottom)))
            cropFilter = "crop=\(cw):\(ch):\(x):\(y)"
        }
        let audioFilter = (AudioFix(rawValue: audioFix) ?? .original).filter

        var args = ["-hide_banner", "-loglevel", "error", "-nostats", "-y"]
        let length: Double
        if segments.count == 1 && !fadeIn && !fadeOut {
            // one continuous part: fast seek straight to it
            let seg = segments[0]
            length = max(0.1, seg.length)
            args += ["-ss", String(format: "%.3f", seg.start), "-i", input.path,
                     "-t", String(format: "%.3f", length)]
            if let cropFilter { args += ["-vf", cropFilter] }
            if let audioFilter { args += ["-af", audioFilter] }
        } else {
            // several parts and/or fades: one filter graph does it all
            let built = Self.buildGraph(segments: segments, transitionLength: transitionLength,
                                        fadeIn: fadeIn, fadeOut: fadeOut, crop: cropFilter,
                                        audioFilter: audioFilter, audio: hasAudio)
            length = max(0.1, built.length)
            // one input per kept part: ffmpeg seeks straight to each one instead of
            // decoding the whole recording (which stalled on long tapes)
            for seg in segments {
                args += ["-ss", String(format: "%.3f", seg.start),
                         "-t", String(format: "%.3f", seg.length),
                         "-i", input.path]
            }
            args += ["-filter_complex", built.graph, "-map", "[vout]"]
            if hasAudio { args += ["-map", "[aout]"] }
        }
        args += ["-c:v", "h264_videotoolbox", "-b:v", "12M", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k",
                 "-movflags", "+faststart",
                 "-progress", "pipe:1",
                 output.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let progressPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = progressPipe
        process.standardError = errorPipe

        progressPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    let p = min(1, max(0, us / 1_000_000 / length))
                    DispatchQueue.main.async { self?.exportProgress = p }
                }
            }
        }
        let errorLog = ErrorLog()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorLog.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            progressPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorLog.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let errText = errorLog.text
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                self.exportProcess = nil
                if proc.terminationReason == .exit && proc.terminationStatus == 0 {
                    self.exportProgress = 1
                    self.exportResult = output
                } else if proc.terminationReason == .uncaughtSignal {
                    self.exportError = "Export cancelled."
                    try? FileManager.default.removeItem(at: output)
                } else {
                    let last = errText.split(separator: "\n").last.map(String.init) ?? ""
                    self.exportError = "Export failed. \(last)"
                }
            }
        }

        exportProgress = 0
        exportResult = nil
        exportError = nil
        do {
            try process.run()
            isExporting = true
            exportProcess = process
            pause()
        } catch {
            exportError = "Couldn't start ffmpeg."
        }
    }

    /// Save dialog: pick the folder and name; starts in the last export folder.
    private func chooseExportLocation(for input: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Edited Video"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let suggested = Self.outputURL(for: input)
        panel.nameFieldStringValue = suggested.lastPathComponent
        if let last = UserDefaults.standard.string(forKey: "lastExportFolder"),
           FileManager.default.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        } else {
            panel.directoryURL = input.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, var output = panel.url else { return nil }
        if output.pathExtension.lowercased() != "mp4" {
            output = output.appendingPathExtension("mp4")
        }
        if output.standardizedFileURL == input.standardizedFileURL {
            exportError = "Choose a different name, so the original recording isn't overwritten."
            return nil
        }
        UserDefaults.standard.set(output.deletingLastPathComponent().path, forKey: "lastExportFolder")
        return output
    }

    func cancelExport() {
        exportProcess?.terminate()
    }

    func clearExportStatus() {
        exportResult = nil
        exportError = nil
    }

    /// "<name> (edited).mp4", or "(edited 2)", ... next to the original
    static func outputURL(for input: URL) -> URL {
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? "\(base) (edited).mp4" : "\(base) (edited \(n)).mp4"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: picking files

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.prompt = "Edit"
        if panel.runModal() == .OK, let picked = panel.url {
            load(picked)
        }
    }

    /// Recordings made before this moment are hidden from the recent list
    /// (the files themselves are not touched).
    @Published private(set) var recentClearedAt: Date =
        UserDefaults.standard.object(forKey: "recentClearedAt") as? Date ?? .distantPast

    func clearRecent() {
        recentClearedAt = Date()
        UserDefaults.standard.set(recentClearedAt, forKey: "recentClearedAt")
    }

    /// recordings made by the app, newest first
    func recentRecordings() -> [URL] {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(
                at: movies, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "mp4" && $0.lastPathComponent.hasPrefix("USB-Live2") }
            .filter {
                let date = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return date > recentClearedAt
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(8)
            .map { $0 }
    }
}
