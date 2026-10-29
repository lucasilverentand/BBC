import AppKit

@main struct RenderMessageSymbol {
    enum Failure: Error { case outputPath, symbolUnavailable, bitmap, encoding }
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.outputPath }
        let white = NSColor.white
        guard let symbol = NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [white])) else {
            throw Failure.symbolUnavailable
        }
        let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        let width: CGFloat = 700
        let height = width * symbol.size.height / symbol.size.width
        let frame = NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 30, width: width, height: height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.bitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(canvas)
        symbol.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure.encoding }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
