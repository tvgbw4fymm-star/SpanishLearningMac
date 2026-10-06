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
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let pageSpacing: CGFloat = 16
    static let magenta = Color.accentColor
    static let violet = Color.accentColor
    static let cyan = Color.accentColor
    static let indigo = AppPalette.canvas
    static let secondaryText = AppPalette.secondaryInk
    static let tertiaryText = AppPalette.tertiaryInk
    static let border = AppPalette.separator
    static let animation = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovering = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous)
                    .fill(AppPalette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.cardRadius, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : AppPalette.separator.opacity(0.65), lineWidth: 1)
            }
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
            .background(AppPalette.surface, in: shape)
            .overlay {
                shape.strokeBorder(AppPalette.separator, lineWidth: 1)
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
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            configuration.label
                .font(AppType.ui(15, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            configuration.content
        }
        .padding(.vertical, AppSpacing.small)
    }
}

struct AppActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppType.ui(13, weight: .semibold))
            .foregroundStyle(prominent ? AppPalette.primaryActionText : AppPalette.ink)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent
                          ? GlassTheme.magenta
                          : AppPalette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(prominent ? GlassTheme.magenta : AppPalette.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .foregroundStyle(AppPalette.primaryActionText)
            .frame(width: 92, height: 92)
            .background(GlassTheme.magenta, in: Circle())
            .overlay(Circle().strokeBorder(AppPalette.separator, lineWidth: 1))
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(GlassTheme.animation, value: hovering)
        .accessibilityLabel("开始学习，进入听写")
    }
}
