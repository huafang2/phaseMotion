#if os(macOS)
import SwiftUI
import AVFoundation
import AppKit
import Combine

final class MacCameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    @Published var resultImage: PlatformImage?
    @Published var statusText: String = "准备启动相机..."
    @Published var selectedResolution: Int = 256
    @Published var detectionSettings = MotionDetector.DetectionSettings.default
    @Published var boundingBoxSettings = MotionDetector.BoundingBoxSettings.defaults(for: 256)

    private var detector = MotionDetector(size: 256)
    private let context = CIContext(options: nil)
    private let captureQueue = DispatchQueue(label: "com.phasemotion.maccamera")
    private var isConfigured = false

    override init() {
        super.init()
        detector.updateDetectionSettings(detectionSettings)
        detector.updateBoundingBoxSettings(boundingBoxSettings)
    }

    func start() {
        guard !isConfigured else {
            if !session.isRunning {
                session.startRunning()
            }
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if granted {
                    self.configureSession()
                } else {
                    self.statusText = "未获得相机权限"
                }
            }
        }
    }

    func updateResolution(_ resolution: Int) {
        guard selectedResolution != resolution else { return }
        selectedResolution = resolution

        let currentBoundingBoxes = detector.currentBoundingBoxSettings
        let currentDetectionSettings = detectionSettings
        boundingBoxSettings = currentBoundingBoxes
        detector = MotionDetector(size: resolution)
        detector.updateBoundingBoxSettings(currentBoundingBoxes)
        detector.updateDetectionSettings(currentDetectionSettings)
        statusText = "分辨率已切换到 \(resolution)"
    }

    func updateDetectionSettings(_ settings: MotionDetector.DetectionSettings) {
        detectionSettings = settings
        detector.updateDetectionSettings(settings)
        statusText = settings.usesTemporalFusion
            ? "算法增强已更新: RGB \(settings.usesColorChannelFusion ? "开" : "关") / \(settings.temporalFusionFrameCount) 帧 / 下采样 \(formattedDownsample(settings.preprocessingDownsampleScale))"
            : "算法增强已更新: RGB \(settings.usesColorChannelFusion ? "开" : "关") / 多帧关闭 / 下采样 \(formattedDownsample(settings.preprocessingDownsampleScale))"
    }

    func updateBoundingBoxSettings(_ settings: MotionDetector.BoundingBoxSettings) {
        boundingBoxSettings = settings
        detector.updateBoundingBoxSettings(settings)
        statusText = settings.isEnabled
            ? "Bounding Box 已开启"
            : "Bounding Box 已关闭"
    }

    private func formattedDownsample(_ scale: Float) -> String {
        let effectiveLongEdge = max(32, Int(round(Float(selectedResolution) * scale)))
        return scale >= 0.995
            ? "关闭 / \(effectiveLongEdge)px"
            : String(format: "%.2fx / %dpx", scale, effectiveLongEdge)
    }

    private func configureSession() {
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            statusText = "无法访问相机"
            return
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (device.position == .front)
            }
        } else {
            session.commitConfiguration()
            statusText = "无法添加输出"
            return
        }

        session.commitConfiguration()
        session.startRunning()
        statusText = "运行中"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        if let detectionResult = detector.processFrame(cgImage) {
            DispatchQueue.main.async { [weak self] in
                self?.resultImage = detectionResult.boxedSaliencyImage
            }
        }
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        view.layer?.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.previewLayer?.frame = nsView.bounds
    }

    final class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

struct MacCameraView: View {
    @StateObject private var model = MacCameraViewModel()
    @State private var showsSettings = true

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 16) {
                desktopStage(title: "实时取景") {
                    CameraPreviewView(session: model.session)
                        .frame(minWidth: 420, minHeight: 420)
                        .background(Color.black.opacity(0.82))
                }

                desktopStage(title: "Phase Output") {
                    Group {
                        if let image = model.resultImage {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Color.black.opacity(0.6)
                        }
                    }
                    .frame(minWidth: 420, minHeight: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsSettings {
                settingsPanel
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(minWidth: 1080, minHeight: 720)
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.12), Color(red: 0.03, green: 0.03, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .topLeading) {
            Text(model.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.24), in: Capsule())
                .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            Button(showsSettings ? "隐藏设置" : "设置") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsSettings.toggle()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint.opacity(0.85))
            .padding(14)
        }
        .onAppear {
            model.start()
        }
    }

    private func desktopStage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: Capsule())

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("设置")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()
                }

                settingsSection(title: "算法") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("分析分辨率")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.76))

                        Picker("分析分辨率", selection: Binding(
                            get: { model.selectedResolution },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateResolution(newValue)
                                }
                            }
                        )) {
                            Text("256").tag(256)
                            Text("512").tag(512)
                            Text("1024").tag(1024)
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("颜色通道联合", isOn: Binding(
                        get: { model.detectionSettings.usesColorChannelFusion },
                        set: { newValue in
                            DispatchQueue.main.async {
                                model.updateDetectionSettings(updatedDetectionSettings(colorFusion: newValue))
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .foregroundColor(.white)

                    Toggle("相邻多帧联合", isOn: Binding(
                        get: { model.detectionSettings.usesTemporalFusion },
                        set: { newValue in
                            DispatchQueue.main.async {
                                model.updateDetectionSettings(updatedDetectionSettings(temporalFusion: newValue))
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .foregroundColor(.white)

                    sliderGroup(
                        title: "联合帧数 \(model.detectionSettings.temporalFusionFrameCount)",
                        value: Binding(
                            get: { Double(model.detectionSettings.temporalFusionFrameCount) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateDetectionSettings(
                                        updatedDetectionSettings(frameCount: Int(round(newValue)))
                                    )
                                }
                            }
                        ),
                        range: 1...12,
                        step: 1
                    )

                    sliderGroup(
                        title: downsampleSummary,
                        value: Binding(
                            get: { Double(model.detectionSettings.preprocessingDownsampleScale) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateDetectionSettings(
                                        updatedDetectionSettings(downsample: Float(newValue))
                                    )
                                }
                            }
                        ),
                        range: 0.2...1.0,
                        step: 0.05
                    )
                }

                settingsSection(title: "Bounding Box") {
                    Toggle("显示 Bounding Box", isOn: Binding(
                        get: { model.boundingBoxSettings.isEnabled },
                        set: { newValue in
                            DispatchQueue.main.async {
                                model.updateBoundingBoxSettings(updatedBoundingBoxSettings(isEnabled: newValue))
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .foregroundColor(.white)

                    sliderGroup(
                        title: String(format: "Seed 阈值 %.2f", model.boundingBoxSettings.seedThreshold),
                        value: Binding(
                            get: { Double(model.boundingBoxSettings.seedThreshold) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateBoundingBoxSettings(
                                        updatedBoundingBoxSettings(seedThreshold: Float(newValue))
                                    )
                                }
                            }
                        ),
                        range: 0.10...0.95,
                        step: 0.01
                    )

                    sliderGroup(
                        title: String(format: "Region 阈值 %.2f", model.boundingBoxSettings.regionThreshold),
                        value: Binding(
                            get: { Double(model.boundingBoxSettings.regionThreshold) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateBoundingBoxSettings(
                                        updatedBoundingBoxSettings(regionThreshold: Float(newValue))
                                    )
                                }
                            }
                        ),
                        range: 0.05...0.90,
                        step: 0.01
                    )

                    sliderGroup(
                        title: "抑制半径 \(model.boundingBoxSettings.suppressionRadius)",
                        value: Binding(
                            get: { Double(model.boundingBoxSettings.suppressionRadius) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateBoundingBoxSettings(
                                        updatedBoundingBoxSettings(suppressionRadius: Int(round(newValue)))
                                    )
                                }
                            }
                        ),
                        range: suppressionRadiusRange(for: model.selectedResolution),
                        step: 1
                    )

                    sliderGroup(
                        title: "最小面积 \(model.boundingBoxSettings.minArea)",
                        value: Binding(
                            get: { Double(model.boundingBoxSettings.minArea) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateBoundingBoxSettings(
                                        updatedBoundingBoxSettings(minArea: Int(round(newValue)))
                                    )
                                }
                            }
                        ),
                        range: minAreaRange(for: model.selectedResolution),
                        step: 1
                    )

                    sliderGroup(
                        title: "最多框数 \(model.boundingBoxSettings.maxBoxes)",
                        value: Binding(
                            get: { Double(model.boundingBoxSettings.maxBoxes) },
                            set: { newValue in
                                DispatchQueue.main.async {
                                    model.updateBoundingBoxSettings(
                                        updatedBoundingBoxSettings(maxBoxes: Int(round(newValue)))
                                    )
                                }
                            }
                        ),
                        range: 1...12,
                        step: 1
                    )

                    Button("重置 Bounding Box 参数") {
                        DispatchQueue.main.async {
                            model.updateBoundingBoxSettings(
                                MotionDetector.BoundingBoxSettings.defaults(for: model.selectedResolution)
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.16))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func updatedDetectionSettings(
        colorFusion: Bool? = nil,
        temporalFusion: Bool? = nil,
        frameCount: Int? = nil,
        downsample: Float? = nil
    ) -> MotionDetector.DetectionSettings {
        MotionDetector.DetectionSettings(
            usesColorChannelFusion: colorFusion ?? model.detectionSettings.usesColorChannelFusion,
            usesTemporalFusion: temporalFusion ?? model.detectionSettings.usesTemporalFusion,
            temporalFusionFrameCount: frameCount ?? model.detectionSettings.temporalFusionFrameCount,
            preprocessingDownsampleScale: downsample ?? model.detectionSettings.preprocessingDownsampleScale
        )
    }

    private func updatedBoundingBoxSettings(
        isEnabled: Bool? = nil,
        suppressionRadius: Int? = nil,
        seedThreshold: Float? = nil,
        regionThreshold: Float? = nil,
        minArea: Int? = nil,
        maxBoxes: Int? = nil
    ) -> MotionDetector.BoundingBoxSettings {
        MotionDetector.BoundingBoxSettings(
            isEnabled: isEnabled ?? model.boundingBoxSettings.isEnabled,
            suppressionRadius: suppressionRadius ?? model.boundingBoxSettings.suppressionRadius,
            seedThreshold: seedThreshold ?? model.boundingBoxSettings.seedThreshold,
            regionThreshold: regionThreshold ?? model.boundingBoxSettings.regionThreshold,
            minArea: minArea ?? model.boundingBoxSettings.minArea,
            maxSeedCount: model.boundingBoxSettings.maxSeedCount,
            maxBoxes: maxBoxes ?? model.boundingBoxSettings.maxBoxes,
            padding: model.boundingBoxSettings.padding
        )
    }

    private var downsampleSummary: String {
        let scale = model.detectionSettings.preprocessingDownsampleScale
        let effectiveLongEdge = max(32, Int(round(Float(model.selectedResolution) * scale)))
        return scale >= 0.995
            ? "预下采样 关闭 / \(effectiveLongEdge)px"
            : String(format: "预下采样 %.2fx / %dpx", scale, effectiveLongEdge)
    }

    private func suppressionRadiusRange(for size: Int) -> ClosedRange<Double> {
        let upperBound = max(8, size / 8)
        return 1...Double(upperBound)
    }

    private func minAreaRange(for size: Int) -> ClosedRange<Double> {
        let upperBound = max(32, (size * size) / 16)
        return 1...Double(upperBound)
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.76))

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sliderGroup(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.82))

            Slider(value: value, in: range, step: step)
        }
    }
}
#endif
