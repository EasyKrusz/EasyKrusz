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
                    Text("Link do filmiku")
                } footer: {
                    Text("W TikToku: Udostępnij → Kopiuj link.")
                }

                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                } header: {
                    Text("Notatki (opcjonalnie)")
                } footer: {
                    Text("Jeśli przepis jest tylko mówiony w filmiku, wpisz tu składniki lub kroki – zostaną połączone z opisem.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Nowy przepis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz", action: save).disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let (recipe, duplicate) = RecipeImporter.enqueue(link: link, notes: notes, in: context)
        if duplicate {
            message = "Ten filmik jest już zapisany: „\(recipe.displayTitle)”."
            return
        }
        Task { await RecipeImporter.process(recipe, in: context) }
        dismiss()
    }
}
