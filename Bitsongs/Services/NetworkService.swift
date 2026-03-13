import Foundation

/// Network service for communicating with the PyMusic backend
class NetworkService: ObservableObject {
    
    // MARK: - Configuration
    // Change this to your PyMusic server IP address
    // For simulator: use localhost / 127.0.0.1
    // For physical device: use your Mac's local IP (e.g., 192.168.1.x)
    static let shared = NetworkService()
    @Published var baseURL: String = "http://Jay.local:499"
    
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
    func getRecommendations(artistId: Int) async throws -> [Song] {
        guard artistId > 0 else { return [] }
        guard let url = URL(string: "\(baseURL)/api/mobile/recommend?artist_id=\(artistId)") else {
            throw NetworkError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode([Song].self, from: data)
    }
    
    // MARK: - Get Stream URL
    func getStreamURL(song: Song) async throws -> StreamInfo {
        guard let artist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let title = song.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/play?id=\(song.id)&artist=\(artist)&title=\(title)") else {
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
        guard let url = URL(string: "\(baseURL)/api/mobile/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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
