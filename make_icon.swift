import AppKit

// 公式アイコン画像(~/karukan/icon.png 等)を読み込み、指定サイズの正方形PNGとして書き出す。
// Usage: swift make_icon.swift <input> <output> <size> [cornerRadiusRatio]

let args = CommandLine.arguments
guard args.count >= 4, let size = Double(args[3]).map({ CGFloat($0) }) else {
    FileHandle.standardError.write("Usage: make_icon.swift <input> <output> <size> [cornerRadiusRatio]\n".data(using: .utf8)!)
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let cornerRadiusRatio: CGFloat = args.count >= 5 ? CGFloat(Double(args[4]) ?? 0) : 0

guard let sourceImage = NSImage(contentsOfFile: inputPath) else {
    FileHandle.standardError.write("入力画像の読み込みに失敗しました: \(inputPath)\n".data(using: .utf8)!)
    exit(1)
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
if cornerRadiusRatio > 0 {
    let cornerRadius = size * cornerRadiusRatio
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
}
sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

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
