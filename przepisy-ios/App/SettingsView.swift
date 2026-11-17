import SwiftUI
import SwiftData

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var recipes: [Recipe]
    @State private var key = APIKeyStore.apiKey ?? ""
    @State private var saveFailed = false
    @State private var exportDocument: BackupDocument?
    @State private var importing = false
    @State private var backupMessage: String?

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

                Section {
                    Button("Zapisz kopię przepisów do pliku", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = BackupDocument(data: try Backup.export(recipes))
                        } catch {
                            backupMessage = "Nie udało się przygotować kopii: \(error.localizedDescription)"
                        }
                    }
                    .disabled(recipes.isEmpty)
                    Button("Wczytaj przepisy z pliku", systemImage: "square.and.arrow.down") { importing = true }
                    if let backupMessage {
                        Text(backupMessage).font(.footnote)
                    }
                } header: {
                    Text("Kopia zapasowa")
                } footer: {
                    Text("Plik możesz zapisać w iCloud Drive albo wysłać sobie. Przy wczytywaniu przepisy, które już są w aplikacji, zostaną pominięte. Ten sam plik działa w wersji webowej aplikacji.")
                }

                if saveFailed {
                    Section { Text("Nie udało się zapisać klucza.").foregroundStyle(.red) }
                }
            }
            .fileExporter(
                isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                document: exportDocument,
                contentType: .json,
                defaultFilename: Backup.fileName
            ) { result in
                switch result {
                case .success: backupMessage = "Zapisano kopię \(recipes.count) \(Kitchen.plural(recipes.count, "przepisu", "przepisów", "przepisów"))."
                case .failure(let error): backupMessage = "Nie udało się zapisać: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let (added, skipped) = try Backup.importData(try Data(contentsOf: url), into: context)
                    backupMessage = "Dodano \(added) \(Kitchen.plural(added, "przepis", "przepisy", "przepisów"))"
                        + (skipped > 0 ? ", pominięto \(skipped) (już były w aplikacji)." : ".")
                } catch {
                    backupMessage = error.localizedDescription
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
