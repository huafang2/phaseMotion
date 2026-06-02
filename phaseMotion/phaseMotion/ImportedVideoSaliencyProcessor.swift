// Author: Jau

#if canImport(UIKit)
import UIKit
import AVFoundation

final class ImportedVideoSaliencyProcessor {
    enum OutputMode {
        case saliencyOnly(saveToLibrary: Bool)
        case liveFormat(includeRawVideo: Bool, saveToLibrary: Bool)
        case sideBySidePlayback
    }

    private let sourceURL: URL
    private let outputResolution: Int
    private let outputMode: OutputMode
    private let detectionSettings: MotionDetector.DetectionSettings
    private let boundingBoxSettings: MotionDetector.BoundingBoxSettings
    private let processingQueue = DispatchQueue(label: "com.phasemotion.imported-video")
    private let context = CIContext(options: nil)
    private var isCancelled = false

    init(
        sourceURL: URL,
        outputResolution: Int,
        outputMode: OutputMode,
        detectionSettings: MotionDetector.DetectionSettings,
        boundingBoxSettings: MotionDetector.BoundingBoxSettings
    ) {
        self.sourceURL = sourceURL
        self.outputResolution = outputResolution
        self.outputMode = outputMode
        self.detectionSettings = detectionSettings
        self.boundingBoxSettings = boundingBoxSettings
    }

    func cancel() {
        processingQueue.async { [weak self] in
            self?.isCancelled = true
        }
    }

    func process(completion: @escaping (Bool, URL?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion(false, nil)
                return
            }

            let detector = MotionDetector(size: self.outputResolution)
            detector.updateDetectionSettings(self.detectionSettings)
            detector.updateBoundingBoxSettings(self.boundingBoxSettings)

            let shouldIncludeRawVideo: Bool
            let shouldSaveToLibrary: Bool
            let usesSideBySideLayout: Bool
            switch self.outputMode {
            case .saliencyOnly(let saveToLibrary):
                shouldIncludeRawVideo = false
                shouldSaveToLibrary = saveToLibrary
                usesSideBySideLayout = false
            case .liveFormat(let includeRawVideo, let saveToLibrary):
                shouldIncludeRawVideo = includeRawVideo
                shouldSaveToLibrary = saveToLibrary
                usesSideBySideLayout = false
            case .sideBySidePlayback:
                shouldIncludeRawVideo = true
                shouldSaveToLibrary = false
                usesSideBySideLayout = true
            }

            let recorderSize = CGSize(
                width: usesSideBySideLayout ? self.outputResolution * 2 : self.outputResolution,
                height: shouldIncludeRawVideo && !usesSideBySideLayout ? self.outputResolution * 2 : self.outputResolution
            )
            let recorder = VideoRecorder(
                size: recorderSize,
                fileName: "imported_saliency_\(Int(Date().timeIntervalSince1970)).mp4",
                expectsRealTime: false
            )

            let readySemaphore = DispatchSemaphore(value: 0)
            recorder.start {
                readySemaphore.signal()
            }
            readySemaphore.wait()

            let asset = AVURLAsset(url: self.sourceURL)
            guard let track = self.loadVideoTrack(from: asset) else {
                completion(false, nil)
                return
            }
            let preferredTransform = self.loadPreferredTransform(for: track)

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                completion(false, nil)
                return
            }

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            trackOutput.alwaysCopiesSampleData = false
            if reader.canAdd(trackOutput) {
                reader.add(trackOutput)
            } else {
                completion(false, nil)
                return
            }

            guard reader.startReading() else {
                completion(false, nil)
                return
            }

            while reader.status == .reading, !self.isCancelled {
                autoreleasepool {
                    guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }

                    let transformedImage = self.makePreparedCGImage(from: pixelBuffer, preferredTransform: preferredTransform)
                    guard let cgImage = transformedImage else {
                        return
                    }

                    guard let detectionResult = detector.processFrame(cgImage) else {
                        return
                    }

                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let outputImage: PlatformImage
                    switch self.outputMode {
                    case .saliencyOnly:
                        outputImage = detectionResult.boxedSaliencyImage
                    case .liveFormat(let includeRaw, _):
                        if includeRaw {
                            let rawImage = PlatformImage.from(cgImage: cgImage)
                            outputImage = self.stitchedImage(raw: rawImage, processed: detectionResult.boxedSaliencyImage) ?? detectionResult.boxedSaliencyImage
                        } else {
                            outputImage = detectionResult.boxedSaliencyImage
                        }
                    case .sideBySidePlayback:
                        let rawImage = PlatformImage.from(cgImage: cgImage)
                        outputImage = self.sideBySideImage(raw: rawImage, processed: detectionResult.boxedSaliencyImage) ?? detectionResult.boxedSaliencyImage
                    }

                    recorder.append(image: outputImage, timestamp: timestamp)
                }
            }

            if self.isCancelled {
                recorder.stop(saveToLibrary: shouldSaveToLibrary) { success in
                    completion(success, recorder.outputURL)
                }
                return
            }

            if reader.status != .completed && reader.status != .reading {
                recorder.stop(saveToLibrary: shouldSaveToLibrary) { _ in
                    completion(false, recorder.outputURL)
                }
                return
            }

            recorder.stop(saveToLibrary: shouldSaveToLibrary) { success in
                completion(success, recorder.outputURL)
            }
        }
    }

    private func makePreparedCGImage(from pixelBuffer: CVPixelBuffer, preferredTransform: CGAffineTransform) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        image = image.transformed(by: preferredTransform)

        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }

        let extent = image.extent.integral
        let longEdge = max(extent.width, extent.height)
        if longEdge > 0 {
            let targetLongEdge = CGFloat(outputResolution)
            let scale = min(1.0, targetLongEdge / longEdge)
            if scale < 0.999 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        return context.createCGImage(image, from: image.extent.integral)
    }

    private func loadVideoTrack(from asset: AVURLAsset) -> AVAssetTrack? {
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?

        Task {
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            track = tracks.first
            semaphore.signal()
        }

        semaphore.wait()
        return track
    }

    private func loadPreferredTransform(for track: AVAssetTrack) -> CGAffineTransform {
        let semaphore = DispatchSemaphore(value: 0)
        var transform = CGAffineTransform.identity

        Task {
            transform = (try? await track.load(.preferredTransform)) ?? .identity
            semaphore.signal()
        }

        semaphore.wait()
        return transform
    }

    private func stitchedImage(raw: PlatformImage, processed: PlatformImage) -> PlatformImage? {
        let width = max(1, processed.size.width)
        let height = max(1, processed.size.height)
        let totalSize = CGSize(width: width, height: height * 2)

        UIGraphicsBeginImageContextWithOptions(totalSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        raw.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        processed.draw(in: CGRect(x: 0, y: height, width: width, height: height))

        return UIGraphicsGetImageFromCurrentImageContext()
    }

    private func sideBySideImage(raw: PlatformImage, processed: PlatformImage) -> PlatformImage? {
        let width = max(1, processed.size.width)
        let height = max(1, processed.size.height)
        let totalSize = CGSize(width: width * 2, height: height)

        UIGraphicsBeginImageContextWithOptions(totalSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        raw.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        processed.draw(in: CGRect(x: width, y: 0, width: width, height: height))

        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
#endif
