import SwiftUI
import AVFoundation
import AppKit

@main
@MainActor
struct SpanishLearningMacApp: App {
    @StateObject private var store = StudyStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 880, minHeight: 620)
                .task { _ = try? await store.createAutomaticBackup() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .inactive || phase == .background {
                        Task { _ = try? await store.createAutomaticBackup() }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum StudyScreen: String, CaseIterable, Identifiable {
    case overview = "总览"
    case listening = "听"
    case dictationHistory = "听写历史"
    case reading = "读"
    case readingHistory = "阅读历史"
    case writing = "写"
    case writingHistory = "写作历史"
    case cards = "卡片"
    case settings = "设置"

    var id: String { rawValue }
    var accent: Color {
        switch self {
        case .overview: GlassTheme.magenta
        case .listening: Color(red: 0.39, green: 0.70, blue: 1.00)
        case .dictationHistory: GlassTheme.cyan
        case .reading: Color(red: 0.44, green: 0.88, blue: 0.69)
        case .readingHistory: Color(red: 1.00, green: 0.69, blue: 0.45)
        case .writing: Color(red: 1.00, green: 0.72, blue: 0.40)
        case .writingHistory: Color(red: 0.40, green: 0.85, blue: 0.77)
        case .cards: GlassTheme.violet
        case .settings: Color(red: 0.61, green: 0.70, blue: 1.00)
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .listening: "waveform"
        case .dictationHistory: "clock.arrow.circlepath"
        case .reading: "text.book.closed"
        case .readingHistory: "books.vertical"
        case .writing: "square.and.pencil"
        case .writingHistory: "doc.text"
        case .cards: "rectangle.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var selectedScreen: StudyScreen? = .overview
    @State private var selectedArticleID: UUID?
    @State private var selectedAudioID: UUID?
    @State private var selectedSentenceID: UUID?
    @State private var selectedWritingExerciseID: UUID?
    @State private var cardSearchQuery = ""
    @State private var showDueCards = false
    @State private var sidebarCollapsed = false
    @State private var sidebarHovering = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Floating, collapsible sidebar
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(action: { sidebarCollapsed.toggle() }) {
                            Image(systemName: sidebarCollapsed ? "chevron.right" : "chevron.left")
                                .font(AppType.ui(12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(6)
                                .background(.white.opacity(0.08), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(sidebarCollapsed ? "展开侧边栏" : "收起侧边栏")
                        .accessibilityLabel(sidebarCollapsed ? "展开侧边栏" : "收起侧边栏")
                        .opacity(sidebarHovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: sidebarHovering)
                    }
                    .padding(.horizontal, sidebarCollapsed ? 6 : 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    ScrollView {
                        if #available(macOS 26.0, *) {
                            GlassEffectContainer(spacing: 0) {
                                sidebarRows
                            }
                        } else {
                            sidebarRows
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: sidebarCollapsed ? 72 : 230)
                .background {
                    // Glass floating card with rounded corners
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14)))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                }
                .padding(.leading, 16)
                .padding(.vertical, 16)
                .onHover { sidebarHovering = $0 }
            }
            .animation(GlassTheme.animation, value: sidebarCollapsed)

            // Detail content area
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.clear)
                .padding(.leading, 12)
        }
        .background(AppGlassBackground())
        .background(GlassWindowConfiguration().frame(width: 0, height: 0))
        .tint(GlassTheme.magenta)
        .font(AppType.ui(15, weight: .regular))
        .buttonStyle(AppActionButtonStyle())
        .preferredColorScheme(.dark)
        .groupBoxStyle(GlassGroupBoxStyle())
        .alert("本机资料读取错误", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebarRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebar(.overview).staggered(index: 0)
            sidebar(.listening).staggered(index: 1)
            sidebar(.reading).staggered(index: 2)
            sidebar(.writing).staggered(index: 3)
            sidebar(.cards).staggered(index: 4)
            if !sidebarCollapsed {
                Rectangle().fill(.white.opacity(0.16))
                    .frame(height: 1)
                    .padding(.vertical, 14)
                    .staggered(index: 5)
                Text("记录")
                    .font(AppType.ui(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.leading, 13)
                    .padding(.bottom, 2)
                    .staggered(index: 6)
            }
            sidebar(.dictationHistory).staggered(index: 7)
            sidebar(.readingHistory).staggered(index: 8)
            sidebar(.writingHistory).staggered(index: 9)
            if !sidebarCollapsed {
                Rectangle().fill(.white.opacity(0.16))
                    .frame(height: 1)
                    .padding(.vertical, 14)
                    .staggered(index: 10)
            }
            sidebar(.settings).staggered(index: 11)
        }
        .padding(.horizontal, sidebarCollapsed ? 10 : 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sidebar(_ screen: StudyScreen) -> some View {
        SidebarNavigationItem(screen: screen, selection: $selectedScreen)
            .environment(\.sidebarCollapsed, sidebarCollapsed)
    }

    @ViewBuilder private var detailContent: some View {
        switch selectedScreen ?? .overview {
        case .overview: OverviewView(selectedScreen: $selectedScreen, cardSearchQuery: $cardSearchQuery, showDueCards: $showDueCards)
        case .listening: ListeningView(selectedID: $selectedAudioID, selectedSentenceID: $selectedSentenceID)
        case .dictationHistory: DictationHistoryView(selectedMaterialID: $selectedAudioID,
                                                     selectedSentenceID: $selectedSentenceID,
                                                     selectedScreen: $selectedScreen)
        case .reading: ReadingView(selectedArticleID: $selectedArticleID)
        case .readingHistory: ReadingHistoryView(selectedArticleID: $selectedArticleID,
                                                 selectedScreen: $selectedScreen)
        case .writing: WritingView(selectedExerciseID: $selectedWritingExerciseID)
        case .writingHistory: WritingHistoryView(selectedExerciseID: $selectedWritingExerciseID,
                                                 selectedScreen: $selectedScreen)
        case .cards: CardsView(query: $cardSearchQuery, showDueCards: $showDueCards)
        case .settings: SettingsView()
        }
    }
}

private struct SidebarCollapsedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
private extension EnvironmentValues {
    var sidebarCollapsed: Bool {
        get { self[SidebarCollapsedKey.self] }
        set { self[SidebarCollapsedKey.self] = newValue }
    }
}

private struct SidebarNavigationItem: View {
    let screen: StudyScreen
    @Binding var selection: StudyScreen?
    @Environment(\.sidebarCollapsed) private var collapsed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: Bool { selection == screen }
    private var hoverAnimation: Animation { .easeOut(duration: 0.16) }
    private var selectAnimation: Animation { .easeInOut(duration: 0.22) }

    var body: some View {
        Button { selection = screen } label: {
            decoratedRow
                .contentShape(RoundedRectangle(cornerRadius: collapsed ? 14 : 23))
                .help(collapsed ? screen.rawValue : "")
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : selectAnimation, value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var rowContent: some View {
        HStack(spacing: collapsed ? 0 : 12) {
            Image(systemName: screen.symbol)
                .font(AppType.ui(collapsed ? 20 : 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(screen.accent)
                .frame(width: collapsed ? 40 : 30, height: collapsed ? 40 : 30)
                .background(screen.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            if !collapsed {
                Text(screen.rawValue)
                    .font(AppType.ui(15, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.88))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, collapsed ? 8 : 12)
        .frame(height: collapsed ? 44 : 48)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var decoratedRow: some View {
        if selected {
            if #available(macOS 26.0, *) {
                rowContent
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: collapsed ? 14 : 23))
                    .glassEffectTransition(.materialize)
                    .overlay(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.06), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: collapsed ? 14 : 23))
                    )
                    .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
                    .offset(y: -1)
            } else {
                rowContent
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: collapsed ? 14 : 23))
                    .overlay(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.06), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: collapsed ? 14 : 23))
                    )
                    .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
                    .offset(y: -1)
            }
        } else {
            rowContent
        }
    }
}

struct StudyChoiceBar<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option))
                        .font(AppType.ui(15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(.white)
                        .background(selection == option ? .white.opacity(0.22) : .white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 23))
                        .overlay(RoundedRectangle(cornerRadius: 23)
                            .strokeBorder(.white.opacity(selection == option ? 0.40 : 0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 30))
    }
}

struct StudyPickerChrome: ViewModifier {
    func body(content: Content) -> some View {
        let radius: CGFloat = 28
        let shape = Capsule(style: .continuous)
        return content
            .pickerStyle(.menu)
            .controlSize(.large)
            .foregroundStyle(GlassTheme.cyan)
            .tint(GlassTheme.cyan)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .background(
                LinearGradient(colors: [
                    .white.opacity(0.10),
                    .white.opacity(0.07)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: shape
            )
            .overlay {
                shape.strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
            }
            .overlay {
                // inner glow
                shape.fill(
                    RadialGradient(colors: [GlassTheme.cyan.opacity(0.18), .clear],
                                   center: .topTrailing, startRadius: 4, endRadius: 180)
                )
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .menuStyle(.borderlessButton)
            .focusEffectDisabled(true)
    }
}

extension View {
    func studyPickerChrome() -> some View { modifier(StudyPickerChrome()) }
}

struct StudyInputChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassTheme.controlRadius, style: .continuous)
        content
            .textFieldStyle(.plain)
            .background(.white.opacity(0.10), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.22)).allowsHitTesting(false))
            .clipShape(shape)
            .contentShape(shape)
    }
}

extension View {
    func studyInputChrome() -> some View { modifier(StudyInputChrome()) }
}

private struct StaggeredAppear: ViewModifier {
    let index: Int
    let baseDelay: Double
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.easeOut(duration: 0.22).delay(baseDelay + Double(index) * 0.05), value: appeared)
            .onAppear { appeared = true }
    }
}

private extension View {
    func staggered(index: Int, baseDelay: Double = 0.05) -> some View {
        modifier(StaggeredAppear(index: index, baseDelay: baseDelay))
    }
}

struct StudyEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol)
                .font(AppType.ui(25, weight: .light))
                .foregroundStyle(GlassTheme.cyan)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppType.ui(18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(AppType.ui(15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.67))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.15)))
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(AppType.ui(12, weight: .semibold))
                .tracking(2)
                .foregroundStyle(GlassTheme.cyan)
            Text(title)
                .font(AppType.ui(32, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))
            Text(subtitle)
                .foregroundStyle(GlassTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }
}


private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

struct ActivityHeatmap: View {
    let database: StudyDatabase
    private let columns = Array(repeating: GridItem(.flexible(minimum: 12, maximum: 22), spacing: 5), count: 30)

    private var hasRecentActivity: Bool {
        let calendar = Calendar.current
        let earliest = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -89, to: .now) ?? .now)
        return dailyWords().contains { $0.key >= earliest && ($0.value.listening + $0.value.reading + $0.value.writing) > 0 }
    }

    private func dailyWords() -> [Date: (listening: Int, reading: Int, writing: Int)] {
        let calendar = Calendar.current
        var result: [Date: (listening: Int, reading: Int, writing: Int)] = [:]
        for attempt in database.dictationAttempts {
            let day = calendar.startOfDay(for: attempt.submittedAt)
            var value = result[day] ?? (0, 0, 0)
            value.listening += wordCount(attempt.text)
            result[day] = value
        }
        for record in database.readingRecords {
            let day = calendar.startOfDay(for: record.completedAt)
            let chunk = database.articles.first(where: { $0.id == record.articleID })?.chunks.first(where: { $0.id == record.chunkID })
            var value = result[day] ?? (0, 0, 0)
            value.reading += wordCount(chunk?.text ?? "")
            result[day] = value
        }
        for exercise in database.writingExercises {
            for version in exercise.versions {
                let day = calendar.startOfDay(for: version.submittedAt)
                var value = result[day] ?? (0, 0, 0)
                value.writing += wordCount(version.spanishText)
                result[day] = value
            }
        }
        return result
    }

    var body: some View {
        let calendar = Calendar.current
        let counts = dailyWords()
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach((0..<90).reversed(), id: \.self) { offset in
                    let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now)
                    let value = counts[date] ?? (0, 0, 0)
                    let total = value.listening + value.reading + value.writing
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Self.color(for: total))
                        .aspectRatio(1, contentMode: .fit)
                        .help("\(date.formatted(date: .abbreviated, time: .omitted))：听 \(value.listening)、读 \(value.reading)、写 \(value.writing) 词")
                        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，共 \(total) 词")
                }
            }
            if !hasRecentActivity {
                Text("最近 90 天暂无学习记录；完成听写、阅读或写作后，对应日期会着色。")
                    .font(AppType.ui(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .frame(maxWidth: 800, alignment: .leading)
        .padding(.vertical, 8)
    }

    static func color(for words: Int) -> Color {
        switch words {
        case 0: Color.white.opacity(0.08)
        case 1..<30: GlassTheme.cyan.opacity(0.33)
        case 30..<100: GlassTheme.cyan.opacity(0.52)
        case 100..<250: GlassTheme.violet.opacity(0.72)
        default: GlassTheme.magenta.opacity(0.9)
        }
    }
}

struct DevelopmentPage: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(AppType.ui(42, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text(title).font(AppType.ui(32, weight: .medium))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            Text("原生开发预览")
                .font(AppType.ui(12, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var pendingRestore: URL?
    @State private var backupSummary: BackupSummary?
    @State private var showRestoreConfirmation = false
    @State private var notice: String?
    @State private var apiKeyInput = ""
    @State private var hasAPIKey = false
    @State private var keyNotice: String?
    @State private var selectedAIProvider = AIProviderSettings.selected
    @State private var modelInput = ""
    @State private var endpointInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(eyebrow: "Settings", title: "设置", subtitle: "本机资料、备份与迁移。")
                    .padding(0)
                GroupBox("本机资料目录") {
                    HStack {
                        Text(store.supportDirectory.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.supportDirectory]) }
                    }
                    .padding(.vertical, 8)
                }
                GroupBox("备份与恢复") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("备份包含学习记录和已导入音频。应用启动和离开前会更新当天的自动备份，并保留最近 14 份；手动备份和恢复前副本不会被自动清理。更换 Mac 后，在新应用中选择备份即可恢复；API 密钥需在新电脑重新填写。")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("创建本地备份…") { chooseBackupDestination() }
                                .buttonStyle(AppActionButtonStyle(prominent: true))
                            Button("从备份恢复…") { chooseBackupToRestore() }
                                .buttonStyle(AppActionButtonStyle())
                            if store.transferInProgress { ProgressView().controlSize(.small) }
                        }
                        .disabled(store.transferInProgress)
                        if let notice { Text(notice).font(AppType.ui(15, weight: .regular)).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                GroupBox("AI 服务") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("学习解释、阅读问答、写作反馈和卡片修订均使用 DeepSeek。音频转写在这台 Mac 上完成，无需上传音频或填写第二个密钥。")
                            .foregroundStyle(.secondary)
                        TextField("模型", text: $modelInput)
                            .studyInputChrome()
                        Button("保存模型") { saveAIOptions() }
                            .buttonStyle(AppActionButtonStyle())
                        SecureField("\(selectedAIProvider.title) API 密钥", text: $apiKeyInput)
                            .studyInputChrome()
                        HStack {
                            Button("保存密钥") { saveAPIKey() }
                                .buttonStyle(AppActionButtonStyle(prominent: true))
                                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if hasAPIKey { Button("删除已保存密钥") { deleteAPIKey() } }
                            if hasAPIKey { Text("已保存").foregroundStyle(.secondary) }
                        }
                        if let keyNotice { Text(keyNotice).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary) }
                        Text("密钥只保存在这台 Mac 的钥匙串，不会写入学习资料或备份。")
                            .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                GroupBox("首页插画来源") {
                    HStack {
                        Text("首页贴纸由 Gohsantosadrive 设计，素材来自 Flaticon。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link("查看作者与素材", destination: URL(string: "https://www.flaticon.com/authors/gohsantosadrive")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(32)
        }
        .onAppear { loadAPIKeyStatus() }
        .confirmationDialog("确认恢复这份备份？", isPresented: $showRestoreConfirmation) {
            Button("恢复并保留当前资料副本") { restoreSelectedBackup() }
            Button("取消", role: .cancel) { pendingRestore = nil; backupSummary = nil }
        } message: {
            if let backupSummary {
                Text("备份创建于 \(backupSummary.createdAt.formatted(date: .abbreviated, time: .shortened))；包含 \(backupSummary.audioCount) 段音频、\(backupSummary.articleCount) 篇文章、\(backupSummary.readingCount) 条阅读记录、\(backupSummary.writingCount) 个写作练习和 \(backupSummary.cardCount) 张卡片。恢复后会替换当前学习资料，并保留恢复前副本。")
            }
        }
    }

    private func loadAPIKeyStatus() {
        selectedAIProvider = AIProviderSettings.selected
        modelInput = AIProviderSettings.model(for: selectedAIProvider)
        endpointInput = AIProviderSettings.compatibleEndpoint
        do {
            hasAPIKey = try APIKeyStore.read(for: selectedAIProvider) != nil
        } catch { keyNotice = error.localizedDescription }
    }

    private func saveAIOptions() {
        AIProviderSettings.setModel(modelInput, for: selectedAIProvider)
        do {
            _ = try AIProviderSettings.endpoint(for: selectedAIProvider)
            guard !AIProviderSettings.model(for: selectedAIProvider).isEmpty else { throw AIProviderError.missingModel }
            keyNotice = "DeepSeek 模型已保存。"
        } catch { keyNotice = error.localizedDescription }
    }

    private func saveAPIKey() {
        do {
            try APIKeyStore.save(apiKeyInput, for: selectedAIProvider)
            apiKeyInput = ""
            hasAPIKey = true
            keyNotice = "密钥已安全保存。"
        } catch { keyNotice = error.localizedDescription }
    }

    private func deleteAPIKey() {
        do {
            try APIKeyStore.delete(for: selectedAIProvider)
            apiKeyInput = ""
            hasAPIKey = false
            keyNotice = "密钥已从钥匙串删除。"
        } catch { keyNotice = error.localizedDescription }
    }

    private func chooseBackupDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "西语学习备份-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        notice = "正在创建备份…"
        Task {
            do {
                let result = try await store.createBackup(at: destination)
                notice = "备份已保存：\(destination.path)（\(result.audioCount) 段音频、\(result.articleCount) 篇文章、\(result.writingCount) 个写作练习）。"
            } catch { notice = "备份失败：\(error.localizedDescription)" }
        }
    }

    private func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        notice = "正在检查备份…"
        Task {
            do {
                backupSummary = try await store.inspectBackup(at: source)
                pendingRestore = source
                notice = nil
                showRestoreConfirmation = true
            } catch { notice = "无法恢复：\(error.localizedDescription)" }
        }
    }

    private func restoreSelectedBackup() {
        guard let source = pendingRestore else { return }
        notice = "正在恢复资料…"
        Task {
            do {
                let safetyCopy = try await store.restoreBackup(at: source)
                if let safetyCopy {
                    notice = "恢复完成。原有资料已保存在：\(safetyCopy.path)"
                } else {
                    notice = "恢复完成，学习资料已载入。"
                }
            } catch { notice = "恢复失败：\(error.localizedDescription)" }
            pendingRestore = nil
            backupSummary = nil
        }
    }
}

private struct CardDetailSheet: View {
    @Binding var feedback: String

    var body: some View {
        draftControls()
    }

    @ViewBuilder
    private func draftControls() -> some View {
        TextField("例如：增加例句；解释得更具体；突出动词本质含义", text: $feedback, axis: .vertical)
            .studyInputChrome()
            .frame(minHeight: 100)
    }
}
