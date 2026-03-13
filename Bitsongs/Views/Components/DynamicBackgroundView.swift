import SwiftUI

struct DynamicBackgroundView: View {
    let colors: ColorExtractor.DominantColors
    
    @State private var animateGradient = false
    
    var body: some View {
        ZStack {
            // Base dark layer
            Color.black.ignoresSafeArea()
            
            // Animated gradient mesh
            MeshGradientBackground(colors: colors, animate: animateGradient)
                .ignoresSafeArea()
                .opacity(0.85)
            
            // Overlay blur
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
                .opacity(0.3)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animateGradient = true
            }
        }
    }
}

struct MeshGradientBackground: View {
    let colors: ColorExtractor.DominantColors
    let animate: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Multiple overlapping gradients for a rich look
                RadialGradient(
                    colors: [colors.primary.opacity(0.8), colors.background],
                    center: animate ? .topLeading : .bottomTrailing,
                    startRadius: 100,
                    endRadius: geo.size.height
                )
                
                RadialGradient(
                    colors: [colors.secondary.opacity(0.6), .clear],
                    center: animate ? .bottomTrailing : .topLeading,
                    startRadius: 50,
                    endRadius: geo.size.width * 0.8
                )
                
                RadialGradient(
                    colors: [colors.accent.opacity(0.3), .clear],
                    center: animate ? .top : .bottom,
                    startRadius: 20,
                    endRadius: geo.size.width * 0.6
                )
                
                // Noise texture overlay for visual depth
                LinearGradient(
                    colors: [
                        .black.opacity(0.2),
                        .clear,
                        .black.opacity(0.3)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

#Preview {
    DynamicBackgroundView(colors: .default)
}
