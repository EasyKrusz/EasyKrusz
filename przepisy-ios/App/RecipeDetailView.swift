import SwiftUI
import SwiftData

@MainActor
struct RecipeDetailView: View {
    @Bindable var recipe: Recipe
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        List {
            header

            switch recipe.status {
            case .pending, .processing:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Pobieram opis i układam przepis…")
                    }
                }
            case .failed:
                Section {
                    Label(recipe.errorMessage.isEmpty ? "Nie udało się przetworzyć." : recipe.errorMessage,
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Spróbuj ponownie", systemImage: "arrow.clockwise", action: reprocess)
                }
            case .ready:
                content
            }

            Section("Moje notatki") {
                TextEditor(text: $recipe.notes)
                    .frame(minHeight: 90)
                if recipe.status == .failed || recipe.status == .ready {
                    Text("Po zmianie notatek możesz przetworzyć przepis ponownie – zostaną uwzględnione.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !recipe.originalDescription.isEmpty {
                Section {
                    DisclosureGroup("Oryginalny opis z TikToka") {
                        Text(recipe.originalDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                if let url = URL(string: recipe.sourceURL), !recipe.sourceURL.isEmpty {
                    Link(destination: url) { Label("Otwórz filmik w TikToku", systemImage: "play.rectangle") }
                }
                if recipe.status == .ready {
                    Button("Przetwórz ponownie", systemImage: "arrow.clockwise", action: reprocess)
                }
                Button("Usuń przepis", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(recipe.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if recipe.status == .ready {
                    ShareLink(item: recipe.shareText) { Image(systemName: "square.and.arrow.up") }
                }
                Button {
                    recipe.favorite.toggle()
                } label: {
                    Image(systemName: recipe.favorite ? "star.fill" : "star")
                }
            }
        }
        .confirmationDialog("Usunąć „\(recipe.displayTitle)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                context.delete(recipe)
                try? context.save()
                dismiss()
            }
        }
        .onDisappear { try? context.save() }
    }

    // MARK: - Sekcje

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if !recipe.thumbnailURL.isEmpty {
                    Thumbnail(url: recipe.thumbnailURL)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(recipe.displayTitle).font(.title2.bold())
                if !recipe.summary.isEmpty {
                    Text(recipe.summary).foregroundStyle(.secondary)
                }
                let facts: [(String, String)] = [
                    ("person.2", recipe.servings),
                    ("timer", recipe.prepTime.isEmpty ? "" : "przygotowanie: \(recipe.prepTime)"),
                    ("flame", recipe.cookTime.isEmpty ? "" : "gotowanie: \(recipe.cookTime)"),
                ].filter { !$0.1.isEmpty }
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(facts.indices, id: \.self) { i in
                            Label(facts[i].1, systemImage: facts[i].0).font(.subheadline)
                        }
                    }
                }
                if !recipe.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(recipe.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.brand.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                if !recipe.author.isEmpty {
                    Text("@\(recipe.author)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, item in
                if !item.group.isEmpty && (index == 0 || recipe.ingredients[index - 1].group != item.group) {
                    Text(item.group).font(.subheadline.bold()).foregroundStyle(.secondary)
                }
                CheckRow(done: recipe.isChecked("i\(index)")) {
                    recipe.toggleChecked("i\(index)")
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name)
                        Spacer()
                        Text(item.amount).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Składniki")
        } footer: {
            Text("Stuknij, żeby odhaczyć.")
        }

        Section("Przygotowanie") {
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                CheckRow(done: recipe.isChecked("s\(index)")) {
                    recipe.toggleChecked("s\(index)")
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).").bold().foregroundStyle(Color.brand)
                        Text(step)
                    }
                }
            }
        }

        if !recipe.tips.isEmpty {
            Section("Wskazówki") {
                ForEach(recipe.tips, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb").font(.subheadline)
                }
            }
        }

        if recipe.checked.isEmpty == false {
            Section {
                Button("Wyczyść odhaczenia", systemImage: "checklist.unchecked") { recipe.checked = [] }
            }
        }
    }

    private func reprocess() {
        Task { await RecipeImporter.process(recipe, in: context) }
    }
}

/// Wiersz, który można odhaczyć stuknięciem (składnik albo krok).
struct CheckRow<Content: View>: View {
    let done: Bool
    let toggle: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.secondary : Color.brand)
                label()
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
