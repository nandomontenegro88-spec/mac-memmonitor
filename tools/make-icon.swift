// Gera o ícone do MemMonitor (iconset). Uso: ./make-icon <pasta-de-saída.iconset>
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(size: Int, small: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let cs = CGColorSpaceCreateDeviceRGB()

    // corpo (squircle de 824 pt dentro de 1024, como pede o macOS)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // sombra
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(gray: 0, alpha: 0.38))
    cg.addPath(path); cg.setFillColor(rgb(0x0B1220)); cg.fillPath()
    cg.restoreGState()

    // fundo: ardósia escura + brilho verde atrás do anel
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A374F), rgb(0x0B1220)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x22C55E, 0.30), rgb(0x22C55E, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 10, endCenter: CGPoint(x: 512, y: 520), endRadius: 430, options: [])
    // luz que bate no topo do vidro
    let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    cg.restoreGState()

    // anel: pista + progresso (~78 %), do topo no sentido horário, verde → ciano
    let c = CGPoint(x: 512, y: 512), r: CGFloat = small ? 262 : 268, lw: CGFloat = small ? 96 : 74
    cg.setLineCap(.round)
    cg.setLineWidth(lw)
    cg.setStrokeColor(rgb(0xFFFFFF, 0.10))
    cg.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    let frac: CGFloat = 0.78
    let start: CGFloat = .pi / 2
    let end = start - 2 * .pi * frac
    // brilho
    cg.saveGState()
    if !small { cg.setShadow(offset: .zero, blur: 46, color: rgb(0x22C55E, 0.75)) }
    cg.setStrokeColor(rgb(0x22C55E))
    cg.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
    cg.strokePath()
    cg.restoreGState()
    // cor em degradê, em pequenos segmentos
    let n = 140
    for i in 0..<n {
        let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n)
        let a0 = start + (end - start) * t0, a1 = start + (end - start) * min(t1 + 0.004, 1)
        let g = (0x22C55E, 0x22D3EE)
        func mix(_ s: Int) -> CGFloat {
            let x = CGFloat((g.0 >> s) & 255), y = CGFloat((g.1 >> s) & 255)
            return (x + (y - x) * t0) / 255
        }
        cg.setStrokeColor(CGColor(red: mix(16), green: mix(8), blue: mix(0), alpha: 1))
        cg.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        cg.strokePath()
    }

    // chip no centro, em vetor (nítido em qualquer tamanho)
    cg.saveGState()
    if !small { cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.35)) }
    cg.setStrokeColor(rgb(0xFFFFFF)); cg.setLineWidth(small ? 36 : 26); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.addPath(CGPath(roundedRect: CGRect(x: 384, y: 430, width: 256, height: 164), cornerWidth: 38, cornerHeight: 38, transform: nil))
    cg.strokePath()
    let pins = small ? 3 : 5, gap: CGFloat = small ? 66 : 44
    for i in 0..<pins {
        let x = 512 + (CGFloat(i) - CGFloat(pins - 1) / 2) * gap
        cg.move(to: CGPoint(x: x, y: 594)); cg.addLine(to: CGPoint(x: x, y: 640))
        cg.move(to: CGPoint(x: x, y: 430)); cg.addLine(to: CGPoint(x: x, y: 384))
    }
    cg.strokePath()
    if !small { cg.setFillColor(rgb(0x1E293B)); cg.fillEllipse(in: CGRect(x: 500, y: 500, width: 24, height: 24)) }
    cg.restoreGState()

    // aro de luz na borda
    cg.addPath(path)
    cg.setLineWidth(3)
    cg.setStrokeColor(rgb(0xFFFFFF, 0.20))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let ss = px <= 64 ? 4 : 2                       // desenha maior e reduz depois (melhor suavização)
    let png = render(size: px * ss, small: px <= 64).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(out)/big_\(name)_\(px).png"))
}
print("ok")
