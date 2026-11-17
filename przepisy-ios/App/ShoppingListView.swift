import SwiftUI
import SwiftData
import EventKit

/// Odhaczone pozycje i dopisane ręcznie rzeczy (przepisy na liście = Recipe.shoppingPortions > 0).
@MainActor
@Observable
final class ShoppingState {
    static let shared = ShoppingState()

    private let defaults = UserDefaults.standard
    private(set) var checked: Set<String>
    private(set) var extras: [String]

    private init() {
        checked = Set(defaults.stringArray(forKey: "shopping.checked") ?? [])
        extras = defaults.stringArray(forKey: "shopping.extras") ?? []
    }

    func toggle(_ key: String) {
        if checked.contains(key) { checked.remove(key) } else { checked.insert(key) }
        save()
    }

    func addExtra(_ text: String) {
        guard !extras.contains(text) else { return }
        extras.append(text)
        save()
    }

    func removeExtra(key: String) {
        extras.removeAll { Kitchen.extraKey($0) == key }
        save()
    }

    func clear() {
        checked = []
        extras = []
        save()
    }

    private func save() {
        defaults.set(Array(checked), forKey: "shopping.checked")
        defaults.set(extras, forKey: "shopping.extras")
    }
}

@MainActor
struct ShoppingListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Recipe> { $0.shoppingPortions > 0 }, sort: \Recipe.title) private var recipes: [Recipe]
    @State private var state = ShoppingState.shared
    @State private var newItem = ""
    @State private var confirmClear = false
    @State private var remindersMessage: String?

    private var groups: [Kitchen.ShoppingGroup] {
        Kitchen.shoppingList(
            recipes.map { (title: $0.displayTitle, ingredients: $0.ingredients, portions: $0.shoppingPortions) },
            extras: state.extras
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(recipes) { recipe in
                        HStack {
                            Text("\(recipe.emoji.isEmpty ? "🍳" : recipe.emoji) \(recipe.displayTitle)")
                                .lineLimit(2)
                            Spacer()
                            PortionsStepper(
                                portions: Binding(
                                    get: { recipe.shoppingPortions },
                                    set: { recipe.shoppingPortions = $0; try? context.save() }
                                ),
                                defaultPortions: recipe.shoppingPortions
                            )
                            .controlSize(.small)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { recipes[i].shoppingPortions = 0 }
                        try? context.save()
                    }
                    HStack {
                        TextField("Dopisz coś jeszcze, np. papier do pieczenia", text: $newItem)
                            .onSubmit(addExtra)
                        Button("Dodaj", action: addExtra)
                            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Przepisy")
                } footer: {
                    if recipes.isEmpty {
                        Text("Dodaj przepisy przyciskiem „Do listy zakupów” na stronie przepisu.")
                    }
                }

                ForEach(groups) { group in
                    Section(group.category) {
                        ForEach(group.items) { item in
                            CheckRow(done: state.checked.contains(item.key)) {
                                state.toggle(item.key)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        if item.recipes.count > 1 {
                                            Text(item.recipes.joined(separator: ", "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(item.amount).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                if item.isExtra {
                                    Button("Usuń", role: .destructive) {
                                        state.removeExtra(key: item.key)
                                    }
                                }
                            }
                        }
                    }
                }

                if let remindersMessage {
                    Section { Text(remindersMessage).font(.footnote) }
                }
            }
            .navigationTitle("Zakupy")
            .overlay {
                if groups.isEmpty && recipes.isEmpty {
                    ContentUnavailableView("Lista jest pusta", systemImage: "cart",
                                           description: Text("Na stronie przepisu stuknij „Do listy zakupów”."))
                }
            }
            .toolbar {
                if !groups.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ShareLink(item: Kitchen.shoppingText(groups, checked: state.checked)) {
                                Label("Wyślij jako tekst", systemImage: "square.and.arrow.up")
                            }
                            Button("Dodaj do Przypomnień", systemImage: "checklist") {
                                Task { await sendToReminders() }
                            }
                            Divider()
                            Button("Wyczyść listę", systemImage: "trash", role: .destructive) { confirmClear = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog("Wyczyścić całą listę zakupów?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Wyczyść", role: .destructive) {
                    for r in recipes { r.shoppingPortions = 0 }
                    try? context.save()
                    state.clear()
                }
            }
            .safeAreaInset(edge: .bottom) { TimersBar() }
        }
    }

    private func addExtra() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        state.addExtra(text)
        newItem = ""
    }

    /// Dodaje nieodhaczone pozycje do listy „Zakupy” w aplikacji Przypomnienia.
    private func sendToReminders() async {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToReminders() else {
                remindersMessage = "Brak dostępu do Przypomnień – włącz go w Ustawieniach iPhone'a → Przepisy."
                return
            }
            let listName = "Zakupy"
            let calendar: EKCalendar
            if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
                calendar = existing
            } else {
                calendar = EKCalendar(for: .reminder, eventStore: store)
                calendar.title = listName
                guard let source = store.defaultCalendarForNewReminders()?.source else {
                    remindersMessage = "Nie znalazłem konta Przypomnień na tym iPhonie."
                    return
                }
                calendar.source = source
                try store.saveCalendar(calendar, commit: true)
            }
            var count = 0
            for item in groups.flatMap(\.items) where !state.checked.contains(item.key) {
                let reminder = EKReminder(eventStore: store)
                reminder.title = item.amount.isEmpty ? item.name : "\(item.name) – \(item.amount)"
                reminder.calendar = calendar
                try store.save(reminder, commit: false)
                count += 1
            }
            try store.commit()
            remindersMessage = "Dodano \(count) \(Kitchen.plural(count, "pozycję", "pozycje", "pozycji")) do listy „\(listName)” w Przypomnieniach."
        } catch {
            remindersMessage = "Nie udało się dodać do Przypomnień: \(error.localizedDescription)"
        }
    }
}
