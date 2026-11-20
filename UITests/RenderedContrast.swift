import XCTest
import UIKit

/// Rendered contrast of one on-screen element: the most common sRGB colour in
/// the centre of its frame is the fill, and the colour with the highest
/// contrast against the fill that covers more than `minimumPixels` is the
/// foreground. Antialiased edge pixels never reach the threshold.
struct RenderedContrast {
    let fill: UInt32
    let foreground: UInt32
    let ratio: Double
    let receipt: String

    @MainActor
    static func measure(
        _ element: XCUIElement,
        in app: XCUIApplication,
        inset: CGFloat = 0.2,
        minimumPixels: Int = 30
    ) throws -> RenderedContrast {
        let frame = element.frame
        XCTAssertTrue(app.frame.contains(frame), "\(element) is fully on screen")
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        let sample = crop.insetBy(dx: crop.width * inset, dy: crop.height * inset).integral
        let colors = try histogram(try XCTUnwrap(image.cropping(to: sample)))
            .sorted { $0.value > $1.value }
        let fill = try XCTUnwrap(colors.first)
        var best = (rgb: fill.key, ratio: 1.0)
        for candidate in colors.dropFirst() where candidate.value > minimumPixels {
            let ratio = contrast(fill.key, candidate.key)
            if ratio > best.ratio { best = (candidate.key, ratio) }
        }
        let receipt = "frame=\(frame) sample=\(sample) fill=\(String(fill.key, radix: 16)) "
            + "foreground=\(String(best.rgb, radix: 16)) contrast=\(best.ratio)"
        return RenderedContrast(fill: fill.key, foreground: best.rgb, ratio: best.ratio, receipt: receipt)
    }

    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let ordered = [luminance(first), luminance(second)].sorted()
        return (ordered[1] + 0.05) / (ordered[0] + 0.05)
    }

    static func luminance(_ rgb: UInt32) -> Double {
        let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)]
        let linear = channels.map { channel in
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func histogram(_ image: CGImage) throws -> [UInt32: Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var histogram: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let rgb = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
            histogram[rgb, default: 0] += 1
        }
        return histogram
    }
}

/// Reads screenshot pixels inside a frame, given in app points, against a
/// colour predicate on 0...255 sRGB channels.
enum RenderedPixels {
    /// One horizontal run of pixel columns that each hold a matching pixel.
    struct ColumnRun {
        let width: Int
        let height: Int
    }

    @MainActor
    static func count(
        in frame: CGRect,
        of screenshot: XCUIScreenshot,
        app: XCUIApplication,
        matching predicate: (Int, Int, Int) -> Bool
    ) throws -> Int {
        let region = try sRGBBytes(in: frame, of: screenshot, app: app)
        return stride(from: 0, to: region.bytes.count, by: 4).count { offset in
            predicate(Int(region.bytes[offset]), Int(region.bytes[offset + 1]), Int(region.bytes[offset + 2]))
        }
    }

    /// Runs of neighbouring pixel columns that hold matching pixels, left to
    /// right. A monospaced label draws one run per letter.
    @MainActor
    static func columnRuns(
        in frame: CGRect,
        of screenshot: XCUIScreenshot,
        app: XCUIApplication,
        matching predicate: (Int, Int, Int) -> Bool
    ) throws -> [ColumnRun] {
        let region = try sRGBBytes(in: frame, of: screenshot, app: app)
        let rowCount = region.bytes.count / (region.width * 4)
        var runs: [ColumnRun] = []
        var current: (width: Int, top: Int, bottom: Int)?
        for column in 0..<region.width {
            let rows = (0..<rowCount).filter { row in
                let offset = (row * region.width + column) * 4
                return predicate(Int(region.bytes[offset]), Int(region.bytes[offset + 1]), Int(region.bytes[offset + 2]))
            }
            if let top = rows.first, let bottom = rows.last {
                current = ((current?.width ?? 0) + 1, min(current?.top ?? top, top), max(current?.bottom ?? bottom, bottom))
            } else if let run = current {
                runs.append(ColumnRun(width: run.width, height: run.bottom - run.top + 1))
                current = nil
            }
        }
        if let run = current { runs.append(ColumnRun(width: run.width, height: run.bottom - run.top + 1)) }
        return runs
    }

    @MainActor
    private static func sRGBBytes(
        in frame: CGRect,
        of screenshot: XCUIScreenshot,
        app: XCUIApplication
    ) throws -> (bytes: [UInt8], width: Int) {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        let region = try XCTUnwrap(image.cropping(to: crop))
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                width: region.width, height: region.height, bitsPerComponent: 8,
                bytesPerRow: region.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        }
        return (bytes, region.width)
    }
}
