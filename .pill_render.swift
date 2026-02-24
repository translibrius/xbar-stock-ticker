import Cocoa

// Args: text bg_hex fg_hex font_size pad_x pad_y
let args = CommandLine.arguments
guard args.count >= 4 else {
    fputs("Usage: pill_render <text> <bg_hex> <fg_hex> [font_size] [pad_x] [pad_y]\n", stderr)
    exit(1)
}

let text = args[1]
let bgHex = args[2]
let fgHex = args[3]
let fontSize: CGFloat = args.count > 4 ? CGFloat(Double(args[4]) ?? 11) : 11
let padX: CGFloat = args.count > 5 ? CGFloat(Double(args[5]) ?? 8) : 8
let padY: CGFloat = args.count > 6 ? CGFloat(Double(args[6]) ?? 3) : 3

func hexColor(_ hex: String) -> NSColor {
    var h = hex
    if h.hasPrefix("#") { h = String(h.dropFirst()) }
    let scanner = Scanner(string: h)
    var rgb: UInt64 = 0
    scanner.scanHexInt64(&rgb)
    return NSColor(
        red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
        green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
        blue: CGFloat(rgb & 0xFF) / 255.0,
        alpha: 1.0
    )
}

let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: hexColor(fgHex)
]
let attrStr = NSAttributedString(string: text, attributes: attrs)
let textSize = attrStr.size()

let w = ceil(textSize.width + padX * 2)
let h = ceil(textSize.height + padY * 2)
let radius = h / 2.0

let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                         xRadius: radius, yRadius: radius)
hexColor(bgHex).setFill()
path.fill()

attrStr.draw(at: NSPoint(x: padX, y: padY))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to render\n", stderr)
    exit(1)
}

// Output base64 to stdout
print(png.base64EncodedString())
