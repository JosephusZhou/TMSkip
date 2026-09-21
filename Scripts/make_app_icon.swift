// 生成 TMSkip App 图标（1024×1024 PNG，含 macOS 圆角矩形与投影）
// 用法: swift Scripts/make_app_icon.swift <输出路径.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgbSpace, components: [r, g, b, a])!
}

let ctx = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: srgbSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// MARK: - 背景: macOS 圆角方块 + 白底（浅色主题）
let sq = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: sq, cornerWidth: 185, cornerHeight: 185, transform: nil)
let brandBlue = srgb(0.12, 0.42, 0.9) // 前景主色（加深版品牌蓝），与应用强调色同相

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0.04, 0.04, 0.2, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(srgb(1, 1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// 极淡描边，避免白底图标在浅色背景中边缘不清
ctx.addPath(squircle)
ctx.setStrokeColor(srgb(0, 0, 0, 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

// MARK: - 时钟（Time Machine 意象）— 居于圆角方块几何中心
let c = CGPoint(x: 512, y: 512)
let ringR: CGFloat = 290
ctx.setStrokeColor(brandBlue)
ctx.setLineWidth(62)
ctx.setLineCap(.round)
ctx.strokeEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))

func drawHand(angleDeg: CGFloat, length: CGFloat) {
    // 角度以 12 点方向为 0°、顺时针为正（CG 坐标系 y 向上）
    let a = angleDeg * .pi / 180
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + sin(a) * length, y: c.y + cos(a) * length))
    ctx.strokePath()
}
ctx.setLineWidth(46)
drawHand(angleDeg: 272.5, length: 140) // 时针指 9 点过 5 分
drawHand(angleDeg: 30, length: 205)    // 分针指 5 分
ctx.setFillColor(brandBlue)
ctx.fillEllipse(in: CGRect(x: c.x - 42, y: c.y - 42, width: 84, height: 84))

// MARK: - 右下角「跳过」徽章: 蓝底 + 白色双箭头（»）
// 徽章中心挂在钟圈右下 45° 方向上，随钟圈同心移动
let badgeCenter = CGPoint(
    x: c.x + (ringR + 0) * CGFloat(cos(Double.pi / 4)),
    y: c.y - (ringR + 0) * CGFloat(sin(Double.pi / 4))
)
let badgeRect = CGRect(x: badgeCenter.x - 126, y: badgeCenter.y - 94, width: 252, height: 188)
let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 58, cornerHeight: 58, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: srgb(0, 0, 0.1, 0.3))
ctx.addPath(badgePath)
ctx.setFillColor(brandBlue)
ctx.fillPath()
ctx.restoreGState()

// 白色描边隔开徽章与时钟圈（同色前景需要分离感）
ctx.addPath(badgePath)
ctx.setStrokeColor(srgb(1, 1, 1))
ctx.setLineWidth(24)
ctx.strokePath()
ctx.addPath(badgePath)
ctx.setFillColor(brandBlue)
ctx.fillPath()

let white = srgb(1, 1, 1)
let hh: CGFloat = 52, depth: CGFloat = 54, thick: CGFloat = 30, gap: CGFloat = 16
let chevronW = thick + depth
var x0 = badgeCenter.x - (chevronW * 2 + gap) / 2
for _ in 0..<2 {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: badgeCenter.y + hh))
    p.addLine(to: CGPoint(x: x0 + depth, y: badgeCenter.y))
    p.addLine(to: CGPoint(x: x0, y: badgeCenter.y - hh))
    p.addLine(to: CGPoint(x: x0 + thick, y: badgeCenter.y - hh))
    p.addLine(to: CGPoint(x: x0 + thick + depth, y: badgeCenter.y))
    p.addLine(to: CGPoint(x: x0 + thick, y: badgeCenter.y + hh))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(white)
    ctx.fillPath()
    x0 += chevronW + gap
}

// MARK: - 输出
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("failed to write \(out)\n".data(using: .utf8)!)
    exit(1)
}
print("written \(out)")
