import Foundation

/// Network service for communicating with the PyMusic backend
class NetworkService: ObservableObject {
    
    // MARK: - Configuration
    // Change this to your PyMusic server IP address
    // For simulator: use localhost / 127.0.0.1
    // For physical device: use your Mac's local IP (e.g., 192.168.1.x)
    static let shared = NetworkService()
    @Published var baseURL: String = "http://127.0.0.1:8000"
    
    private let session: URLSession
    private let decoder: JSONDecoder
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }
    
    // MARK: - Search
    func searchSongs(query: String) async throws -> [Song] {
        guard !query.isEmpty else { return [] }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/search?q=\(encoded)") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode([Song].self, from: data)
    }
    
    // MARK: - Chart / Trending
    func getChart() async throws -> [Song] {
        guard let url = URL(string: "\(baseURL)/api/mobile/chart") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode([Song].self, from: data)
    }
    
    // MARK: - Recommendations
    func getRecommendations(songId: String) async throws -> RecommendationResponse {
        guard !songId.isEmpty else { return RecommendationResponse(behaviorBased: [], contentBased: []) }
        guard let encodedSongId = songId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/recommend?song_id=\(encodedSongId)") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode(RecommendationResponse.self, from: data)
    }
    
    // MARK: - Up Next
    func getUpNext(songId: String, limit: Int = 10) async throws -> [Song] {
        guard !songId.isEmpty else { return [] }
        guard let encodedSongId = songId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/up_next?song_id=\(encodedSongId)&limit=\(limit)") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode([Song].self, from: data)
    }
    
    // MARK: - Get Stream URL
    func getStreamURL(song: Song, previousSongID: String? = nil) async throws -> StreamInfo {
        guard let artist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let title = song.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let songId = song.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw NetworkError.invalidURL
        }
        
        var urlString = "\(baseURL)/api/mobile/play?id=\(songId)&artist=\(artist)&title=\(title)"
        if let previousSongID, !previousSongID.isEmpty,
           let encodedPreviousSongID = previousSongID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&previous_song_id=\(encodedPreviousSongID)"
        }
        
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode(StreamInfo.self, from: data)
    }
    
    // MARK: - Lyrics
    func getLyrics(artist: String, title: String) async throws -> LyricsResponse {
        guard let artistEnc = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let titleEnc = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/lyrics?artist=\(artistEnc)&title=\(titleEnc)") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode(LyricsResponse.self, from: data)
    }
    
    // MARK: - Health Check
    func healthCheck() async -> Bool {
        for candidate in candidateBaseURLs() {
            guard let url = URL(string: "\(candidate)/api/mobile/health") else { continue }
            do {
                let (_, response) = try await session.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    await MainActor.run {
                        self.baseURL = candidate
                    }
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }
    
    // MARK: - Server Cache
    func cacheSong(_ song: Song) async {
        guard let url = URL(string: "\(baseURL)/api/mobile/cache_song") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(song)
            let (_, response) = try await session.data(for: request)
            try validateResponse(response)
        } catch {
            // Caching is best-effort and should never block playback.
        }
    }
    
    // MARK: - Helpers
    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }
    }

    private func candidateBaseURLs() -> [String] {
        var candidates = [baseURL]
        for fallback in [
            "http://Jay.local:499",
            "http://127.0.0.1:499",
            "http://localhost:499"
        ] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }
}

// MARK: - Response Models

struct StreamInfo: Codable {
    let source: String
    let url: String
    let directURL: String?
    let headers: [String: String]?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case source, url, headers, error
        case directURL = "direct_url"
    }
}

struct LyricsResponse: Codable {
    let type: String
    let text: String
}

struct RecommendationResponse: Decodable {
    let behaviorBased: [Song]
    let contentBased: [Song]
    
    enum CodingKeys: String, CodingKey {
        case behaviorBased = "behavior_based"
        case contentBased = "content_based"
    }
}

// MARK: - Errors

enum NetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case decodingError
    case noStreamURL
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let code): return "Server error: \(code)"
        case .decodingError: return "Failed to decode response"
        case .noStreamURL: return "No stream URL available"
        }
    }
}
