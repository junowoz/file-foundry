import SwiftUI

struct MediaOrganizerSettingsView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: RackLayout.l) {
            Text("Media Organizer Options").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: RackLayout.s) {
                Toggle("Use file date as a last resort", isOn: Bindable(store).filesystemFallback)
                Text("Finder dates can reflect a copy, not the original capture.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(RackLayout.l)
            .foundryCard()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(RackLayout.xl)
        .frame(width: 460)
    }
}
