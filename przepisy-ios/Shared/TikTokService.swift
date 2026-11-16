import Foundation

struct TikTokVideo {
    var url: String
    var description: String
    var author: String
    var thumbnail: String
    /// Tekst z automatycznych napisów filmiku (rozpoznana mowa), jeśli TikTok je udostępnia.
    var transcript: String
    /// Adres pliku wideo (do rozpoznawania mowy na telefonie). Wygasa po kilku godzinach.
    var videoURL: String
    /// Język opisu / mowy podany przez TikToka (np. "pl", "en").
    var language: String
}

enum TikTokError: LocalizedError {
    case unavailable(String)
    case nothingToRead

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Nie udało się pobrać filmiku z TikToka (\(why))."
        case .nothingToRead: return "Filmik nie ma opisu ani napisów, z których dałoby się odczytać przepis."
        }
    }
}

/// Dane filmiku: strona filmiku (dane osadzone w HTML, w tym napisy) i oficjalny publiczny oEmbed.
enum TikTokService {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Wyciąga pierwszy link do TikToka z dowolnego tekstu (np. „Zobacz ten filmik! https://vm.tiktok.com/…”).
    static func extractURL(from text: String) -> String? {
        let pattern = #"https?://(?:[\w-]+\.)?tiktok\.com/[^\s"'<>]+"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }

    static func fetch(_ rawURL: String) async throws -> TikTokVideo {
        let url = cleanURL(await resolveShortLink(rawURL))

        async let pageAttempt = attempt { try await viaPage(url) }
        async let oembedAttempt = attempt { try await viaOembed(url) }
        let (page, pageError) = await pageAttempt
        let (oembed, oembedError) = await oembedAttempt

        guard page != nil || oembed != nil else {
            throw TikTokError.unavailable([pageError, oembedError].compactMap { $0 }.joined(separator: "; "))
        }

        let pageDesc = page?.description ?? ""
        let oembedDesc = oembed?.description ?? ""
        let video = TikTokVideo(
            url: url,
            description: pageDesc.count >= oembedDesc.count ? pageDesc : oembedDesc,
            author: [page?.author, oembed?.author].compactMap { $0 }.first { !$0.isEmpty } ?? "",
            thumbnail: [oembed?.thumbnail, page?.thumbnail].compactMap { $0 }.first { !$0.isEmpty } ?? "",
            transcript: page?.transcript ?? "",
            videoURL: page?.videoURL ?? "",
            language: page?.language ?? ""
        )
        guard !video.description.isEmpty || !video.transcript.isEmpty || !video.videoURL.isEmpty else {
            throw TikTokError.nothingToRead
        }
        return video
    }

    private static func attempt(_ work: @Sendable () async throws -> TikTokVideo) async -> (TikTokVideo?, String?) {
        do { return (try await work(), nil) } catch { return (nil, error.localizedDescription) }
    }

    /// Pobiera plik (miniaturkę, wideo) z nagłówkami, których oczekuje TikTok.
    static func download(_ urlString: String) async throws -> (Data, String) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard (http?.statusCode ?? 200) == 200 else { throw URLError(.badServerResponse) }
        return (data, http?.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    // MARK: - Źródła

    // Krótkie linki (vm.tiktok.com, vt.tiktok.com, tiktok.com/t/…) przekierowują na pełny adres filmiku.
    private static func resolveShortLink(_ url: String) async -> String {
        let isShort = url.range(of: #"//(vm|vt)\.tiktok\.com|tiktok\.com/t/"#, options: .regularExpression) != nil
        guard isShort, let u = URL(string: url) else { return url }
        var req = URLRequest(url: u)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return response.url?.absoluteString ?? url
        } catch {
            return url
        }
    }

    private static func cleanURL(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        c.query = nil
        c.fragment = nil
        return c.string ?? url
    }

    private static func viaOembed(_ url: String) async throws -> TikTokVideo {
        var c = URLComponents(string: "https://www.tiktok.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: url)]
        var req = URLRequest(url: c.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "oEmbed HTTP \(http.statusCode)"])
        }
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return TikTokVideo(
            url: url,
            description: json["title"] as? String ?? "",
            author: json["author_unique_id"] as? String ?? json["author_name"] as? String ?? "",
            thumbnail: json["thumbnail_url"] as? String ?? "",
            transcript: "",
            videoURL: "",
            language: ""
        )
    }

    private static func viaPage(_ url: String) async throws -> TikTokVideo {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("pl,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // Strona ustawia ciasteczka, bez których TikTok nie wyda pliku wideo – URLSession.shared je zapamięta.
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)

        let marker = #"id="__UNIVERSAL_DATA_FOR_REHYDRATION__""#
        guard let m = html.range(of: marker),
              let start = html.range(of: ">", range: m.upperBound..<html.endIndex),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any],
              let info = detail["itemInfo"] as? [String: Any],
              let item = info["itemStruct"] as? [String: Any]
        else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "nie znaleziono danych filmiku na stronie"])
        }

        let video = item["video"] as? [String: Any] ?? [:]
        let author = (item["author"] as? [String: Any])?["uniqueId"] as? String ?? ""
        let cover = video["cover"] as? String ?? video["originCover"] as? String ?? ""
        let playURL = [video["playAddr"], video["downloadAddr"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? ""
        let language = item["textLanguage"] as? String ?? ""

        return TikTokVideo(
            url: url,
            description: item["desc"] as? String ?? "",
            author: author,
            thumbnail: cover,
            transcript: await fetchTranscript(video),
            videoURL: playURL,
            language: language
        )
    }

    // MARK: - Napisy

    /// Lista napisów filmiku – najpierw oryginalna mowa (ASR), potem polskie, potem angielskie.
    static func subtitleCandidates(_ video: [String: Any]) -> [String] {
        var out: [(url: String, score: Int)] = []
        func score(lang: String, source: String) -> Int {
            let l = lang.lowercased()
            return (source.uppercased() == "ASR" ? 0 : 10) + (l.hasPrefix("pol") || l.hasPrefix("pl") ? 0 : l.hasPrefix("en") ? 1 : 2)
        }
        for s in video["subtitleInfos"] as? [[String: Any]] ?? [] {
            guard let url = s["Url"] as? String else { continue }
            let format = s["Format"] as? String ?? "webvtt"
            guard format.lowercased().contains("vtt") else { continue }
            out.append((url, score(lang: s["LanguageCodeName"] as? String ?? "", source: s["Source"] as? String ?? "")))
        }
        let captions = (video["claInfo"] as? [String: Any])?["captionInfos"] as? [[String: Any]] ?? []
        for c in captions {
            guard let url = c["url"] as? String else { continue }
            let auto = (c["isAutoGen"] as? Bool) ?? false
            out.append((url, score(lang: c["language"] as? String ?? "", source: auto ? "ASR" : "")))
        }
        return out.sorted { $0.score < $1.score }.map(\.url)
    }

    /// Zamienia plik WebVTT na zwykły tekst (bez znaczników czasu i powtórzeń).
    static func vttToText(_ vtt: String) -> String {
        var lines: [String] = []
        for raw in vtt.components(separatedBy: .newlines) {
            let line = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || line.contains("-->") || Int(line) != nil { continue }
            if ["NOTE", "STYLE", "REGION", "Kind:", "Language:"].contains(where: { line.hasPrefix($0) }) { continue }
            if lines.last != line { lines.append(line) }
        }
        return lines.joined(separator: " ")
    }

    private static func fetchTranscript(_ video: [String: Any]) async -> String {
        for url in subtitleCandidates(video) {
            guard let (data, _) = try? await download(url) else { continue }
            let text = vttToText(String(decoding: data, as: UTF8.self))
            if text.count > 20 { return text }
        }
        return ""
    }
}
