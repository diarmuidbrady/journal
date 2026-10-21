import SwiftUI

/// Shows a cleanup against the original. Accept (optionally after editing) or discard.
struct CleanupReviewView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case cleaned = "Cleaned"
        case original = "Original"
        var id: Self { self }
    }

    let review: EntryEditorModel.CleanupReview
    let onAccept: (String) -> Void
    let onDiscard: () -> Void

    @State private var tab: Tab = .changes
    @State private var edited: String

    init(review: EntryEditorModel.CleanupReview, onAccept: @escaping (String) -> Void, onDiscard: @escaping () -> Void) {
        self.review = review
        self.onAccept = onAccept
        self.onDiscard = onDiscard
        _edited = State(initialValue: review.result.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if !review.result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Check these before accepting", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                        ForEach(review.result.warnings, id: \.self) { warning in
                            Text("• \(warning)").font(.callout)
                        }
                    }
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                }

                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .changes:
                    ScrollView {
                        Text(WordDiff.attributed(original: review.original, cleaned: edited))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Text("Struck-through red words are removed; green words are added. Edit on the Cleaned tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .cleaned:
                    TextEditor(text: $edited)
                        .scrollContentBackground(.hidden)
                case .original:
                    ScrollView {
                        Text(review.original)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
            .navigationTitle("Review cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive, action: onDiscard)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") { onAccept(edited) }
                        .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
