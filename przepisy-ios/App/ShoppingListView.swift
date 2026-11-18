import SwiftUI
import SwiftData
import EventKit

/// Stan listy zakupów poza samymi przepisami (te są w Recipe.shoppingPortions):
/// odhaczone pozycje, pozycje dopisane ręcznie i ręczne zmiany pozycji z przepisów.
@MainActor
@Observable
final class ShoppingState {
    static let shared = ShoppingState()

    private let defaults = UserDefaults.standard
    private(set) var checked: Set<String>
    private(set) var extras: [Kitchen.ExtraItem]
    private(set) var overrides: [String: Kitchen.ItemOverride]

    private init() {
        checked = Set(defaults.stringArray(forKey: "shopping.checked") ?? [])
        if let data = defaults.data(forKey: "shopping.extras.v2"),
           let decoded = try? JSONDecoder().decode([Kitchen.ExtraItem].self, from: data) {
            extras = decoded
        } else {
            // starsza wersja: same napisy
            extras = (defaults.stringArray(forKey: "shopping.extras") ?? []).map { Kitchen.ExtraItem(name: $0) }
        }
        if let data = defaults.data(forKey: "shopping.overrides"),
           let decoded = try? JSONDecoder().decode([String: Kitchen.ItemOverride].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    func toggle(_ key: String) {
        if checked.contains(key) { checked.remove(key) } else { checked.insert(key) }
        save()
    }

    func addExtra(_ item: Kitchen.ExtraItem) {
        extras.append(item)
        save()
    }

    func updateExtra(_ item: Kitchen.ExtraItem) {
        if let i = extras.firstIndex(where: { $0.id == item.id }) { extras[i] = item }
        save()
    }

    func removeExtra(id: String) {
        extras.removeAll { $0.id == id }
        checked.remove(Kitchen.extraKey(id))
        save()
    }

    /// Zmienia pozycję z przepisu. `nil` w polu = bez zmian względem przepisu.
    func setOverride(_ key: String, name: String?, amount: String?) {
        var o = overrides[key] ?? Kitchen.ItemOverride()
        o.name = name
        o.amount = amount
        store(o, for: key)
    }

    func setRemoved(_ key: String, _ removed: Bool) {
        var o = overrides[key] ?? Kitchen.ItemOverride()
        o.removed = removed
        if removed { checked.remove(key) }
        store(o, for: key)
    }

    func clear() {
        checked = []
        extras = []
        overrides = [:]
        save()
    }

    private func store(_ o: Kitchen.ItemOverride, for key: String) {
        overrides[key] = o.isEmpty ? nil : o
        save()
    }

    private func save() {
        defaults.set(Array(checked), forKey: "shopping.checked")
        defaults.set(try? JSONEncoder().encode(extras), forKey: "shopping.extras.v2")
        defaults.set(try? JSONEncoder().encode(overrides), forKey: "shopping.overrides")
    }
}

@MainActor
struct ShoppingListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Recipe> { $0.shoppingPortions > 0 }, sort: \Recipe.title) private var recipes: [Recipe]
    @Query private var allRecipes: [Recipe]
    @State private var state = ShoppingState.shared

    @State private var newName = ""
    @State private var newAmount = ""
    @State private var newCategory = "Inne"
    @State private var addMessage: String?
    @State private var editing: Kitchen.ShoppingItem?
    @State private var confirmClear = false
    @State private var remindersMessage: String?
    @FocusState private var nameFocused: Bool

    private var list: (groups: [Kitchen.ShoppingGroup], removed: [Kitchen.ShoppingItem]) {
        Kitchen.shoppingList(
            recipes.map { (title: $0.displayTitle, ingredients: $0.ingredients, portions: $0.shoppingPortions) },
            extras: state.extras,
            overrides: state.overrides
        )
    }

    var body: some View {
        let list = self.list
        NavigationStack {
            List {
                addSection
                recipesSection

                ForEach(list.groups) { group in
                    Section(group.category) {
                        ForEach(group.items) { item in
                            row(item)
                        }
                    }
                }

                if !list.removed.isEmpty {
                    Section {
                        DisclosureGroup("Usunięte z listy (\(list.removed.count))") {
                            ForEach(list.removed) { item in
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Button("Przywróć") { state.setRemoved(item.key, false) }
                                        .buttonStyle(.borderless)
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
            .toolbar {
                if !list.groups.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ShareLink(item: Kitchen.shoppingText(list.groups, checked: state.checked)) {
                                Label("Wyślij jako tekst", systemImage: "square.and.arrow.up")
                            }
                            Button("Dodaj do Przypomnień", systemImage: "checklist") {
                                Task { await sendToReminders(list.groups) }
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
                Button("Wyczyść (przepisy, dopisane rzeczy i zmiany)", role: .destructive) {
                    for r in recipes { r.shoppingPortions = 0 }
                    try? context.save()
                    state.clear()
                }
            }
            .sheet(item: $editing) { item in
                ShoppingItemEditor(item: item, state: state)
            }
            .safeAreaInset(edge: .bottom) { TimersBar() }
        }
    }

    // MARK: - Sekcje

    private var addSection: some View {
        Section {
            TextField("Co dopisać? Np. sól, papier do pieczenia", text: $newName)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(addItem)
                .onChange(of: newName) { _, name in
                    let guess = Kitchen.guessCategory(name, from: allRecipes.flatMap(\.ingredients))
                    if guess != "Inne" { newCategory = guess }
                }
            TextField("Ilość (opcjonalnie), np. 1 opakowanie", text: $newAmount)
                .onSubmit(addItem)
            Picker("Dział sklepu", selection: $newCategory) {
                ForEach(Kitchen.categories, id: \.self) { Text($0) }
            }
            Button("Dodaj do listy", systemImage: "plus.circle.fill", action: addItem)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            if let addMessage {
                Text(addMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Dopisz coś od siebie")
        }
    }

    @ViewBuilder
    private var recipesSection: some View {
        Section {
            if recipes.isEmpty {
                Text("Przepisy dodasz przyciskiem „Do listy zakupów” na stronie przepisu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
        } header: {
            Text("Z przepisów")
        }
    }

    private func row(_ item: Kitchen.ShoppingItem) -> some View {
        CheckRow(done: state.checked.contains(item.key)) {
            state.toggle(item.key)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                        if item.isExtra || item.edited {
                            Text(item.isExtra ? "dopisane" : "zmienione")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    if item.recipes.count > 1 {
                        Text(item.recipes.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.amount).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Usuń", role: .destructive) { delete(item) }
            Button("Edytuj") { editing = item }.tint(.blue)
        }
        .contextMenu {
            Button("Edytuj", systemImage: "pencil") { editing = item }
            Button("Usuń z listy", systemImage: "trash", role: .destructive) { delete(item) }
        }
    }

    // MARK: - Akcje

    private func delete(_ item: Kitchen.ShoppingItem) {
        if let id = item.extraID { state.removeExtra(id: id) } else { state.setRemoved(item.key, true) }
    }

    private func addItem() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let amount = newAmount.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // To samo już jest na liście z przepisu (np. „sól do smaku”)? Zmieniamy tamtą pozycję zamiast dublować.
        let current = list
        let fromRecipes = current.groups.flatMap(\.items).filter { !$0.isExtra } + current.removed
        if let existing = fromRecipes.first(where: { Kitchen.normName($0.name) == Kitchen.normName(name) }) {
            state.setRemoved(existing.key, false)
            if !amount.isEmpty {
                state.setOverride(existing.key,
                                  name: existing.name == existing.originalName ? nil : existing.name,
                                  amount: amount)
            }
            if state.checked.contains(existing.key) { state.toggle(existing.key) }
            addMessage = "„\(existing.name)” już było na liście z przepisu – "
                + (amount.isEmpty ? "zostawiłem jedną pozycję." : "zmieniłem ilość na „\(amount)”.")
        } else {
            state.addExtra(Kitchen.ExtraItem(name: name, amount: amount, category: newCategory))
            addMessage = nil
        }
        newName = ""
        newAmount = ""
        newCategory = "Inne"
        nameFocused = true
    }

    /// Dodaje nieodhaczone pozycje do listy „Zakupy” w aplikacji Przypomnienia.
    private func sendToReminders(_ groups: [Kitchen.ShoppingGroup]) async {
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

/// Edycja pozycji: nazwa, ilość, (dla dopisanych) dział; usunięcie; powrót do wartości z przepisu.
@MainActor
struct ShoppingItemEditor: View {
    let item: Kitchen.ShoppingItem
    let state: ShoppingState
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amount: String
    @State private var category: String

    init(item: Kitchen.ShoppingItem, state: ShoppingState) {
        self.item = item
        self.state = state
        _name = State(initialValue: item.name)
        _amount = State(initialValue: item.amount)
        _category = State(initialValue: item.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nazwa", text: $name)
                    TextField("Ilość, np. 1 opakowanie", text: $amount)
                    if item.isExtra {
                        Picker("Dział sklepu", selection: $category) {
                            ForEach(Kitchen.categories, id: \.self) { Text($0) }
                        }
                    }
                } footer: {
                    if !item.isExtra {
                        Text("Z przepisów (\(item.recipes.joined(separator: ", "))): \(item.originalName)"
                             + (item.originalAmount.isEmpty ? "" : " – \(item.originalAmount)")
                             + ". Zmieniona ilość nie przelicza się przy zmianie porcji.")
                    }
                }

                Section {
                    if !item.isExtra && item.edited {
                        Button("Przywróć wartości z przepisu", systemImage: "arrow.uturn.backward") {
                            state.setOverride(item.key, name: nil, amount: nil)
                            dismiss()
                        }
                    }
                    Button("Usuń z listy", systemImage: "trash", role: .destructive) {
                        if let id = item.extraID { state.removeExtra(id: id) } else { state.setRemoved(item.key, true) }
                        dismiss()
                    }
                }
            }
            .navigationTitle(item.isExtra ? "Twoja pozycja" : "Pozycja z przepisu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let a = amount.trimmingCharacters(in: .whitespaces)
        if let id = item.extraID {
            state.updateExtra(Kitchen.ExtraItem(id: id, name: n, amount: a, category: category))
        } else {
            state.setOverride(item.key,
                              name: n == item.originalName ? nil : n,
                              amount: a == item.originalAmount ? nil : a)
        }
        dismiss()
    }
}
