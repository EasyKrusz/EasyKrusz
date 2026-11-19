import SwiftUI
import SwiftData

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var recipes: [Recipe]
    @AppStorage(L.settingKey, store: L.store) private var appLanguage = "auto"
    @AppStorage(L.unitSettingKey, store: L.store) private var unitSystem = "auto"
    @State private var key = APIKeyStore.apiKey ?? ""
    @State private var saveFailed = false
    @State private var exportDocument: BackupDocument?
    @State private var importing = false
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L.t("settings.language"), selection: $appLanguage) {
                        Text(L.t("lang.auto")).tag("auto")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Deutsch").tag("de")
                        Text(verbatim: "Polski").tag("pl")
                    }
                } footer: {
                    Text(L.t("settings.languageFooter"))
                }

                Section {
                    Picker(L.t("settings.units"), selection: $unitSystem) {
                        Text(L.t("units.auto")).tag("auto")
                        Text(L.t("units.metric")).tag("metric")
                        Text(L.t("units.us")).tag("us")
                        Text(L.t("units.original")).tag("original")
                    }
                } footer: {
                    Text(L.t("settings.unitsFooter"))
                }

                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L.t("settings.apiKey"))
                } footer: {
                    Text(L.t("settings.apiKeyFooter"))
                }

                Section {
                    Link(L.t("settings.createKey"), destination: URL(string: "https://platform.claude.com/settings/keys")!)
                }

                Section(L.t("settings.howTo")) {
                    Text(L.md("settings.howToText"))
                        .font(.subheadline)
                }

                Section {
                    Button(L.t("settings.export"), systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = BackupDocument(data: try Backup.export(recipes))
                        } catch {
                            backupMessage = L.t("settings.exportFailed", ["error": error.localizedDescription])
                        }
                    }
                    .disabled(recipes.isEmpty)
                    Button(L.t("settings.import"), systemImage: "square.and.arrow.down") { importing = true }
                    if let backupMessage {
                        Text(backupMessage).font(.footnote)
                    }
                } header: {
                    Text(L.t("settings.backup"))
                } footer: {
                    Text(L.t("settings.backupFooter"))
                }

                if saveFailed {
                    Section { Text(L.t("settings.keySaveFailed")).foregroundStyle(.red) }
                }
            }
            .fileExporter(
                isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                document: exportDocument,
                contentType: .json,
                defaultFilename: Backup.fileName
            ) { result in
                switch result {
                case .success: backupMessage = L.tp("settings.exported", recipes.count)
                case .failure(let error): backupMessage = L.t("settings.exportFailed", ["error": error.localizedDescription])
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let (added, skipped) = try Backup.importData(try Data(contentsOf: url), into: context)
                    backupMessage = L.tp("settings.imported", added)
                        + (skipped > 0 ? L.t("settings.skipped", ["n": "\(skipped)"]) : ".")
                } catch {
                    backupMessage = error.localizedDescription
                }
            }
            .navigationTitle(L.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.done")) {
                        if APIKeyStore.save(key) { dismiss() } else { saveFailed = true }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
            }
        }
        .id(appLanguage)   // po zmianie języka teksty odświeżają się od razu
    }
}
