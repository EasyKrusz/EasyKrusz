import Foundation

struct TikTokVideo {
    var url: String
    var description: String
    var author: String
    var thumbnail: String
}

enum TikTokError: LocalizedError {
    case noDescription(String)
    var errorDescription: String? {
        switch self {
        case .noDescription(let why): return "Nie udało się pobrać opisu z TikToka (\(why))."
        }
    }
}

/// Pobieranie opisu (caption) filmiku: oficjalny publiczny oEmbed, awaryjnie dane osadzone w stronie filmiku.
enum TikTokService {
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Wyciąga pierwszy link do TikToka z dowolnego tekstu (np. „Zobacz ten filmik! https://vm.tiktok.com/…”).
    static func extractURL(from text: String) -> String? {
        let pattern = #"https?://(?:[\w-]+\.)?tiktok\.com/[^\s"'<>]+"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }

    static func fetch(_ rawURL: String) async throws -> TikTokVideo {
        let url = cleanURL(await resolveShortLink(rawURL))
        var best: TikTokVideo?
        var errors: [String] = []

        do {
            let v = try await viaOembed(url)
            best = v
        } catch {
            errors.append(error.localizedDescription)
        }
        // oEmbed bywa ucięty albo pusty - wtedy próbujemy ze strony
        let truncated = best.map { $0.description.hasSuffix("…") || $0.description.hasSuffix("...") } ?? true
        if best == nil || best!.description.isEmpty || truncated {
            do {
                let v = try await viaPage(url)
                if v.description.count > (best?.description.count ?? 0) {
                    best = TikTokVideo(
                        url: url,
                        description: v.description,
                        author: v.author.isEmpty ? (best?.author ?? "") : v.author,
                        thumbnail: (best?.thumbnail.isEmpty == false) ? best!.thumbnail : v.thumbnail
                    )
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        guard let video = best, !video.description.isEmpty else {
            throw TikTokError.noDescription(errors.isEmpty ? "pusty opis" : errors.joined(separator: "; "))
        }
        return video
    }

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
            thumbnail: json["thumbnail_url"] as? String ?? ""
        )
    }

    private static func viaPage(_ url: String) async throws -> TikTokVideo {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("pl,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)

        let marker = #"id="__UNIVERSAL_DATA_FOR_REHYDRATION__""#
        if let m = html.range(of: marker),
           let start = html.range(of: ">", range: m.upperBound..<html.endIndex),
           let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) {
            let jsonText = String(html[start.upperBound..<end.lowerBound])
            if let root = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
               let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
               let detail = scope["webapp.video-detail"] as? [String: Any],
               let info = detail["itemInfo"] as? [String: Any],
               let item = info["itemStruct"] as? [String: Any],
               let desc = item["desc"] as? String, !desc.isEmpty {
                let author = (item["author"] as? [String: Any])?["uniqueId"] as? String ?? ""
                let cover = (item["video"] as? [String: Any])?["cover"] as? String ?? ""
                return TikTokVideo(url: url, description: desc, author: author, thumbnail: cover)
            }
        }
        throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "nie znaleziono opisu na stronie"])
    }
}
