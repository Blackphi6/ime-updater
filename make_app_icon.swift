import AppKit

// 1024x1024 のマスターアイコンを生成する。
// 背景: 青紫グラデーションの角丸四角、前景: SF Symbol(白)。
// Usage: swift make_app_icon.swift <output> <sfSymbolName> <pointSizeRatio>

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "icon_master.png"
let symbolName = args.count > 2 ? args[2] : "square.stack.3d.up.fill"
let pointSizeRatio = args.count > 3 ? (Double(args[3]) ?? 0.52) : 0.52

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius = size * 0.22
let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.96, alpha: 1.0),
    NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.86, alpha: 1.0),
])
gradient?.draw(in: bgPath, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: size * pointSizeRatio, weight: .bold)
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
        NSColor.white.setFill()
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
