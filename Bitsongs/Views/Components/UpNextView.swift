import SwiftUI

struct UpNextView: View {
    let songs: [Song]
    let allSongs: [Song]
    let currentIndex: Int
    @Binding var isExpanded: Bool
    let colors: ColorExtractor.DominantColors
    let onSelect: (Song) -> Void
    let onToggle: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Song list popover (only when expanded)
            if isExpanded {
                VStack(spacing: 2) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(songs) { song in
                                UpNextRow(song: song, colors: colors)
                                    .onTapGesture {
                                        onSelect(song)
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 250)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // "Up Next" Pill Button
            Button(action: onToggle) {
                Text(isExpanded ? "Close" : "Up Next")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.2))
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
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
    }
}

struct UpNextRow: View {
    let song: Song
    let colors: ColorExtractor.DominantColors
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Album art thumbnail from URL
            AsyncImage(url: URL(string: song.cover)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.2), radius: 4)
                case .failure:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colors.primary.opacity(0.3))
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(width: 44, height: 44)
                default:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.05))
                        .frame(width: 44, height: 44)
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.5)
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                
                Text(song.artist)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Duration
            if song.duration > 0 {
                Text(formatDuration(TimeInterval(song.duration)))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            
            // Play icon
            Image(systemName: "play.circle")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(isHovered ? 0.06 : 0.03))
        )
        .scaleEffect(isHovered ? 0.98 : 1.0)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = pressing
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
        UpNextView(
            songs: [],
            allSongs: [],
            currentIndex: 0,
            isExpanded: .constant(false),
            colors: .default,
            onSelect: { _ in },
            onToggle: {}
        )
        .padding()
    }
}
