import SwiftUI

/// Kullanıcının profil fotoğrafı; yoksa adının baş harfi.
struct UserAvatar: View {
    let user: BoxUser?
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(Color.accentDeep)
            Text(String((user?.name ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundColor(.white)
            if let url = user?.avatarURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
