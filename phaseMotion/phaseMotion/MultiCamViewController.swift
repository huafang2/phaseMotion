#if canImport(UIKit)
import UIKit
import AVFoundation
import CoreMedia

@available(iOS 13.0, *)
class MultiCamViewController: UIViewController, AVCaptureDataOutputSynchronizerDelegate {
    
    // MARK: - Properties
    var multiCamSession: AVCaptureMultiCamSession?
    var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    // 输入与输出
    var inputs: [AVCaptureDeviceInput] = []
    let dataOutputs: [AVCaptureVideoDataOutput] = [AVCaptureVideoDataOutput(), AVCaptureVideoDataOutput()]
    
    // 算法 (确保你的 MotionDetector 已经更新了之前提供的 iOS 18 修复版)
    let detector = MotionDetector(size: 256)
    
    // MARK: - UI Elements
    let resultImageView = UIImageView()
    let statusLabel = UILabel()
    let previewContainer = UIView() // 左下角小预览图
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        
        if !AVCaptureMultiCamSession.isMultiCamSupported {
            updateStatus("错误: 此设备不支持多摄像头 API (需 A12 芯片以上)")
            return
        }
        
        checkPermissions()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resultImageView.frame = view.bounds
        // 状态标签放在顶部
        statusLabel.frame = CGRect(x: 20, y: 60, width: view.bounds.width - 40, height: 100)
        // 小预览窗口放在左下角
        previewContainer.frame = CGRect(x: 20, y: view.bounds.height - 220, width: 144, height: 192) // 3:4 ratio
        previewLayer?.frame = previewContainer.bounds
    }
    
    // MARK: - Setup UI
    func setupUI() {
        view.backgroundColor = .black
        
        // 1. 结果大图
        resultImageView.contentMode = .scaleAspectFit
        view.addSubview(resultImageView)
        
        // 2. 小预览窗口 (画中画)
        previewContainer.layer.borderColor = UIColor.yellow.cgColor
        previewContainer.layer.borderWidth = 2
        previewContainer.backgroundColor = .darkGray
        view.addSubview(previewContainer)
        
        // 3. 状态标签
        statusLabel.textColor = .green
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .left
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        statusLabel.text = "系统初始化中..."
        statusLabel.layer.shadowColor = UIColor.black.cgColor
        statusLabel.layer.shadowOpacity = 1
        statusLabel.layer.shadowOffset = CGSize(width: 1, height: 1)
        view.addSubview(statusLabel)
    }
    
    func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
            print("[Status] \(text)")
        }
    }
    
    // MARK: - Camera Logic
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.global(qos: .userInitiated).async {
                self.configureMultiCamera()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.configureMultiCamera()
                    }
                } else {
                    self.updateStatus("权限被拒绝")
                }
            }
        default:
            self.updateStatus("无法访问相机")
        }
    }
    
    func configureMultiCamera() {
        let session = AVCaptureMultiCamSession()
        self.multiCamSession = session
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        updateStatus("正在寻找摄像头组合...")
        
        // --- 1. 主摄 (必须有) ---
        guard let device1 = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input1 = try? AVCaptureDeviceInput(device: device1) else {
            updateStatus("错误: 找不到后置主摄")
            return
        }
        
        // --- 2. 副摄 (尝试顺序: 超广角 -> 长焦 -> 前置) ---
        var device2: AVCaptureDevice?
        var comboName = ""
        
        if let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            device2 = ultra
            comboName = "广角 + 超广角"
        } else if let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            device2 = tele
            comboName = "广角 + 长焦"
        } else if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            device2 = front
            comboName = "后置 + 前置"
        }
        
        guard let finalDevice2 = device2,
              let input2 = try? AVCaptureDeviceInput(device: finalDevice2) else {
            updateStatus("错误: 找不到第二个摄像头")
            return
        }
        
        updateStatus("配置组合: \(comboName)")
        
        // --- 添加输入 ---
        if session.canAddInput(input1) { session.addInput(input1) } else { updateStatus("无法添加主摄"); return }
        if session.canAddInput(input2) { session.addInput(input2) } else { updateStatus("无法添加副摄"); return }
        
        self.inputs = [input1, input2]
        
        // --- 配置输出 ---
        for (index, output) in dataOutputs.enumerated() {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.alwaysDiscardsLateVideoFrames = true
            
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                updateStatus("无法添加输出 \(index)")
                return
            }
            
            // 绑定 Connection 并设置方向
            if let connection = output.connection(with: .video) {
                // [iOS 18 修复] 使用 videoRotationAngle 替代 videoOrientation
                // 90.0 通常对应后置摄像头的竖屏 (Portrait)
                if connection.isVideoRotationAngleSupported(90.0) {
                    connection.videoRotationAngle = 90.0
                }
                
                // 修正前置摄像头镜像
                if index == 1 && finalDevice2.position == .front && connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
        
        // --- 增加预览层 (只显示主摄) ---
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        // 关键：手动管理连接
        preview.setSessionWithNoConnection(session)
        
        if let port = input1.ports.first {
            // 使用正确的参数标签
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
            
            if session.canAddConnection(connection) {
                session.addConnection(connection)
                
                // [iOS 18 修复] 设置预览层方向
                if connection.isVideoRotationAngleSupported(90.0) {
                    connection.videoRotationAngle = 90.0
                }
            }
        }
        
        self.previewLayer = preview
        
        DispatchQueue.main.async {
            self.previewContainer.layer.addSublayer(preview)
        }
        
        // --- 同步器配置 ---
        updateStatus("正在同步帧率...")
        configureDeviceForSynchronization(device1)
        configureDeviceForSynchronization(finalDevice2)
        
        dataOutputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: dataOutputs)
        dataOutputSynchronizer?.setDelegate(self, queue: DispatchQueue(label: "MultiCamQueue"))
        
        updateStatus("配置完成，启动 Session...")
        
        session.startRunning()
        updateStatus("Session 运行中\n组合: \(comboName)\n等待数据同步...")
    }
    
    // 辅助：锁定帧率 (确保多摄能同步)
    func configureDeviceForSynchronization(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            // 强制设置为 30 FPS
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            print("无法锁定设备配置: \(error)")
        }
    }
    
    // MARK: - Delegate
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        // 获取两路同步数据
        guard let data1 = synchronizedDataCollection.synchronizedData(for: dataOutputs[0]) as? AVCaptureSynchronizedSampleBufferData,
              let data2 = synchronizedDataCollection.synchronizedData(for: dataOutputs[1]) as? AVCaptureSynchronizedSampleBufferData else {
            return
        }
        
        // 如果有任何一路丢帧，则放弃本次计算
        if data1.sampleBufferWasDropped || data2.sampleBufferWasDropped {
            return
        }
        
        guard let buffer1 = data1.sampleBuffer.imageBuffer,
              let buffer2 = data2.sampleBuffer.imageBuffer else { return }
        
        // 转换为 CGImage
        let context = CIContext(options: nil) // 建议在类属性中复用 Context 提升性能，此处演示暂且新建
        let ci1 = CIImage(cvPixelBuffer: buffer1)
        let ci2 = CIImage(cvPixelBuffer: buffer2)
        
        guard let cg1 = context.createCGImage(ci1, from: ci1.extent),
              let cg2 = context.createCGImage(ci2, from: ci2.extent) else { return }
        
        // 调用算法比较两张图
        // 注意：MotionDetector 必须包含 `compareImages` 方法且已更新为指针安全版本
        if let result = detector.compareImages(source: cg1, target: cg2) {
            DispatchQueue.main.async {
                self.resultImageView.image = result.boxedSaliencyImage
                // 更新状态提示
                if self.statusLabel.text?.contains("等待") == true {
                    self.statusLabel.text = "数据流正常\n正在计算光谱差异"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.statusLabel.isHidden = true
                    }
                }
            }
        }
    }
}
#endif
