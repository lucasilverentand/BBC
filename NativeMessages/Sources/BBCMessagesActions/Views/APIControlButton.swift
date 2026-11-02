import SwiftUI

struct APIControlButton: View {
    @Bindable var model: AppModel
    @AppStorage("apiPort") private var port = 7861
    var body: some View {
        Button(model.running || model.starting ? "Stop API" : "Start API") {
            if model.running || model.starting { model.stop() }
            else { model.start(port:port) }
        }.buttonStyle(.borderedProminent)
    }
}

