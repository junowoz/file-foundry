import SwiftUI

struct MediaOrganizerSettingsView: View {
    let store: AppStore
    var body: some View {
        Form {
            Toggle("Usar data do arquivo como último recurso", isOn: Bindable(store).filesystemFallback)
            Text("Datas do Finder podem refletir uma cópia, e não a captura original.").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 460)
    }
}
