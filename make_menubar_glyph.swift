import AppKit

// メニューバー用: 背景なし、文字のみを正方形いっぱいに描画する。
// Usage: swift make_menubar_glyph.swift <output> <glyph> <size>

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "glyph.png"
let glyph = args.count > 2 ? args[2] : "あ"
let size: CGFloat = args.count > 3 ? (CGFloat(Double(args[3]) ?? 256)) : 256

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let fontSize = size * 0.92
let font = NSFont.boldSystemFont(ofSize: fontSize)
let attributed = NSAttributedString(string: glyph, attributes: [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 0.32, green: 0.33, blue: 0.86, alpha: 1.0),
])
let glyphSize = attributed.size()
let origin = NSPoint(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2)
attributed.draw(at: origin)

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
