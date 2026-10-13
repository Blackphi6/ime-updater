import AppKit

// メニューバー用: 背景なし、SF Symbol のシルエットのみを正方形いっぱいに描画する。
// Usage: swift make_menubar_symbol.swift <output> <sfSymbolName> <size>

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "symbol.png"
let symbolName = args.count > 2 ? args[2] : "keyboard.fill"
let size: CGFloat = args.count > 3 ? (CGFloat(Double(args[3]) ?? 256)) : 256

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.88, weight: .bold)
if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    let symbolRect = NSRect(
        x: (size - symbolSize.width) / 2,
        y: (size - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    if let cgImage = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.clip(to: symbolRect, mask: cgImage)
        NSColor(calibratedRed: 0.32, green: 0.33, blue: 0.86, alpha: 1.0).setFill()
        symbolRect.fill()
        context.restoreGState()
    }
} else {
    FileHandle.standardError.write("SF Symbol が見つかりませんでした: \(symbolName)\n".data(using: .utf8)!)
    exit(1)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("PNG生成に失敗しました\n".data(using: .utf8)!)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
