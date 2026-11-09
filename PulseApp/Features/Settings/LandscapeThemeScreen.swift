import SwiftUI

struct LandscapeThemeScreen: View {
    @Environment(Workspace.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(LandscapeTheme.allCases) { theme in
                    Button {
                        store.change { $0.landscapeTheme = theme.rawValue }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            LookoutLandscape(sky: store.sky, energy: 5, theme: theme)
                                .frame(height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(theme.title).font(.headline)
                                    if theme == .pastelPainting {
                                        Text("Default").font(.caption).foregroundStyle(Color.moss)
                                    }
                                    Text(theme.detail).font(.subheadline).foregroundStyle(Color.moss)
                                }
                                Spacer(minLength: 0)
                                if store.landscapeTheme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.journalAccent)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .foregroundStyle(Color.journalInk)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("landscape-theme-\(theme.rawValue)")
                    .accessibilityLabel(theme.title)
                    .accessibilityValue(store.landscapeTheme == theme ? "Selected" : "")
                    .accessibilityHint(theme.detail)
                    .accessibilityAddTraits(store.landscapeTheme == theme ? .isSelected : [])
                }
            } footer: {
                Text("Your theme appears on Today and check-in. Every pack follows your atmosphere setting.")
            }
        }
        .formPaper()
        .navigationTitle("Theme packs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
