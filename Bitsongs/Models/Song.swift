import Foundation

struct Song: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let artist: String
    let artistId: Int
    let album: String
    let cover: String      // 200x200 artwork URL
    let coverXL: String    // 600x600 artwork URL
    let duration: Int       // seconds
    let genre: String
    let cached: Bool
    let reason: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, cover, duration, genre, cached, reason
        case artistId = "artist_id"
        case coverXL = "cover_xl"
    }
    
    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.id == rhs.id
    }
    
    init(id: String, title: String, artist: String, artistId: Int, album: String, cover: String, coverXL: String, duration: Int, genre: String, cached: Bool = false, reason: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.cover = cover
        self.coverXL = coverXL
        self.duration = duration
        self.genre = genre
        self.cached = cached
        self.reason = reason
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle id as either String or Int from JSON
        if let stringId = try? container.decode(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = "0"
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown"
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown"
        artistId = try container.decodeIfPresent(Int.self, forKey: .artistId) ?? 0
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Single"
        cover = try container.decodeIfPresent(String.self, forKey: .cover) ?? ""
        coverXL = try container.decodeIfPresent(String.self, forKey: .coverXL) ?? ""
        duration = try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? "Music"
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(artistId, forKey: .artistId)
        try container.encode(album, forKey: .album)
        try container.encode(cover, forKey: .cover)
        try container.encode(coverXL, forKey: .coverXL)
        try container.encode(duration, forKey: .duration)
        try container.encode(genre, forKey: .genre)
        try container.encode(cached, forKey: .cached)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}
