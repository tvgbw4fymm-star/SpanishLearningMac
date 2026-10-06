import SwiftUI
import AppKit

/// 玻璃规格。所有数值来自设计系统 §1.3 的实测三档。
///
/// **纵深原则**:侧栏最透、内容面板居中、卡片较实 —— 形成"侧栏浮起、内容坐稳"的关系。
/// 不要所有表面用同一个值,那样玻璃只是一层均匀的半透明膜。
enum MiauGlass {
    case panel        // 内容面板:白 42%
    case panelStrong  // 卡片 / 焦点区:白 52%
    case sidebar      // 侧边栏:白 26%(最透)
    case floating     // 浮动层:白 52% + 较重投影

    /// 白色叠加量。**这是"玻璃能不能被看见"的关键参数**:
    /// v2.0 用过 0.58–0.72,糊完还是接近白色,看起来像不透明色板。
    var whiteOpacity: Double {
        switch self {
        case .panel: 0.42
        case .panelStrong: 0.52
        case .sidebar: 0.26
        case .floating: 0.52
        }
    }

    var blurRadius: CGFloat {
        switch self {
        case .panel, .panelStrong: 28
        case .sidebar: 34
        case .floating: 30
        }
    }

    var saturation: Double {
        switch self {
        case .panel, .panelStrong: 1.9
        case .sidebar: 2.1
        case .floating: 1.9
        }
    }

    /// 顶部高光折边 —— 少了它玻璃只是个半透明色块。
    var highlightTop: Double {
        switch self {
        case .sidebar: 0.70
        case .panel, .panelStrong, .floating: 0.95
        }
    }

    /// 右侧高光折边(侧边栏专用,液态感的关键)。
    var highlightRight: Double? {
        self == .sidebar ? 0.85 : nil
    }
}

private struct MiauGlassSurface: View {
    let style: MiauGlass
    let radius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceTransparency {
                // 「降低透明度」:退化为不透明实底,布局不变
                shape.fill(MiauColor.surfaceSolid)
                    .overlay(shape.strokeBorder(MiauColor.borderSolid, lineWidth: 1))
            } else {
                ZStack {
                    // 内部模糊:视觉上等价于毛玻璃面板(窗口级材质由 MiauMeshBackground 提供)
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.white.opacity(style.whiteOpacity))
                    shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                }
                .saturation(style.saturation)
                .overlay(alignment: .top) {
                    // 顶部高光
                    Rectangle()
                        .fill(Color.white.opacity(style.highlightTop))
                        .frame(height: 1)
                        .padding(.horizontal, radius * 0.5)
                }
                .overlay(alignment: .trailing) {
                    if let right = style.highlightRight {
                        Rectangle()
                            .fill(Color.white.opacity(right))
                            .frame(width: 1)
                    }
                }
            }
        }
    }
}

/// 玻璃面板容器。**嵌套时不要再套第二层玻璃**(玻璃叠玻璃会糊成一团),
/// 内层改用 `MiauColor.borderSolid` 描边区分。
struct MiauGlassPanel<Content: View>: View {
    var style: MiauGlass = .panel
    var radius: CGFloat = MiauRadius.surface
    var padding: CGFloat = MiauSpacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                MiauGlassSurface(style: style, radius: radius)
                    .shadow(
                        color: style == .floating ? MiauShadow.float : MiauShadow.glass,
                        radius: style == .floating ? MiauShadow.floatRadius : MiauShadow.glassRadius,
                        y: style == .floating ? MiauShadow.floatY : MiauShadow.glassY
                    )
            }
    }
}

/// AppKit 材质回退封装。需要系统级材质(而非内部模糊)时使用。
struct MiauVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

#Preview {
    ZStack {
        MiauMeshBackground()
        VStack(spacing: MiauSpacing.lg) {
            MiauGlassPanel(style: .panel) { Text("内容面板 · 白 42%").font(MiauFont.body) }
            MiauGlassPanel(style: .panelStrong) { Text("卡片 · 白 52%").font(MiauFont.body) }
            MiauGlassPanel(style: .floating) { Text("浮动层 · 白 52% + 重投影").font(MiauFont.body) }
        }
        .padding(MiauSpacing.xl)
        .frame(width: 420)
    }
    .frame(width: 900, height: 620)
}
