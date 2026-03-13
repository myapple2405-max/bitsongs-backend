import AVFoundation
import CoreText
import MediaPlayer
import SwiftUI

/// Main ViewModel managing the music player state, audio streaming, and theming
class MusicPlayerViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published var songs: [Song] = []
    @Published var currentSongIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var dominantColors: ColorExtractor.DominantColors = .default
    @Published var isLoading: Bool = false
    @Published var isBuffering: Bool = false
    @Published var errorMessage: String?
    @Published var searchResults: [Song] = []
    @Published var isSearchLoading: Bool = false
    @Published var lyrics: LyricsResponse?
    @Published var isLyricsLoading: Bool = false
    @Published var serverConnected: Bool = false
    @Published var recommendations: [Song] = []
    @Published var showUpNext: Bool = false
    @Published var fontsLoaded: Bool = false
    
    // MARK: - Audio (AVPlayer for streaming)
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemEndObserver: Any?
    
    // MARK: - Network
    private let networkService = NetworkService.shared
    
    // MARK: - Search debounce
    private var searchTask: Task<Void, Never>?
    
    // MARK: - Computed Properties
    var currentSong: Song? {
        guard !songs.isEmpty, currentSongIndex >= 0, currentSongIndex < songs.count else { return nil }
        return songs[currentSongIndex]
    }
    
    /// All songs after the current one (for Up Next queue)
    var upNextSongs: [Song] {
        guard !songs.isEmpty else { return [] }
        let nextIndex = currentSongIndex + 1
        if nextIndex < songs.count {
            return Array(songs[nextIndex...])
        }
        return []
    }
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    var currentTimeString: String {
        formatTime(currentTime)
    }
    
    var durationString: String {
        formatTime(duration)
    }
    
    var remainingTimeString: String {
        formatTime(max(0, duration - currentTime))
    }
    
    // MARK: - Initialization
    init() {
        setupAudioSession()
        setupRemoteCommands()
        loadCustomFonts()
        loadChartSongs()
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        statusObserver?.invalidate()
        if let observer = itemEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Audio Session
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }
    
    // MARK: - Load Chart Songs
    func loadChartSongs() {
        isLoading = true
        errorMessage = nil
        
        Task { @MainActor in
            // Check server first
            let connected = await networkService.healthCheck()
            self.serverConnected = connected
            
            if !connected {
                self.errorMessage = "Cannot connect to server.\nMake sure PyMusic is running."
                self.isLoading = false
                return
            }
            
            do {
                let chartSongs = try await networkService.getChart()
                self.songs = chartSongs
                self.isLoading = false
                
                if !chartSongs.isEmpty {
                    self.currentSongIndex = 0
                    self.duration = TimeInterval(chartSongs[0].duration)
                    self.extractColorsFromURL(chartSongs[0].coverXL.isEmpty ? chartSongs[0].cover : chartSongs[0].coverXL)
                }
            } catch {
                self.errorMessage = "Failed to load songs: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Search (called from View's onChange)
    func onSearchTextChanged(_ text: String) {
        // Cancel any previous search
        searchTask?.cancel()
        
        guard isSearching else { return }
        
        if text.isEmpty {
            searchResults = []
            isSearchLoading = false
            return
        }
        
        isSearchLoading = true
        
        searchTask = Task { @MainActor in
            // Debounce: wait 400ms before actually searching
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return // Task was cancelled
            }
            
            guard !Task.isCancelled else { return }
            
            do {
                let results = try await networkService.searchSongs(query: text)
                if !Task.isCancelled {
                    self.searchResults = results
                    self.isSearchLoading = false
                }
            } catch {
                if !Task.isCancelled {
                    print("Search error: \(error)")
                    self.searchResults = []
                    self.isSearchLoading = false
                }
            }
        }
    }
    
    // MARK: - Load & Play Song
    func loadAndPlaySong(at index: Int, from songList: [Song]? = nil) {
        let list = songList ?? songs
        guard index >= 0, index < list.count else { return }
        
        // If playing from a separate list (e.g. search results), merge into main queue
        if let songList = songList {
            let song = songList[index]
            if let existingIndex = songs.firstIndex(where: { $0.id == song.id }) {
                currentSongIndex = existingIndex
            } else {
                // Add search results to the songs list for queue
                songs.append(contentsOf: songList.filter { newSong in
                    !songs.contains(where: { $0.id == newSong.id })
                })
                if let newIndex = songs.firstIndex(where: { $0.id == song.id }) {
                    currentSongIndex = newIndex
                }
            }
        } else {
            currentSongIndex = index
        }
        
        guard let song = currentSong else { return }
        
        // Reset state
        stopPlayback()
        currentTime = 0
        duration = TimeInterval(song.duration)
        isBuffering = true
        errorMessage = nil
        
        // Update colors from artwork
        let coverURL = song.coverXL.isEmpty ? song.cover : song.coverXL
        extractColorsFromURL(coverURL)
        
        // Update now playing immediately with song info
        updateNowPlayingInfo()
        
        // Fetch stream URL and play
        Task { @MainActor in
            do {
                let streamInfo = try await networkService.getStreamURL(song: song)
                guard let streamURL = URL(string: streamInfo.url) else {
                    throw NetworkError.noStreamURL
                }
                
                // Make sure this is still the current song (user might have skipped)
                guard self.currentSong?.id == song.id else { return }
                
                self.setupAVPlayer(with: streamURL)
                self.play()
                
                // Load recommendations in background
                self.loadRecommendations(artistId: song.artistId)
                
                // Load lyrics in background
                self.loadLyrics(artist: song.artist, title: song.title)
                
            } catch {
                // Only show error if this is still the current song
                if self.currentSong?.id == song.id {
                    self.isBuffering = false
                    self.errorMessage = "Failed to play: \(error.localizedDescription)"
                    print("Stream error: \(error)")
                }
            }
        }
    }
    
    // MARK: - AVPlayer Setup
    private func setupAVPlayer(with url: URL) {
        // Clean up previous player
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObserver?.invalidate()
        if let observer = itemEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemEndObserver = nil
        }
        
        // Create new player
        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        playerItem?.preferredForwardBufferDuration = 10
        
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        
        player?.automaticallyWaitsToMinimizeStalling = true
        
        // Observe player item status
        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.isBuffering = false
                    // Update duration from actual stream if available
                    let streamDuration = item.duration.seconds
                    if streamDuration.isFinite && streamDuration > 0 {
                        self?.duration = streamDuration
                    }
                    self?.updateNowPlayingInfo()
                case .failed:
                    self?.isBuffering = false
                    self?.errorMessage = "Playback failed"
                    print("Player item failed: \(item.error?.localizedDescription ?? "unknown")")
                default:
                    break
                }
            }
        }
        
        // Periodic time observer for progress
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
                // Check if buffering
                if let item = self.playerItem {
                    self.isBuffering = !item.isPlaybackLikelyToKeepUp && self.isPlaying
                }
            }
        }
        
        // Observe song end
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.playNext()
        }
    }
    
    // MARK: - Playback Controls
    func togglePlayPause() {
        HapticManager.playButtonTap()
        if isPlaying {
            pause()
        } else {
            if player?.currentItem != nil {
                play()
            } else if currentSong != nil {
                loadAndPlaySong(at: currentSongIndex)
            }
        }
    }
    
    func play() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
    }
    
    func playNext() {
        HapticManager.playSelection()
        guard !songs.isEmpty else { return }
        let nextIndex = (currentSongIndex + 1) % songs.count
        let wasPlaying = isPlaying
        loadAndPlaySong(at: nextIndex)
        // If wasn't playing, loadAndPlaySong will play automatically via its Task
        // If was already playing, it will continue to play
        if !wasPlaying {
            // loadAndPlaySong calls play() after getting stream, so we don't need to do anything extra
        }
    }
    
    func playPrevious() {
        HapticManager.playSelection()
        guard !songs.isEmpty else { return }
        // If more than 3 seconds in, restart current song
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let prevIndex = currentSongIndex > 0 ? currentSongIndex - 1 : songs.count - 1
            loadAndPlaySong(at: prevIndex)
        }
    }
    
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateNowPlayingInfo()
    }
    
    func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: max(0, min(time, duration)))
    }
    
    // MARK: - Song Selection
    func selectSong(_ song: Song, from list: [Song]? = nil) {
        HapticManager.playSuccess()
        let songList = list ?? songs
        if let index = songList.firstIndex(where: { $0.id == song.id }) {
            loadAndPlaySong(at: index, from: list)
        }
        
        withAnimation(.easeInOut(duration: 0.3)) {
            searchText = ""
            isSearching = false
            searchResults = []
        }
    }
    
    func selectUpNextSong(_ song: Song) {
        HapticManager.playLightTap()
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        loadAndPlaySong(at: index)
    }
    
    // MARK: - Search
    func beginSearch() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isSearching = true
        }
    }
    
    func cancelSearch() {
        searchTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            searchText = ""
            isSearching = false
            searchResults = []
            isSearchLoading = false
        }
        HapticManager.playLightTap()
    }
    
    // MARK: - Up Next Toggle
    func toggleUpNext() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showUpNext.toggle()
        }
        HapticManager.playLightTap()
    }
    
    // MARK: - Recommendations
    private func loadRecommendations(artistId: Int) {
        Task { @MainActor in
            do {
                let recs = try await networkService.getRecommendations(artistId: artistId)
                self.recommendations = recs
            } catch {
                self.recommendations = []
            }
        }
    }
    
    // MARK: - Lyrics
    private func loadLyrics(artist: String, title: String) {
        isLyricsLoading = true
        Task { @MainActor in
            do {
                let result = try await networkService.getLyrics(artist: artist, title: title)
                self.lyrics = result
                self.isLyricsLoading = false
            } catch {
                self.lyrics = nil
                self.isLyricsLoading = false
            }
        }
    }
    
    // MARK: - Color Extraction from URL
    private func extractColorsFromURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            dominantColors = .default
            return
        }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    let colors = ColorExtractor.extractColors(from: image)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.dominantColors = colors
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.dominantColors = .default
                }
            }
        }
    }
    
    // MARK: - Now Playing Info Center
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
    
    func updateNowPlayingInfo() {
        guard let song = currentSong else { return }
        
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        // Load artwork asynchronously for Now Playing
        let coverURL = song.coverXL.isEmpty ? song.cover : song.coverXL
        if let url = URL(string: coverURL) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        await MainActor.run {
                            var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                        }
                    }
                } catch {}
            }
        }
    }
    
    // MARK: - Helpers
    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // MARK: - Custom Font Loading
    private func loadCustomFonts() {
        let fonts = [
            ("Jersey10-Regular", "https://github.com/google/fonts/raw/main/ofl/jersey10/Jersey10-Regular.ttf"),
            ("Almendra-Regular", "https://github.com/google/fonts/raw/main/ofl/almendra/Almendra-Regular.ttf")
        ]
        
        Task {
            var loadedCount = 0
            for font in fonts {
                if self.registerFont(name: font.0, urlString: font.1) {
                    loadedCount += 1
                }
            }
            if loadedCount == fonts.count {
                DispatchQueue.main.async {
                    self.fontsLoaded = true
                }
            }
        }
    }
    
    private func registerFont(name: String, urlString: String) -> Bool {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let fontUrl = documentsPath.appendingPathComponent("\(name).ttf")
        
        if FileManager.default.fileExists(atPath: fontUrl.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fontUrl as CFURL, .process, &error) {
                return true
            }
            return true // Might be already registered
        }
        
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        
        do {
            try data.write(to: fontUrl)
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fontUrl as CFURL, .process, &error) {
                return true
            }
        } catch {
            print("Failed to save or register font \(name): \(error)")
        }
        return false
    }
}
