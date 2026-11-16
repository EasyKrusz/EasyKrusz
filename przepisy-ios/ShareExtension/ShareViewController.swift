import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Punkt wejścia rozszerzenia „Udostępnij” (TikTok → Udostępnij → Więcej → Przepisy).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.start(items: items) }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case reading
        case working
        case done(String)
        case info(String)
        case failed(String)
    }

    var phase: Phase = .reading
    let close: () -> Void

    init(close: @escaping () -> Void) {
        self.close = close
    }

    func start(items: [NSExtensionItem]) async {
        guard let text = await Self.sharedText(from: items),
              let link = TikTokService.extractURL(from: text) else {
            phase = .failed("Nie znalazłem linku do TikToka w udostępnionych danych.")
            return
        }

        let context = SharedStore.newContext()
        let (recipe, duplicate) = RecipeImporter.enqueue(link: link, notes: "", in: context)
        SharedStore.markExternalChange()
        if duplicate {
            phase = .info("Ten filmik jest już zapisany: „\(recipe.displayTitle)”.")
            return
        }
        guard APIKeyStore.hasKey else {
            phase = .info("Link zapisany. Dodaj klucz API w aplikacji Przepisy – przepis przetworzy się po jej otwarciu.")
            return
        }

        phase = .working
        await RecipeImporter.process(recipe, in: context)
        SharedStore.markExternalChange()
        switch recipe.status {
        case .ready:
            phase = .done(recipe.displayTitle)
            try? await Task.sleep(for: .seconds(1.5))
            close()
        default:
            phase = .failed(recipe.errorMessage + "\n\nWpis jest w aplikacji – możesz tam dopisać notatki i spróbować ponownie.")
        }
    }

    /// Zbiera tekst i linki z tego, co udostępniła inna aplikacja.
    private static func sharedText(from items: [NSExtensionItem]) async -> String? {
        var texts: [String] = []
        for item in items {
            if let s = item.attributedContentText?.string, !s.isEmpty { texts.append(s) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(s)
                }
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                switch model.phase {
                case .reading, .working:
                    ProgressView().controlSize(.large)
                    Text("Pobieram opis i układam przepis…")
                        .font(.headline)
                    Text("Możesz zamknąć to okno – przepis dokończy się w aplikacji.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .done(let title):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Zapisano").font(.headline)
                    Text(title).foregroundStyle(.secondary)
                case .info(let text):
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text(text)
                case .failed(let text):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(text)
                }
                Spacer()
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Przepisy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zamknij") { model.close() }
                }
            }
        }
        .tint(Color.brand)
    }
}
