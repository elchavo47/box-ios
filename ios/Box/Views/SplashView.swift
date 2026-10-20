import SwiftUI

struct SplashView: View {
    @State private var glow = false
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RadialGradient(
                colors: [Color.neon.opacity(glow ? 0.22 : 0.08), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image("BoxLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .blendMode(.screen)
                    .shadow(color: Color.neon.opacity(glow ? 0.9 : 0.35), radius: glow ? 28 : 10)
                    .scaleEffect(appear ? 1 : 0.86)

                Text("BOX")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .tracking(14)
                    .foregroundColor(.neon)
                    .shadow(color: Color.neon.opacity(0.8), radius: glow ? 12 : 4)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 10)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                appear = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}
