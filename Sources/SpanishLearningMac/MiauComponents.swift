import SwiftUI
import AppKit

// MARK: - 贴纸图标

/// 贴纸 / 插画显示组件。所有图片都从 bundle 根目录按裸文件名加载
/// (SwiftPM 会拍平 Resources/,子目录参数无效)。
struct MiauArtwork: View {
    enum Variant {
        /// 导航用:原色,可轻微弱化
        case icon(opacity: Double = 1)
        /// 空状态 / 奖励用:大尺寸插画,不裁切、不加阴影
        case illustration
    }

    let name: String
    var size: CGFloat
    var variant: Variant = .icon()

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                // 资源缺失时的兜底,避免出现空白
                RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                    .fill(MiauColor.borderSolid)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(MiauColor.inkTertiary)
                    }
            }
        }
        .modifier(ArtworkVariantModifier(variant: variant))
        .accessibilityHidden(true)
        .task(id: name) { load() }
        .onAppear { if image == nil { load() } }
    }

    private func load() {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let loaded = NSImage(contentsOf: url) else { return }
        image = loaded
    }
}

private struct ArtworkVariantModifier: ViewModifier {
    let variant: MiauArtwork.Variant

    func body(content: Content) -> some View {
        switch variant {
        case .icon(let opacity):
            content.opacity(opacity)
        case .illustration:
            content
        }
    }
}

// MARK: - 侧边栏

/// 侧边栏顶部品牌区。猫头像保留原色 —— 它是品牌锚点。
struct MiauSidebarBrand: View {
    var body: some View {
        HStack(spacing: MiauSpacing.sm) {
            MiauArtwork(name: "mascot-cat", size: 28)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 0) {
                Text("西语喵").font(MiauFont.ui(13, bold: true))
                Text("SPANISH MIAU")
                    .font(MiauFont.labelLatin)
                    .foregroundStyle(MiauColor.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 侧边栏导航行。选中态用白色叠加 + 主色文字 + 左侧指示条,**不用实心色块**。
struct MiauModuleRow: View {
    let title: String
    let stickerName: String?
    let isSelected: Bool
    var dimmed = false

    var body: some View {
        HStack(spacing: MiauSpacing.sm) {
            if let stickerName {
                MiauArtwork(name: stickerName, size: 18, variant: .icon(opacity: dimmed ? 0.62 : 1))
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(MiauColor.inkSecondary)
                    .frame(width: 18, height: 18)
            }
            Text(title)
                .font(MiauFont.ui(13, bold: isSelected))
                .foregroundStyle(isSelected ? MiauColor.primaryDeep : (dimmed ? MiauColor.inkSecondary : MiauColor.ink))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MiauSpacing.sm)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                    .fill(Color.white.opacity(0.62))
                    .overlay {
                        RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                    }
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(MiauColor.primary)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 连续打卡徽章。
struct MiauStreakBadge: View {
    let days: Int
    let todaySummary: String
    /// 当周七天是否已打卡(周一为首)
    var weekActive: [Bool] = Array(repeating: false, count: 7)

    var body: some View {
        HStack(spacing: MiauSpacing.sm) {
            MiauArtwork(name: "progress", size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("连续 \(days) 天").font(MiauFont.ui(12, bold: true))
                Text(todaySummary)
                    .font(MiauFont.ui(10))
                    .foregroundStyle(MiauColor.inkTertiary)
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { index in
                        Circle()
                            .fill(index < weekActive.count && weekActive[index]
                                  ? MiauColor.primary
                                  : MiauColor.borderSolid)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MiauSpacing.sm)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                .fill(Color.white.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                }
        }
    }
}

// MARK: - 页面头与画布

/// 模块页面头:图标 + 标题 + 人格化副标题 + 右侧操作。
struct MiauModuleHeader<Trailing: View>: View {
    let module: MiauModule?
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: MiauSpacing.md) {
            if let module {
                MiauArtwork(name: module.stickerName, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(MiauFont.ui(16, bold: true))
                Text(subtitle)
                    .font(MiauFont.ui(11))
                    .foregroundStyle(MiauColor.inkSecondary)
            }
            Spacer(minLength: MiauSpacing.md)
            trailing
        }
        .padding(.horizontal, MiauSpacing.lg)
        .padding(.vertical, MiauSpacing.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MiauColor.borderSolid.opacity(0.6)).frame(height: 1)
        }
    }
}

/// 学习主区容器:限宽居中,白底面板,不加阴影。
struct MiauStudyCanvas<Content: View>: View {
    var maxWidth: CGFloat = 940
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 按钮

/// 主按钮:珊瑚实底,每屏最多 1 个。
struct MiauPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MiauFont.ui(12.5, bold: true))
            .foregroundStyle(.white)
            .padding(.horizontal, MiauSpacing.md)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                    .fill(MiauColor.primary)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(MiauMotion.easeQuick, value: configuration.isPressed)
    }
}

/// 次级按钮:玻璃底 + 高光描边。
struct MiauSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MiauFont.ui(12.5))
            .foregroundStyle(MiauColor.ink)
            .padding(.horizontal, MiauSpacing.md)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                    .fill(Color.white.opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: MiauRadius.control, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                    }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(MiauMotion.easeQuick, value: configuration.isPressed)
    }
}

/// 幽灵按钮:低权重动作(重新分析、再听一次)。
struct MiauGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MiauFont.ui(12.5))
            .foregroundStyle(MiauColor.inkSecondary)
            .padding(.horizontal, MiauSpacing.sm)
            .frame(minHeight: 30)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .animation(MiauMotion.easeQuick, value: configuration.isPressed)
    }
}

// MARK: - 空状态

/// 空状态:**用自然插画**(80–140pt),不裁圆、不加阴影。
struct MiauEmptyState: View {
    let illustrationName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: MiauSpacing.md) {
            MiauArtwork(name: illustrationName, size: 130, variant: .illustration)
            Text(title).font(MiauFont.ui(17, bold: true))
            Text(message)
                .font(MiauFont.body)
                .foregroundStyle(MiauColor.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(MiauPrimaryButtonStyle())
                    .padding(.top, MiauSpacing.xs)
            }
        }
        .frame(maxWidth: 420)
        .padding(MiauSpacing.xl)
    }
}

// MARK: - 胶囊标签

struct MiauPill: View {
    let text: String
    var tone: Tone = .neutral
    var selected = false

    enum Tone { case neutral, success, warning, danger, primary }

    var body: some View {
        Text(text)
            .font(MiauFont.ui(10.5))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: selected ? MiauColor.primaryDeep : MiauColor.inkSecondary
        case .success: MiauColor.success
        case .warning: MiauColor.warning
        case .danger: MiauColor.danger
        case .primary: MiauColor.primaryDeep
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: selected ? MiauColor.primarySoft : Color.white.opacity(0.55)
        case .success: MiauColor.successSoft
        case .warning: MiauColor.warningSoft
        case .danger: MiauColor.dangerSoft
        case .primary: MiauColor.primarySoft
        }
    }

    private var border: Color {
        switch tone {
        case .neutral: selected ? MiauColor.primary.opacity(0.35) : Color.white.opacity(0.55)
        case .success: MiauColor.success.opacity(0.3)
        case .warning: MiauColor.warning.opacity(0.35)
        case .danger: MiauColor.danger.opacity(0.3)
        case .primary: MiauColor.primary.opacity(0.35)
        }
    }
}
