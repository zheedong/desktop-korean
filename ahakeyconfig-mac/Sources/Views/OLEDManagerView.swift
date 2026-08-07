import SwiftUI
import UniformTypeIdentifiers

struct OLEDManagerView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    @State private var selectedImage: NSImage?
    @State private var selectedGIFURL: URL?
    @State private var fps: Int = 30
    @State private var frameCount: Int = 0

    var body: some View {
        Form {
            Section("애니메이션 관리") {
                // 미리보기 영역
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                        .frame(height: 160)

                    if let image = selectedImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 140)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("이미지 없음")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("이미지 추가") {
                        selectImage()
                    }
                    .buttonStyle(.bordered)

                    Button("GIF 추가") {
                        selectGIF()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("비우기") {
                        selectedImage = nil
                        selectedGIFURL = nil
                        frameCount = 0
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                if frameCount > 0 {
                    HStack {
                        Text("FPS:")
                        Stepper("\(fps)", value: $fps, in: 1...30)
                            .frame(width: 100)
                        Spacer()
                        Text("\(frameCount) 프레임")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if bleManager.isConnected {
                Section {
                    Button("기기로 업로드") {
                        // TODO: BLE 0x7343을 통해 이미지/GIF 데이터를 분할 패킷으로 업로드
                        // OLED 해상도와 이미지 포맷은 리버스 엔지니어링으로 확인 필요
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImage == nil && selectedGIFURL == nil)
                }
            } else {
                Section {
                    Text("먼저 AhaKey 기기를 연결하세요")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }

    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedImage = NSImage(contentsOf: url)
            selectedGIFURL = nil
            frameCount = 0
        }
    }

    private func selectGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gif")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: url)
            } catch {
                NSSound.beep()
                return
            }
            selectedGIFURL = url
            selectedImage = NSImage(contentsOf: url)
            // GIF 프레임 수 추정
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                frameCount = CGImageSourceGetCount(source)
            }
        }
    }
}
