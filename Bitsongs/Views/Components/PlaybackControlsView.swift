import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: MusicPlayerViewModel
    @State private var dragProgress: Double?
    
    var body: some View {
        VStack(spacing: 24) {
            // Progress bar
            progressSection
            
            // Main controls
            controlButtons
        }
    }
    
    // MARK: - Progress Section
    private var progressSection: some View {
        VStack(spacing: 8) {
            // Custom slider (no thumb, just a line)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(height: 2)
                    
                    // Progress fill
                    Rectangle()
                        .fill(.white)
                        .frame(width: max(0, geo.size.width * (dragProgress ?? viewModel.progress)), height: 2)
                }
                .contentShape(Rectangle()) // Make touchable
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let progress = max(0, min(value.location.x / geo.size.width, 1.0))
                            dragProgress = progress
                        }
                        .onEnded { _ in
                            if let dragProgress {
                                viewModel.seekToProgress(dragProgress)
                            }
                            dragProgress = nil
                            HapticManager.playLightTap()
                        }
                )
            }
            .frame(height: 20)
        }
    }
    
    // MARK: - Control Buttons
    private var controlButtons: some View {
        HStack(spacing: 50) {
            // Previous
            Button {
                viewModel.playPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(viewModel.songs.isEmpty)
            
            // Play/Pause
            Button {
                viewModel.togglePlayPause()
            } label: {
                if viewModel.isBuffering {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                } else {
                    Image(systemName: viewModel.isPlaying ? "pause" : "play")
                        .font(.system(size: 42, weight: .ultraLight))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(viewModel.songs.isEmpty)
            
            // Next
            Button {
                viewModel.playNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(viewModel.songs.isEmpty)
        }
    }
}

// MARK: - Scale Button Style
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        PlaybackControlsView(viewModel: MusicPlayerViewModel())
            .padding(.horizontal, 32)
    }
}
