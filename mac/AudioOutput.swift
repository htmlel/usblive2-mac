// AudioOutput.swift - plays the USB-Live2's line-in audio live.
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation

final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Int16>
    private var configObserver: NSObjectProtocol?

    init() {
        scratch = UnsafeMutablePointer<Int16>.allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func start() {
        guard sourceNode == nil,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        else { return }

        let scratch = self.scratch
        let maxFrames = self.maxFrames
        // real-time render callback: pull 48 kHz stereo S16 from the engine's ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = min(Int(frameCount), maxFrames)
            _ = eng_audio_read(scratch, Int32(frames))
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            for i in 0..<frames {
                left[i] = Float(scratch[2 * i]) / 32768.0
                right[i] = Float(scratch[2 * i + 1]) / 32768.0
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        // headphones plugged in / output device changed: restart the engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            try? self?.engine.start()
        }
        do {
            try engine.start()
        } catch {
            NSLog("USB-Live2: audio output could not start: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }
}
