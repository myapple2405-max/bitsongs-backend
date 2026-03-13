import SwiftUI

struct MusicPlayerView: View {
    @StateObject private var viewModel = MusicPlayerViewModel()
    @Namespace private var animation
    
    var body: some View {
        ZStack {
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
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        // Trigger search when text changes
        .onChange(of: viewModel.searchText) { _, newValue in
            viewModel.onSearchTextChanged(newValue)
        }
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Connecting to server...")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            
            Text("Make sure PyMusic is running")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
    
    // MARK: - Error View
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))
            
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                viewModel.loadChartSongs()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.15))
                )
            }
        }
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
                    viewModel.selectSong(song)
                }
            )
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    MusicPlayerView()
}
