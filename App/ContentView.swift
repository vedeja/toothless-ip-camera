import SwiftUI

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    private let accent = Color(red: 0.88, green: 0.23, blue: 0.15)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    preview
                        .frame(height: max(240, min(geometry.size.height * 0.49, 520)))
                        .clipped()
                    controls
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .tint(accent)
        .task { await model.prepare() }
        .onChange(of: model.frontCamera) { _, _ in model.switchCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.background() }
            if phase == .active { model.foreground() }
        }
        .alert("Camera", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Toothless").font(.system(.title, design: .rounded, weight: .bold))
                Text("IP CAMERA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.isStreaming ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.isStreaming ? "Live" : model.isStarting ? "Starting" : "Standby")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.cameraReady {
                CameraPreview(session: model.pipeline.session, mirrored: model.frontCamera)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text(model.permissionDenied ? "Camera access is off" : "Camera unavailable")
                        .font(.headline)
                    if model.permissionDenied {
                        Button("Open Settings", systemImage: "gear") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }.buttonStyle(.bordered)
                    }
                }
                .foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Label(model.frontCamera ? "Front" : "Back", systemImage: "camera")
                    Spacer()
                    Text("H.264 / \(model.resolution.label) / \(model.frameRate) fps").monospaced()
                }
                Spacer()
                if let started = model.startedAt {
                    HStack {
                        Text(started, style: .timer).monospacedDigit()
                        Spacer()
                        Label("\(model.viewerCount)", systemImage: "person.2")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(20)
            .background {
                VStack {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 80)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityLabel("Live camera preview")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Camera").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Camera", selection: $model.frontCamera) {
                    Text("Back").tag(false)
                    Text("Front").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
                .disabled(model.isStreaming || model.isStarting || !model.cameraReady)
            }
            Divider()
            VStack(spacing: 12) {
                HStack {
                    Text("Resolution").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Resolution", selection: $model.resolution) {
                        ForEach(model.availableResolutions) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isStreaming || model.isStarting || !model.cameraReady)
                    .onChange(of: model.resolution) { _, _ in model.configureVideo() }
                }
                HStack {
                    Text("Frame rate").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Frame rate", selection: $model.frameRate) {
                        ForEach(model.availableFrameRates, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isStreaming || model.isStarting || !model.cameraReady)
                    .onChange(of: model.frameRate) { _, _ in model.configureVideo() }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Network stream").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(model.isStreaming ? "Live" : "Not streaming")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.isStreaming ? Color.green : Color.secondary)
                }
                HStack(spacing: 12) {
                    Text(model.streamURL ?? "No local network")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = model.streamURL {
                        Button {
                            UIPasteboard.general.string = url
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(copied ? "Copied stream URL" : "Copy stream URL")
                        .help("Copy stream URL")
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Share stream URL")
                    }
                }
            }
            Button {
                if model.isStreaming || model.isStarting { model.stop() } else { model.start() }
            } label: {
                HStack(spacing: 10) {
                    if model.isStarting { ProgressView().tint(.white) }
                    else { Image(systemName: model.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right") }
                    Text(model.isStreaming ? "Stop streaming" : model.isStarting ? "Cancel" : "Start streaming")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(.white)
                .background(accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!model.cameraReady || model.address == nil)
            .opacity(model.cameraReady && model.address != nil ? 1 : 0.45)
            HStack {
                Label("Local network", systemImage: "wifi")
                Spacer()
                Label("Video only", systemImage: "mic.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .onChange(of: model.streamURL) { _, _ in copied = false }
    }
}