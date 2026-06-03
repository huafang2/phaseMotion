// Author: Jau

#if canImport(UIKit)
import UIKit
@preconcurrency import AVFoundation
import CoreMedia
import AVKit
import PhotosUI
import UniformTypeIdentifiers

class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    enum FullscreenStage {
        case preview
        case result
    }
    
    // MARK: - Properties
    let backgroundGradientLayer = CAGradientLayer()
    var captureSession: AVCaptureSession?
    var detector = MotionDetector(size: 256)
    var recorder: VideoRecorder?
    var isRecording = false
    
    // 状态记录
    var currentResolution: Int = 256
    var includeRawVideo: Bool = false
    var detectionSettings = MotionDetector.DetectionSettings.default
    var boundingBoxSettings = MotionDetector.BoundingBoxSettings.defaults(for: 256)
    
    // 性能优化：复用 Context
    let context = CIContext(options: nil)
    let sessionQueue = DispatchQueue(label: "com.phasemotion.camera.session")
    let videoOutputQueue = DispatchQueue(label: "com.phasemotion.camera.video")
    
    // 定义摄像头选项结构体
    struct CameraOption {
        let title: String
        let position: AVCaptureDevice.Position
        let deviceType: AVCaptureDevice.DeviceType
    }
    
    // 当前设备可用的摄像头列表
    var availableCameras: [CameraOption] = []
    
    // MARK: - UI Elements
    let topHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let previewView = UIView()
    let resultImageView = UIImageView()
    let previewCanvasView = UIView()
    let resultCanvasView = UIImageView()
    let previewContentView = UIView()
    let resultContentImageView = UIImageView()
    let previewBadgeLabel = UILabel()
    let previewSubtitleLabel = UILabel()
    let resultBadgeLabel = UILabel()
    let resultSubtitleLabel = UILabel()
    let controlsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    let controlsTitleLabel = UILabel()
    let controlsSubtitleLabel = UILabel()
    let rawCaptionLabel = UILabel()
    let zoomCaptionLabel = UILabel()
    let zoomValueLabel = UILabel()
    let zoomSlider = UISlider()
    let downsampleCaptionLabel = UILabel()
    let downsampleValueSummaryLabel = UILabel()
    let downsampleMainSlider = UISlider()
    let recordHintLabel = UILabel()
    let recordButton = UIButton()
    let resolutionMenuButton = UIButton(type: .system)
    let boundingBoxSettingsButton = UIButton(type: .system)
    let importVideoButton = UIButton(type: .system)
    let boundingBoxPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    let boundingBoxScrollView = UIScrollView()
    let boundingBoxTitleLabel = UILabel()
    let boundingBoxResetButton = UIButton(type: .system)
    let boundingBoxDoneButton = UIButton(type: .system)
    let colorFusionLabel = UILabel()
    let colorFusionSwitch = UISwitch()
    let temporalFusionLabel = UILabel()
    let temporalFusionSwitch = UISwitch()
    let temporalFrameCountLabel = UILabel()
    let temporalFrameCountValueLabel = UILabel()
    let temporalFrameCountSlider = UISlider()
    let showBoundingBoxLabel = UILabel()
    let showBoundingBoxSwitch = UISwitch()
    let seedThresholdLabel = UILabel()
    let seedThresholdValueLabel = UILabel()
    let seedThresholdSlider = UISlider()
    let regionThresholdLabel = UILabel()
    let regionThresholdValueLabel = UILabel()
    let regionThresholdSlider = UISlider()
    let suppressionRadiusLabel = UILabel()
    let suppressionRadiusValueLabel = UILabel()
    let suppressionRadiusSlider = UISlider()
    let minAreaLabel = UILabel()
    let minAreaValueLabel = UILabel()
    let minAreaSlider = UISlider()
    let maxBoxesLabel = UILabel()
    let maxBoxesValueLabel = UILabel()
    let maxBoxesSlider = UISlider()
    
    // 原片录制开关
    let rawSwitch = UISwitch()
    let rawLabel = UILabel()
    
    // 摄像头选择器
    let cameraControl = UISegmentedControl(items: [])
    // 【新增】毛玻璃背景 (模拟 iOS 原生相机 HUD 风格)
    // 使用 .systemUltraThinMaterialDark 提供极薄的深色磨砂效果，非常有科技感且遮挡感低
    let cameraControlBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    let fullscreenBackdropView = UIView()
    let fullscreenHintLabel = UILabel()
    let importProgressView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    let importProgressLabel = UILabel()
    let importProgressSpinner = UIActivityIndicatorView(style: .medium)
    let clearTempFilesButton = UIButton(type: .system)
    var displayZoomScale: CGFloat = 1.0
    var displayContentOffset: CGPoint = .zero
    var fullscreenStage: FullscreenStage?
    var importedVideoProcessor: ImportedVideoSaliencyProcessor?
    var isImportingVideo = false
    var importedPlaybackCleanupURLs: [URL] = []
    var importedSourceCleanupURL: URL?
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupAvailableCameras() // 先检测摄像头
        setupUI()
        purgeStaleTemporaryMediaFiles()
        checkPermissions()
        
        // 初始化默认配置
        refreshResolutionMenu()
        updateRecordingConfiguration()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        let w = view.bounds.width
        let h = view.bounds.height
        let isLandscape = w > h
        let safeTop = view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : 28
        let safeBottom = max(view.safeAreaInsets.bottom, 18)
        let horizontalPadding: CGFloat = 16
        let cardSpacing: CGFloat = 14

        backgroundGradientLayer.frame = view.bounds

        let topRowY = safeTop + (isLandscape ? 2 : 4)
        let topRowHeight: CGFloat = isLandscape ? 42 : 46
        let titleWidth = isLandscape
            ? min(178, max(154, w * 0.28))
            : min(158, w * 0.40)
        topHUD.frame = CGRect(
            x: horizontalPadding,
            y: topRowY,
            width: titleWidth,
            height: topRowHeight
        )
        titleLabel.frame = CGRect(x: 12, y: 6, width: topHUD.bounds.width - 24, height: 19)
        subtitleLabel.frame = CGRect(x: 12, y: 25, width: topHUD.bounds.width - 24, height: 13)

        let settingsButtonWidth: CGFloat = isLandscape ? 68 : 76
        boundingBoxSettingsButton.frame = CGRect(
            x: topHUD.frame.maxX + 8,
            y: topRowY + (isLandscape ? 1 : 2),
            width: settingsButtonWidth,
            height: isLandscape ? 30 : 32
        )

        let importButtonWidth: CGFloat = isLandscape ? 68 : 76
        if isLandscape {
            importVideoButton.frame = CGRect(
                x: boundingBoxSettingsButton.frame.maxX + 6,
                y: topRowY + 1,
                width: importButtonWidth,
                height: 30
            )
        } else {
            importVideoButton.frame = .zero
        }

        let controlHeight: CGFloat = isLandscape ? 30 : 34
        let controlX: CGFloat
        let controlWidth: CGFloat
        if isLandscape {
            let desiredWidth = min(224, max(186, w * 0.30))
            let availableWidth = w - horizontalPadding - (importVideoButton.frame.maxX + 8)
            controlWidth = max(150, min(desiredWidth, availableWidth))
            controlX = w - horizontalPadding - controlWidth
        } else {
            controlX = boundingBoxSettingsButton.frame.maxX + 8
            controlWidth = w - horizontalPadding - controlX
        }
        let controlFrame = CGRect(
            x: controlX,
            y: topRowY + (isLandscape ? 1 : 1),
            width: controlWidth,
            height: controlHeight
        )
        cameraControl.frame = controlFrame
        cameraControlBlur.frame = controlFrame
        cameraControlBlur.layer.cornerRadius = controlHeight / 2
        cameraControlBlur.layer.masksToBounds = true

        let recordButtonSize: CGFloat = isLandscape ? 60 : 72
        let bottomRowHeight: CGFloat = isLandscape ? 98 : 126
        let bottomRowY = h - safeBottom - bottomRowHeight - (isLandscape ? 8 : 12)
        let controlsPanelHeight: CGFloat = bottomRowHeight
        let controlsWidth = w - horizontalPadding * 2 - recordButtonSize - 14
        controlsPanel.frame = CGRect(x: horizontalPadding, y: bottomRowY, width: controlsWidth, height: controlsPanelHeight)
        controlsPanel.layer.cornerRadius = isLandscape ? 24 : 28
        controlsPanel.layer.masksToBounds = true

        let resolutionButtonWidth: CGFloat = isLandscape ? 84 : 98
        let resolutionButtonHeight: CGFloat = 28
        let resolutionButtonY = controlsPanel.frame.minY + 6
        resolutionMenuButton.frame = CGRect(
            x: controlsPanel.frame.maxX + 14 + (recordButtonSize - resolutionButtonWidth) / 2,
            y: resolutionButtonY,
            width: resolutionButtonWidth,
            height: resolutionButtonHeight
        )

        recordButton.frame = CGRect(
            x: controlsPanel.frame.maxX + 14,
            y: controlsPanel.frame.minY + (isLandscape ? 34 : 38),
            width: recordButtonSize,
            height: recordButtonSize
        )
        recordButton.layer.cornerRadius = recordButtonSize / 2
        recordHintLabel.frame = CGRect(x: recordButton.frame.minX - 4, y: recordButton.frame.maxY + 5, width: recordButtonSize + 8, height: 14)
        recordHintLabel.isHidden = isLandscape

        let previewTop = max(topHUD.frame.maxY, cameraControl.frame.maxY, importVideoButton.frame.maxY) + 12
        let cardsBottom = controlsPanel.frame.minY - (isLandscape ? 10 : 16)
        let availableCardsHeight = cardsBottom - previewTop
        let previewDefaultFrame: CGRect
        let resultDefaultFrame: CGRect

        if isLandscape {
            let cardWidth = max(140, (w - horizontalPadding * 2 - cardSpacing) / 2)
            let cardHeight = max(120, availableCardsHeight)
            previewDefaultFrame = CGRect(x: horizontalPadding, y: previewTop, width: cardWidth, height: cardHeight)
            resultDefaultFrame = CGRect(x: previewDefaultFrame.maxX + cardSpacing, y: previewTop, width: cardWidth, height: cardHeight)
        } else {
            let previewHeight = max(150, (availableCardsHeight - cardSpacing) / 2)
            let resultY = previewTop + previewHeight + cardSpacing
            previewDefaultFrame = CGRect(x: horizontalPadding, y: previewTop, width: w - horizontalPadding * 2, height: previewHeight)
            resultDefaultFrame = CGRect(x: horizontalPadding, y: resultY, width: w - horizontalPadding * 2, height: previewHeight)
        }

        switch fullscreenStage {
        case .preview:
            previewView.frame = fullscreenFrame(in: view.bounds, safeTop: safeTop, safeBottom: safeBottom)
            resultImageView.frame = resultDefaultFrame
        case .result:
            previewView.frame = previewDefaultFrame
            resultImageView.frame = fullscreenFrame(in: view.bounds, safeTop: safeTop, safeBottom: safeBottom)
        case nil:
            previewView.frame = previewDefaultFrame
            resultImageView.frame = resultDefaultFrame
        }

        layoutStageContents(stageView: previewView, canvasView: previewCanvasView, badgeLabel: previewBadgeLabel, subtitleLabel: previewSubtitleLabel, isLandscape: isLandscape)
        layoutStageContents(stageView: resultImageView, canvasView: resultCanvasView, badgeLabel: resultBadgeLabel, subtitleLabel: resultSubtitleLabel, isLandscape: isLandscape)

        let controlsContentWidth = controlsPanel.bounds.width
        layoutControls(panelWidth: controlsContentWidth, isLandscape: isLandscape)

        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let panelOriginX: CGFloat
        let panelOriginY: CGFloat
        if boundingBoxPanel.isHidden {
            panelWidth = min(w - 32, 268)
            panelHeight = min(max(h * 0.48, 280), 376)
            panelOriginX = min(max(horizontalPadding, boundingBoxSettingsButton.frame.maxX - panelWidth + 8), w - panelWidth - horizontalPadding)
            panelOriginY = max(cameraControl.frame.maxY + 8, controlsPanel.frame.minY - panelHeight - 12)
        } else {
            panelWidth = w - 24
            panelHeight = h - safeTop - safeBottom - 20
            panelOriginX = 12
            panelOriginY = safeTop + 10
        }
        boundingBoxPanel.frame = CGRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight)
        boundingBoxPanel.layer.cornerRadius = 18
        boundingBoxPanel.layer.masksToBounds = true

        if !isLandscape {
            importVideoButton.frame = CGRect(
                x: controlsPanel.frame.maxX - importButtonWidth - 8,
                y: controlsPanel.frame.minY + 8,
                width: importButtonWidth,
                height: 30
            )
        }

        layoutBoundingBoxPanelContent(width: panelWidth, height: panelHeight)
        fullscreenBackdropView.frame = view.bounds
        fullscreenHintLabel.frame = CGRect(x: 0, y: h - safeBottom - 34, width: w, height: 20)
        layoutImportProgressView()
        updatePreviewLayerFrame()
        applyDisplayZoom()
        updateCaptureConnectionsForCurrentOrientation()
    }
    
    // 检测设备支持的摄像头
    func setupAvailableCameras() {
        availableCameras.removeAll()

        let backWideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        
        // 1. 前置
        if let _ = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            availableCameras.append(CameraOption(title: "前置", position: .front, deviceType: .builtInWideAngleCamera))
        }
        
        // 2. 后置广角 (主摄)
        if let backWideDevice {
            availableCameras.append(CameraOption(
                title: cameraTitle(for: backWideDevice, baselineWideDevice: backWideDevice),
                position: .back,
                deviceType: .builtInWideAngleCamera
            ))
        }
        
        // 3. 后置超广角
        if let ultraWideDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            availableCameras.append(CameraOption(
                title: cameraTitle(for: ultraWideDevice, baselineWideDevice: backWideDevice),
                position: .back,
                deviceType: .builtInUltraWideCamera
            ))
        }
        
        // 4. 后置长焦
        if let telephotoDevice = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            availableCameras.append(CameraOption(
                title: cameraTitle(for: telephotoDevice, baselineWideDevice: backWideDevice),
                position: .back,
                deviceType: .builtInTelephotoCamera
            ))
        }
        
        // 填充 SegmentedControl
        cameraControl.removeAllSegments()
        for (index, option) in availableCameras.enumerated() {
            cameraControl.insertSegment(withTitle: option.title, at: index, animated: false)
        }
        
        // 默认选中后置广角
        if let backIndex = availableCameras.firstIndex(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) {
            cameraControl.selectedSegmentIndex = backIndex
        } else if !availableCameras.isEmpty {
            cameraControl.selectedSegmentIndex = 0
        }
    }

    func cameraTitle(for device: AVCaptureDevice, baselineWideDevice: AVCaptureDevice?) -> String {
        guard device.position == .back else {
            return "前置"
        }

        guard let baselineWideDevice else {
            switch device.deviceType {
            case .builtInUltraWideCamera:
                return "0.5x"
            case .builtInTelephotoCamera:
                return "Tele"
            default:
                return "1x"
            }
        }

        if device.deviceType == .builtInWideAngleCamera {
            return "1x"
        }

        let baselineFOV = Double(baselineWideDevice.activeFormat.videoFieldOfView)
        let targetFOV = Double(device.activeFormat.videoFieldOfView)

        guard baselineFOV > 0, targetFOV > 0 else {
            switch device.deviceType {
            case .builtInUltraWideCamera:
                return "0.5x"
            case .builtInTelephotoCamera:
                return "Tele"
            default:
                return "1x"
            }
        }

        let zoomFactor = tan((baselineFOV * .pi / 180.0) / 2.0) / tan((targetFOV * .pi / 180.0) / 2.0)
        return formattedZoomFactorLabel(zoomFactor)
    }

    func formattedZoomFactorLabel(_ zoomFactor: Double) -> String {
        let roundedToTenth = (zoomFactor * 10).rounded() / 10

        if abs(roundedToTenth.rounded() - roundedToTenth) < 0.06 {
            return "\(Int(roundedToTenth.rounded()))x"
        }

        return String(format: "%.1fx", roundedToTenth)
    }
    
    // MARK: - Setup UI
    func setupUI() {
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1.0)
        backgroundGradientLayer.colors = [
            UIColor(red: 0.08, green: 0.13, blue: 0.24, alpha: 1).cgColor,
            UIColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1).cgColor,
            UIColor(red: 0.11, green: 0.08, blue: 0.14, alpha: 1).cgColor
        ]
        backgroundGradientLayer.locations = [0.0, 0.48, 1.0]
        backgroundGradientLayer.startPoint = CGPoint(x: 0.1, y: 0.0)
        backgroundGradientLayer.endPoint = CGPoint(x: 0.9, y: 1.0)
        view.layer.insertSublayer(backgroundGradientLayer, at: 0)

        topHUD.layer.cornerRadius = 24
        topHUD.layer.masksToBounds = true
        view.addSubview(topHUD)

        titleLabel.text = "Phase Motion"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        topHUD.contentView.addSubview(titleLabel)

        subtitleLabel.text = "Created by Jau"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        subtitleLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        subtitleLabel.isHidden = false
        topHUD.contentView.addSubview(subtitleLabel)

        styleStageView(previewView)
        view.addSubview(previewView)

        styleCanvasView(previewCanvasView)
        previewView.addSubview(previewCanvasView)
        previewContentView.backgroundColor = .clear
        previewCanvasView.addSubview(previewContentView)

        styleStageView(resultImageView)
        resultImageView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 0.86)
        view.addSubview(resultImageView)

        styleCanvasView(resultCanvasView)
        resultImageView.addSubview(resultCanvasView)
        resultContentImageView.contentMode = .scaleAspectFit
        resultContentImageView.clipsToBounds = true
        resultCanvasView.addSubview(resultContentImageView)

        configureStageLabel(previewBadgeLabel, text: "实时取景", tint: UIColor.systemMint)
        configureStageSubtitle(previewSubtitleLabel, text: "当前相机画面")
        previewView.addSubview(previewBadgeLabel)
        previewView.addSubview(previewSubtitleLabel)

        configureStageLabel(resultBadgeLabel, text: "Phase Output", tint: UIColor.systemYellow)
        configureStageSubtitle(resultSubtitleLabel, text: "频谱运动显著图")
        resultImageView.addSubview(resultBadgeLabel)
        resultImageView.addSubview(resultSubtitleLabel)

        controlsPanel.layer.cornerRadius = 28
        controlsPanel.layer.masksToBounds = true
        view.addSubview(controlsPanel)

        controlsTitleLabel.text = "Capture Console"
        controlsTitleLabel.textColor = .white
        controlsTitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        controlsPanel.contentView.addSubview(controlsTitleLabel)

        controlsSubtitleLabel.text = "实时调整分辨率、输出方式与检测设置"
        controlsSubtitleLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        controlsSubtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        controlsPanel.contentView.addSubview(controlsSubtitleLabel)

        rawCaptionLabel.text = "原片输出"
        rawCaptionLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        rawCaptionLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        controlsPanel.contentView.addSubview(rawCaptionLabel)

        zoomCaptionLabel.text = "同步缩放"
        zoomCaptionLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        zoomCaptionLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        controlsPanel.contentView.addSubview(zoomCaptionLabel)

        downsampleCaptionLabel.text = "预下采样"
        downsampleCaptionLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        downsampleCaptionLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        controlsPanel.contentView.addSubview(downsampleCaptionLabel)

        downsampleValueSummaryLabel.textColor = .systemYellow
        downsampleValueSummaryLabel.textAlignment = .right
        downsampleValueSummaryLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        controlsPanel.contentView.addSubview(downsampleValueSummaryLabel)

        zoomValueLabel.textColor = .systemMint
        zoomValueLabel.textAlignment = .right
        zoomValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        controlsPanel.contentView.addSubview(zoomValueLabel)
        
        resolutionMenuButton.setTitleColor(.white, for: .normal)
        resolutionMenuButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        resolutionMenuButton.layer.cornerRadius = 15
        resolutionMenuButton.layer.borderWidth = 1
        resolutionMenuButton.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.35).cgColor
        resolutionMenuButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        resolutionMenuButton.showsMenuAsPrimaryAction = true
        view.addSubview(resolutionMenuButton)

        importVideoButton.setTitle("导入", for: .normal)
        importVideoButton.setTitleColor(.white, for: .normal)
        importVideoButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        importVideoButton.layer.cornerRadius = 15
        importVideoButton.layer.borderWidth = 1
        importVideoButton.layer.borderColor = UIColor.systemMint.withAlphaComponent(0.32).cgColor
        importVideoButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        importVideoButton.addTarget(self, action: #selector(importVideoTapped), for: .touchUpInside)
        view.addSubview(importVideoButton)
        
        // 开关和标签
        rawSwitch.onTintColor = .systemMint
        rawSwitch.addTarget(self, action: #selector(configChanged), for: .valueChanged)
        controlsPanel.contentView.addSubview(rawSwitch)
        
        rawLabel.text = "录制时拼接原画面"
        rawLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        rawLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        controlsPanel.contentView.addSubview(rawLabel)

        zoomSlider.minimumValue = 0.6
        zoomSlider.maximumValue = 4.0
        zoomSlider.value = Float(displayZoomScale)
        zoomSlider.minimumTrackTintColor = .systemMint
        zoomSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.18)
        zoomSlider.addTarget(self, action: #selector(displayZoomChanged), for: .valueChanged)
        controlsPanel.contentView.addSubview(zoomSlider)

        downsampleMainSlider.minimumValue = 0.2
        downsampleMainSlider.maximumValue = 1.0
        downsampleMainSlider.minimumTrackTintColor = .systemYellow
        downsampleMainSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.18)
        downsampleMainSlider.addTarget(self, action: #selector(boundingBoxControlsChanged), for: .valueChanged)
        controlsPanel.contentView.addSubview(downsampleMainSlider)
        updateZoomLabel()

        recordHintLabel.text = "Tap to record"
        recordHintLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        recordHintLabel.textAlignment = .center
        recordHintLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        view.addSubview(recordHintLabel)
        
        // 录制按钮
        recordButton.backgroundColor = UIColor.systemRed
        recordButton.layer.borderWidth = 6
        recordButton.layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        recordButton.layer.shadowColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
        recordButton.layer.shadowOpacity = 0.9
        recordButton.layer.shadowRadius = 22
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 10)
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)
        
        // 【修改】摄像头选择器样式
        cameraControl.backgroundColor = .clear
        cameraControl.selectedSegmentTintColor = UIColor.systemMint.withAlphaComponent(0.28)
        cameraControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .medium)], for: .normal)
        cameraControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)], for: .selected)
        cameraControl.addTarget(self, action: #selector(cameraSelectionChanged), for: .valueChanged)
        
        cameraControlBlur.alpha = 0.78
        
        view.addSubview(cameraControlBlur)
        view.addSubview(cameraControl)

        setupFullscreenUI()
        setupImportProgressUI()
        setupInteractionGestures()
        setupBoundingBoxUI()
    }

    func styleStageView(_ view: UIView) {
        view.layer.cornerRadius = 30
        view.layer.masksToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        view.backgroundColor = UIColor.white.withAlphaComponent(0.03)
    }

    func styleCanvasView(_ view: UIView) {
        view.layer.cornerRadius = 22
        view.layer.masksToBounds = true
        view.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    }

    func configureStageLabel(_ label: UILabel, text: String, tint: UIColor) {
        label.text = "  \(text)  "
        label.textColor = tint
        label.backgroundColor = tint.withAlphaComponent(0.12)
        label.layer.cornerRadius = 13
        label.layer.masksToBounds = true
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
    }

    func configureStageSubtitle(_ label: UILabel, text: String) {
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.72)
        label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    }

    func layoutStageContents(stageView: UIView, canvasView: UIView, badgeLabel: UILabel, subtitleLabel: UILabel, isLandscape: Bool) {
        let topInset: CGFloat = isLandscape ? 10 : 12
        let sideInset: CGFloat = isLandscape ? 10 : 12
        let bottomInset: CGFloat = isLandscape ? 10 : 12
        canvasView.frame = CGRect(
            x: sideInset,
            y: topInset,
            width: stageView.bounds.width - sideInset * 2,
            height: stageView.bounds.height - topInset - bottomInset
        )
        badgeLabel.frame = CGRect(
            x: isLandscape ? 16 : 20,
            y: isLandscape ? 14 : 18,
            width: min(stageView.bounds.width - (isLandscape ? 32 : 40), isLandscape ? 144 : 180),
            height: isLandscape ? 24 : 26
        )
        subtitleLabel.isHidden = isLandscape
        subtitleLabel.frame = CGRect(x: 20, y: badgeLabel.frame.maxY + 4, width: min(stageView.bounds.width - 40, 230), height: 18)

        // Fullscreen toggle changes the canvas bounds. Reset content transforms before
        // laying out their base frames so the visual zoom state can be reapplied cleanly.
        previewContentView.transform = .identity
        resultContentImageView.transform = .identity
        previewContentView.frame = previewCanvasView.bounds
        previewContentView.center = CGPoint(x: previewCanvasView.bounds.midX, y: previewCanvasView.bounds.midY)
        resultContentImageView.frame = resultCanvasView.bounds
        resultContentImageView.center = CGPoint(x: resultCanvasView.bounds.midX, y: resultCanvasView.bounds.midY)
    }

    func layoutControls(panelWidth: CGFloat, isLandscape: Bool) {
        controlsTitleLabel.isHidden = isLandscape
        controlsSubtitleLabel.isHidden = true
        rawCaptionLabel.isHidden = false

        if isLandscape {
            let rawRowY: CGFloat = 30
            rawCaptionLabel.frame = CGRect(x: 14, y: 10, width: 58, height: 13)
            rawLabel.frame = CGRect(x: rawCaptionLabel.frame.minX, y: rawRowY, width: 92, height: 20)
            rawLabel.textAlignment = .left
            rawSwitch.frame = CGRect(x: rawLabel.frame.maxX + 4, y: rawRowY - 4, width: 42, height: 28)

            let zoomX = rawSwitch.frame.maxX + 14
            zoomCaptionLabel.frame = CGRect(x: zoomX, y: 10, width: 72, height: 13)
            zoomValueLabel.frame = CGRect(x: panelWidth - 50, y: 10, width: 36, height: 13)
            zoomSlider.frame = CGRect(x: zoomX, y: 29, width: panelWidth - zoomX - 58, height: 14)
            downsampleCaptionLabel.frame = CGRect(x: zoomX, y: 52, width: 72, height: 13)
            downsampleValueSummaryLabel.frame = CGRect(x: panelWidth - 96, y: 52, width: 82, height: 13)
            downsampleMainSlider.frame = CGRect(x: zoomX, y: 70, width: panelWidth - zoomX - 58, height: 14)
        } else {
            controlsTitleLabel.frame = CGRect(x: 16, y: 10, width: panelWidth - 32, height: 18)
            controlsSubtitleLabel.frame = CGRect(x: 16, y: 27, width: panelWidth - 32, height: 13)
            rawCaptionLabel.frame = CGRect(x: 16, y: 52, width: 70, height: 14)
            rawLabel.frame = CGRect(x: 88, y: 48, width: panelWidth - 146, height: 20)
            rawLabel.textAlignment = .right
            rawSwitch.frame = CGRect(x: panelWidth - 50, y: 44, width: 42, height: 28)
            zoomCaptionLabel.frame = CGRect(x: 16, y: 80, width: 76, height: 14)
            zoomValueLabel.frame = CGRect(x: panelWidth - 54, y: 80, width: 38, height: 14)
            zoomSlider.frame = CGRect(x: 94, y: 80, width: panelWidth - 154, height: 14)
            downsampleCaptionLabel.frame = CGRect(x: 16, y: 100, width: 76, height: 14)
            downsampleValueSummaryLabel.frame = CGRect(x: panelWidth - 108, y: 100, width: 92, height: 14)
            downsampleMainSlider.frame = CGRect(x: 94, y: 100, width: panelWidth - 170, height: 14)
        }
    }

    func fullscreenFrame(in bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat) -> CGRect {
        CGRect(
            x: 12,
            y: safeTop + 10,
            width: bounds.width - 24,
            height: bounds.height - safeTop - safeBottom - 20
        )
    }

    func setupFullscreenUI() {
        fullscreenBackdropView.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        fullscreenBackdropView.alpha = 0
        fullscreenBackdropView.isHidden = true
        view.addSubview(fullscreenBackdropView)

        fullscreenHintLabel.text = "双击退出全屏"
        fullscreenHintLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        fullscreenHintLabel.textAlignment = .center
        fullscreenHintLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        fullscreenBackdropView.addSubview(fullscreenHintLabel)
    }

    func setupImportProgressUI() {
        importProgressView.alpha = 0
        importProgressView.isHidden = true
        importProgressView.layer.cornerRadius = 18
        importProgressView.layer.masksToBounds = true
        importProgressView.layer.borderWidth = 1
        importProgressView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        view.addSubview(importProgressView)

        importProgressSpinner.color = .systemMint
        importProgressSpinner.hidesWhenStopped = true
        importProgressView.contentView.addSubview(importProgressSpinner)

        importProgressLabel.text = "正在处理导入视频..."
        importProgressLabel.textColor = .white
        importProgressLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        importProgressView.contentView.addSubview(importProgressLabel)
    }

    func layoutImportProgressView() {
        let width: CGFloat = 220
        let height: CGFloat = 72
        importProgressView.frame = CGRect(x: view.bounds.midX - width / 2, y: view.bounds.midY - height / 2, width: width, height: height)
        importProgressSpinner.frame = CGRect(x: 22, y: 21, width: 28, height: 28)
        importProgressLabel.frame = CGRect(x: 60, y: 18, width: width - 76, height: 34)
    }

    func setupInteractionGestures() {
        let previewDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handlePreviewDoubleTap))
        previewDoubleTap.numberOfTapsRequired = 2
        previewView.addGestureRecognizer(previewDoubleTap)

        let resultDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleResultDoubleTap))
        resultDoubleTap.numberOfTapsRequired = 2
        resultImageView.isUserInteractionEnabled = true
        resultImageView.addGestureRecognizer(resultDoubleTap)

        let previewPan = UIPanGestureRecognizer(target: self, action: #selector(handleContentPan(_:)))
        previewCanvasView.addGestureRecognizer(previewPan)
        let resultPan = UIPanGestureRecognizer(target: self, action: #selector(handleContentPan(_:)))
        resultCanvasView.isUserInteractionEnabled = true
        resultCanvasView.addGestureRecognizer(resultPan)
    }

    @objc func displayZoomChanged() {
        displayZoomScale = CGFloat(zoomSlider.value)
        displayContentOffset = clampedContentOffset(displayContentOffset)
        applyDisplayZoom()
    }

    func updateZoomLabel() {
        zoomValueLabel.text = String(format: "%.1fx", displayZoomScale)
    }

    func applyDisplayZoom() {
        let scale = displayZoomScale
        zoomSlider.value = Float(scale)
        let clampedOffset = clampedContentOffset(displayContentOffset)
        displayContentOffset = clampedOffset

        previewContentView.transform = CGAffineTransform(scaleX: scale, y: scale)
        resultContentImageView.transform = CGAffineTransform(scaleX: scale, y: scale)

        previewContentView.center = CGPoint(
            x: previewCanvasView.bounds.midX + clampedOffset.x,
            y: previewCanvasView.bounds.midY + clampedOffset.y
        )
        resultContentImageView.center = CGPoint(
            x: resultCanvasView.bounds.midX + clampedOffset.x,
            y: resultCanvasView.bounds.midY + clampedOffset.y
        )

        if scale <= 1.001 {
            displayContentOffset = .zero
        }
        updateZoomLabel()
    }

    func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        let maxOffsetX = max(0, (previewCanvasView.bounds.width * displayZoomScale - previewCanvasView.bounds.width) / 2)
        let maxOffsetY = max(0, (previewCanvasView.bounds.height * displayZoomScale - previewCanvasView.bounds.height) / 2)
        return CGPoint(
            x: min(max(offset.x, -maxOffsetX), maxOffsetX),
            y: min(max(offset.y, -maxOffsetY), maxOffsetY)
        )
    }

    @objc func handleContentPan(_ gesture: UIPanGestureRecognizer) {
        guard displayZoomScale > 1.0 else { return }
        let translation = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        displayContentOffset = clampedContentOffset(CGPoint(
            x: displayContentOffset.x + translation.x,
            y: displayContentOffset.y + translation.y
        ))
        applyDisplayZoom()
    }

    @objc func handlePreviewDoubleTap() {
        toggleFullscreen(stage: .preview)
    }

    @objc func handleResultDoubleTap() {
        toggleFullscreen(stage: .result)
    }

    func toggleFullscreen(stage: FullscreenStage) {
        if fullscreenStage == stage {
            fullscreenStage = nil
            fullscreenBackdropView.isHidden = true
            UIView.animate(withDuration: 0.25) {
                self.fullscreenBackdropView.alpha = 0
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
            return
        }

        fullscreenStage = stage
        fullscreenBackdropView.isHidden = false
        view.bringSubviewToFront(fullscreenBackdropView)
        view.bringSubviewToFront(stage == .preview ? previewView : resultImageView)
        view.bringSubviewToFront(fullscreenHintLabel)

        UIView.animate(withDuration: 0.25) {
            self.fullscreenBackdropView.alpha = 1
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    @objc func importVideoTapped() {
        guard !isImportingVideo else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self = self else { return }
            guard let url, error == nil else { return }

            guard let copiedURL = self.copyImportedVideoToTemporaryLocation(from: url) else {
                DispatchQueue.main.async {
                    self.showSimpleAlert(title: "导入失败", message: "无法复制导入的视频文件")
                }
                return
            }
            DispatchQueue.main.async {
                self.presentImportOutputModeSheet(for: copiedURL)
            }
        }
    }
    func presentImportOutputModeSheet(for videoURL: URL) {
        let alert = UIAlertController(title: "导入视频输出", message: "保存会写入相册；播放只生成临时文件。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "保存：与现拍一致", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.startImportedVideoProcessing(videoURL: videoURL, outputMode: .liveFormat(includeRawVideo: self.rawSwitch.isOn, saveToLibrary: true))
        })
        alert.addAction(UIAlertAction(title: "保存：仅显著图", style: .default) { [weak self] _ in
            self?.startImportedVideoProcessing(videoURL: videoURL, outputMode: .saliencyOnly(saveToLibrary: true))
        })
        alert.addAction(UIAlertAction(title: "保存：原视频 + 显著图并列", style: .default) { [weak self] _ in
            self?.startImportedVideoProcessing(videoURL: videoURL, outputMode: .sideBySide(saveToLibrary: true))
        })
        alert.addAction(UIAlertAction(title: "播放：仅显著图（不保存）", style: .default) { [weak self] _ in
            self?.startImportedVideoProcessing(videoURL: videoURL, outputMode: .saliencyOnly(saveToLibrary: false))
        })
        alert.addAction(UIAlertAction(title: "播放：原视频 + 显著图并列（不保存）", style: .default) { [weak self] _ in
            self?.startImportedVideoProcessing(videoURL: videoURL, outputMode: .sideBySide(saveToLibrary: false))
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            if videoURL.lastPathComponent.hasPrefix("phasemotion_import_") {
                try? FileManager.default.removeItem(at: videoURL)
            }
            self?.importedSourceCleanupURL = nil
        })

        if let popover = alert.popoverPresentationController {
            popover.sourceView = importVideoButton
            popover.sourceRect = importVideoButton.bounds
        }

        present(alert, animated: true)
    }

    func copyImportedVideoToTemporaryLocation(from sourceURL: URL) -> URL? {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phasemotion_import_\(UUID().uuidString)")
            .appendingPathExtension(ext)

        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    func startImportedVideoProcessing(videoURL: URL, outputMode: ImportedVideoSaliencyProcessor.OutputMode) {
        guard !isImportingVideo else { return }
        isImportingVideo = true
        importedSourceCleanupURL = videoURL
        importVideoButton.isEnabled = false
        importVideoButton.alpha = 0.6
        showImportProgress(true, message: "正在处理导入视频...")

        let processor = ImportedVideoSaliencyProcessor(
            sourceURL: videoURL,
            outputResolution: currentResolution,
            outputMode: outputMode,
            detectionSettings: detectionSettings,
            boundingBoxSettings: boundingBoxSettings
        )
        importedVideoProcessor = processor

        processor.process { [weak self] success, outputURL in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isImportingVideo = false
                self.importedVideoProcessor = nil
                self.importVideoButton.isEnabled = true
                self.importVideoButton.alpha = 1.0
                self.showImportProgress(false, message: nil)
                self.cleanupImportedSourceFile()

                switch outputMode {
                case .saliencyOnly(let saveToLibrary) where !saveToLibrary:
                    guard success, let outputURL else {
                        if let outputURL {
                            try? FileManager.default.removeItem(at: outputURL)
                        }
                        self.showSimpleAlert(title: "播放失败", message: "显著图视频生成失败")
                        return
                    }
                    self.presentImportedPlayback(url: outputURL)
                case .sideBySide(let saveToLibrary) where !saveToLibrary:
                    guard success, let outputURL else {
                        if let outputURL {
                            try? FileManager.default.removeItem(at: outputURL)
                        }
                        self.showSimpleAlert(title: "播放失败", message: "并列视频生成失败")
                        return
                    }
                    self.presentImportedPlayback(url: outputURL)
                default:
                    let alert = UIAlertController(
                        title: success ? "导出完成" : "导出失败",
                        message: success ? "已保存到相册" : "处理导入视频时出错",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    func showImportProgress(_ show: Bool, message: String?) {
        importProgressLabel.text = message ?? "正在处理导入视频..."
        if show {
            importProgressView.isHidden = false
            view.bringSubviewToFront(importProgressView)
            importProgressSpinner.startAnimating()
            UIView.animate(withDuration: 0.2) {
                self.importProgressView.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.2, animations: {
                self.importProgressView.alpha = 0
            }) { _ in
                self.importProgressSpinner.stopAnimating()
                self.importProgressView.isHidden = true
            }
        }
    }

    func showSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func presentImportedPlayback(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showSimpleAlert(title: "播放失败", message: "临时视频文件不存在")
            return
        }
        cleanupImportedPlaybackFiles()
        let player = AVPlayer(url: url)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        controller.presentationController?.delegate = self
        importedPlaybackCleanupURLs = [url]
        present(controller, animated: true) {
            player.play()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupImportedPlaybackFiles()
    }

    func cleanupImportedSourceFile() {
        guard let url = importedSourceCleanupURL else { return }
        try? FileManager.default.removeItem(at: url)
        importedSourceCleanupURL = nil
    }

    func cleanupImportedPlaybackFiles() {
        guard !importedPlaybackCleanupURLs.isEmpty else { return }
        for url in importedPlaybackCleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        importedPlaybackCleanupURLs.removeAll()
    }

    func purgeStaleTemporaryMediaFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let prefixes = ["motion_debug", "imported_saliency_", "phasemotion_import_"]

        guard let urls = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else {
            return
        }

        for url in urls {
            let name = url.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func setupBoundingBoxUI() {
        boundingBoxSettingsButton.setTitle("设置", for: .normal)
        boundingBoxSettingsButton.setTitleColor(.white, for: .normal)
        boundingBoxSettingsButton.backgroundColor = UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 0.78)
        boundingBoxSettingsButton.layer.cornerRadius = 16
        boundingBoxSettingsButton.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
        boundingBoxSettingsButton.layer.borderWidth = 1
        boundingBoxSettingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        boundingBoxSettingsButton.addTarget(self, action: #selector(toggleBoundingBoxPanel), for: .touchUpInside)
        boundingBoxSettingsButton.layer.shadowColor = UIColor.black.withAlphaComponent(0.28).cgColor
        boundingBoxSettingsButton.layer.shadowOpacity = 1
        boundingBoxSettingsButton.layer.shadowRadius = 12
        boundingBoxSettingsButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(boundingBoxSettingsButton)

        boundingBoxPanel.isHidden = true
        boundingBoxPanel.alpha = 0.98
        boundingBoxPanel.layer.borderWidth = 1
        boundingBoxPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        view.addSubview(boundingBoxPanel)

        boundingBoxScrollView.showsVerticalScrollIndicator = false
        boundingBoxPanel.contentView.addSubview(boundingBoxScrollView)

        boundingBoxTitleLabel.text = "Detection Settings"
        boundingBoxTitleLabel.textColor = .white
        boundingBoxTitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        boundingBoxScrollView.addSubview(boundingBoxTitleLabel)

        boundingBoxResetButton.setTitle("重置", for: .normal)
        boundingBoxResetButton.setTitleColor(.systemYellow, for: .normal)
        boundingBoxResetButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        boundingBoxResetButton.addTarget(self, action: #selector(resetBoundingBoxSettings), for: .touchUpInside)
        boundingBoxScrollView.addSubview(boundingBoxResetButton)

        boundingBoxDoneButton.setTitle("完成", for: .normal)
        boundingBoxDoneButton.setTitleColor(.systemMint, for: .normal)
        boundingBoxDoneButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        boundingBoxDoneButton.addTarget(self, action: #selector(closeBoundingBoxPanel), for: .touchUpInside)
        boundingBoxScrollView.addSubview(boundingBoxDoneButton)

        clearTempFilesButton.setTitle("清理临时文件", for: .normal)
        clearTempFilesButton.setTitleColor(.systemOrange, for: .normal)
        clearTempFilesButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        clearTempFilesButton.layer.cornerRadius = 12
        clearTempFilesButton.layer.borderWidth = 1
        clearTempFilesButton.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.35).cgColor
        clearTempFilesButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        clearTempFilesButton.addTarget(self, action: #selector(confirmClearTemporaryFiles), for: .touchUpInside)
        boundingBoxScrollView.addSubview(clearTempFilesButton)

        colorFusionLabel.text = "颜色通道联合"
        colorFusionLabel.textColor = .white
        colorFusionLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        boundingBoxScrollView.addSubview(colorFusionLabel)

        colorFusionSwitch.onTintColor = .systemMint
        colorFusionSwitch.addTarget(self, action: #selector(boundingBoxControlsChanged), for: .valueChanged)
        boundingBoxScrollView.addSubview(colorFusionSwitch)

        temporalFusionLabel.text = "相邻多帧联合"
        temporalFusionLabel.textColor = .white
        temporalFusionLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        boundingBoxScrollView.addSubview(temporalFusionLabel)

        temporalFusionSwitch.onTintColor = .systemMint
        temporalFusionSwitch.addTarget(self, action: #selector(boundingBoxControlsChanged), for: .valueChanged)
        boundingBoxScrollView.addSubview(temporalFusionSwitch)

        configureSliderRow(
            label: temporalFrameCountLabel,
            valueLabel: temporalFrameCountValueLabel,
            slider: temporalFrameCountSlider,
            title: "联合帧数"
        )
        showBoundingBoxLabel.text = "显示框"
        showBoundingBoxLabel.textColor = .white
        showBoundingBoxLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        boundingBoxScrollView.addSubview(showBoundingBoxLabel)

        showBoundingBoxSwitch.onTintColor = .systemYellow
        showBoundingBoxSwitch.addTarget(self, action: #selector(boundingBoxControlsChanged), for: .valueChanged)
        boundingBoxScrollView.addSubview(showBoundingBoxSwitch)

        configureSliderRow(label: seedThresholdLabel, valueLabel: seedThresholdValueLabel, slider: seedThresholdSlider, title: "Seed 阈值")
        configureSliderRow(label: regionThresholdLabel, valueLabel: regionThresholdValueLabel, slider: regionThresholdSlider, title: "Region 阈值")
        configureSliderRow(label: suppressionRadiusLabel, valueLabel: suppressionRadiusValueLabel, slider: suppressionRadiusSlider, title: "抑制半径")
        configureSliderRow(label: minAreaLabel, valueLabel: minAreaValueLabel, slider: minAreaSlider, title: "最小面积")
        configureSliderRow(label: maxBoxesLabel, valueLabel: maxBoxesValueLabel, slider: maxBoxesSlider, title: "最多框数")

        refreshBoundingBoxControls()
    }

    func configureSliderRow(label: UILabel, valueLabel: UILabel, slider: UISlider, title: String) {
        label.text = title
        label.textColor = UIColor.white.withAlphaComponent(0.92)
        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        boundingBoxScrollView.addSubview(label)

        valueLabel.textColor = .systemYellow
        valueLabel.textAlignment = .right
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        boundingBoxScrollView.addSubview(valueLabel)

        slider.minimumTrackTintColor = .systemYellow
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
        slider.addTarget(self, action: #selector(boundingBoxControlsChanged), for: .valueChanged)
        boundingBoxScrollView.addSubview(slider)
    }

    func layoutBoundingBoxPanelContent(width: CGFloat, height: CGFloat) {
        let contentWidth = width
        boundingBoxScrollView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)

        let horizontalPadding: CGFloat = 14
        let rowWidth = contentWidth - horizontalPadding * 2
        let titleHeight: CGFloat = 24
        let switchHeight: CGFloat = 32
        let rowSpacing: CGFloat = 16
        let sliderRowHeight: CGFloat = 44

        boundingBoxTitleLabel.frame = CGRect(x: horizontalPadding, y: 14, width: 140, height: titleHeight)
        boundingBoxDoneButton.frame = CGRect(x: contentWidth - horizontalPadding - 54, y: 12, width: 54, height: 28)
        boundingBoxResetButton.frame = CGRect(x: contentWidth - horizontalPadding - 112, y: 12, width: 50, height: 28)

        let colorSwitchY = boundingBoxTitleLabel.frame.maxY + 10
        colorFusionLabel.frame = CGRect(x: horizontalPadding, y: colorSwitchY, width: 132, height: switchHeight)
        colorFusionSwitch.frame = CGRect(x: contentWidth - horizontalPadding - 52, y: colorSwitchY + 1, width: 52, height: 31)

        let temporalSwitchY = colorFusionLabel.frame.maxY + 4
        temporalFusionLabel.frame = CGRect(x: horizontalPadding, y: temporalSwitchY, width: 132, height: switchHeight)
        temporalFusionSwitch.frame = CGRect(x: contentWidth - horizontalPadding - 52, y: temporalSwitchY + 1, width: 52, height: 31)

        let temporalSliderY = temporalFusionLabel.frame.maxY + 8
        layoutSliderRow(label: temporalFrameCountLabel, valueLabel: temporalFrameCountValueLabel, slider: temporalFrameCountSlider, y: temporalSliderY, width: rowWidth, padding: horizontalPadding)

        let switchY = temporalFrameCountSlider.frame.maxY + 12
        showBoundingBoxLabel.frame = CGRect(x: horizontalPadding, y: switchY, width: 96, height: switchHeight)
        showBoundingBoxSwitch.frame = CGRect(x: contentWidth - horizontalPadding - 52, y: switchY + 1, width: 52, height: 31)

        let sliderStartY = showBoundingBoxLabel.frame.maxY + 12
        layoutSliderRow(label: seedThresholdLabel, valueLabel: seedThresholdValueLabel, slider: seedThresholdSlider, y: sliderStartY, width: rowWidth, padding: horizontalPadding)
        layoutSliderRow(label: regionThresholdLabel, valueLabel: regionThresholdValueLabel, slider: regionThresholdSlider, y: sliderStartY + (sliderRowHeight + rowSpacing) * 1, width: rowWidth, padding: horizontalPadding)
        layoutSliderRow(label: suppressionRadiusLabel, valueLabel: suppressionRadiusValueLabel, slider: suppressionRadiusSlider, y: sliderStartY + (sliderRowHeight + rowSpacing) * 2, width: rowWidth, padding: horizontalPadding)
        layoutSliderRow(label: minAreaLabel, valueLabel: minAreaValueLabel, slider: minAreaSlider, y: sliderStartY + (sliderRowHeight + rowSpacing) * 3, width: rowWidth, padding: horizontalPadding)
        layoutSliderRow(label: maxBoxesLabel, valueLabel: maxBoxesValueLabel, slider: maxBoxesSlider, y: sliderStartY + (sliderRowHeight + rowSpacing) * 4, width: rowWidth, padding: horizontalPadding)

        clearTempFilesButton.frame = CGRect(x: horizontalPadding, y: sliderStartY + (sliderRowHeight + rowSpacing) * 5 + 2, width: rowWidth, height: 32)

        let contentHeight = clearTempFilesButton.frame.maxY + 12
        boundingBoxScrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
    }

    func layoutSliderRow(label: UILabel, valueLabel: UILabel, slider: UISlider, y: CGFloat, width: CGFloat, padding: CGFloat) {
        label.frame = CGRect(x: padding, y: y, width: width - 104, height: 18)
        valueLabel.frame = CGRect(x: padding + width - 96, y: y, width: 96, height: 18)
        slider.frame = CGRect(x: padding, y: y + 20, width: width, height: 22)
    }

    @objc func toggleBoundingBoxPanel() {
        boundingBoxPanel.isHidden.toggle()
        if !boundingBoxPanel.isHidden {
            view.bringSubviewToFront(boundingBoxPanel)
        }
        boundingBoxSettingsButton.backgroundColor = boundingBoxPanel.isHidden
            ? UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 0.78)
            : UIColor.systemYellow.withAlphaComponent(0.25)
        view.setNeedsLayout()
    }

    @objc func closeBoundingBoxPanel() {
        boundingBoxPanel.isHidden = true
        boundingBoxSettingsButton.backgroundColor = UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 0.78)
        view.setNeedsLayout()
    }

    @objc func confirmClearTemporaryFiles() {
        let alert = UIAlertController(
            title: "清理临时文件",
            message: "将删除 app 在临时目录里生成的导入视频和显著图文件，不影响相册中的视频。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清理", style: .destructive) { [weak self] _ in
            self?.clearTemporaryFiles()
        })
        present(alert, animated: true)
    }

    func clearTemporaryFiles() {
        purgeStaleTemporaryMediaFiles()
        cleanupImportedSourceFile()
        cleanupImportedPlaybackFiles()

        if let recorderURL = recorder?.outputURL {
            try? FileManager.default.removeItem(at: recorderURL)
        }

        showSimpleAlert(title: "已清理", message: "临时媒体文件已删除")
    }

    @objc func resetBoundingBoxSettings() {
        detectionSettings = .default
        boundingBoxSettings = MotionDetector.BoundingBoxSettings.defaults(for: currentResolution)
        detector.updateDetectionSettings(detectionSettings)
        detector.updateBoundingBoxSettings(boundingBoxSettings)
        refreshBoundingBoxControls()
    }

    @objc func boundingBoxControlsChanged() {
        applyBoundingBoxSettingsFromControls()
    }

    func refreshBoundingBoxControls() {
        let suppressionRange = suppressionRadiusRange(for: currentResolution)
        suppressionRadiusSlider.minimumValue = suppressionRange.lowerBound
        suppressionRadiusSlider.maximumValue = suppressionRange.upperBound

        let minAreaRange = minAreaRange(for: currentResolution)
        minAreaSlider.minimumValue = minAreaRange.lowerBound
        minAreaSlider.maximumValue = minAreaRange.upperBound

        maxBoxesSlider.minimumValue = 1
        maxBoxesSlider.maximumValue = 12
        temporalFrameCountSlider.minimumValue = 1
        temporalFrameCountSlider.maximumValue = 12
        seedThresholdSlider.minimumValue = 0.10
        seedThresholdSlider.maximumValue = 0.95
        regionThresholdSlider.minimumValue = 0.05
        regionThresholdSlider.maximumValue = 0.90

        colorFusionSwitch.isOn = detectionSettings.usesColorChannelFusion
        temporalFusionSwitch.isOn = detectionSettings.usesTemporalFusion
        temporalFrameCountSlider.value = Float(detectionSettings.temporalFusionFrameCount)
        downsampleMainSlider.value = detectionSettings.preprocessingDownsampleScale
        showBoundingBoxSwitch.isOn = boundingBoxSettings.isEnabled
        seedThresholdSlider.value = boundingBoxSettings.seedThreshold
        regionThresholdSlider.value = boundingBoxSettings.regionThreshold
        suppressionRadiusSlider.value = min(max(Float(boundingBoxSettings.suppressionRadius), suppressionRange.lowerBound), suppressionRange.upperBound)
        minAreaSlider.value = min(max(Float(boundingBoxSettings.minArea), minAreaRange.lowerBound), minAreaRange.upperBound)
        maxBoxesSlider.value = Float(boundingBoxSettings.maxBoxes)

        updateBoundingBoxValueLabels()
    }

    func applyBoundingBoxSettingsFromControls() {
        let defaults = MotionDetector.BoundingBoxSettings.defaults(for: currentResolution)
        detectionSettings = MotionDetector.DetectionSettings(
            usesColorChannelFusion: colorFusionSwitch.isOn,
            usesTemporalFusion: temporalFusionSwitch.isOn,
            temporalFusionFrameCount: Int(round(temporalFrameCountSlider.value)),
            preprocessingDownsampleScale: downsampleMainSlider.value
        )
        boundingBoxSettings = MotionDetector.BoundingBoxSettings(
            isEnabled: showBoundingBoxSwitch.isOn,
            suppressionRadius: Int(round(suppressionRadiusSlider.value)),
            seedThreshold: seedThresholdSlider.value,
            regionThreshold: regionThresholdSlider.value,
            minArea: Int(round(minAreaSlider.value)),
            maxSeedCount: defaults.maxSeedCount,
            maxBoxes: Int(round(maxBoxesSlider.value)),
            padding: defaults.padding
        )

        detector.updateDetectionSettings(detectionSettings)
        detector.updateBoundingBoxSettings(boundingBoxSettings)
        updateBoundingBoxValueLabels()
    }

    func updateBoundingBoxValueLabels() {
        temporalFrameCountValueLabel.text = "\(Int(round(temporalFrameCountSlider.value)))"
        let effectiveLongEdge = max(32, Int(round(Float(currentResolution) * downsampleMainSlider.value)))
        downsampleValueSummaryLabel.text = downsampleMainSlider.value >= 0.995
            ? "关闭 / \(effectiveLongEdge)px"
            : String(format: "%.2fx / %dpx", downsampleMainSlider.value, effectiveLongEdge)
        seedThresholdValueLabel.text = String(format: "%.2f", seedThresholdSlider.value)
        regionThresholdValueLabel.text = String(format: "%.2f", regionThresholdSlider.value)
        suppressionRadiusValueLabel.text = "\(Int(round(suppressionRadiusSlider.value)))"
        minAreaValueLabel.text = "\(Int(round(minAreaSlider.value)))"
        maxBoxesValueLabel.text = "\(Int(round(maxBoxesSlider.value)))"
    }

    func suppressionRadiusRange(for size: Int) -> ClosedRange<Float> {
        1...Float(max(12, size / 8))
    }

    func minAreaRange(for size: Int) -> ClosedRange<Float> {
        let lower = Float(max(8, (size * size) / 16384))
        let upper = Float(max((size * size) / 64, Int(lower) + 24))
        return lower...upper
    }

    func scaledBoundingBoxSettings(from oldResolution: Int, to newResolution: Int) -> MotionDetector.BoundingBoxSettings {
        guard oldResolution > 0, oldResolution != newResolution else {
            return boundingBoxSettings
        }

        let defaults = MotionDetector.BoundingBoxSettings.defaults(for: newResolution)
        let linearScale = CGFloat(newResolution) / CGFloat(oldResolution)
        let areaScale = linearScale * linearScale

        return MotionDetector.BoundingBoxSettings(
            isEnabled: boundingBoxSettings.isEnabled,
            suppressionRadius: max(1, Int(round(CGFloat(boundingBoxSettings.suppressionRadius) * linearScale))),
            seedThreshold: boundingBoxSettings.seedThreshold,
            regionThreshold: boundingBoxSettings.regionThreshold,
            minArea: max(1, Int(round(CGFloat(boundingBoxSettings.minArea) * areaScale))),
            maxSeedCount: defaults.maxSeedCount,
            maxBoxes: boundingBoxSettings.maxBoxes,
            padding: defaults.padding
        )
    }
    
    // MARK: - Configuration Logic
    @objc func configChanged() {
        if isRecording {
            toggleRecording() // 录制中改配置需停止
        }
        updateRecordingConfiguration()
    }

    func refreshResolutionMenu() {
        let resolutions = [256, 512, 1024]
        let actions = resolutions.map { resolution in
            UIAction(title: "\(resolution)") { [weak self] _ in
                self?.selectResolution(resolution)
            }
        }

        resolutionMenuButton.menu = UIMenu(title: "录制分辨率", children: actions)
        resolutionMenuButton.setTitle("\(currentResolution) ▼", for: .normal)
    }

    func selectResolution(_ resolution: Int) {
        guard currentResolution != resolution else { return }

        if isRecording {
            toggleRecording()
        }

        currentResolution = resolution
        refreshResolutionMenu()
        updateRecordingConfiguration()
    }
    
    func updateRecordingConfiguration() {
        let previousResolution = currentResolution
        includeRawVideo = rawSwitch.isOn
        boundingBoxSettings = scaledBoundingBoxSettings(from: previousResolution, to: currentResolution)
        self.detector = MotionDetector(size: currentResolution)
        self.detector.updateDetectionSettings(detectionSettings)
        self.detector.updateBoundingBoxSettings(boundingBoxSettings)
        refreshBoundingBoxControls()
        refreshResolutionMenu()
        
        let videoWidth = currentResolution
        let videoHeight = includeRawVideo ? currentResolution * 2 : currentResolution
        self.recorder = VideoRecorder(size: CGSize(width: videoWidth, height: videoHeight))
    }
    
    // MARK: - Camera Switch Logic
    @objc func cameraSelectionChanged(_ sender: UISegmentedControl) {
        guard let session = captureSession else { return }
        let index = sender.selectedSegmentIndex
        guard index >= 0 && index < availableCameras.count else { return }
        
        let selectedOption = availableCameras[index]
        let rotationAngle = videoRotationAngle(
            for: view.window?.windowScene?.interfaceOrientation,
            frontCamera: selectedOption.position == .front
        )

        sessionQueue.async {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard let currentInput = session.inputs.first as? AVCaptureDeviceInput else { return }
            session.removeInput(currentInput)

            guard let newDevice = AVCaptureDevice.default(selectedOption.deviceType, for: .video, position: selectedOption.position) else {
                session.addInput(currentInput)
                return
            }

            guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                session.addInput(currentInput)
                return
            }

            if session.canAddInput(newInput) {
                session.addInput(newInput)

                if let output = session.outputs.first as? AVCaptureVideoDataOutput,
                   let conn = output.connection(with: .video) {
                    if conn.isVideoRotationAngleSupported(rotationAngle) {
                        conn.videoRotationAngle = rotationAngle
                    }
                    if conn.isVideoMirroringSupported {
                        conn.automaticallyAdjustsVideoMirroring = false
                        conn.isVideoMirrored = (newDevice.position == .front)
                    }
                }
            } else {
                session.addInput(currentInput)
            }

            DispatchQueue.main.async {
                self.updateCaptureConnectionsForCurrentOrientation()
            }
        }
    }
    
    // MARK: - Actions
    @objc func toggleRecording() {
        if isRecording {
            // --- 停止 ---
            isRecording = false
            UIView.animate(withDuration: 0.2) {
                self.recordButton.transform = .identity
                self.recordButton.layer.cornerRadius = 40
                self.recordButton.backgroundColor = .systemRed
                self.recordButton.layer.shadowColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            }
            resolutionMenuButton.isEnabled = true
            resolutionMenuButton.alpha = 1.0
            rawSwitch.isEnabled = true
            cameraControl.isEnabled = true
            cameraControl.alpha = 1.0
            
            recorder?.stop(saveToLibrary: true) { success in
                DispatchQueue.main.async {
                    let title = success ? "保存成功" : "保存失败"
                    let msg = success ? "已保存到相册" : "录制时间太短或出错"
                    let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        } else {
            // --- 开始 ---
            isRecording = true
            resolutionMenuButton.isEnabled = false
            resolutionMenuButton.alpha = 0.55
            rawSwitch.isEnabled = false
            
            cameraControl.isEnabled = false
            cameraControl.alpha = 0.5
            
            recorder?.start()
            
            UIView.animate(withDuration: 0.2) {
                self.recordButton.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
                self.recordButton.layer.cornerRadius = 10
                self.recordButton.layer.shadowColor = UIColor.systemOrange.withAlphaComponent(0.55).cgColor
            }
            self.recordButton.isEnabled = false
            self.recordButton.backgroundColor = UIColor.systemOrange
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.isRecording {
                    self.recordButton.isEnabled = true
                    self.recordButton.backgroundColor = .systemRed
                }
            }
        }
    }
    
    // MARK: - Camera Setup
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    self.setupCamera()
                }
            }
        default: break
        }
    }
    
    func setupCamera() {
        let selectedIndex = cameraControl.selectedSegmentIndex
        let cameraOptions = availableCameras
        let initialIsFrontCamera = selectedIndex >= 0 && selectedIndex < cameraOptions.count
            ? cameraOptions[selectedIndex].position == .front
            : false
        let rotationAngle = videoRotationAngle(
            for: view.window?.windowScene?.interfaceOrientation,
            frontCamera: initialIsFrontCamera
        )
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoOutputQueue)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]

        sessionQueue.async {
            let session = AVCaptureSession()
            session.sessionPreset = .hd1280x720

            var initialDevice: AVCaptureDevice?
            if selectedIndex >= 0 && selectedIndex < cameraOptions.count {
                let option = cameraOptions[selectedIndex]
                initialDevice = AVCaptureDevice.default(option.deviceType, for: .video, position: option.position)
            }

            if initialDevice == nil {
                initialDevice = AVCaptureDevice.default(for: .video)
            }

            guard let device = initialDevice,
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            if session.canAddInput(input) { session.addInput(input) }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspect

            if session.canAddOutput(output) {
                session.addOutput(output)
                if let conn = output.connection(with: .video) {
                    if conn.isVideoRotationAngleSupported(rotationAngle) {
                        conn.videoRotationAngle = rotationAngle
                    }
                    if conn.isVideoMirroringSupported {
                        conn.automaticallyAdjustsVideoMirroring = false
                        conn.isVideoMirrored = (device.position == .front)
                    }
                }
            }

            session.startRunning()

            DispatchQueue.main.async {
                self.captureSession = session
                self.previewContentView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
                self.previewContentView.layer.addSublayer(previewLayer)
                self.updatePreviewLayerFrame()
                self.updateCaptureConnectionsForCurrentOrientation()
            }
        }
    }
    
    func updatePreviewLayerFrame() {
        if let layers = previewContentView.layer.sublayers {
            for layer in layers {
                if let pLayer = layer as? AVCaptureVideoPreviewLayer {
                    pLayer.frame = previewContentView.bounds
                }
            }
        }
    }

    func currentVideoRotationAngle() -> CGFloat {
        videoRotationAngle(
            for: view.window?.windowScene?.interfaceOrientation,
            frontCamera: (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device.position == .front
        )
    }

    func videoRotationAngle(for orientation: UIInterfaceOrientation?, frontCamera: Bool) -> CGFloat {
        switch orientation {
        case .landscapeLeft:
            return frontCamera ? 0.0 : 180.0
        case .landscapeRight:
            return frontCamera ? 180.0 : 0.0
        case .portraitUpsideDown:
            return 270.0
        default:
            return 90.0
        }
    }

    func updateCaptureConnectionsForCurrentOrientation() {
        let activeDevice = (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device
        let isFrontCamera = activeDevice?.position == .front
        let rotationAngle = videoRotationAngle(
            for: view.window?.windowScene?.interfaceOrientation,
            frontCamera: isFrontCamera
        )

        if let layers = previewContentView.layer.sublayers {
            for layer in layers {
                guard let previewLayer = layer as? AVCaptureVideoPreviewLayer,
                      let connection = previewLayer.connection else { continue }

                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = isFrontCamera
                }
            }
        }

        if let output = captureSession?.outputs.first as? AVCaptureVideoDataOutput,
           let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFrontCamera
            }
        }
    }

    func normalizedProcessingImage(from image: CGImage, connection: AVCaptureConnection) -> CGImage {
        let isFrontCamera = (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device.position == .front
        guard isFrontCamera else {
            return image
        }

        let sourceImage = UIImage(cgImage: image)
        let rotationAngle = currentVideoRotationAngle()
        let radians = rotationAngle * (.pi / 180.0)
        let normalizedAngle = Int(rotationAngle) % 180
        let swapsDimensions = normalizedAngle != 0
        let outputSize = swapsDimensions
            ? CGSize(width: sourceImage.size.height, height: sourceImage.size.width)
            : sourceImage.size

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let renderedImage = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            if connection.isVideoMirrored {
                context.scaleBy(x: -1, y: 1)
            }
            context.rotate(by: radians)

            let drawRect = CGRect(
                x: -sourceImage.size.width / 2,
                y: -sourceImage.size.height / 2,
                width: sourceImage.size.width,
                height: sourceImage.size.height
            )
            sourceImage.draw(in: drawRect)
        }

        return renderedImage.cgImage ?? image
    }
    
    // MARK: - Image Stitching
    func stitchImages(raw: CGImage, processed: UIImage) -> UIImage? {
        let width = max(1, processed.size.width)
        let height = max(1, processed.size.height)
        let totalSize = CGSize(width: width, height: height * 2)
        
        UIGraphicsBeginImageContext(totalSize)
        
        let rawUIImage = UIImage(cgImage: raw)
        rawUIImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        processed.draw(in: CGRect(x: 0, y: height, width: width, height: height))
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return result
    }
    
    // MARK: - Processing
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = self.context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let processedInputImage = normalizedProcessingImage(from: cgImage, connection: connection)
        
        // 1. 算法处理
        if let detectionResult = detector.processFrame(processedInputImage) {
            
            // 2. 写入视频
            if self.isRecording {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                
                if self.includeRawVideo {
                    if let stitched = stitchImages(raw: processedInputImage, processed: detectionResult.boxedSaliencyImage) {
                        self.recorder?.append(image: stitched, timestamp: timestamp)
                    }
                } else {
                    self.recorder?.append(image: detectionResult.boxedSaliencyImage, timestamp: timestamp)
                }
            }
            
            // 3. 更新 UI
            DispatchQueue.main.async {
                self.resultContentImageView.image = detectionResult.boxedSaliencyImage
            }
        }
    }
}
#endif
