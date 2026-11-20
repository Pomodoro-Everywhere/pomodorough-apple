#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Pomodorough

// IOS27-18: at accessibility sizes the stepper symbols and the launch
// caption must keep clear of their neighbours and the screen edge.
@Suite("Accessibility size clearance")
@MainActor
struct AccessibilitySizeClearanceTests {
    private func fittingSize(_ view: some View, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @Test func stepButtonKeepsTouchMinimumAtDefaultSize() {
        let size = fittingSize(
            StepButton(title: "Increase focus duration", symbol: "plus", action: {})
                .environment(\.dynamicTypeSize, .large)
        )
        #expect(abs(size.width - 44) < 0.5, "default step button \(size)")
        #expect(abs(size.height - 44) < 0.5, "default step button \(size)")
    }

    @Test func stepButtonGrowsAroundItsSymbolAtAccessibilitySizes() {
        let size = fittingSize(
            StepButton(title: "Increase focus duration", symbol: "plus", action: {})
                .environment(\.dynamicTypeSize, .accessibility5)
        )
        // The symbol alone outgrows 44 pt here; a fixed box clipped it
        // against the minutes text and the stepper border.
        #expect(size.width > 44, "AX5 step button \(size)")
    }

    /// The caption's sky pixels stay off the outer columns of a phone-wide
    /// launch screen at the largest text size.
    @Test func launchCaptionKeepsScreenMargins() throws {
        let width: CGFloat = 375
        let view = LaunchView()
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: width, height: 667)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let margin = try skyFreeMargin(in: image)
        #expect(margin >= 16, "caption margin \(margin) pt at AX5")
    }

    /// Smallest distance from either side to a pixel near the sky colour.
    private func skyFreeMargin(in image: CGImage) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn: Void? = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        try #require(drawn != nil)
        let sky = PomodoroughTheme.skySRGB
        let target = [Int(sky.red * 255), Int(sky.green * 255), Int(sky.blue * 255)]
        var margin = image.width
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let pixel = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
            guard zip(pixel, target).allSatisfy({ abs($0 - $1) <= 12 }) else { continue }
            let column = (offset / 4) % image.width
            margin = min(margin, column, image.width - 1 - column)
        }
        return margin
    }
}
#endif
