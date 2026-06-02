// Author: Jau

#if canImport(UIKit)
import UIKit
import AVFoundation
import Photos

final class VideoRecorder {
    
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var fileName: String
    private var videoSize: CGSize
    private var expectsRealTime: Bool
    private var sessionStarted = false // 标记 Session 是否已启动
    private var currentOutputURL: URL?
    
    // 计数器
    private var frameCount = 0
    private var attemptCount = 0
    
    private let recordingQueue = DispatchQueue(label: "com.phasemotion.recorder")
    
    private var _isRecording = false
    var isRecording: Bool {
        get { recordingQueue.sync { _isRecording } }
    }
    
    init(size: CGSize, fileName: String = "motion_debug.mp4", expectsRealTime: Bool = true) {
        // 强制偶数尺寸，防止 H.264 崩溃
        let width = Int(size.width) / 2 * 2
        let height = Int(size.height) / 2 * 2
        self.videoSize = CGSize(width: width, height: height)
        self.fileName = fileName
        self.expectsRealTime = expectsRealTime
        print("🛠 [Recorder Init] Target Size: \(self.videoSize)")
    }
    
    func start(completion: (() -> Void)? = nil) {
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            print("🚀 [Recorder] Start requested...")
            self.setupWriter()
            self._isRecording = true
            self.sessionStarted = false
            self.frameCount = 0
            self.attemptCount = 0
            completion?()
        }
    }
    
    private func setupWriter() {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
            currentOutputURL = fileURL
            
            // 1. 创建 Writer
            do {
                // 这里直接赋值给属性是OK的
                assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
            } catch {
                print("❌ [Critical] Init Writer Failed: \(error)")
                return
            }
            
            guard let writer = assetWriter else { return }
            
            // 2. 配置 Input
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height)
            ]
            
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = expectsRealTime
            
            // 3. 配置 Adaptor
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
            
            // 【关键修复】这里一定要加 let，把它声明为局部变量
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
            
            // 4. 添加并启动
            if writer.canAdd(input) {
                writer.add(input)
                if writer.startWriting() {
                    print("✅ [Recorder] Writer started writing. Status: \(writer.status.rawValue)")
                } else {
                    print("❌ [Critical] startWriting() returned false. Error: \(String(describing: writer.error))")
                }
            } else {
                print("❌ [Critical] Cannot add input to writer.")
            }
            
            // 最后统一赋值给属性
            // self.assetWriter 已经在最上面赋值过了，这里不需要再赋值
            self.writerInput = input
            self.adaptor = adaptor
        }
    
    func append(image: PlatformImage, timestamp: CMTime) {
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            guard self._isRecording else { return } // 停止后不再接收
            
            guard let writer = self.assetWriter,
                  let input = self.writerInput,
                  let adaptor = self.adaptor else {
                print("⚠️ [Drop] Components not ready")
                return
            }
            
            // --- 核心诊断区 ---
            
            // 1. 检查 Writer 是否已经挂了
            if writer.status == .failed {
                print("❌ [Loop Error] Writer Failed! Error: \(String(describing: writer.error))")
                // 强制停止，避免刷屏
                self._isRecording = false
                return
            }
            
            if writer.status == .completed {
                print("⚠️ [Loop] Writer is already completed.")
                return
            }
            
            // 2. 检查 Input 是否准备好
            if !input.isReadyForMoreMediaData {
                if !self.expectsRealTime {
                    while !input.isReadyForMoreMediaData && writer.status == .writing {
                        Thread.sleep(forTimeInterval: 0.0015)
                    }
                }
            }

            if !input.isReadyForMoreMediaData {
                self.attemptCount += 1
                if self.attemptCount % 30 == 0 { // 减少刷屏
                    print("⏳ [Waiting] Writer input not ready... (Attempts: \(self.attemptCount))")
                }
                return
            }
            
            // 3. 启动 Session (如果还没启动)
            // 修正策略：直接使用第一帧的原始时间作为起点，不做减法运算，防止数学误差
            if !self.sessionStarted {
                writer.startSession(atSourceTime: timestamp)
                self.sessionStarted = true
                print("▶️ [Recorder] Session Started at: \(timestamp.seconds)")
            }
            
            // 4. 转换图片
            guard let buffer = self.pixelBuffer(from: image) else {
                print("⚠️ [Drop] PixelBuffer creation failed")
                return
            }
            
            // 5. 写入
            // 直接传入原始 timestamp，因为我们上面 startSession 也是用的它
            if adaptor.append(buffer, withPresentationTime: timestamp) {
                self.frameCount += 1
                if self.frameCount % 30 == 0 {
                    print("🎥 [Recording] Written \(self.frameCount) frames")
                }
            } else {
                print("⚠️ [Drop] Adaptor append returned false. Writer Status: \(writer.status.rawValue)")
                if let e = writer.error { print("   Reason: \(e)") }
            }
        }
    }
    
    var outputURL: URL? {
        recordingQueue.sync { currentOutputURL }
    }

    func stop(saveToLibrary: Bool = true, completion: @escaping (Bool) -> Void) {
        recordingQueue.async { [weak self] in
            guard let self = self else { completion(false); return }
            print("🛑 [Recorder] Stop requested. Total frames: \(self.frameCount)")
            
            guard let writer = self.assetWriter, let input = self.writerInput else {
                completion(false)
                return
            }
            
            self._isRecording = false
            
            if writer.status == .writing {
                input.markAsFinished()
                writer.finishWriting {
                    print("🏁 [Recorder] Finished writing. Status: \(writer.status.rawValue)")
                    if writer.status == .completed {
                        if saveToLibrary {
                            self.saveToLibrary(videoURL: writer.outputURL, completion: completion)
                        } else {
                            completion(true)
                        }
                    } else {
                        print("❌ [Final] Finish failed error: \(String(describing: writer.error))")
                        completion(false)
                    }
                }
            } else {
                print("❌ [Final] Cannot finish. Writer status is \(writer.status.rawValue) (Not Writing)")
                completion(false)
            }
        }
    }
    
    private func saveToLibrary(videoURL: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                print("❌ [Perm] Permission denied: \(status.rawValue)")
                completion(false)
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }) { success, error in
                if success {
                    print("✅ [Library] Saved successfully!")
                } else {
                    print("❌ [Library] Save failed: \(String(describing: error))")
                }
                completion(success)
            }
        }
    }
    
    private func pixelBuffer(from image: PlatformImage) -> CVPixelBuffer? {
        // ... (保持之前的 pixelBuffer 代码，它是正确的) ...
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor?.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        if let cgImage = image.cgImageRepresentation {
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}
#else
import AVFoundation

final class VideoRecorder {
    init(size: CGSize, fileName: String = "motion_debug.mp4", expectsRealTime: Bool = true) {}

    func start() {}

    func append(image: PlatformImage, timestamp: CMTime) {}

    func stop(saveToLibrary: Bool = true, completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}
#endif
