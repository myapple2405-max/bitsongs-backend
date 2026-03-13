import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    @Binding var isSearching: Bool
    let onCancel: () -> Void
    let accentColor: Color
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                
                TextField("Search", text: $text)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white)
                    .tint(accentColor)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: isFocused) { _, focused in
                        if focused {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isSearching = true
                            }
                        }
                    }
                
                if !text.isEmpty {
                    Button {
                        text = ""
                        HapticManager.playLightTap()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(.white.opacity(0.15))
            )
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )
            
            // Cancel button
            if isSearching {
                Button {
                    isFocused = false
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(accentColor)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isSearching)
        .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
    }
}

// MARK: - Search Results View
struct SearchResultsView: View {
    let songs: [Song]
    let colors: ColorExtractor.DominantColors
    let onSelect: (Song) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(songs) { song in
                    SearchResultRow(song: song, colors: colors)
                        .onTapGesture {
                            onSelect(song)
                        }
                }
            }
            .padding(.top, 8)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct SearchResultRow: View {
    let song: Song
    let colors: ColorExtractor.DominantColors
    @State private var isPressed = false
    
    var body: some View {
        HStack(spacing: 14) {
            // Mini album art from URL
            AsyncImage(url: URL(string: song.cover)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colors.primary.opacity(0.3))
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(width: 48, height: 48)
                default:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.05))
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    .frame(width: 48, height: 48)
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(song.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                    
                    if !song.genre.isEmpty {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                        
                        Text(song.genre)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(colors.accent.opacity(0.8))
                    }
                }
                .lineLimit(1)
            }
            
            Spacer()
            
            // Duration if available
            if song.duration > 0 {
                Text(formatDuration(TimeInterval(song.duration)))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(isPressed ? 0.08 : 0.0))
        )
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.15)) {
                isPressed = pressing
            }
        }) {}
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            SearchBarView(
                text: .constant(""),
                isSearching: .constant(false),
                onCancel: {},
                accentColor: .purple
            )
            .padding()
        }
    }
}
