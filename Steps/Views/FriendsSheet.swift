import AVFoundation
import SwiftUI
import UIKit
import WidgetKit

struct FriendsSheet: View {
    @Environment(FriendStore.self) private var friends
    @Environment(WalkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var entering = false
    @State private var typed = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var confirmingReset = false
    @State private var tap = FriendTap()
    @AppStorage("steps.addByProximity") private var addByProximity = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    codeCard
                    proximityToggle
                    if addByProximity {
                        tapHint
                    }
                    addButtons
                    if entering {
                        enterRow
                    }
                    if let message = friends.message {
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    friendList
                }
                .padding(24)
            }
            .background(Color.black)
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { beginTap() }
        .onDisappear {
            tap.stop()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .fullScreenCover(isPresented: $scanning) {
            FriendScanner { code in
                scanning = false
                guard let code else { return }
                Task { await add(code) }
            }
        }
    }

    private var codeCard: some View {
        VStack(spacing: 14) {
            if let image = FriendCodeImage.make(friends.code) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(friends.code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.white)
            Button("Reset code") { confirmingReset = true }
                .font(.system(size: 15, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(.white)
                .confirmationDialog("Reset your code?", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset code", role: .destructive) {
                        Task {
                            await friends.resetCode()
                            if let day = store.day { friends.publishNow(day) }
                            beginTap()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Friends are cleared, and the old code disappears from their charts. A new code is saved to iCloud.")
                }
            TextField("Name friends see", text: Bindable(friends).displayName)
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private var proximityToggle: some View {
        HStack(spacing: 12) {
            Text("Add by proximity")
                .font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 12)
            ContrastSwitch(isOn: $addByProximity)
        }
        .onChange(of: addByProximity) { _, on in
            if on {
                beginTap()
            } else {
                tap.stop()
            }
        }
    }

    private var tapHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text(tap.status)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
    }

    private func beginTap() {
        guard addByProximity else {
            tap.stop()
            return
        }
        tap.start(
            code: friends.code,
            name: friends.displayName.isEmpty ? friends.code : friends.displayName,
            skip: Set(friends.friends.map(\.id))
        ) { code in
            await friends.addFromNearby(code: code)
        }
    }

    private var addButtons: some View {
        HStack(spacing: 12) {
            Button {
                entering.toggle()
            } label: {
                Label("Enter code", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                entering = false
                scanning = true
            } label: {
                Label("Scan", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .disabled(friends.friends.count >= 3 || busy)
    }

    private var enterRow: some View {
        HStack(spacing: 10) {
            TextField("Code", text: codeText)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { Task { await add(typed) } }
            Button("Add") {
                Task { await add(typed) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(busy || typed.count < 6)
        }
    }

    private var friendList: some View {
        VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Show friends on widget")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer(minLength: 12)
                        ContrastSwitch(isOn: Bindable(friends).showOnWidget)
                    }
                    if friends.friends.isEmpty {
                Text("Add up to three people. Their day shows behind yours.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(friends.friends) { friend in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Palette.friendColor(friend.colorIndex))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.name)
                                .font(.system(size: 16, weight: .semibold))
                            Text("\(friend.steps.formatted()) steps")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        Spacer()
                        Button {
                            friends.remove(code: friend.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .accessibilityLabel("Delete \(friend.name)")
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codeText: Binding<String> {
        Binding(
            get: { typed },
            set: { newValue in
                let cleaned = newValue.uppercased().filter { !$0.isWhitespace && $0 != "-" }
                typed = String(cleaned.prefix(6))
            }
        )
    }

    private func add(_ raw: String) async {
        busy = true
        let added = await friends.add(code: raw)
        busy = false
        if added {
            typed = ""
            entering = false
        }
    }
}

private struct FriendScanner: View {
    var onCode: (String?) -> Void
    @State private var denied = false
    @State private var allowed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                VStack(spacing: 12) {
                    Text("Camera access is off")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Turn on the camera for Steps in Settings to scan a code.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else if allowed {
                ScannerPreview { onCode($0) }
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 240, height: 240)
                VStack {
                    Spacer()
                    Text("Point at their code")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.bottom, 48)
                }
            }
            VStack {
                HStack {
                    Button("Cancel") { onCode(nil) }
                        .font(.system(size: 17, weight: .semibold))
                        .padding(20)
                    Spacer()
                }
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .authorized {
                allowed = true
            } else if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                allowed = granted
                denied = !granted
            } else {
                denied = true
            }
        }
    }
}

private struct ScannerPreview: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "steps.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var found = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !found,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              let code = FriendCode.normalize(value) else { return }
        found = true
        onCode?(code)
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private struct ContrastSwitch: UIViewRepresentable {
    @Binding var isOn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.onTintColor = .white
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.parent = self
        if control.isOn != isOn {
            control.setOn(isOn, animated: true)
        }
        control.onTintColor = .white
        control.thumbTintColor = isOn ? .black : .white
    }

    final class Coordinator: NSObject {
        var parent: ContrastSwitch

        init(_ parent: ContrastSwitch) {
            self.parent = parent
        }

        @objc func changed(_ sender: UISwitch) {
            parent.isOn = sender.isOn
            sender.thumbTintColor = sender.isOn ? .black : .white
        }
    }
}
