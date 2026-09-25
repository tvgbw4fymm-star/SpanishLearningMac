import SwiftUI

enum CardSourceKind: String, Hashable {
    case listening
    case reading
    case writing
    case unknown

    var tagKind: CardTagKind {
        .source(self)
    }
}

enum CardTagKind: Hashable {
    case category(CardCategory)
    case source(CardSourceKind)

    var label: String {
        switch self {
        case .category(let category): return category.rawValue
        case .source(let source):
            switch source {
            case .listening: return "听力"
            case .reading: return "阅读"
            case .writing: return "写作"
            case .unknown: return "来源"
            }
        }
    }

    var icon: String? {
        switch self {
        case .category: return nil
        case .source(let source):
            switch source {
            case .listening: return "headphones"
            case .reading: return "book"
            case .writing: return "pencil"
            case .unknown: return "link"
            }
        }
    }

    var color: Color {
        switch self {
        case .category(let category):
            switch category {
            case .vocabulary: return .blue
            case .expression: return .teal
            case .grammar: return .purple
            case .knowledge: return .yellow
            case .correction: return .pink
            }
        case .source(let source):
            switch source {
            case .listening: return .orange
            case .reading: return .cyan
            case .writing: return .pink
            case .unknown: return .secondary
            }
        }
    }
}

struct CardTagView: View {
    let kind: CardTagKind
    var showsIcon = true

    var body: some View {
        HStack(spacing: 5) {
            if showsIcon, let icon = kind.icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(kind.label)
        }
        .font(AppType.ui(12, weight: .semibold))
        .foregroundStyle(kind.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(kind.color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.30), lineWidth: 1))
    }
}

enum CardSourceResolver {
    static func kind(for source: SourceReference, in database: StudyDatabase) -> CardSourceKind {
        if database.audioMaterials.contains(where: { $0.id == source.materialID }) {
            return .listening
        }
        if database.articles.contains(where: { $0.id == source.materialID }) {
            return .reading
        }
        if database.writingExercises.contains(where: { $0.id == source.materialID }) {
            return .writing
        }
        return .unknown
    }
}
