import SwiftUI

struct ScribeRecordingSetupView: View {
    @ObservedObject var store: TranscribeStore
    @Binding var isPresented: Bool
    @State private var microphone = true
    @State private var screen = false

    var body: some View {
        VStack(alignment: .leading, spacing: RackLayout.xl) {
            HStack {
                Image(systemName: "record.circle").font(.system(size: 32)).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("New Recording").font(.title2.bold())
                    Text("System audio is always recorded.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: RackLayout.m) {
                Toggle("Include my microphone", isOn: $microphone)
                Toggle("Also record the screen", isOn: $screen)
            }
            GroupBox {
                Label("macOS will ask for Screen Recording access to capture audio from Meet, Zoom, your browser, and other apps. Use headphones to reduce echo.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary).padding(RackLayout.xs)
            }
            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Recording") {
                    store.startRecording(includeMicrophone: microphone, recordScreen: screen)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(RackLayout.xl).frame(width: 500)
    }
}
