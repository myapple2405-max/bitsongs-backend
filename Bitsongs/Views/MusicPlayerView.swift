import SwiftUI

struct MusicPlayerView: View {
    @StateObject private var viewModel = MusicPlayerViewModel()
    @Namespace private var animation
    @State private var showRecentSidebar = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dynamic animated background
                DynamicBackgroundView(colors: viewModel.dominantColors)
                    .animation(.easeInOut(duration: 1.0), value: viewModel.currentSongIndex)
                
                if viewModel.isLoading && viewModel.songs.isEmpty {
                    // Loading state
                    loadingView
                } else if let error = viewModel.errorMessage, viewModel.songs.isEmpty {
                    // Error state
                    errorView(message: error)
                } else {
                    // Main content
                    VStack(spacing: 0) {
                        // Search bar at top
                        SearchBarView(
                            text: $viewModel.searchText,
                            isSearching: $viewModel.isSearching,
                            onCancel: { viewModel.cancelSearch() },
                            onSidebarToggle: { toggleRecentSidebar() },
                            accentColor: viewModel.dominantColors.accent
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        
                        if viewModel.isSearching {
                            // Search results
                            searchResultsOverlay
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            // Main player
                            playerContent
                                .transition(.opacity)
                        }
                    }
                }
                
                if showRecentSidebar {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleRecentSidebar()
                        }
                        .transition(.opacity)
                    
                    recentSidebar(in: geo.size)
                        .padding(.leading, 20)
                        .padding(.top, 66)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        // Trigger search when text changes
        .onChange(of: viewModel.searchText) { _, newValue in
            viewModel.onSearchTextChanged(newValue)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: showRecentSidebar)
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        offlineStateCard(
            icon: "waveform.circle",
            eyebrow: "DayDreamin",
            title: "Waiting for your music source",
            detail: "Open your server and the room wakes back up."
        ) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.88)))
                .scaleEffect(1.05)
        }
    }
    
    // MARK: - Error View
    private func errorView(message: String) -> some View {
        offlineStateCard(
            icon: "wifi.slash",
            eyebrow: "Offline",
            title: "No connection yet",
            detail: message
        ) {
            Button {
                viewModel.loadChartSongs()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.34, green: 0.08, blue: 0.14),
                                    Color(red: 0.12, green: 0.04, blue: 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
    }

    private func offlineStateCard<Accessory: View>(
        icon: String,
        eyebrow: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.14, green: 0.03, blue: 0.06),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(0.08))
                .background(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.8)
                )
                .frame(maxWidth: 320)
                .overlay {
                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.38, green: 0.08, blue: 0.14),
                                            Color.black
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 70, height: 70)
                            
                            Image(systemName: icon)
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        
                        Text(eyebrow.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.42))
                        
                        Text(title)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 18)
                        
                        Text(detail)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.58))
                            .padding(.horizontal, 22)
                        
                        accessory()
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 30)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    // MARK: - Player Content
    private var playerContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                Spacer()
                    .frame(height: 16)
                
                // Album Art
                if let song = viewModel.currentSong {
                    AlbumArtView(
                        imageURL: song.coverXL.isEmpty ? song.cover : song.coverXL,
                        colors: viewModel.dominantColors,
                        isPlaying: viewModel.isPlaying
                    )
                    .id(song.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                    
                    // Song Info
                    songInfoSection(song: song)
                        .animation(.easeInOut(duration: 0.5), value: viewModel.currentSongIndex)
                }
                
                // Buffering indicator
                if viewModel.isBuffering {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: viewModel.dominantColors.accent))
                            .scaleEffect(0.8)
                        Text("Buffering...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .transition(.opacity)
                }
                
                // Playback Controls
                PlaybackControlsView(viewModel: viewModel)
                    .padding(.horizontal, 28)
                
                // Up Next (collapsible queue)
                UpNextView(
                    songs: viewModel.upNextSongs,
                    allSongs: viewModel.songs,
                    currentIndex: viewModel.currentSongIndex,
                    isExpanded: $viewModel.showUpNext,
                    colors: viewModel.dominantColors,
                    onSelect: { song in
                        viewModel.selectUpNextSong(song)
                    },
                    onToggle: {
                        viewModel.toggleUpNext()
                    }
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
                
                Spacer()
                    .frame(height: 40)
            }
        }
    }
    
    // MARK: - Song Info
    private func songInfoSection(song: Song) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(song.title)
                .font(.custom("Jersey10-Regular", size: 52))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .id("title-\(song.id)")
            
            Text(song.artist)
                .font(.custom("Almendra-Regular", size: 24))
                .foregroundStyle(.white.opacity(0.85))
                .id("artist-\(song.id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    
    // MARK: - Search Results
    private var searchResultsOverlay: some View {
        VStack(spacing: 0) {
            if viewModel.isSearchLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Searching...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
            } else if viewModel.searchText.isEmpty {
                // Show chart songs when search is open but empty
                allSongsView
            } else if viewModel.searchResults.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.2))
                    
                    Text("No results found")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    
                    Text("Try a different search term")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.25))
                    
                    Spacer()
                }
            } else {
                SearchResultsView(
                    songs: viewModel.searchResults,
                    colors: viewModel.dominantColors,
                    onSelect: { song in
                        dismissKeyboard()
                        viewModel.selectSong(song, from: viewModel.searchResults)
                    }
                )
            }
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - All Songs View
    private var allSongsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRENDING")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.5)
                
                Spacer()
                
                Text("\(viewModel.songs.count) songs")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            SearchResultsView(
                songs: viewModel.songs,
                colors: viewModel.dominantColors,
                onSelect: { song in
                    dismissKeyboard()
                    viewModel.selectSong(song)
                }
            )
            .padding(.horizontal, 4)
        }
    }
    
    private func recentSidebar(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("RECENTLY PLAYED")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
            }
            
            if viewModel.recentSongs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No recent songs yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Play something once and it will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(.top, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.recentSongs) { song in
                            recentSongRow(song)
                                .onTapGesture {
                                    dismissKeyboard()
                                    viewModel.selectSong(song, from: viewModel.recentSongs)
                                    toggleRecentSidebar()
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(width: min(size.width * 0.46, 320), height: size.height * 0.48, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(.white.opacity(0.11))
        )
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.14), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 12)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private func recentSongRow(_ song: Song) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: song.cover)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(viewModel.dominantColors.primary.opacity(0.35))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        )
                default:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.06))
                        .overlay(ProgressView().scaleEffect(0.55))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Text(minimalRecentTitle(for: song.title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            
            Spacer()
            
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.26))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.white.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
    
    private func minimalRecentTitle(for title: String) -> String {
        let words = title
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .map(String.init)
        
        if words.isEmpty {
            return "Untitled"
        }
        return words.joined(separator: " ")
    }
    
    private func toggleRecentSidebar() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            showRecentSidebar.toggle()
        }
        HapticManager.playLightTap()
    }
}

#Preview {
    MusicPlayerView()
}
