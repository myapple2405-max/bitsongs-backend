import AVFoundation
import CoreText
import MediaPlayer
import SwiftUI

/// Main ViewModel managing the music player state, audio streaming, and theming
class MusicPlayerViewModel: ObservableObject {
    private enum StorageKeys {
        static let lastPlayedSong = "bitsongs.lastPlayedSong"
        static let recentSongs = "bitsongs.recentSongs"
    }
    
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
    @Published var upNextRecommendations: [Song] = []
    @Published var recentSongs: [Song] = []
    @Published var showUpNext: Bool = false
    @Published var fontsLoaded: Bool = false
    
    // MARK: - Audio (AVPlayer for streaming)
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemEndObserver: Any?
    private var colorExtractionTask: Task<Void, Never>?
    private var expectedSongDuration: TimeInterval = 0
    private var didTriggerAutoAdvanceForCurrentSong = false
    
    // MARK: - Network
    private let networkService = NetworkService.shared
    
    // MARK: - Search debounce
    private var searchTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    
    // MARK: - Computed Properties
    var currentSong: Song? {
        guard !songs.isEmpty, currentSongIndex >= 0, currentSongIndex < songs.count else { return nil }
        return songs[currentSongIndex]
    }
    
    /// All songs after the current one (for Up Next queue)
    var upNextSongs: [Song] {
        if !upNextRecommendations.isEmpty {
            return upNextRecommendations
        }
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
        loadRecentSongs()
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
                self.errorMessage = "Your music source is offline.\nBring your server back and try again."
                self.isLoading = false
                return
            }
            
            do {
                let chartSongs = try await networkService.getChart()
                self.recommendations = []
                self.upNextRecommendations = []
                self.isLoading = false
                
                self.restoreStartupSong(from: chartSongs)
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
        let previousSongID = shouldTrackCurrentSongForRecommendations ? currentSong?.id : nil
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
        persistLastPlayedSong(song)
        
        // Reset state
        stopPlayback()
        currentTime = 0
        duration = TimeInterval(song.duration)
        expectedSongDuration = TimeInterval(song.duration)
        didTriggerAutoAdvanceForCurrentSong = false
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
                let streamInfo = try await networkService.getStreamURL(song: song, previousSongID: previousSongID)
                guard let streamURL = URL(string: streamInfo.url) else {
                    throw NetworkError.noStreamURL
                }
                
                // Make sure this is still the current song (user might have skipped)
                guard self.currentSong?.id == song.id else { return }
                
                self.setupAVPlayer(with: streamURL)
                self.play()
                Task {
                    await self.networkService.cacheSong(song)
                }
                
                // Load recommendations in background
                self.loadRecommendations(songId: song.id)
                self.loadUpNext(songId: song.id)
                
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
                        if let expectedSongDuration = self?.expectedSongDuration, expectedSongDuration > 0 {
                            self?.duration = min(expectedSongDuration, streamDuration)
                        } else {
                            self?.duration = streamDuration
                        }
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
                
                if self.shouldAutoAdvanceAtExpectedEnd {
                    self.didTriggerAutoAdvanceForCurrentSong = true
                    self.pause()
                    self.playNext()
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
        if let recommendedSong = upNextRecommendations.first {
            selectUpNextSong(recommendedSong)
            return
        }
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
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            loadAndPlaySong(at: index)
        } else {
            loadAndPlaySong(at: 0, from: [song])
        }
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
    private func loadRecommendations(songId: String) {
        Task { @MainActor in
            do {
                let recs = try await networkService.getRecommendations(songId: songId)
                self.recommendations = recs.behaviorBased + recs.contentBased
            } catch {
                self.recommendations = []
            }
        }
    }
    
    private func restoreStartupSong(from chartSongs: [Song]) {
        let lastPlayedSong = loadLastPlayedSong()
        
        if let lastPlayedSong {
            let mergedSongs = [lastPlayedSong] + chartSongs.filter { $0.id != lastPlayedSong.id }
            songs = mergedSongs
            currentSongIndex = 0
            duration = TimeInterval(lastPlayedSong.duration)
            extractColorsFromURL(lastPlayedSong.coverXL.isEmpty ? lastPlayedSong.cover : lastPlayedSong.coverXL)
            loadRecommendations(songId: lastPlayedSong.id)
            loadUpNext(songId: lastPlayedSong.id)
            loadLyrics(artist: lastPlayedSong.artist, title: lastPlayedSong.title)
            return
        }
        
        songs = chartSongs
        guard let firstSong = chartSongs.first else { return }
        currentSongIndex = 0
        duration = TimeInterval(firstSong.duration)
        extractColorsFromURL(firstSong.coverXL.isEmpty ? firstSong.cover : firstSong.coverXL)
    }
    
    private func persistLastPlayedSong(_ song: Song) {
        guard let data = try? JSONEncoder().encode(song) else { return }
        defaults.set(data, forKey: StorageKeys.lastPlayedSong)
        updateRecentSongs(with: song)
    }
    
    private func loadLastPlayedSong() -> Song? {
        guard let data = defaults.data(forKey: StorageKeys.lastPlayedSong) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }
    
    private func loadRecentSongs() {
        guard let data = defaults.data(forKey: StorageKeys.recentSongs),
              let songs = try? JSONDecoder().decode([Song].self, from: data) else {
            recentSongs = []
            return
        }
        recentSongs = songs
    }
    
    private func updateRecentSongs(with song: Song) {
        let updatedSongs = [song] + recentSongs.filter { $0.id != song.id }
        let trimmedSongs = Array(updatedSongs.prefix(20))
        recentSongs = trimmedSongs
        
        guard let data = try? JSONEncoder().encode(trimmedSongs) else { return }
        defaults.set(data, forKey: StorageKeys.recentSongs)
    }
    
    private func loadUpNext(songId: String) {
        Task { @MainActor in
            do {
                let upNext = try await networkService.getUpNext(songId: songId, limit: 10)
                self.upNextRecommendations = upNext
            } catch {
                self.upNextRecommendations = []
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
        colorExtractionTask?.cancel()
        guard let url = URL(string: urlString) else {
            dominantColors = .default
            return
        }
        
        colorExtractionTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
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
    
    private var shouldTrackCurrentSongForRecommendations: Bool {
        guard duration > 0 else { return false }
        return currentTime >= (duration / 2)
    }
    
    private var shouldAutoAdvanceAtExpectedEnd: Bool {
        guard !didTriggerAutoAdvanceForCurrentSong else { return false }
        guard isPlaying else { return false }
        guard expectedSongDuration > 0 else { return false }
        return currentTime >= max(expectedSongDuration - 0.35, 0)
    }
    
    // MARK: - Custom Font Loading
    private func loadCustomFonts() {
        let fonts = ["Jersey10-Regular", "Almendra-Regular"]
        
        Task {
            var loadedCount = 0
            for font in fonts {
                if self.registerFont(name: font) {
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
    
    private func registerFont(name: String) -> Bool {
        if UIFont(name: name, size: 14) != nil {
            return true
        }
        
        if let bundleFontURL = Bundle.main.url(forResource: name, withExtension: "ttf") {
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(bundleFontURL as CFURL, .process, &error)
            return registered || UIFont(name: name, size: 14) != nil
        }
        
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let fontUrl = documentsPath.appendingPathComponent("\(name).ttf")
        
        if FileManager.default.fileExists(atPath: fontUrl.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fontUrl as CFURL, .process, &error) {
                return true
            }
            return true // Might be already registered
        }
        return false
    }
}
