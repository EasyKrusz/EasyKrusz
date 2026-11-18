import Foundation
import AVFoundation
import Speech

enum SpeechError: LocalizedError {
    case notAuthorized
    case unavailable
    case noVideo
    case audioExport
    case nothingHeard

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return L.t("speech.notAuthorized")
        case .unavailable: return L.t("speech.unavailable")
        case .noVideo: return L.t("speech.noVideo")
        case .audioExport: return L.t("speech.audioExport")
        case .nothingHeard: return L.t("speech.nothingHeard")
        }
    }
}

/// Transkrypcja mowy z filmiku na telefonie (Apple Speech) – gdy filmik nie ma opisu ani napisów.
enum SpeechTranscriber {

    static func transcribe(videoURL: String, languageHint: String) async throws -> String {
        guard await authorize() else { throw SpeechError.notAuthorized }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Pobierz wideo
        guard !videoURL.isEmpty, let (data, _) = try? await TikTokService.download(videoURL), data.count > 10_000 else {
            throw SpeechError.noVideo
        }
        let video = dir.appendingPathComponent("video.mp4")
        try data.write(to: video)

        // 2. Wyciągnij ścieżkę dźwiękową
        let audio = dir.appendingPathComponent("audio.m4a")
        try await exportAudio(from: video, to: audio)

        // 3. Rozpoznaj mowę – w języku filmiku, a jeśli nic nie wyjdzie, w języku telefonu i po angielsku
        for locale in locales(for: languageHint) {
            if let text = try? await recognize(audio, locale: locale), text.count > 20 {
                return text
            }
        }
        throw SpeechError.nothingHeard
    }

    /// Języki do rozpoznawania: język filmiku (jeśli iPhone go obsługuje), potem język telefonu i angielski.
    private static func locales(for hint: String) -> [Locale] {
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        func best(for tag: String) -> Locale? {
            guard !tag.isEmpty else { return nil }
            let want = Locale.Language(identifier: L.normalizeTag(tag))
            let sameLanguage = supported.filter { $0.language.languageCode == want.languageCode }
            // chiński: pismo tradycyjne → Tajwan/Hongkong, uproszczone → Chiny kontynentalne
            if want.languageCode?.identifier == "zh" {
                let traditional = want.script?.identifier == "Hant"
                let regions = traditional ? ["TW", "HK"] : ["CN"]
                if let match = sameLanguage.first(where: { regions.contains($0.region?.identifier ?? "") }) { return match }
            }
            // preferuj „główny” region danego języka, np. de-DE, ja-JP
            let main = sameLanguage.first { ($0.region?.identifier ?? "").lowercased() == want.languageCode?.identifier }
            return main ?? sameLanguage.first
        }
        var out: [Locale] = []
        for tag in [hint, L.recipeLang, "en"] {
            if let l = best(for: tag), !out.contains(where: { $0.identifier == l.identifier }) { out.append(l) }
        }
        return out
    }

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        }
    }

    private static func exportAudio(from video: URL, to audio: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechError.audioExport
        }
        session.outputURL = audio
        session.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else { throw SpeechError.audioExport }
    }

    private static func recognize(_ audio: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // za darmo, bez limitu długości, nic nie wychodzi z telefonu
        }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    finished = true
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
