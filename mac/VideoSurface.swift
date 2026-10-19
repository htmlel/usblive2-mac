// VideoSurface.swift - shows frames from the engine with AVSampleBufferDisplayLayer
// (GPU colour conversion + scaling, frames shown as soon as they arrive).
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI

/// Receives pictures from the capture thread and puts them on screen.
final class FrameSink {
    static let shared = FrameSink()

    let layer = AVSampleBufferDisplayLayer()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private var lastBuffer: CVPixelBuffer?

    private init() {
        // the picture is always 4:3; SwiftUI sizes the view to 4:3, so stretch to fill it
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor

        // a timebase that runs on the host clock lets us schedule the second
        // field of "smooth" mode half a frame in the future
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
        }
    }

    /// Called on the capture thread. `data` is packed YUYV 4:2:2.
    func handle(_ data: UnsafePointer<UInt8>, width: Int, height: Int, delay: Double) {
        if pool == nil || width != poolWidth || height != poolHeight {
            makePool(width: width, height: height)
        }
        guard let pool else { return }

        var pixelBufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut) == kCVReturnSuccess,
              let pixelBuffer = pixelBufferOut else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let srcStride = width * 2
            for y in 0..<height {
                memcpy(base + y * dstStride, data + y * srcStride, srcStride)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        // standard-definition video colour (BT.601)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixelBuffer) {
            var newFormat: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &newFormat)
            format = newFormat
        }
        guard let format else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTimeAdd(now, CMTime(seconds: delay, preferredTimescale: 1_000_000)),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)

        lock.lock()
        lastBuffer = pixelBuffer
        lock.unlock()
    }

    private func makePool(width: Int, height: Int) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8_yuvs,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
        pool = newPool
        poolWidth = width
        poolHeight = height
        format = nil
    }

    /// Saves the picture currently on screen as a 4:3 PNG.
    func savePNG(to url: URL) -> Bool {
        lock.lock()
        let buffer = lastBuffer
        lock.unlock()
        guard let buffer else { return false }

        var image = CIImage(cvPixelBuffer: buffer)
        let width = image.extent.width
        let height = image.extent.height
        let squareWidth = (height * 4.0 / 3.0).rounded()   // square pixels at 4:3
        image = image.transformed(by: CGAffineTransform(scaleX: squareWidth / width, y: 1.0))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace)
        else { return false }
        return (try? data.write(to: url)) != nil
    }
}

/// C callback from the engine's capture thread.
let engineVideoCallback: eng_video_cb = { data, width, height, delay, _ in
    guard let data else { return }
    FrameSink.shared.handle(data, width: Int(width), height: Int(height), delay: delay)
}

/// An NSView backed by the shared display layer.
final class DisplayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func makeBackingLayer() -> CALayer {
        FrameSink.shared.layer
    }
}

struct VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DisplayView {
        DisplayView(frame: .zero)
    }

    func updateNSView(_ nsView: DisplayView, context: Context) {}
}
