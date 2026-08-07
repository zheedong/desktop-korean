import CoreGraphics
import Foundation
import ImageIO

enum OLEDFrameEncodingError: LocalizedError {
    case cannotCreateImageSource
    case noFrames
    case cannotCreateContext
    case sourceFileTooLarge(fileSize: Int, maxBytes: Int)
    case tooManyFrames(count: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .cannotCreateImageSource:
            return "GIF 파일을 읽을 수 없습니다."
        case .noFrames:
            return "인코딩할 이미지 프레임이 없습니다."
        case .cannotCreateContext:
            return "LCD 인코딩 컨텍스트를 생성할 수 없습니다."
        case .sourceFileTooLarge(let fileSize, let maxBytes):
            let f = ByteCountFormatter()
            f.allowedUnits = [.useMB, .useKB, .useBytes]
            f.countStyle = .file
            let a = f.string(fromByteCount: Int64(fileSize))
            let b = f.string(fromByteCount: Int64(maxBytes))
            return "이미지 원본 파일이 약 \(a)로, 파일당 상한인 \(b)를 초과합니다. 해상도를 줄이거나 프레임 수를 줄이거나 애니메이션 길이를 짧게 한 뒤 다시 시도해 주세요."
        case .tooManyFrames(let count, let max):
            return "현재 애니메이션은 총 \(count)프레임으로, 모드당 상한인 \(max)프레임을 초과합니다. 프레임 수를 줄이거나 애니메이션 길이를 짧게 한 뒤 다시 시도해 주세요."
        }
    }
}

enum OLEDFrameEncoder {
    static func frameCount(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// 원본 GIF 파일의 바이트 수. 읽을 수 없으면 `nil`을 반환한다.
    static func sourceFileByteCount(at url: URL) -> Int? {
        if let v = try? url.resourceValues(forKeys: [.fileSizeKey]), let n = v.fileSize { return n }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? Int {
            return n
        }
        return nil
    }

    /// `AhaKeyCommand.oledMaxSourceFileBytes`를 초과하면 `sourceFileTooLarge`를 던진다.
    static func validateGIFSourceFileSize(at url: URL) throws {
        guard let n = sourceFileByteCount(at: url) else {
            return
        }
        guard n <= AhaKeyCommand.oledMaxSourceFileBytes else {
            throw OLEDFrameEncodingError.sourceFileTooLarge(fileSize: n, maxBytes: AhaKeyCommand.oledMaxSourceFileBytes)
        }
    }

    static func validateFrameCount(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OLEDFrameEncodingError.cannotCreateImageSource
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw OLEDFrameEncodingError.noFrames
        }
        guard count <= AhaKeyCommand.oledMaxFramesPerMode else {
            throw OLEDFrameEncodingError.tooManyFrames(count: count, max: AhaKeyCommand.oledMaxFramesPerMode)
        }
    }

    static func frames(fromGIFAt url: URL) throws -> [Data] {
        try validateGIFSourceFileSize(at: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OLEDFrameEncodingError.cannotCreateImageSource
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw OLEDFrameEncodingError.noFrames
        }
        guard count <= AhaKeyCommand.oledMaxFramesPerMode else {
            throw OLEDFrameEncodingError.tooManyFrames(count: count, max: AhaKeyCommand.oledMaxFramesPerMode)
        }

        var frames: [Data] = []
        frames.reserveCapacity(count)
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(try encodeFrame(image))
        }

        guard !frames.isEmpty else {
            throw OLEDFrameEncodingError.noFrames
        }
        return frames
    }

    private static func encodeFrame(_ image: CGImage) throws -> Data {
        let width = AhaKeyCommand.oledWidth
        let height = AhaKeyCommand.oledHeight
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OLEDFrameEncodingError.cannotCreateContext
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawWidth = Double(image.width) * scale
        let drawHeight = Double(image.height) * scale
        let drawRect = CGRect(
            x: (Double(width) - drawWidth) / 2,
            y: (Double(height) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        context.draw(image, in: drawRect)

        // 프레임당 정확히 160*80*2 = 25600바이트 RGB565 빅엔디안이며, 원본 Python도 padding을 넣지 않는다.
        // flash의 물리 프레임 슬롯은 28672바이트이고, 남는 3072바이트는 address가 증가하면서 자연스럽게 비워진다.
        var data = Data(capacity: width * height * 2)
        for pixel in stride(from: 0, to: rgba.count, by: bytesPerPixel) {
            let red = UInt16(rgba[pixel])
            let green = UInt16(rgba[pixel + 1])
            let blue = UInt16(rgba[pixel + 2])
            let rgb565 = ((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3)
            data.append(UInt8((rgb565 >> 8) & 0xFF))
            data.append(UInt8(rgb565 & 0xFF))
        }
        return data
    }
}
