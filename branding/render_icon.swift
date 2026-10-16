import AppKit
import SwiftUI
import ImageIO

// Renders the SyncHz app icon and the README / site artwork.
//
// The mark is a sample-rate readout — "96 kHz", the number the app exists to
// get right — on a sumi squircle, with two faded sine waves running behind it
// in lockstep: the source and the output at the same frequency (同频).
//
// Writes:
//   AppIcon.icon/Assets/readout.png, waves.png   Icon Composer layers
//   branding/icon_1024.png                       masked squircle + shadow (README)
//   branding/banner-light.png, banner-dark.png   README header (icon + wordmark)
//   docs/icon.png, favicon.png, apple-touch-icon.png
//   docs/social.png                              1280×640 link preview (Open Graph,
//                                                GitHub social preview); needs
//                                                docs/screenshots/panel-dark.png
// Run from the repo root: swift branding/render_icon.swift

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824 pt body on a 1024 pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sumiTop = srgb(0x2C2B2E)
let sumiBottom = srgb(0x151416)
let paper = srgb(0xF2EEE4)
let rikyu = srgb(0xB6C07A)          // the app's dark-mode 利休 accent
let rikyuDeep = srgb(0x646C36)      // light-mode accent
let ink = srgb(0x18181A)
let inkSoft = srgb(0x18181A, 0.58)
let paperSoft = srgb(0xF2EEE4, 0.62)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ width: CGFloat, _ height: CGFloat) -> CGContext {
    CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// MARK: - Mark parts (drawn in a 1024 canvas, CoreGraphics y-up)

/// The two waves behind the readout, in phase: paper above, 利休 below.
func drawWaves(_ ctx: CGContext, alpha: CGFloat) {
    func wave(midY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x0: CGFloat = 60, x1: CGFloat = 964, amp: CGFloat = 120
        for i in 0...480 {
            let t = Double(i) / 480
            let point = CGPoint(x: x0 + (x1 - x0) * CGFloat(t),
                                y: midY + amp * CGFloat(sin(t * 2 * .pi * 1.25 + 0.4)))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
    for (midY, color, strength) in [(CGFloat(600), paper, CGFloat(1)), (420, rikyu, 1.4)] {
        // Stroke opaque inside a transparency layer, then fade the layer, so
        // the round joins never double up into darker dots.
        ctx.saveGState()
        ctx.setAlpha(min(alpha * strength, 1))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(wave(midY: midY))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(30)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

@discardableResult
func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight,
              color: CGColor, x: CGFloat, baseline: CGFloat, anchor: CGFloat = 0.5,
              tracking: CGFloat = 0, font: NSFont? = nil) -> CGRect {
    let font = font ?? NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = CGPoint(x: x - bounds.width * anchor - bounds.minX, y: baseline)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    return CGRect(x: origin.x + bounds.minX, y: origin.y + bounds.minY,
                  width: bounds.width, height: bounds.height)
}

/// "96" over "kHz", centred on the tile.
func drawReadout(_ ctx: CGContext) {
    drawText(ctx, "96", size: 440, weight: .semibold, color: paper, x: 512, baseline: 428, tracking: -16)
    drawText(ctx, "kHz", size: 118, weight: .medium, color: rikyu, x: 512, baseline: 262, tracking: 2)
}

func drawTileBody(_ ctx: CGContext) {
    let path = squircle(tile, radius: tileRadius)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [sumiTop, sumiBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    drawWaves(ctx, alpha: 0.10)
    ctx.restoreGState()
    drawReadout(ctx)
    // Hairline rim so the tile holds its edge on dark backgrounds.
    ctx.addPath(path)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.07))
    ctx.strokePath()
}

/// The finished icon as macOS draws it: squircle body with a soft drop shadow.
func renderIcon() -> CGImage {
    let ctx = makeContext(canvas, canvas)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000, 0.32))
    ctx.addPath(squircle(tile, radius: tileRadius))
    ctx.setFillColor(sumiBottom)
    ctx.fillPath()
    ctx.restoreGState()
    drawTileBody(ctx)
    return ctx.makeImage()!
}

/// Full-bleed square (no mask, no shadow) for apple-touch-icon.
func renderFullBleed() -> CGImage {
    let ctx = makeContext(canvas, canvas)
    let gradient = CGGradient(colorsSpace: space, colors: [sumiTop, sumiBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: .zero, options: [])
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.18, y: 1.18)
    ctx.translateBy(x: -512, y: -512)
    drawWaves(ctx, alpha: 0.10)
    drawReadout(ctx)
    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to side: CGFloat) -> CGImage {
    let ctx = makeContext(side, side)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
}

// MARK: - README banner: icon, wordmark, "for Apple Music on Mac"

func renderBanner(dark: Bool, icon: CGImage) -> CGImage {
    let width: CGFloat = 1840, height: CGFloat = 720
    let ctx = makeContext(width, height)
    ctx.draw(icon, in: CGRect(x: 40, y: 0, width: 720, height: 720))
    let textX: CGFloat = 790
    let wordmark = drawText(ctx, "SyncHz", size: 236, weight: .bold, color: dark ? paper : ink,
                            x: textX, baseline: 352, anchor: 0, tracking: -6)
    drawText(ctx, "同频", size: 92, weight: .medium, color: dark ? rikyu : rikyuDeep,
             x: wordmark.maxX + 36, baseline: 352, anchor: 0, tracking: 6,
             font: NSFont(name: "PingFangSC-Medium", size: 92))
    drawText(ctx, "for Apple Music on Mac", size: 92, weight: .medium, color: dark ? paperSoft : inkSoft,
             x: textX + 6, baseline: 214, anchor: 0, tracking: -1)
    return ctx.makeImage()!
}

// MARK: - Link preview: icon, wordmark and the panel

func renderSocial(icon: CGImage, screenshot: CGImage) -> CGImage {
    let width: CGFloat = 1280, height: CGFloat = 640
    let ctx = makeContext(width, height)
    let background = CGGradient(colorsSpace: space, colors: [srgb(0x232225), srgb(0x111012)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: .zero, options: [])

    // The panel, at the right, in a rounded window frame.
    let shotHeight: CGFloat = 548
    let shotWidth = shotHeight * CGFloat(screenshot.width) / CGFloat(screenshot.height)
    let shot = CGRect(x: width - shotWidth - 72, y: (height - shotHeight) / 2, width: shotWidth, height: shotHeight)
    let frame = squircle(shot, radius: 22)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: srgb(0x000000, 0.55))
    ctx.addPath(frame)
    ctx.setFillColor(srgb(0x18181A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(frame)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screenshot, in: shot)
    ctx.restoreGState()
    ctx.addPath(frame)
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.12))
    ctx.strokePath()

    let left: CGFloat = 76
    ctx.draw(icon, in: CGRect(x: left - 26, y: 372, width: 212, height: 212))
    let wordmark = drawText(ctx, "SyncHz", size: 112, weight: .bold, color: paper,
                            x: left, baseline: 262, anchor: 0, tracking: -3)
    drawText(ctx, "同频", size: 44, weight: .medium, color: rikyu, x: wordmark.maxX + 20, baseline: 262,
             anchor: 0, tracking: 3, font: NSFont(name: "PingFangSC-Medium", size: 44))
    drawText(ctx, "for Apple Music on Mac", size: 44, weight: .medium, color: paperSoft,
             x: left + 2, baseline: 196, anchor: 0)
    drawText(ctx, "Automatic sample-rate switching", size: 28, weight: .regular,
             color: srgb(0xF2EEE4, 0.48), x: left + 2, baseline: 118, anchor: 0)
    drawText(ctx, "and AutoEq / PEQdB headphone EQ", size: 28, weight: .regular,
             color: srgb(0xF2EEE4, 0.48), x: left + 2, baseline: 80, anchor: 0)
    return ctx.makeImage()!
}

// MARK: - Icon Composer layers

func renderLayer(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(canvas, canvas)
    draw(ctx)
    return ctx.makeImage()!
}

let icon = renderIcon()
save(icon, to: "branding/icon_1024.png")
save(renderBanner(dark: false, icon: icon), to: "branding/banner-light.png")
save(renderBanner(dark: true, icon: icon), to: "branding/banner-dark.png")

// The system masks and lights the layers itself; fill = the sumi gradient in icon.json.
save(renderLayer { ctx in
    ctx.saveGState()
    ctx.addPath(CGPath(rect: CGRect(x: 0, y: 0, width: canvas, height: canvas), transform: nil))
    ctx.clip()
    drawWaves(ctx, alpha: 0.10)
    ctx.restoreGState()
}, to: "AppIcon.icon/Assets/waves.png")
save(renderLayer(drawReadout), to: "AppIcon.icon/Assets/readout.png")

save(scaled(icon, to: 512), to: "docs/icon.png")
save(scaled(icon, to: 64), to: "docs/favicon.png")
save(scaled(renderFullBleed(), to: 180), to: "docs/apple-touch-icon.png")

if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "docs/screenshots/panel-dark.png") as CFURL, nil),
   let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    save(renderSocial(icon: icon, screenshot: screenshot), to: "docs/social.png")
}
