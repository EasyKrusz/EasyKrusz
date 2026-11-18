import SwiftUI
import SwiftData

@MainActor
struct RecipeListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recipe.createdAt, order: .reverse) private var recipes: [Recipe]

    @State private var search = ""
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var onlyFavorites = false
    @State private var hasKey = APIKeyStore.hasKey

    private var shown: [Recipe] {
        recipes
            .filter { $0.matches(search) && (!onlyFavorites || $0.favorite) }
            .sorted { ($0.favorite ? 1 : 0) > ($1.favorite ? 1 : 0) }   // stabilne: ulubione na górze
    }

    var body: some View {
        NavigationStack {
            List {
                if !hasKey {
                    Section {
                        Button {
                            showSettings = true
                        } label: {
                            Label(L.t("list.addKey"), systemImage: "key.fill")
                        }
                    }
                }
                ForEach(shown) { recipe in
                    NavigationLink(value: recipe) {
                        RecipeRow(recipe: recipe)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            recipe.favorite.toggle()
                            try? context.save()
                        } label: {
                            Label(L.t("list.favorite"), systemImage: recipe.favorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(shown[i]) }
                    try? context.save()
                }
            }
            .overlay {
                if recipes.isEmpty {
                    ContentUnavailableView {
                        Label(L.t("list.empty"), systemImage: "fork.knife")
                    } description: {
                        Text(L.md("list.emptyHint"))
                    } actions: {
                        Button(L.t("list.addRecipe")) { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle(L.t("tab.recipes"))
            .navigationDestination(for: Recipe.self) { RecipeDetailView(recipe: $0) }
            .searchable(text: $search, prompt: L.t("list.search"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L.t("settings.title"))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { onlyFavorites.toggle() } label: {
                        Image(systemName: onlyFavorites ? "star.fill" : "star")
                    }
                    .accessibilityLabel(L.t("list.onlyFavorites"))
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L.t("list.addRecipe"))
                }
            }
            .sheet(isPresented: $showAdd) { AddRecipeView() }
            .sheet(isPresented: $showSettings, onDismiss: { hasKey = APIKeyStore.hasKey }) { SettingsView() }
        }
    }
}

struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(recipe: recipe)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text((recipe.favorite ? "★ " : "") + L.isolate(recipe.displayTitle))
                    .font(.headline)
                    .lineLimit(2)
                switch recipe.status {
                case .pending, .processing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L.t(recipe.needsSpeech ? "status.speech" : "status.processing"))
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                case .failed:
                    Label(L.t("status.failed"), systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                case .ready:
                    let r = recipe.localized
                    let meta = [r.prepTime.isEmpty ? "" : "⏱ \(r.prepTime)",
                                r.servings,
                                recipe.author.isEmpty ? "" : "@\(recipe.author)"]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Miniaturka zapisana na telefonie, a gdy jej nie ma – kafelek z emoji dobranym do dania.
struct Thumbnail: View {
    let recipe: Recipe
    var emojiSize: CGFloat = 28

    var body: some View {
        if let data = recipe.thumbnailData, let image = UIImage(data: data) {
            Color.clear.overlay {
                Image(uiImage: image).resizable().scaledToFill()
            }
            .clipped()
        } else {
            ZStack {
                Self.tileColor(for: recipe.displayTitle)
                if recipe.emoji.isEmpty {
                    Image(systemName: "fork.knife").font(.system(size: emojiSize * 0.8)).foregroundStyle(Color.brand)
                } else {
                    Text(recipe.emoji).font(.system(size: emojiSize))
                }
            }
        }
    }

    /// Stały, pastelowy kolor wyliczony z nazwy – każdy przepis ma „swój”.
    static func tileColor(for text: String) -> Color {
        var hash: UInt32 = 0
        for scalar in text.unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.35, brightness: 0.95)
    }
}
