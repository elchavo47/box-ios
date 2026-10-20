import SwiftUI

/// Ayarlar › Dil: Otomatik (telefonun dili) ya da desteklenen dillerden biri. Seçim hemen uygulanır.
struct LanguagePickerView: View {
    @EnvironmentObject private var lang: Lang

    var body: some View {
        List {
            Section {
                row(code: "auto", title: L("Otomatik"), subtitle: Lang.supported.first { $0.code == Lang.resolveAutomatic() }?.name)
            } footer: {
                Text(L("Telefonunun dili değişince Box da değişir."))
            }
            .listRowBackground(Color.boxSurface2)

            Section {
                ForEach(Lang.supported) { language in
                    row(code: language.code, title: language.name, subtitle: nil)
                }
            }
            .listRowBackground(Color.boxSurface2)
        }
        .scrollContentBackground(.hidden)
        .boxScreenBackground()
        .navigationTitle(L("Dil"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(code: String, title: String, subtitle: String?) -> some View {
        Button {
            guard lang.choice != code else { return }
            Haptics.tap()
            lang.choice = code
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.white)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundColor(.boxSecondaryText)
                    }
                }
                Spacer()
                if lang.choice == code {
                    Image(systemName: "checkmark").foregroundColor(.accent).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
