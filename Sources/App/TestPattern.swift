import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// A moving frame counter and clock, to see in a video app that frames flow from the app.
/// LIMITATION: placeholder content until AvatarRenderer (Phase 2) draws the avatar.
final class TestPattern {
    private var pool: CVPixelBufferPool!
    private var frame = 0
    private let width = Int(CameraIdentifiers.width)
    private let height = Int(CameraIdentifiers.height)

    init() {
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
    }

    func nextFrame() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        frame += 1

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

        let hue = CGFloat(frame % 300) / 300
        context.setFillColor(CGColor(red: 0.2 + 0.3 * hue, green: 0.4, blue: 0.6 - 0.3 * hue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: frame * 8 % width, y: 0, width: 40, height: height))

        let time = Date().formatted(date: .omitted, time: .standard)
        let text = NSAttributedString(string: "vutusi  #\(frame)  \(time)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return buffer
    }
}
