import SwiftUI
import AppKit
import CoreText

enum AppType {
    private static let chinesePostScriptName = "LXGWWenKaiGBScreenR"
    private static let fontReady: Bool = {
        #if SWIFT_PACKAGE
        let resource = Bundle.module.url(forResource: chinesePostScriptName, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: chinesePostScriptName, withExtension: "ttf")
        #else
        let resource = Bundle.main.url(forResource: chinesePostScriptName, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: chinesePostScriptName, withExtension: "ttf")
        #endif
        guard let resource else { return NSFont(name: chinesePostScriptName, size: 15) != nil }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(resource as CFURL, .process, &error)
        return registered || NSFont(name: chinesePostScriptName, size: 15) != nil
    }()

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard fontReady else { return .system(size: size, weight: weight) }
        return .custom(chinesePostScriptName, size: size).weight(weight)
    }

    static func latin(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .semibold || weight == .bold ? "AvenirNext-DemiBold" :
            (weight == .medium ? "AvenirNext-Medium" : "AvenirNext-Regular")
        return .custom(name, size: size)
    }

    static func reading(_ size: CGFloat) -> Font { .custom("IowanOldStyle-Roman", size: size) }

    static let pageTitle = ui(24, weight: .semibold)
    static let sectionTitle = ui(17, weight: .semibold)
    static let body = ui(15)
    static let supporting = ui(13)
    static let caption = ui(11)
    static let studyText = reading(19)
}

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let standard: CGFloat = 16
    static let roomy: CGFloat = 24
    static let spacious: CGFloat = 32
}

enum AppPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let insetSurface = Color(nsColor: .textBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let secondaryInk = Color(nsColor: .secondaryLabelColor)
    static let tertiaryInk = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let selected = Color.accentColor.opacity(0.14)
    static let primaryActionText = Color(nsColor: .selectedControlTextColor)
}

enum GlassTheme {
    static let sidebarWidth: CGFloat = 210
    static let cardRadius: CGFloat = 36
    static let controlRadius: CGFloat = 20
    static let pageSpacing: CGFloat = 24
    static let magenta = Color(red: 0.18, green: 0.78, blue: 0.62)
    static let violet = Color(red: 0.33, green: 0.58, blue: 1.00)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 0.94)
    static let indigo = Color(red: 0.05, green: 0.09, blue: 0.16)
    static let secondaryText = Color.white.opacity(0.67)
    static let tertiaryText = Color.white.opacity(0.46)
    static let border = Color.white.opacity(0.16)
    static let animation = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

private final class ClearWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
    }
}

struct GlassWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct WindowBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct AppGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                GlassTheme.indigo
            } else {
                WindowBlurView()
                GlassTheme.indigo.opacity(0.34)
                RadialGradient(colors: [GlassTheme.magenta.opacity(0.46), .clear],
                               center: .topLeading, startRadius: 30, endRadius: 780)
                RadialGradient(colors: [Color(red: 0.20, green: 0.53, blue: 1.0).opacity(0.42), .clear],
                               center: .top, startRadius: 10, endRadius: 720)
                RadialGradient(colors: [GlassTheme.cyan.opacity(0.38), .clear],
                               center: .bottomLeading, startRadius: 10, endRadius: 650)
                RadialGradient(colors: [GlassTheme.violet.opacity(0.40), .clear],
                               center: .bottomTrailing, startRadius: 40, endRadius: 780)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let accent: Color
    @ViewBuilder let content: Content
    @State private var hovering = false

    init(accent: Color = GlassTheme.violet, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous)
                    .fill(reduceTransparency ? Color(red: 0.15, green: 0.13, blue: 0.29) : Color.white.opacity(hovering ? 0.12 : 0.10))
                    .overlay(alignment: .topTrailing) {
                        RadialGradient(colors: [accent.opacity(0.17), .clear], center: .topTrailing,
                                       startRadius: 0, endRadius: 240)
                            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.21 : 0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
            .offset(y: hovering ? -2 : 0)
            .onHover { hovering = $0 }
            .animation(GlassTheme.animation, value: hovering)
    }
}

    struct HistoryPanel<Content: View>: View {
        @ViewBuilder let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                content
                    .padding(14)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(GlassTheme.border, lineWidth: 1)
            }
    }
}

struct HistoryEntryChrome: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: GlassTheme.controlRadius, style: .continuous)

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.075), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

extension View {
    func historyEntryChrome() -> some View {
        modifier(HistoryEntryChrome())
    }
}

struct GlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                configuration.label
                    .font(AppType.ui(17, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                configuration.content
            }
        }
    }
}

struct AppActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppType.ui(15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(prominent
                          ? LinearGradient(colors: [GlassTheme.magenta.opacity(0.77), GlassTheme.violet.opacity(0.76)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [.white.opacity(0.19), .white.opacity(0.10)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(prominent ? 0.34 : 0.22), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.48)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

typealias SecondaryPlaybackButtonStyle = AppActionButtonStyle

struct FloatingStudyButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("开始学习")
                    .font(AppType.ui(13, weight: .bold))
                Image(systemName: "arrow.right")
                    .font(AppType.ui(17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 92, height: 92)
            .background {
                if #available(macOS 26.0, *) {
                    Circle()
                        .fill(LinearGradient(colors: [GlassTheme.magenta.opacity(0.80), GlassTheme.violet.opacity(0.80)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .glassEffect(.regular, in: Circle())
                } else {
                    Circle().fill(LinearGradient(colors: [GlassTheme.magenta, GlassTheme.violet],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: GlassTheme.magenta.opacity(hovering ? 0.48 : 0.30), radius: hovering ? 27 : 18, y: 7)
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(GlassTheme.animation, value: hovering)
        .accessibilityLabel("开始学习，进入听写")
    }
}
