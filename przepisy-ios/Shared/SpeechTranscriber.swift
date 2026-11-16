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
        case .notAuthorized:
            return "Brak zgody na rozpoznawanie mowy. Włącz ją w Ustawieniach iPhone'a → Przepisy."
        case .unavailable:
            return "Rozpoznawanie mowy jest teraz niedostępne na tym iPhonie."
        case .noVideo:
            return "Nie udało się pobrać nagrania z filmiku."
        case .audioExport:
            return "Nie udało się wyciągnąć dźwięku z filmiku."
        case .nothingHeard:
            return "W filmiku nie rozpoznano żadnej mowy."
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

        // 3. Rozpoznaj mowę – w języku filmiku, a jeśli nic nie wyjdzie, po polsku i po angielsku
        var tried = Set<String>()
        for locale in locales(for: languageHint) where tried.insert(locale.identifier).inserted {
            if let text = try? await recognize(audio, locale: locale), text.count > 20 {
                return text
            }
        }
        throw SpeechError.nothingHeard
    }

    private static func locales(for hint: String) -> [Locale] {
        let map = ["pl": "pl-PL", "en": "en-US", "de": "de-DE", "es": "es-ES", "fr": "fr-FR",
                   "it": "it-IT", "uk": "uk-UA", "pt": "pt-BR"]
        let code = String(hint.lowercased().prefix(2))
        var ids: [String] = []
        if let id = map[code] { ids.append(id) }
        ids += ["pl-PL", "en-US"]
        return ids.map(Locale.init(identifier:))
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
