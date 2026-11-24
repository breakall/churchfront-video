import SwiftUI

struct CameraBridgeSetup: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var bridge = CameraBridgeRuntime.shared
    @State private var draft = CameraBridgeSettings()

    var body: some View {
        Card(title: "Physical camera controller") {
            VStack(alignment: .leading, spacing: T.s3) {
                Toggle("Route the Canon camera through the controller bridge", isOn: $draft.enabled)
                Text("Physical controls turn tracking off. Enable tracking again when the shot is ready. The bridge continues forwarding when Churchfront Video closes.")
                    .font(.sans(12)).foregroundStyle(T.inkMuted)
                HStack(spacing: T.s2) {
                    Text("Mac listener address").font(.sans(12)).frame(width: 150, alignment: .leading)
                    TextField("Mac IP address", text: $draft.listenHost).textFieldStyle(CueFieldStyle()).frame(width: 180)
                    TextField("Port", value: $draft.controllerPort, format: .number.grouping(.never))
                        .textFieldStyle(CueFieldStyle()).frame(width: 70)
                }
                HStack(spacing: T.s2) {
                    Text("RC-IP100 address").font(.sans(12)).frame(width: 150, alignment: .leading)
                    TextField("Controller IP address", text: $draft.controllerAddress).textFieldStyle(CueFieldStyle()).frame(width: 180)
                }
                Text("Register the Mac listener address and port as the camera destination on the RC-IP100. The bridge uses the single Canon camera configured above.")
                    .font(.sans(12)).foregroundStyle(T.inkMuted)
                Toggle("Use RC-IP100 tracking control for Churchfront", isOn: $draft.nativeTrackingControl)
                    .disabled(true)
                Text("Native tracking interception will be available after its controller commands have been verified. Use Churchfront's Track control in this build.")
                    .font(.sans(12)).foregroundStyle(T.inkMuted)
                Toggle("Detailed bridge diagnostics", isOn: $draft.diagnosticsEnabled)
                HStack(spacing: T.s2) {
                    Button("Apply bridge settings") { store.update { $0.cameraBridge = draft } }
                        .buttonStyle(CueButton(kind: .primary))
                        .disabled(draft == store.config.cameraBridge)
                    Button("Start bridge") { bridge.startBridge() }
                        .buttonStyle(CueButton()).disabled(!store.config.cameraBridge.enabled || bridge.running)
                    Button("Stop bridge") { bridge.stopBridge() }
                        .buttonStyle(CueButton(kind: .danger)).disabled(!bridge.running)
                    Button("Export diagnostics…") { bridge.exportDiagnostics() }.buttonStyle(CueButton())
                }
                Text(bridge.message).font(.sans(12, .semibold)).foregroundStyle(T.inkMuted)
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .onAppear { draft = store.config.cameraBridge }
        .onChange(of: store.config.cameraBridge) { _, value in draft = value }
    }
}
