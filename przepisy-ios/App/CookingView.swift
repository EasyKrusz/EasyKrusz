import SwiftUI
import SwiftData

/// Tryb gotowania: jeden krok na ekran, duży tekst, ekran nie gaśnie, minutniki z czasów kroków.
@MainActor
struct CookingView: View {
    @Bindable var recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var lastPage: Int { recipe.steps.count }   // strona 0 = składniki

    var body: some View {
        VStack(spacing: 0) {
            header
            ProgressView(value: Double(page), total: Double(max(lastPage, 1)))
                .tint(Color.brand)
                .padding(.horizontal)

            TabView(selection: $page) {
                ingredientsPage.tag(0)
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    stepPage(index: index, step: step).tag(index + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            TimersBar()

            HStack(spacing: 12) {
                Button {
                    page = max(0, page - 1)
                } label: {
                    Label("Wstecz", systemImage: "chevron.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(page == 0)

                Button {
                    if page >= lastPage { dismiss() } else { page += 1 }
                } label: {
                    Text(page >= lastPage ? "Gotowe 🎉" : "Dalej").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding()
        }
        .tint(Color.brand)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }    // ekran nie gaśnie
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline)
            }
            .accessibilityLabel("Zamknij tryb gotowania")
            Text(recipe.displayTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(page == 0 ? "Składniki" : "Krok \(page) z \(lastPage)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var ingredientsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("PRZYGOTUJ SKŁADNIKI")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                PortionsStepper(portions: $recipe.portions, defaultPortions: recipe.displayPortions)
                    .padding(.vertical, 12)
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, item in
                    if !item.group.isEmpty && (index == 0 || recipe.ingredients[index - 1].group != item.group) {
                        Text(item.group).font(.headline).padding(.top, 14)
                    }
                    CheckRow(done: recipe.isChecked("i\(index)")) {
                        recipe.toggleChecked("i\(index)")
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name)
                            Spacer()
                            Text(item.amount(portions: recipe.displayPortions)).foregroundStyle(.secondary)
                        }
                        .font(.title3)
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
            }
            .padding()
        }
    }

    private func stepPage(index: Int, step: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(step.text)
                    .font(.system(size: 30, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
                if step.minutes > 0 {
                    Button {
                        CookingTimers.shared.start(step: step, recipeTitle: recipe.displayTitle)
                    } label: {
                        Label("Włącz minutnik: \(Kitchen.minutesLabel(step.minutes))", systemImage: "timer")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// Wybór liczby porcji (−/+). `portions == 0` oznacza „jak w filmiku”.
struct PortionsStepper: View {
    @Binding var portions: Int
    let defaultPortions: Int

    var body: some View {
        let current = portions > 0 ? portions : defaultPortions
        HStack(spacing: 4) {
            Button { portions = max(1, current - 1) } label: { Image(systemName: "minus") }
                .disabled(current <= 1)
                .accessibilityLabel("Mniej porcji")
            Text(Kitchen.portionsLabel(current))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 84)
            Button { portions = min(99, current + 1) } label: { Image(systemName: "plus") }
                .disabled(current >= 99)
                .accessibilityLabel("Więcej porcji")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}
