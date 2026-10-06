import SwiftUI
import AppKit

/// 渐变网格背景层 —— **这是全部玻璃效果的前提**。
///
/// 毛玻璃只能"搬运"背景里已有的色差,不能创造色差。若窗口背后是纯色,
/// `glassEffect` 与一块半透明灰板在视觉上没有区别。
///
/// 网格质量硬指标:**RGB 极差 ≥ 60**(当前实现用 assets/bg-mesh.jpg,极差 67)。
/// 低于这个值玻璃会看起来像不透明色板。详见设计系统 §1.3。
struct MiauMeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 漂移进度 0…1,循环。极慢、幅度极小(≤ 视口 2%)。
    @State private var phase: Double = 0

    private var meshImage: NSImage? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "bg-mesh", withExtension: "jpg"),
           let image = NSImage(contentsOf: url) { return image }
        #else
        if let url = Bundle.main.url(forResource: "bg-mesh", withExtension: "jpg"),
           let image = NSImage(contentsOf: url) { return image }
        #endif
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if let meshImage {
                    Image(nsImage: meshImage)
                        .resizable()
                        .interpolation(.high)
                        // 放大 8% 留出漂移余量,避免边缘露白
                        .frame(width: size.width * 1.08, height: size.height * 1.08)
                        .offset(
                            x: sin(phase * 2 * .pi) * size.width * 0.012,
                            y: cos(phase * 2 * .pi) * size.height * 0.010
                        )
                        .blur(radius: 18)
                } else {
                    // 网格图缺失时的兜底:静态渐变,保证界面仍可用
                    LinearGradient(
                        colors: [MiauColor.canvas, MiauColor.primarySoft.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear(perform: startDrift)
            .onChange(of: reduceMotion) { _, _ in startDrift() }
        }
        // 关键:背景层绝不能拦截点击,否则整窗按钮都点不动
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func startDrift() {
        // 「减少动态效果」开启时保持静止
        guard !reduceMotion else {
            phase = 0
            return
        }
        phase = 0
        withAnimation(.linear(duration: MiauMotion.meshDriftDuration).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

#Preview {
    MiauMeshBackground()
        .frame(width: 900, height: 600)
}
