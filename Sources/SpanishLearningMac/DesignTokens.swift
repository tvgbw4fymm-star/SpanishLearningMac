import SwiftUI
import AppKit
import CoreText

// MARK: - 色彩

/// 全应用配色。**只有一个彩色主色(珊瑚)**,其余为中性色与三个语义色。
/// 所有值来自《西语喵 · 设计系统规范 v2.8》§2.2。
enum MiauColor {
    // 主色(唯一彩色)
    static let primary = Color(light: 0xF2764B, dark: 0xFF8A5E)
    static let primaryDeep = Color(light: 0xC9502A, dark: 0xE06B3E)
    static let primarySoft = Color(light: 0xFDE4DA, dark: 0x4A2A20)

    // 中性
    static let canvas = Color(light: 0xF7FBFE, dark: 0x141A1F)
    static let surfaceSolid = Color(light: 0xFFFFFF, dark: 0x1C242B)
    static let ink = Color(light: 0x23303A, dark: 0xE8EFF5)
    static let inkSecondary = Color(light: 0x5F7280, dark: 0x9FB0BD)
    static let inkTertiary = Color(light: 0x93A5B2, dark: 0x7C8C99)
    static let borderSolid = Color(light: 0xDCE7EF, dark: 0x2E3A44)
    static let borderStrong = Color(light: 0xB9CBD8, dark: 0x44525E)

    // 语义色(只允许 3 个;且必须配形状或文字,不得单独用颜色表意)
    static let success = Color(light: 0x3FA98A, dark: 0x43C4B9)
    static let successSoft = Color(light: 0xE3F3EE, dark: 0x1E3833)
    static let warning = Color(light: 0xD9A03C, dark: 0xF2BB5C)
    static let warningSoft = Color(light: 0xFBF0DC, dark: 0x3D3220)
    static let danger = Color(light: 0xD96A6A, dark: 0xE8837F)
    static let dangerSoft = Color(light: 0xFBE9E9, dark: 0x3D2424)

    // 进度热力图:主色单色梯度(空 → 最强)
    static let heatEmpty = Color(light: 0xF6F0EC, dark: 0x232A30)
    static let heat1 = Color(light: 0xFBE0D5, dark: 0x4A2A20)
    static let heat2 = Color(light: 0xF0A98A, dark: 0x8A4630)
    static let heat3 = Color(light: 0xEE7F52, dark: 0xC2603C)
    static let heat4 = Color(light: 0xC9502A, dark: 0xE0764C)
}

extension Color {
    /// 支持浅色 / 深色两套取值的动态颜色。
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 字体

/// 字体栈。中文 = Hiragino Sans GB(系统字体),西语正文 = Source Serif 4(随包分发)。
///
/// ⚠️ 两个必须遵守的实现细节:
/// 1. Hiragino **不是可变字体**,只有 W3 / W6 两个字面,`Font.weight()` 不可靠,
///    必须显式取 PostScript 名。
/// 2. **绝不要用** `.HiraginoSansGBInterface-W3/-W6` —— 点号开头是 CoreText 保留名,
///    会被静默替换成 Times New Roman。
enum MiauFont {
    static let chineseRegularName = "HiraginoSansGB-W3"
    static let chineseBoldName = "HiraginoSansGB-W6"

    /// ⚠️ 实测:注册这个可变字体后,PostScript 名是 `SourceSerif4Roman-Regular`,
    /// **不是** `SourceSerif4-Regular`。写成后者会静默回退成系统衬线字体。
    static let serifName = "SourceSerif4Roman-Regular"
    static let serifEmphasisName = "SourceSerif4Roman-SemiBold"

    /// 注册随包分发的 Source Serif 4(可变字体)。
    ///
    /// ⚠️ SwiftPM 会把 Resources/ 下的文件**拍平**到 bundle 根目录,
    /// 所以按裸文件名找(不能只写 subdirectory)。
    private static let serifReady: Bool = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let url = bundle.url(forResource: "SourceSerif4-VF", withExtension: "ttf")
            ?? bundle.url(forResource: "SourceSerif4-VF", withExtension: "ttf", subdirectory: "Fonts")
        guard let url else { return NSFont(name: serifName, size: 19) != nil }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return registered || NSFont(name: serifName, size: 19) != nil
    }()

    /// 触发字体注册。App 启动时调用一次即可。
    static func ensureFontsLoaded() { _ = serifReady }

    /// 中文界面字体。`bold: true` 取 W6,否则 W3。
    static func ui(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? chineseBoldName : chineseRegularName, size: size)
    }

    /// 西语学习正文(衬线)。
    static func spanish(_ size: CGFloat) -> Font {
        .custom(serifName, size: size)
    }

    static let display = ui(30, bold: true)
    static let pageTitle = ui(24, bold: true)
    static let sectionTitle = ui(17, bold: true)
    static let body = ui(15)
    static let supporting = ui(13)
    static let caption = ui(11)
    static let studyES = spanish(19)
    static let studyESLarge = spanish(26)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let labelLatin = Font.custom("AvenirNext-DemiBold", size: 11)
}

/// 中文字体可用性自检。开发期用它确认没有静默回退成系统字体。
enum MiauFontCheck {
    static var isChineseRegularAvailable: Bool { NSFont(name: MiauFont.chineseRegularName, size: 15) != nil }
    static var isChineseBoldAvailable: Bool { NSFont(name: MiauFont.chineseBoldName, size: 15) != nil }

    static func report() -> String {
        let w3 = isChineseRegularAvailable ? "OK" : "缺失(会回退系统字体)"
        let w6 = isChineseBoldAvailable ? "OK" : "缺失(会回退系统字体)"
        return "HiraginoSansGB-W3: \(w3) / HiraginoSansGB-W6: \(w6)"
    }
}

// MARK: - 间距 / 圆角 / 阴影 / 动效

enum MiauSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum MiauRadius {
    static let control: CGFloat = 10
    static let surface: CGFloat = 16
    static let large: CGFloat = 22
}

enum MiauShadow {
    /// 玻璃面板极轻投影,仅用于区分层次。
    static let glass = Color.black.opacity(0.04)
    static let glassRadius: CGFloat = 2
    static let glassY: CGFloat = 1

    /// 浮动层(检查器、奖励卡)。
    static let float = Color.black.opacity(0.10)
    static let floatRadius: CGFloat = 28
    static let floatY: CGFloat = 8
}

enum MiauMotion {
    static let easeQuick = Animation.easeOut(duration: 0.14)
    static let springSoft = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let popReward = Animation.spring(response: 0.35, dampingFraction: 0.6)
    /// 背景网格漂移:6 秒一轮,位移极小。
    static let meshDriftDuration: Double = 6
}

// MARK: - 模块

/// 五个学习模块 + 记录区。**模块之间不再用颜色区分**(图标自带色彩),
/// 这里只提供图标资源名与显示文案。
enum MiauModule: String, CaseIterable, Identifiable {
    case listening
    case reading
    case writing
    case cards
    case progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listening: "听"
        case .reading: "读"
        case .writing: "写"
        case .cards: "卡片"
        case .progress: "进度"
        }
    }

    var subtitle: String {
        switch self {
        case .listening: "我念给你听"
        case .reading: "我们一起读一段"
        case .writing: "写错了也没关系"
        case .cards: "该复习啦"
        case .progress: "连续打卡 / 成就"
        }
    }

    /// 与 Resources/Stickers/ 下的 PNG 文件名一一对应。
    var stickerName: String { rawValue }

    /// 空状态 / 奖励用的自然插画名(Resources/Nature/,已归档 10 张)。
    var emptyStateIllustration: String {
        switch self {
        case .listening: "bird"
        case .reading: "bee"
        case .writing: "mouse"
        case .cards: "butterflies"
        case .progress: "whale"
        }
    }
}
