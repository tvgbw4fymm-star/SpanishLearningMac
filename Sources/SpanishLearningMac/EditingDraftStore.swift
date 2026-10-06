import Foundation
import SwiftUI

@MainActor
final class EditingDraftStore: ObservableObject {
    private static let storageKey = "pendingEditingDrafts.v1"
    private let defaults: UserDefaults

    @Published private var drafts: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func draft(for key: String) -> String? {
        drafts[key]
    }

    func save(_ value: String, for key: String) {
        drafts[key] = value
        defaults.set(drafts, forKey: Self.storageKey)
    }

    func removeDraft(for key: String) {
        guard drafts.removeValue(forKey: key) != nil else { return }
        defaults.set(drafts, forKey: Self.storageKey)
    }

    func removeDrafts(withPrefix prefix: String) {
        let matchingKeys = drafts.keys.filter { $0.hasPrefix(prefix) }
        guard !matchingKeys.isEmpty else { return }
        matchingKeys.forEach { drafts.removeValue(forKey: $0) }
        defaults.set(drafts, forKey: Self.storageKey)
    }
}
