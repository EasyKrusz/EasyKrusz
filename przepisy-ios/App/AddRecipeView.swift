import SwiftUI
import SwiftData

@MainActor
struct AddRecipeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var notes = ""
    @State private var message: String?

    private var canSave: Bool {
        TikTokService.extractURL(from: link) != nil || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.tiktok.com/…", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { link = TikTokService.extractURL(from: s) ?? s }
                    }
                } header: {
                    Text(L.t("add.linkHeader"))
                } footer: {
                    Text(L.t("add.linkFooter"))
                }

                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                } header: {
                    Text(L.t("add.notesHeader"))
                } footer: {
                    Text(L.t("add.notesFooter"))
                }

                if let message {
                    Section { Text(message).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(L.t("recipe.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.save"), action: save).disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let (recipe, duplicate) = RecipeImporter.enqueue(link: link, notes: notes, in: context)
        if duplicate {
            message = L.t("add.duplicate", ["title": recipe.displayTitle])
            return
        }
        Task { await RecipeImporter.process(recipe, in: context) }
        dismiss()
    }
}
