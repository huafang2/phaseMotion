import SwiftUI

#if canImport(UIKit)
import UIKit

// 1. 创建桥接器：让 SwiftUI 能识别 UIKit 的 Controller
struct CameraViewWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CameraViewController {
        return CameraViewController()
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        // 更新逻辑（如果需要）
    }
}

// 1. 创建一个新的 Wrapper，专门用于桥接 MultiCamViewController
struct MultiCamWrapper: UIViewControllerRepresentable {
    // 必须指定要包装的控制器类型
    typealias UIViewControllerType = MultiCamViewController
    
    func makeUIViewController(context: Context) -> MultiCamViewController {
        // 返回双摄控制器的实例
        return MultiCamViewController()
    }
    
    func updateUIViewController(_ uiViewController: MultiCamViewController, context: Context) {
        // 这里通常为空，因为我们不需要从 SwiftUI 动态更新 UIKit 控制器的状态
    }
}
#endif

// 2. 主界面
struct ContentView: View {
    var body: some View {
        ZStack {
            #if os(macOS)
            MacCameraView()
            #elseif canImport(UIKit)
            // 全屏显示相机处理结果
            //CameraViewWrapper()
            //MultiCamWrapper()
            CameraViewWrapper()
                .edgesIgnoringSafeArea(.all)
            #endif
            
            //VStack {
                //Spacer()
                //Text("Motion Dection by Phase")
                    //.foregroundColor(.yellow)
                    //.padding()
                    //.background(Color.black.opacity(0.7))
                    //.cornerRadius(10)
                    //.padding(.bottom, 10)
            //}
        }
    }
}
