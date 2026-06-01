# Phase Motion

Phase Motion 是一个基于 Zhou、Hou 和 Zhang 提出的 Phase Discrepancy 方法实现的 Apple 平台运动检测 App。

> 说明：本项目是非官方实现，仅用于学习、实验和原型验证；项目不隶属于论文作者、论文发表机构或 Apple。

项目使用相邻视频帧的频域相位/幅值差异生成运动显著图，用于突出画面中发生运动的区域。

## 功能

- 实时相机运动检测：打开摄像头后持续输出相位差运动显著图。
- 多摄像头切换：支持前置、后置等设备可用摄像头。
- 录制结果视频：可将检测结果保存到系统相册。
- 原画面拼接：录制时可选择同时保存原画面与显著图。
- 导入视频处理：从相册导入视频，生成显著图视频或原视频/显著图并列预览。
- 可调参数：支持 256、512、1024 输出分辨率，以及颜色融合、时序融合、检测框阈值等设置。
- 运动框标注：可开启显著区域 bounding box，便于观察检测结果。

## 项目结构

```text
.
└── phaseMotion
    ├── phaseMotion.xcodeproj
    └── phaseMotion
        ├── ContentView.swift
        ├── CameraViewController.swift
        ├── MotionDetector.swift
        ├── ImportedVideoSaliencyProcessor.swift
        └── VideoRecorder.swift
```

主要文件：

- `MotionDetector.swift`：核心相位差运动显著图算法，使用 Accelerate/vDSP 做 FFT 处理。
- `CameraViewController.swift`：相机采集、实时预览、参数面板、录制和导入入口。
- `ImportedVideoSaliencyProcessor.swift`：导入视频的逐帧处理和结果导出。
- `VideoRecorder.swift`：将处理后的帧编码为视频并保存。
- `ContentView.swift`：SwiftUI 入口，桥接 UIKit 相机控制器。

## 运行方式

1. 使用 Xcode 打开：

   ```bash
   open phaseMotion/phaseMotion.xcodeproj
   ```

2. 选择 `phaseMotion` Scheme。
3. 选择 iPhone 真机或模拟器运行。
4. 首次启动时允许相机和相册权限。

建议使用真机运行。实时相机检测依赖摄像头输入，真机上的性能和权限行为更接近实际使用场景。

## 使用说明

- 启动后 App 会显示实时运动显著图。
- 顶部可切换可用摄像头。
- 底部可选择输出分辨率、是否拼接原画面，并开始/停止录制。
- 点击“设置”可调整颜色融合、时序融合和检测框相关参数。
- 点击“导入”可选择本地视频进行离线处理。

## 参考论文

Zhou, B., Hou, X., & Zhang, L. (2011). A Phase Discrepancy Analysis of Object Motion. In R. Kimmel, R. Klette, & A. Sugimoto (Eds.), *Computer Vision - ACCV 2010* (Lecture Notes in Computer Science, Vol. 6494, pp. 225-238). Springer, Berlin, Heidelberg. https://doi.org/10.1007/978-3-642-19318-7_18

实现重点是将视频帧转换到频域后，利用帧间相位/幅值差异重建运动显著图，并通过多通道融合、时序融合和阈值区域提取增强可视化结果。

## 开发环境

- Xcode
- Swift / SwiftUI / UIKit
- AVFoundation
- Accelerate
- PhotosUI
