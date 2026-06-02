// Author: Jau

import Accelerate

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MotionDetectionResult {
    let saliencyImage: PlatformImage
    let boxedSaliencyImage: PlatformImage
    let boundingBoxes: [CGRect]
}

final class MotionDetector {

    struct DetectionSettings {
        var usesColorChannelFusion: Bool
        var usesTemporalFusion: Bool
        var temporalFusionFrameCount: Int
        var preprocessingDownsampleScale: Float

        static let `default` = DetectionSettings(
            usesColorChannelFusion: true,
            usesTemporalFusion: true,
            temporalFusionFrameCount: 5,
            preprocessingDownsampleScale: 1.0
        )
    }

    struct BoundingBoxSettings {
        var isEnabled: Bool
        var suppressionRadius: Int
        var seedThreshold: Float
        var regionThreshold: Float
        var minArea: Int
        var maxSeedCount: Int
        var maxBoxes: Int
        var padding: CGFloat

        static func defaults(for size: Int) -> BoundingBoxSettings {
            BoundingBoxSettings(
                isEnabled: false,
                suppressionRadius: max(6, size / 40),
                seedThreshold: 0.60,
                regionThreshold: 0.35,
                minArea: max(24, (size * size) / 4096),
                maxSeedCount: 24,
                maxBoxes: 8,
                padding: CGFloat(max(2, size / 128))
            )
        }
    }

    private struct ProcessingLayout: Equatable {
        let fftWidth: Int
        let fftHeight: Int
        let contentWidth: Int
        let contentHeight: Int
        let xOffset: Int
        let yOffset: Int

        var contentRect: CGRect {
            CGRect(x: xOffset, y: yOffset, width: contentWidth, height: contentHeight)
        }

        var pixelCount: Int {
            fftWidth * fftHeight
        }

        var log2Width: vDSP_Length {
            vDSP_Length(log2(Float(fftWidth)))
        }

        var log2Height: vDSP_Length {
            vDSP_Length(log2(Float(fftHeight)))
        }
    }

    private struct BoundingBoxParameters {
        let suppressionRadius: Int
        let seedThreshold: Float
        let regionThreshold: Float
        let minArea: Int
        let maxSeedCount: Int
        let maxBoxes: Int
        let padding: CGFloat

        init(settings: BoundingBoxSettings) {
            self.suppressionRadius = settings.suppressionRadius
            self.seedThreshold = settings.seedThreshold
            self.regionThreshold = settings.regionThreshold
            self.minArea = settings.minArea
            self.maxSeedCount = settings.maxSeedCount
            self.maxBoxes = settings.maxBoxes
            self.padding = settings.padding
        }
    }

    private struct ChannelSpectrum {
        let amplitude: [Float]
        let phase: [Float]
    }

    private struct FrameSpectrumState {
        let channels: [ChannelSpectrum]
    }

    private struct Seed {
        let x: Int
        let y: Int
        let value: Float
    }

    private struct ConnectedComponent {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
        var area: Int
        var maxValue: Float
    }

    private let maxDimension: Int
    private let log2MaxDimension: vDSP_Length
    private let fftSetup: FFTSetup
    private let stateLock = NSLock()

    private var previousFrameSpectrum: FrameSpectrumState?
    private var prevLayout: ProcessingLayout?
    private var temporalSaliencyHistory: [[Float]] = []
    private var detectionSettings = DetectionSettings.default
    private var boundingBoxSettings: BoundingBoxSettings

    private var boundingBoxParameters: BoundingBoxParameters {
        BoundingBoxParameters(settings: boundingBoxSettings)
    }

    init(size: Int) {
        self.maxDimension = size
        self.log2MaxDimension = vDSP_Length(log2(Float(size)))
        self.boundingBoxSettings = BoundingBoxSettings.defaults(for: size)

        guard let setup = vDSP_create_fftsetup(log2MaxDimension, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    var currentBoundingBoxSettings: BoundingBoxSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return boundingBoxSettings
    }

    var currentDetectionSettings: DetectionSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return detectionSettings
    }

    func updateBoundingBoxSettings(_ settings: BoundingBoxSettings) {
        stateLock.lock()
        defer { stateLock.unlock() }
        boundingBoxSettings = sanitize(settings)
    }

    func updateDetectionSettings(_ settings: DetectionSettings) {
        stateLock.lock()
        defer { stateLock.unlock() }
        detectionSettings = sanitize(settings)
        previousFrameSpectrum = nil
        temporalSaliencyHistory.removeAll()
    }

    func processFrame(_ image: CGImage) -> MotionDetectionResult? {
        stateLock.lock()
        defer { stateLock.unlock() }

        let layout = makeProcessingLayout(for: image)
        guard let rawChannels = convertToRGBFloatChannels(image, layout: layout) else {
            return nil
        }
        let channels = processingChannels(from: rawChannels)

        if prevLayout != layout {
            previousFrameSpectrum = nil
            prevLayout = layout
            temporalSaliencyHistory.removeAll()
        }

        guard let saliencyMap = makeTemporalSaliencyMap(from: channels, layout: layout) else {
            return nil
        }

        return makeDetectionResult(from: saliencyMap, layout: layout)
    }

    func compareImages(source: CGImage, target: CGImage) -> MotionDetectionResult? {
        stateLock.lock()
        defer { stateLock.unlock() }

        let layout = makeProcessingLayout(for: source)
        guard let rawSourceChannels = convertToRGBFloatChannels(source, layout: layout),
              let rawTargetChannels = convertToRGBFloatChannels(target, layout: layout) else {
            return nil
        }

        let sourceChannels = processingChannels(from: rawSourceChannels)
        let targetChannels = processingChannels(from: rawTargetChannels)
        guard let saliencyMap = makeSpatialSaliencyMap(sourceChannels: sourceChannels, targetChannels: targetChannels, layout: layout) else {
            return nil
        }

        return makeDetectionResult(from: saliencyMap, layout: layout)
    }

    private func makeProcessingLayout(for image: CGImage) -> ProcessingLayout {
        let sourceWidth = max(1, image.width)
        let sourceHeight = max(1, image.height)
        let longEdge = max(sourceWidth, sourceHeight)
        let effectiveDimension = max(32, Int(round(Float(maxDimension) * detectionSettings.preprocessingDownsampleScale)))
        let scale = CGFloat(effectiveDimension) / CGFloat(longEdge)

        let contentWidth = max(1, Int(round(CGFloat(sourceWidth) * scale)))
        let contentHeight = max(1, Int(round(CGFloat(sourceHeight) * scale)))
        let fftWidth = nextPowerOfTwo(for: contentWidth)
        let fftHeight = nextPowerOfTwo(for: contentHeight)
        let xOffset = (fftWidth - contentWidth) / 2
        let yOffset = (fftHeight - contentHeight) / 2

        return ProcessingLayout(
            fftWidth: fftWidth,
            fftHeight: fftHeight,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            xOffset: xOffset,
            yOffset: yOffset
        )
    }

    private func nextPowerOfTwo(for value: Int) -> Int {
        var candidate = 1
        while candidate < value {
            candidate <<= 1
        }
        return min(candidate, maxDimension)
    }

    private func makeTemporalSaliencyMap(from channels: [[Float]], layout: ProcessingLayout) -> [Float]? {
        guard let currentSpectrum = makeFrameSpectrum(from: channels, layout: layout) else {
            return nil
        }

        defer {
            previousFrameSpectrum = currentSpectrum
        }

        guard let previousFrameSpectrum,
              previousFrameSpectrum.channels.count == currentSpectrum.channels.count else {
            return nil
        }

        var channelMaps: [[Float]] = []
        for (previousChannel, currentChannel) in zip(previousFrameSpectrum.channels, currentSpectrum.channels) {
            guard let channelMap = makeBidirectionalSaliencyMap(
                previous: previousChannel,
                current: currentChannel,
                layout: layout
            ) else {
                return nil
            }
            channelMaps.append(channelMap)
        }

        guard let fusedChannels = linearlyCombineChannelMaps(channelMaps) else {
            return nil
        }

        guard detectionSettings.usesTemporalFusion else {
            temporalSaliencyHistory.removeAll()
            return fusedChannels
        }

        return fuseRecentSaliencyMaps(with: fusedChannels)
    }

    private func makeSpatialSaliencyMap(sourceChannels: [[Float]], targetChannels: [[Float]], layout: ProcessingLayout) -> [Float]? {
        guard sourceChannels.count == targetChannels.count else {
            return nil
        }

        var channelMaps: [[Float]] = []
        for (sourceChannel, targetChannel) in zip(sourceChannels, targetChannels) {
            guard let sourceSpectrum = makeSpectrum(from: sourceChannel, layout: layout),
                  let targetSpectrum = makeSpectrum(from: targetChannel, layout: layout),
                  let channelMap = makeBidirectionalSaliencyMap(previous: sourceSpectrum, current: targetSpectrum, layout: layout) else {
                return nil
            }
            channelMaps.append(channelMap)
        }

        return linearlyCombineChannelMaps(channelMaps)
    }

    private func makeDetectionResult(from saliencyMap: [Float], layout: ProcessingLayout) -> MotionDetectionResult? {
        guard let saliencyImage = imageFromFloatArray(saliencyMap, layout: layout) else {
            return nil
        }

        let boxes = boundingBoxSettings.isEnabled ? detectBoundingBoxes(in: saliencyMap, layout: layout) : []
        let boxedSaliencyImage = boxes.isEmpty ? saliencyImage : (drawBoundingBoxes(on: saliencyImage, boxes: boxes) ?? saliencyImage)

        return MotionDetectionResult(
            saliencyImage: saliencyImage,
            boxedSaliencyImage: boxedSaliencyImage,
            boundingBoxes: boxes
        )
    }

    private func detectBoundingBoxes(in saliencyMap: [Float], layout: ProcessingLayout) -> [CGRect] {
        let normalizedMap = normalize(saliencyMap)
        let binaryMask = normalizedMap.map { $0 >= boundingBoxParameters.regionThreshold ? UInt8(1) : UInt8(0) }
        let (labels, components) = connectedComponents(in: binaryMask, saliencyMap: normalizedMap, layout: layout)

        guard !components.isEmpty else { return [] }

        var candidates: [Seed] = []
        for y in layout.yOffset..<(layout.yOffset + layout.contentHeight) {
            for x in layout.xOffset..<(layout.xOffset + layout.contentWidth) {
                let index = y * layout.fftWidth + x
                let value = normalizedMap[index]
                if value >= boundingBoxParameters.seedThreshold {
                    candidates.append(Seed(x: x, y: y, value: value))
                }
            }
        }

        candidates.sort { $0.value > $1.value }

        let suppressionRadiusSquared = boundingBoxParameters.suppressionRadius * boundingBoxParameters.suppressionRadius
        var acceptedSeeds: [Seed] = []

        for candidate in candidates {
            let overlapsExistingSeed = acceptedSeeds.contains { seed in
                let dx = seed.x - candidate.x
                let dy = seed.y - candidate.y
                return (dx * dx + dy * dy) <= suppressionRadiusSquared
            }

            if overlapsExistingSeed {
                continue
            }

            acceptedSeeds.append(candidate)

            if acceptedSeeds.count >= boundingBoxParameters.maxSeedCount {
                break
            }
        }

        var selectedBoxes: [CGRect] = []
        var selectedComponentLabels = Set<Int>()

        for seed in acceptedSeeds {
            let label = labels[seed.y * layout.fftWidth + seed.x]
            guard label > 0,
                  !selectedComponentLabels.contains(label) else {
                continue
            }

            let component = components[label - 1]
            guard component.area >= boundingBoxParameters.minArea,
                  let rect = makeRect(for: component, layout: layout) else {
                continue
            }

            selectedComponentLabels.insert(label)
            selectedBoxes.append(rect)

            if selectedBoxes.count >= boundingBoxParameters.maxBoxes {
                break
            }
        }

        if selectedBoxes.isEmpty {
            let fallbackBoxes = components
                .filter { $0.area >= boundingBoxParameters.minArea && $0.maxValue >= boundingBoxParameters.seedThreshold }
                .compactMap { makeRect(for: $0, layout: layout) }
                .prefix(boundingBoxParameters.maxBoxes)
            selectedBoxes = Array(fallbackBoxes)
        }

        return selectedBoxes
    }

    private func connectedComponents(in binaryMask: [UInt8], saliencyMap: [Float], layout: ProcessingLayout) -> ([Int], [ConnectedComponent]) {
        var labels = [Int](repeating: 0, count: binaryMask.count)
        var components: [ConnectedComponent] = []
        var queue: [Int] = []
        var nextLabel = 1

        for startY in layout.yOffset..<(layout.yOffset + layout.contentHeight) {
            for startX in layout.xOffset..<(layout.xOffset + layout.contentWidth) {
                let startIndex = startY * layout.fftWidth + startX
                guard binaryMask[startIndex] != 0, labels[startIndex] == 0 else {
                    continue
                }

                labels[startIndex] = nextLabel
                queue.removeAll(keepingCapacity: true)
                queue.append(startIndex)

                var queueIndex = 0
                var component = ConnectedComponent(
                    minX: layout.fftWidth,
                    minY: layout.fftHeight,
                    maxX: 0,
                    maxY: 0,
                    area: 0,
                    maxValue: 0
                )

                while queueIndex < queue.count {
                    let currentIndex = queue[queueIndex]
                    queueIndex += 1

                    let x = currentIndex % layout.fftWidth
                    let y = currentIndex / layout.fftWidth

                    component.minX = min(component.minX, x)
                    component.minY = min(component.minY, y)
                    component.maxX = max(component.maxX, x)
                    component.maxY = max(component.maxY, y)
                    component.area += 1
                    component.maxValue = max(component.maxValue, saliencyMap[currentIndex])

                    let minY = max(layout.yOffset, y - 1)
                    let maxY = min(layout.yOffset + layout.contentHeight - 1, y + 1)
                    let minX = max(layout.xOffset, x - 1)
                    let maxX = min(layout.xOffset + layout.contentWidth - 1, x + 1)

                    for neighborY in minY...maxY {
                        for neighborX in minX...maxX {
                            let neighborIndex = neighborY * layout.fftWidth + neighborX
                            guard binaryMask[neighborIndex] != 0,
                                  labels[neighborIndex] == 0 else {
                                continue
                            }

                            labels[neighborIndex] = nextLabel
                            queue.append(neighborIndex)
                        }
                    }
                }

                components.append(component)
                nextLabel += 1
            }
        }

        return (labels, components)
    }

    private func makeRect(for component: ConnectedComponent, layout: ProcessingLayout) -> CGRect? {
        let rawRect = CGRect(
            x: component.minX,
            y: component.minY,
            width: component.maxX - component.minX + 1,
            height: component.maxY - component.minY + 1
        )

        let paddedRect = rawRect
            .insetBy(dx: -boundingBoxParameters.padding, dy: -boundingBoxParameters.padding)
            .intersection(layout.contentRect)

        guard !paddedRect.isNull, !paddedRect.isEmpty else {
            return nil
        }

        return paddedRect.offsetBy(dx: -CGFloat(layout.xOffset), dy: -CGFloat(layout.yOffset))
    }

    private func normalize(_ data: [Float]) -> [Float] {
        var maxValue: Float = 0
        vDSP_maxv(data, 1, &maxValue, vDSP_Length(data.count))

        guard maxValue > 0 else {
            return [Float](repeating: 0, count: data.count)
        }

        var normalized = [Float](repeating: 0, count: data.count)
        var divisor = maxValue
        vDSP_vsdiv(data, 1, &divisor, &normalized, 1, vDSP_Length(data.count))
        return normalized
    }

    private func sanitize(_ settings: BoundingBoxSettings) -> BoundingBoxSettings {
        let defaults = BoundingBoxSettings.defaults(for: maxDimension)
        return BoundingBoxSettings(
            isEnabled: settings.isEnabled,
            suppressionRadius: max(1, settings.suppressionRadius),
            seedThreshold: min(max(settings.seedThreshold, 0.01), 1.0),
            regionThreshold: min(max(settings.regionThreshold, 0.01), 1.0),
            minArea: max(1, settings.minArea),
            maxSeedCount: max(1, settings.maxSeedCount),
            maxBoxes: max(1, settings.maxBoxes),
            padding: max(1, settings.padding == 0 ? defaults.padding : settings.padding)
        )
    }

    private func sanitize(_ settings: DetectionSettings) -> DetectionSettings {
        DetectionSettings(
            usesColorChannelFusion: settings.usesColorChannelFusion,
            usesTemporalFusion: settings.usesTemporalFusion,
            temporalFusionFrameCount: min(max(settings.temporalFusionFrameCount, 1), 12),
            preprocessingDownsampleScale: min(max(settings.preprocessingDownsampleScale, 0.2), 1.0)
        )
    }

    private func processingChannels(from channels: [[Float]]) -> [[Float]] {
        guard detectionSettings.usesColorChannelFusion else {
            return [luminanceChannel(from: channels)]
        }
        return channels
    }

    private func luminanceChannel(from channels: [[Float]]) -> [Float] {
        guard channels.count >= 3,
              channels[0].count == channels[1].count,
              channels[1].count == channels[2].count else {
            return channels.first ?? []
        }

        let count = channels[0].count
        var luminance = [Float](repeating: 0, count: count)
        for index in 0..<count {
            luminance[index] = channels[0][index] * 0.299 + channels[1][index] * 0.587 + channels[2][index] * 0.114
        }
        return luminance
    }

    private func makeFrameSpectrum(from channels: [[Float]], layout: ProcessingLayout) -> FrameSpectrumState? {
        var spectra: [ChannelSpectrum] = []
        spectra.reserveCapacity(channels.count)

        for channel in channels {
            guard let spectrum = makeSpectrum(from: channel, layout: layout) else {
                return nil
            }
            spectra.append(spectrum)
        }

        return FrameSpectrumState(channels: spectra)
    }

    private func makeSpectrum(from source: [Float], layout: ProcessingLayout) -> ChannelSpectrum? {
        let count = layout.pixelCount
        var real = source
        var imag = [Float](repeating: 0, count: count)
        var amplitude: [Float] = []
        var phase: [Float] = []

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress else {
                    return
                }

                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft2d_zip(
                    fftSetup,
                    &split,
                    1,
                    0,
                    layout.log2Width,
                    layout.log2Height,
                    FFTDirection(kFFTDirection_Forward)
                )

                amplitude = [Float](repeating: 0, count: count)
                phase = [Float](repeating: 0, count: count)
                vDSP_zvabs(&split, 1, &amplitude, 1, vDSP_Length(count))
                vDSP_zvphas(&split, 1, &phase, 1, vDSP_Length(count))
            }
        }

        guard !amplitude.isEmpty, !phase.isEmpty else {
            return nil
        }

        return ChannelSpectrum(amplitude: amplitude, phase: phase)
    }

    private func makeBidirectionalSaliencyMap(previous: ChannelSpectrum, current: ChannelSpectrum, layout: ProcessingLayout) -> [Float]? {
        guard previous.amplitude.count == current.amplitude.count,
              previous.phase.count == current.phase.count else {
            return nil
        }

        var amplitudeDifference = [Float](repeating: 0, count: current.amplitude.count)
        vDSP_vsub(previous.amplitude, 1, current.amplitude, 1, &amplitudeDifference, 1, vDSP_Length(current.amplitude.count))

        guard let previousPhaseMap = reconstructSaliencyMap(
            amplitudeDifference: amplitudeDifference,
            phase: previous.phase,
            layout: layout
        ),
        let currentPhaseMap = reconstructSaliencyMap(
            amplitudeDifference: amplitudeDifference,
            phase: current.phase,
            layout: layout
        ) else {
            return nil
        }

        let normalizedPrevious = normalize(previousPhaseMap)
        let normalizedCurrent = normalize(currentPhaseMap)
        var combined = [Float](repeating: 0, count: normalizedPrevious.count)
        vDSP_vmul(normalizedPrevious, 1, normalizedCurrent, 1, &combined, 1, vDSP_Length(combined.count))
        return normalize(combined)
    }

    private func reconstructSaliencyMap(amplitudeDifference: [Float], phase: [Float], layout: ProcessingLayout) -> [Float]? {
        let count = layout.pixelCount
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)

        var cosPhase = [Float](repeating: 0, count: count)
        var sinPhase = [Float](repeating: 0, count: count)
        var count32 = Int32(count)
        vvcosf(&cosPhase, phase, &count32)
        vvsinf(&sinPhase, phase, &count32)

        vDSP_vmul(amplitudeDifference, 1, cosPhase, 1, &real, 1, vDSP_Length(count))
        vDSP_vmul(amplitudeDifference, 1, sinPhase, 1, &imag, 1, vDSP_Length(count))

        var resultMap: [Float] = []
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress else {
                    return
                }

                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft2d_zip(
                    fftSetup,
                    &split,
                    1,
                    0,
                    layout.log2Width,
                    layout.log2Height,
                    FFTDirection(kFFTDirection_Inverse)
                )

                resultMap = [Float](repeating: 0, count: count)
                vDSP_zvabs(&split, 1, &resultMap, 1, vDSP_Length(count))
            }
        }

        return resultMap.isEmpty ? nil : resultMap
    }

    private func linearlyCombineChannelMaps(_ channelMaps: [[Float]]) -> [Float]? {
        guard let first = channelMaps.first else {
            return nil
        }

        let count = first.count
        var combined = [Float](repeating: 0, count: count)

        for map in channelMaps {
            guard map.count == count else {
                return nil
            }

            let normalized = normalize(map)
            vDSP_vadd(combined, 1, normalized, 1, &combined, 1, vDSP_Length(count))
        }

        var divisor = Float(channelMaps.count)
        vDSP_vsdiv(combined, 1, &divisor, &combined, 1, vDSP_Length(count))
        return normalize(combined)
    }

    private func fuseRecentSaliencyMaps(with currentMap: [Float]) -> [Float] {
        let normalizedCurrent = normalize(currentMap)
        temporalSaliencyHistory.append(normalizedCurrent)

        let window = max(1, detectionSettings.temporalFusionFrameCount)
        if temporalSaliencyHistory.count > window {
            temporalSaliencyHistory.removeFirst(temporalSaliencyHistory.count - window)
        }

        let count = normalizedCurrent.count
        var fused = [Float](repeating: 0, count: count)
        var weightSum: Float = 0

        for (index, map) in temporalSaliencyHistory.enumerated() {
            let weight = Float(index + 1)
            weightSum += weight

            var weightedMap = [Float](repeating: 0, count: count)
            var mutableWeight = weight
            vDSP_vsmul(map, 1, &mutableWeight, &weightedMap, 1, vDSP_Length(count))
            vDSP_vadd(fused, 1, weightedMap, 1, &fused, 1, vDSP_Length(count))
        }

        var divisor = max(weightSum, 1)
        vDSP_vsdiv(fused, 1, &divisor, &fused, 1, vDSP_Length(count))
        return normalize(fused)
    }

    private func drawBoundingBoxes(on image: PlatformImage, boxes: [CGRect]) -> PlatformImage? {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { rendererContext in
            let drawRect = CGRect(origin: .zero, size: image.size)
            image.draw(in: drawRect)

            let context = rendererContext.cgContext
            context.setShouldAntialias(true)
            context.setLineWidth(max(2, min(image.size.width, image.size.height) / 128))

            for box in boxes {
                context.setFillColor(PlatformColor.systemRed.withAlphaComponent(0.12).cgColor)
                context.fill(box)
                context.setStrokeColor(PlatformColor.systemYellow.cgColor)
                context.stroke(box)
            }
        }
        #elseif canImport(AppKit)
        let result = PlatformImage(size: image.size)
        result.lockFocus()
        defer { result.unlockFocus() }

        let drawRect = CGRect(origin: .zero, size: image.size)
        image.draw(in: drawRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            return result
        }

        context.setShouldAntialias(true)
        context.setLineWidth(max(2, min(image.size.width, image.size.height) / 128))

        for box in boxes {
            context.setFillColor(PlatformColor.systemRed.withAlphaComponent(0.12).cgColor)
            context.fill(box)
            context.setStrokeColor(PlatformColor.systemYellow.cgColor)
            context.stroke(box)
        }

        return result
        #endif
    }

    private func convertToRGBFloatChannels(_ image: CGImage, layout: ProcessingLayout) -> [[Float]]? {
        let bitsPerComponent = 8
        let bytesPerPixel = 4
        let bytesPerRow = layout.fftWidth * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: layout.pixelCount * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        guard let context = CGContext(
            data: &pixelData,
            width: layout.fftWidth,
            height: layout.fftHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.setFillColor(PlatformColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: layout.fftWidth, height: layout.fftHeight))
        context.draw(image, in: layout.contentRect)

        let scale: Float = 1.0 / 255.0
        var red = [Float](repeating: 0, count: layout.pixelCount)
        var green = [Float](repeating: 0, count: layout.pixelCount)
        var blue = [Float](repeating: 0, count: layout.pixelCount)

        for index in 0..<layout.pixelCount {
            let base = index * bytesPerPixel
            red[index] = Float(pixelData[base]) * scale
            green[index] = Float(pixelData[base + 1]) * scale
            blue[index] = Float(pixelData[base + 2]) * scale
        }

        return [red, green, blue]
    }

    private func imageFromFloatArray(_ data: [Float], layout: ProcessingLayout) -> PlatformImage? {
        var maxValue: Float = 0
        vDSP_maxv(data, 1, &maxValue, vDSP_Length(data.count))

        let scale: Float = maxValue > 0 ? 255.0 / maxValue : 0
        var scaledData = [Float](repeating: 0, count: data.count)
        var mutableScale = scale
        vDSP_vsmul(data, 1, &mutableScale, &scaledData, 1, vDSP_Length(data.count))

        var fullPixelData = [UInt8](repeating: 0, count: data.count)
        vDSP_vfixu8(scaledData, 1, &fullPixelData, 1, vDSP_Length(data.count))

        var croppedPixelData = [UInt8](repeating: 0, count: layout.contentWidth * layout.contentHeight)
        for row in 0..<layout.contentHeight {
            let sourceStart = (row + layout.yOffset) * layout.fftWidth + layout.xOffset
            let targetStart = row * layout.contentWidth
            for column in 0..<layout.contentWidth {
                croppedPixelData[targetStart + column] = fullPixelData[sourceStart + column]
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &croppedPixelData,
            width: layout.contentWidth,
            height: layout.contentHeight,
            bitsPerComponent: 8,
            bytesPerRow: layout.contentWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        guard let cgImage = context.makeImage() else {
            return nil
        }

        return PlatformImage.from(cgImage: cgImage)
    }
}
