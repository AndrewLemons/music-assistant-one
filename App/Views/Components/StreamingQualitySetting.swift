import SwiftUI

struct StreamingQualitySetting: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Cellular Streaming", selection: Binding(
            get: { model.downloads.cellularStreamingQuality },
            set: { model.downloads.cellularStreamingQuality = $0 }
        )) {
            Text("Lossless").tag("flac")
            Text("High Efficiency").tag("aac")
        }
    }
}
