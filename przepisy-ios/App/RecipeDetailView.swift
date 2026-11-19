import SwiftUI
import SwiftData

@MainActor
struct RecipeDetailView: View {
    @Bindable var recipe: Recipe
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var cooking = false
    @State private var showOriginal = false
    @State private var translating = false
    @State private var translateError: String?

    // MARK: - Język

    private var preferred: String { L.recipeLang }
    private var hasOriginal: Bool { !recipe.sourceLanguage.isEmpty && recipe.sourceLanguage != preferred }
    private var viewLang: String { showOriginal && hasOriginal ? recipe.sourceLanguage : preferred }
    /// Tekst w wybranym języku albo nil, gdy tłumaczenia jeszcze nie ma.
    private var shown: LocalizedRecipe? { recipe.text(in: viewLang) }
    /// To, co pokazujemy: wybrany język, a do czasu tłumaczenia – zapisany.
    private var r: LocalizedRecipe { shown ?? recipe.base }

    var body: some View {
        List {
            header

            switch recipe.status {
            case .pending, .processing:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t(recipe.needsSpeech ? "status.speech" : "detail.working"))
                            Text(L.t("detail.workingHint"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            case .failed:
                Section {
                    Label(recipe.errorMessage.isEmpty ? L.t("detail.failed") : recipe.errorMessage,
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button(L.t("detail.retry"), systemImage: "arrow.clockwise", action: reprocess)
                }
            case .ready:
                content
            }

            Section(L.t("recipe.myNotes")) {
                TextEditor(text: $recipe.notes)
                    .frame(minHeight: 90)
                if recipe.status == .failed || recipe.status == .ready {
                    Text(L.t("detail.notesHint"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !recipe.originalDescription.isEmpty {
                Section {
                    DisclosureGroup(L.t("recipe.originalDescription")) {
                        Text(recipe.originalDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, L.direction(ofText: recipe.originalDescription))
                    }
                }
            }

            if !recipe.transcript.isEmpty {
                Section {
                    DisclosureGroup(L.t("recipe.transcript")) {
                        Text(recipe.transcript)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, L.direction(ofText: recipe.transcript))
                    }
                }
            }

            Section {
                if let url = URL(string: recipe.sourceURL), !recipe.sourceURL.isEmpty {
                    Link(destination: url) { Label(L.t("recipe.openVideo"), systemImage: "play.rectangle") }
                }
                if recipe.status == .ready {
                    Button(L.t("detail.reprocess"), systemImage: "arrow.clockwise", action: reprocess)
                }
                Button(L.t("detail.delete"), systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(r.title.isEmpty ? recipe.displayTitle : r.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if recipe.status == .ready {
                    ShareLink(item: recipe.shareText(r)) { Image(systemName: "square.and.arrow.up") }
                }
                Button {
                    recipe.favorite.toggle()
                } label: {
                    Image(systemName: recipe.favorite ? "star.fill" : "star")
                }
                .accessibilityLabel(L.t("list.favorite"))
                Button {
                    newTitle = r.title.isEmpty ? recipe.displayTitle : r.title
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel(L.t("recipe.rename"))
            }
        }
        .confirmationDialog(L.t("recipe.confirmDelete", ["title": L.isolate(r.title)]), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L.t("common.delete"), role: .destructive) {
                context.delete(recipe)
                try? context.save()
                dismiss()
            }
        }
        .alert(L.t("recipe.renamePrompt"), isPresented: $renaming) {
            TextField(L.t("shop.name"), text: $newTitle)
            Button(L.t("common.cancel"), role: .cancel) {}
            Button(L.t("common.save"), action: rename)
        }
        .fullScreenCover(isPresented: $cooking) { CookingView(recipe: recipe, text: r) }
        .safeAreaInset(edge: .bottom) { TimersBar() }
        .onDisappear { try? context.save() }
    }

    // MARK: - Sekcje

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(recipe: recipe, emojiSize: 72)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(r.title.isEmpty ? recipe.displayTitle : r.title).font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentLanguage(r.shownLanguage)
                languageControls
                if !r.summary.isEmpty {
                    Text(r.summary).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentLanguage(r.shownLanguage)
                }
                let facts: [(String, String)] = [
                    ("timer", r.prepTime.isEmpty ? "" : L.t("detail.prep", ["t": L.isolate(r.prepTime)])),
                    ("flame", r.cookTime.isEmpty ? "" : L.t("detail.cook", ["t": L.isolate(r.cookTime)])),
                ].filter { !$0.1.isEmpty }
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(facts.indices, id: \.self) { i in
                            Label(facts[i].1, systemImage: facts[i].0).font(.subheadline)
                        }
                    }
                }
                if !r.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(r.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.brand.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .contentLanguage(r.shownLanguage)
                }
                if !recipe.author.isEmpty {
                    Text("@\(recipe.author)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// „Pokaż oryginał” / „Pokaż po …” oraz informacja, że przepis jest w innym języku.
    @ViewBuilder
    private var languageControls: some View {
        if recipe.status == .ready {
            if hasOriginal {
                Button {
                    translateError = nil
                    showOriginal.toggle()
                    if showOriginal && recipe.text(in: recipe.sourceLanguage) == nil { translate(to: recipe.sourceLanguage) }
                } label: {
                    Label(showOriginal
                          ? L.t("lang.showTranslated", ["lang": L.langName(preferred)])
                          : L.t("lang.showOriginal", ["lang": L.langName(recipe.sourceLanguage)]),
                          systemImage: "globe")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(translating)
            }
            if translating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("lang.translating")).font(.subheadline)
                }
            } else if let translateError {
                Text(translateError).font(.footnote).foregroundStyle(.orange)
            } else if shown == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("lang.recipeIn", ["lang": L.langName(recipe.language)])).font(.subheadline)
                    Button(L.t("lang.translate", ["lang": L.langName(viewLang)])) { translate(to: viewLang) }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            Button {
                cooking = true
            } label: {
                Label(L.t("recipe.cookMode"), systemImage: "frying.pan")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Button {
                recipe.shoppingPortions = recipe.shoppingPortions > 0 ? 0 : recipe.displayPortions
                try? context.save()
            } label: {
                Label(L.t(recipe.shoppingPortions > 0 ? "detail.inCart" : "recipe.toCart"),
                      systemImage: recipe.shoppingPortions > 0 ? "cart.fill" : "cart.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
        }
        .listRowBackground(Color.clear)

        Section {
            HStack {
                Text(L.t("detail.portions"))
                Spacer()
                PortionsStepper(portions: $recipe.portions, defaultPortions: recipe.displayPortions)
                    .controlSize(.small)
            }
            ForEach(Array(r.ingredients.enumerated()), id: \.offset) { index, item in
                if !item.group.isEmpty && (index == 0 || r.ingredients[index - 1].group != item.group) {
                    Text(item.group).font(.subheadline.bold()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentLanguage(r.shownLanguage)
                }
                CheckRow(done: recipe.isChecked("i\(index)")) {
                    recipe.toggleChecked("i\(index)")
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name)
                        Spacer()
                        Text(L.isolate(item.amount(portions: recipe.displayPortions)))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .contentLanguage(r.shownLanguage)
            }
        } header: {
            Text(L.t("recipe.ingredients"))
        } footer: {
            Text((r.servings.isEmpty ? "" : L.t("recipe.inVideo", ["s": L.isolate(r.servings)]))
                 + L.t("recipe.perPortion") + " " + L.t("detail.tapToCheck"))
        }

        Section(L.t("recipe.steps")) {
            ForEach(Array(r.steps.enumerated()), id: \.offset) { index, step in
                CheckRow(done: recipe.isChecked("s\(index)")) {
                    recipe.toggleChecked("s\(index)")
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).").bold().foregroundStyle(Color.brand)
                        Text(Kitchen.convertTemperatures(step.text))
                    }
                }
                .contentLanguage(r.shownLanguage)
                if step.minutes > 0 {
                    Button {
                        CookingTimers.shared.start(step: step, recipeTitle: r.title)
                    } label: {
                        Label(L.t("detail.timer", ["t": Kitchen.minutesLabel(step.minutes)]), systemImage: "timer")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .padding(.leading, 34)
                }
            }
        }

        if !r.tips.isEmpty {
            Section(L.t("recipe.tips")) {
                ForEach(r.tips, id: \.self) { tip in
                    Label(Kitchen.convertTemperatures(tip), systemImage: "lightbulb").font(.subheadline)
                        .contentLanguage(r.shownLanguage)
                }
            }
        }

        if recipe.checked.isEmpty == false {
            Section {
                Button(L.t("detail.clearChecks"), systemImage: "checklist.unchecked") { recipe.checked = [] }
            }
        }
    }

    // MARK: - Akcje

    private func reprocess() {
        showOriginal = false
        Task { await RecipeImporter.process(recipe, in: context) }
    }

    private func translate(to lang: String) {
        translating = true
        translateError = nil
        Task {
            do {
                try await RecipeImporter.translate(recipe, to: lang, in: context)
            } catch {
                translateError = error.localizedDescription
            }
            translating = false
        }
    }

    /// Zmiana nazwy dotyczy języka, w którym przepis jest właśnie wyświetlany.
    private func rename() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if r.shownLanguage == recipe.language {
            recipe.title = title
            recipe.titleEdited = true
        } else if var tr = recipe.translations[r.shownLanguage] {
            tr.title = title
            var all = recipe.translations
            all[r.shownLanguage] = tr
            recipe.translations = all
        }
        try? context.save()
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
