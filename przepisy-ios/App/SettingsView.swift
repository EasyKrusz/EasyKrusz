import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = APIKeyStore.apiKey ?? ""
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Klucz API Anthropic")
                } footer: {
                    Text("Potrzebny do zamiany opisów w przepisy. Klucz zakładasz na platform.claude.com – płacisz za każdy przetworzony przepis (zwykle ułamek centa). Klucz jest zapisany w pęku kluczy tego iPhone'a.")
                }

                Section {
                    Link("Utwórz klucz API", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                }

                Section("Jak dodawać przepisy") {
                    Text("1. W TikToku stuknij **Udostępnij**.\n2. Przewiń w prawo i wybierz **Więcej** (…).\n3. Wybierz **Przepisy**. Za pierwszym razem możesz je dodać do ulubionych w tym menu (Edytuj działania).")
                        .font(.subheadline)
                }

                if saveFailed {
                    Section { Text("Nie udało się zapisać klucza.").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Ustawienia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") {
                        if APIKeyStore.save(key) { dismiss() } else { saveFailed = true }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
            }
        }
    }
}
