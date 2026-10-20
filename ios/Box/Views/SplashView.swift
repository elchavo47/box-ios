import SwiftUI

/// Açılış ekranı: sistem açılış görseliyle aynı yerde duran sade küp logosu, ışık efekti yok.
struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.boxBackground.ignoresSafeArea()

            BoxMark(size: 88)

            Text("Box")
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.5)
                .foregroundColor(.white)
                .offset(y: 78)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.1)) {
                appear = true
            }
        }
    }
}
