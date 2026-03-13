import SwiftUI

struct AlbumArtView: View {
    let imageURL: String
    let colors: ColorExtractor.DominantColors
    let isPlaying: Bool
    
    @State private var rotation: Double = 0
    @State private var isImageLoaded = false
    
    var body: some View {
        ZStack {
            // Vinyl Record Outer Edge
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.8), Color.black]),
                        center: .center,
                        startRadius: 80,
                        endRadius: 160
                    )
                )
                .frame(width: 320, height: 320)
                .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
            
            // Vinyl Grooves (Concentric Circles)
            ForEach(0..<10) { i in
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                    .frame(width: 320 - CGFloat(i * 14), height: 320 - CGFloat(i * 14))
            }
            
            // Inner light reflection / glare
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.0), location: 0),
                            .init(color: .white.opacity(0.15), location: 0.1),
                            .init(color: .white.opacity(0.0), location: 0.2),
                            .init(color: .white.opacity(0.0), location: 0.5),
                            .init(color: .white.opacity(0.15), location: 0.6),
                            .init(color: .white.opacity(0.0), location: 0.7),
                            .init(color: .white.opacity(0.0), location: 1)
                        ]),
                        center: .center,
                        angle: .degrees(45)
                    )
                )
                .frame(width: 320, height: 320)
                .blendMode(.screen)
            
            // Center Album Art (Label)
            ZStack {
                Circle()
                    .fill(colors.primary)
                    .frame(width: 130, height: 130)
                
                AsyncImage(url: URL(string: imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 130, height: 130)
                            .clipShape(Circle())
                            .onAppear {
                                withAnimation(.easeIn(duration: 0.5)) {
                                    isImageLoaded = true
                                }
                            }
                    default:
                        ZStack {
                            Circle()
                                .fill(colors.secondary.opacity(0.5))
                                .frame(width: 130, height: 130)
                            Image(systemName: "music.note")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                
                // Spindle hole
                Circle()
                    .fill(Color.black)
                    .frame(width: 14, height: 14)
            }
        }
        .rotationEffect(.degrees(rotation))
        .onAppear {
            if isPlaying {
                startRotation()
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startRotation()
            } else {
                stopRotation()
            }
        }
    }
    
    private func startRotation() {
        withAnimation(.linear(duration: 12.0).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
    
    private func stopRotation() {
        // Capture current rotation to avoid jumping
        let currentRotation = rotation.truncatingRemainder(dividingBy: 360)
        withAnimation(.linear(duration: 0)) {
            rotation = currentRotation
        }
    }
}
