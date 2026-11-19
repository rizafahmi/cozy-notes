#!/usr/bin/env swift
import AppKit
import CoreGraphics

struct IconGenerator {
    static let sizes: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Deterministic lightweight PRNG so tactile paper/linen grain is 100% reproducible across builds.
    struct SeededRNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func unit() -> CGFloat {
            CGFloat((next() >> 33) & 0x7FFFFFFF) / CGFloat(0x7FFFFFFF)
        }
    }

    static func drawPaperGrain(in cg: CGContext, rect: CGRect, pixelSize: Int, intensity: CGFloat, seed: UInt64) {
        guard pixelSize >= 128 else { return }
        let texSize = min(512, pixelSize)
        var bytes = [UInt8](repeating: 0, count: texSize * texSize * 4)
        var rng = SeededRNG(state: seed)
        for i in 0..<(texSize * texSize) {
            let v = rng.unit()
            let bright = v > 0.5
            let mag = abs(v - 0.5) * 2.0
            let alpha = UInt8(min(255, max(0, Int(mag * intensity * 255.0))))
            let tone: UInt8 = bright ? 255 : 28
            let idx = i * 4
            bytes[idx] = tone
            bytes[idx + 1] = tone
            bytes[idx + 2] = tone
            bytes[idx + 3] = alpha
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: texSize,
                height: texSize,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: texSize * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return }
        cg.saveGState()
        cg.interpolationQuality = .high
        cg.draw(cgImage, in: rect)
        cg.restoreGState()
    }

    static func drawLinenWeave(in cg: CGContext, rect: CGRect, s: CGFloat, pixelSize: Int) {
        guard pixelSize >= 128 else { return }
        cg.saveGState()
        cg.clip(to: rect)
        let step = max(2.0, 5.0 * s)
        cg.setLineWidth(max(0.75, 1.2 * s))

        // Fine vertical warp threads
        cg.setStrokeColor(color(1.0, 1.0, 1.0, 0.030).cgColor)
        var x = rect.minX
        while x <= rect.maxX {
            cg.move(to: CGPoint(x: x, y: rect.minY))
            cg.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        cg.strokePath()

        // Fine horizontal weft threads
        cg.setStrokeColor(color(0.0, 0.0, 0.0, 0.085).cgColor)
        var y = rect.minY
        while y <= rect.maxY {
            cg.move(to: CGPoint(x: rect.minX, y: y))
            cg.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        cg.strokePath()
        cg.restoreGState()
    }

    static func render(px: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: px * 4,
            bitsPerPixel: 32
        )!
        rep.size = NSSize(width: px, height: px)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        cg.interpolationQuality = .high

        let s = CGFloat(px) / 1024.0
        let isTiny = px <= 24       // 16px
        let isSmall = px <= 48      // 32px

        // Palette tokens anchored to Cozy Notes's Neo-Acid & Plaster theme (Theme.swift)
        let obsidianDeep = color(0.071, 0.082, 0.098)      // #121519 Theme.canvas neoAcidDark
        let obsidianMid  = color(0.114, 0.129, 0.153)      // #1D2127
        let obsidianTop  = color(0.180, 0.198, 0.228)      // #2E323A subtle lit cloth edge
        let plasterTop   = color(0.969, 0.969, 0.957)      // #F7F7F4 Theme.paper neoAcidLight
        let plasterMid   = color(0.935, 0.935, 0.914)      // #EEEEEA
        let plasterBot   = color(0.884, 0.884, 0.858)      // #E1E1DB
        let acidBright   = color(0.850, 1.000, 0.340)      // #D9FF57 ribbon top catch-light
        let acidMain     = color(0.773, 0.973, 0.165)      // #C5F82A Theme.accent neoAcidDark
        let acidDeep     = color(0.675, 0.900, 0.075)      // #ACE613 lower depth

        // 1. Apple macOS Icon Grid Squircle (824x824 centered at 100..924, r=185)
        // Uses Apple's standard rounded-rect corner geometry so macOS 26/27 IconServices
        // treats the icon as a native full-bleed squircle instead of shrinking it inside a gray box.
        let inset: CGFloat = isTiny ? 64.0 * s : 100.0 * s
        let boardSize: CGFloat = CGFloat(px) - inset * 2.0
        let boardRect = NSRect(x: inset, y: inset, width: boardSize, height: boardSize)
        let boardRadius: CGFloat = isTiny ? 150.0 * s : 185.0 * s
        let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: boardRadius, yRadius: boardRadius)

        // Subtle outer drop shadow under the hardcover board (skipped at 16px for crisp edges)
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let outerShadow = NSShadow()
            outerShadow.shadowColor = color(0.02, 0.03, 0.05, 0.40)
            outerShadow.shadowOffset = NSSize(width: 0, height: -14 * s)
            outerShadow.shadowBlurRadius = 26 * s
            outerShadow.set()
            obsidianDeep.setFill()
            boardPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 2. Hardcover Obsidian Outer Binding Board (also forms the crisp protective rim around plaster)
        NSGraphicsContext.saveGraphicsState()
        boardPath.addClip()

        let spineGrad = NSGradient(colors: [
            obsidianTop,
            obsidianMid,
            obsidianDeep
        ], atLocations: [0.0, 0.42, 1.0], colorSpace: .sRGB)!
        spineGrad.draw(in: boardRect, angle: -82)

        // Left cloth spine subtle cylindrical highlight along far left edge
        let spineRatio: CGFloat = isTiny ? 0.27 : (isSmall ? 0.25 : 0.235)
        let spineRightX = boardRect.minX + boardRect.width * spineRatio
        let spineRect = NSRect(x: boardRect.minX, y: boardRect.minY, width: spineRightX - boardRect.minX, height: boardRect.height)

        let spineRollGrad = NSGradient(colors: [
            color(1.0, 1.0, 1.0, 0.11),
            color(1.0, 1.0, 1.0, 0.02),
            color(0.0, 0.0, 0.0, 0.16)
        ], atLocations: [0.0, 0.45, 1.0], colorSpace: .sRGB)!
        spineRollGrad.draw(in: spineRect, angle: 0)

        drawLinenWeave(in: cg, rect: spineRect, s: s, pixelSize: px)

        // Subtle debossed bookbinding hinge groove on the spine edge
        if !isTiny {
            let grooveW = max(1.5, 9.0 * s)
            let grooveX = spineRightX - grooveW - 14.0 * s
            let grooveRect = NSRect(x: grooveX, y: boardRect.minY + 34 * s, width: grooveW, height: boardRect.height - 68 * s)
            let groovePath = NSBezierPath(roundedRect: grooveRect, xRadius: grooveW * 0.5, yRadius: grooveW * 0.5)
            color(0.0, 0.0, 0.0, 0.48).setFill()
            groovePath.fill()
            color(1.0, 1.0, 1.0, 0.10).setFill()
            NSRect(x: grooveRect.maxX, y: grooveRect.minY + 6 * s, width: max(1.0, 2.5 * s), height: grooveRect.height - 12 * s).fill()
        }

        // 3. Raw Architectural Plaster Cover (inset cleanly inside top/right/bottom obsidian binding rim)
        let rimWidth: CGFloat = isTiny ? max(1.0, 20.0 * s) : (isSmall ? max(1.5, 16.0 * s) : 13.0 * s)
        let coverBoardRect = boardRect.insetBy(dx: rimWidth, dy: rimWidth)
        let coverRadius = max(8.0 * s, boardRadius - rimWidth)
        let coverBoardPath = NSBezierPath(roundedRect: coverBoardRect, xRadius: coverRadius, yRadius: coverRadius)

        let coverClipRect = NSRect(
            x: spineRightX,
            y: coverBoardRect.minY,
            width: coverBoardRect.maxX - spineRightX,
            height: coverBoardRect.height
        )

        NSGraphicsContext.saveGraphicsState()
        coverBoardPath.addClip()
        NSBezierPath(rect: coverClipRect).addClip()

        // Architectural plaster studio lighting gradient
        let plasterGrad = NSGradient(colors: [
            plasterTop,
            plasterMid,
            plasterBot
        ], atLocations: [0.0, 0.58, 1.0], colorSpace: .sRGB)!
        plasterGrad.draw(in: coverClipRect, angle: -96)

        // Soft warm studio bounce light from upper-left onto the plaster surface
        if !isTiny {
            let glow = NSGradient(
                starting: color(1.0, 1.0, 1.0, 0.45),
                ending: color(1.0, 1.0, 1.0, 0.0)
            )!
            glow.draw(
                fromCenter: NSPoint(x: coverClipRect.minX + coverClipRect.width * 0.28, y: coverClipRect.maxY - coverClipRect.height * 0.20),
                radius: 0,
                toCenter: NSPoint(x: coverClipRect.midX, y: coverClipRect.midY),
                radius: coverClipRect.width * 0.90,
                options: [.drawsBeforeStartingLocation]
            )
        }

        // Fine tactile cotton-plaster paper grain
        drawPaperGrain(in: cg, rect: coverClipRect, pixelSize: px, intensity: 0.032, seed: 0xC027_AC1D)

        // Crisp seam shadow where the obsidian spine meets the plaster cover
        let seamGrad = NSGradient(colors: [
            color(0.05, 0.06, 0.08, 0.22),
            color(0.05, 0.06, 0.08, 0.0)
        ])!
        seamGrad.draw(in: NSRect(x: spineRightX, y: coverClipRect.minY, width: max(2.0, 18.0 * s), height: coverClipRect.height), angle: 0)

        // Subtle inner top catch-light along the plaster cover edge
        color(1.0, 1.0, 1.0, 0.72).setFill()
        NSRect(x: spineRightX + max(1.0, 2.0 * s), y: coverClipRect.maxY - max(1.0, 3.0 * s), width: coverClipRect.width - 140 * s, height: max(1.0, 3.0 * s)).fill()

        // 4. Debossed Pocket Slit & Tucked Obsidian Index Slip with Neo-Acid Folded Corner
        let coverCenterX = (spineRightX + coverBoardRect.maxX) * 0.5
        let slipW: CGFloat = isTiny ? coverClipRect.width * 0.68 : (isSmall ? coverClipRect.width * 0.64 : coverClipRect.width * 0.57)
        let slipH: CGFloat = isTiny ? boardRect.height * 0.23 : (isSmall ? boardRect.height * 0.21 : boardRect.height * 0.195)
        let slitY: CGFloat = boardRect.minY + (isTiny ? boardRect.height * 0.22 : boardRect.height * 0.245)
        let slitH: CGFloat = isTiny ? max(1.5, 20.0 * s) : (isSmall ? max(2.0, 18.0 * s) : 14.0 * s)
        let slitPadX: CGFloat = isTiny ? 16.0 * s : 28.0 * s
        let slitRect = NSRect(
            x: coverCenterX - slipW * 0.5 - slitPadX,
            y: slitY - slitH * 0.5,
            width: slipW + slitPadX * 2.0,
            height: slitH
        )

        // Organic elliptical pillowed shadow directly beneath the pocket mouth (zero hard vertical edges)
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let pocketMouthClip = NSRect(x: coverClipRect.minX, y: coverClipRect.minY, width: coverClipRect.width, height: slitY - coverClipRect.minY)
            NSBezierPath(rect: pocketMouthClip).addClip()
            cg.saveGState()
            cg.translateBy(x: coverCenterX, y: slitY - 4 * s)
            cg.scaleBy(x: (slitRect.width * 0.56) / (68 * s), y: 1.0)
            let bulgeColors = [color(0.10, 0.12, 0.14, 0.11).cgColor, color(0.10, 0.12, 0.14, 0.0).cgColor] as CFArray
            if let radial = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: bulgeColors, locations: [0.0, 1.0]) {
                cg.drawRadialGradient(
                    radial,
                    startCenter: .zero,
                    startRadius: 0,
                    endCenter: .zero,
                    endRadius: 68 * s,
                    options: []
                )
            }
            cg.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Recessed pocket slot
        let slitPath = NSBezierPath(roundedRect: slitRect, xRadius: slitH * 0.5, yRadius: slitH * 0.5)
        color(0.75, 0.75, 0.72, 0.96).setFill()
        slitPath.fill()
        if !isTiny {
            // Inner upper shadow inside slit
            NSGraphicsContext.saveGraphicsState()
            slitPath.addClip()
            color(0.10, 0.12, 0.14, 0.36).setFill()
            NSRect(x: slitRect.minX, y: slitRect.midY, width: slitRect.width, height: slitRect.height * 0.6).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Crisp bottom lip highlight below pocket slit
            color(1.0, 1.0, 1.0, 0.85).setFill()
            NSRect(x: slitRect.minX + slitH * 0.4, y: slitRect.minY - max(1.0, 2.5 * s), width: slitRect.width - slitH * 0.8, height: max(1.0, 2.5 * s)).fill()
        }

        // Tucked Obsidian Slip rising out of the pocket slit (clipped cleanly at slit midline)
        let slipRect = NSRect(x: coverCenterX - slipW * 0.5, y: slitY, width: slipW, height: slipH)
        let slipR: CGFloat = 24.0 * s
        let foldSize: CGFloat = isTiny ? slipH * 0.58 : (isSmall ? slipH * 0.54 : slipH * 0.53)

        func makeSlipBodyPath() -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: slipRect.minX, y: slipRect.minY))
            p.line(to: NSPoint(x: slipRect.minX, y: slipRect.maxY - slipR))
            p.appendArc(
                withCenter: NSPoint(x: slipRect.minX + slipR, y: slipRect.maxY - slipR),
                radius: slipR,
                startAngle: 180,
                endAngle: 90,
                clockwise: true
            )
            p.line(to: NSPoint(x: slipRect.maxX - foldSize, y: slipRect.maxY))
            p.line(to: NSPoint(x: slipRect.maxX, y: slipRect.maxY - foldSize))
            p.line(to: NSPoint(x: slipRect.maxX, y: slipRect.minY))
            p.close()
            return p
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: coverClipRect.minX, y: slitY, width: coverClipRect.width, height: coverClipRect.maxY - slitY)).addClip()

        let slipBodyPath = makeSlipBodyPath()

        // Slip soft ambient shadow onto plaster cover
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let slipShadow = NSShadow()
            slipShadow.shadowColor = color(0.05, 0.06, 0.08, 0.22)
            slipShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
            slipShadow.shadowBlurRadius = 16 * s
            slipShadow.set()
            obsidianMid.setFill()
            slipBodyPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Fill obsidian slip with subtle top-to-bottom matte gradient
        NSGraphicsContext.saveGraphicsState()
        slipBodyPath.addClip()
        let slipGrad = NSGradient(colors: [
            color(0.175, 0.190, 0.215),
            color(0.105, 0.118, 0.138),
            color(0.075, 0.085, 0.100)
        ], atLocations: [0.0, 0.62, 1.0], colorSpace: .sRGB)!
        slipGrad.draw(in: slipRect, angle: -90)

        // Subtle inner darkening at pocket mouth where the slip enters the slot
        if !isTiny {
            let mouthShadow = NSGradient(colors: [
                color(0.0, 0.0, 0.0, 0.40),
                color(0.0, 0.0, 0.0, 0.0)
            ])!
            mouthShadow.draw(in: NSRect(x: slipRect.minX, y: slipRect.minY, width: slipRect.width, height: 20 * s), angle: 90)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Folded Neo-Acid Lime Dog-Ear Corner Flap on top-right of slip
        let flapR: CGFloat = isTiny ? 10.0 * s : 16.0 * s
        let fx0 = slipRect.maxX - foldSize
        let fy0 = slipRect.maxY - foldSize
        let flapPath = NSBezierPath()
        flapPath.move(to: NSPoint(x: fx0, y: slipRect.maxY))
        flapPath.line(to: NSPoint(x: fx0, y: fy0 + flapR))
        flapPath.appendArc(
            withCenter: NSPoint(x: fx0 + flapR, y: fy0 + flapR),
            radius: flapR,
            startAngle: 180,
            endAngle: 270,
            clockwise: false
        )
        flapPath.line(to: NSPoint(x: slipRect.maxX, y: fy0))
        flapPath.close()

        // Crisp fold shadow cast by the acid flap onto the obsidian slip
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            slipBodyPath.addClip()
            let flapShadow = NSShadow()
            flapShadow.shadowColor = color(0.0, 0.0, 0.0, 0.55)
            flapShadow.shadowOffset = NSSize(width: -5 * s, height: -6 * s)
            flapShadow.shadowBlurRadius = 11 * s
            flapShadow.set()
            acidMain.setFill()
            flapPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.saveGraphicsState()
        flapPath.addClip()
        let flapGrad = NSGradient(colors: [
            acidBright,
            acidMain,
            acidDeep
        ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
        flapGrad.draw(in: NSRect(x: fx0, y: fy0, width: foldSize, height: foldSize), angle: -135)

        // Crisp specular crease highlight along the diagonal paper fold
        if !isTiny {
            let crease = NSBezierPath()
            crease.move(to: NSPoint(x: fx0, y: slipRect.maxY))
            crease.line(to: NSPoint(x: slipRect.maxX, y: fy0))
            color(1.0, 1.0, 1.0, 0.45).setStroke()
            crease.lineWidth = max(1.0, 3.0 * s)
            crease.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState() // end slip above-slit clip

        NSGraphicsContext.restoreGraphicsState() // end plaster cover clip

        // 5. Sculptural Neo-Acid Bookmark Ribbon flush with the top-right edge of the book
        // Kept strictly inside boardPath (824x824) so macOS Tahoe/Liquid Glass IconServices
        // recognizes the native squircle silhouette instead of shrinking it inside a gray box.
        let ribW: CGFloat = isTiny ? 154.0 * s : (isSmall ? 142.0 * s : 126.0 * s)
        let ribH: CGFloat = isTiny ? 316.0 * s : (isSmall ? 304.0 * s : 292.0 * s)
        let ribRightMargin: CGFloat = isTiny ? 132.0 * s : (isSmall ? 146.0 * s : 162.0 * s)
        let ribX: CGFloat = boardRect.maxX - ribRightMargin - ribW
        let ribTopY: CGFloat = boardRect.maxY
        let ribBotY: CGFloat = ribTopY - ribH
        let notchDepth: CGFloat = isTiny ? 56.0 * s : 48.0 * s

        let ribbonPath = NSBezierPath()
        ribbonPath.move(to: NSPoint(x: ribX, y: ribBotY))
        ribbonPath.line(to: NSPoint(x: ribX, y: ribTopY))
        ribbonPath.line(to: NSPoint(x: ribX + ribW, y: ribTopY))
        ribbonPath.line(to: NSPoint(x: ribX + ribW, y: ribBotY))
        ribbonPath.line(to: NSPoint(x: ribX + ribW * 0.5, y: ribBotY + notchDepth))
        ribbonPath.close()

        // Cast realistic ribbon shadow onto the book cover
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let ribShadow = NSShadow()
            ribShadow.shadowColor = color(0.05, 0.07, 0.04, 0.28)
            ribShadow.shadowOffset = NSSize(width: 4 * s, height: -16 * s)
            ribShadow.shadowBlurRadius = 24 * s
            ribShadow.set()
            acidMain.setFill()
            ribbonPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Fill Neo-Acid ribbon with woven top-wrap highlight and rich chartreuse gradient
        NSGraphicsContext.saveGraphicsState()
        ribbonPath.addClip()

        let ribRect = NSRect(x: ribX, y: ribBotY, width: ribW, height: ribH)
        let ribGrad = NSGradient(colors: [
            acidBright,
            acidMain,
            acidMain,
            acidDeep
        ], atLocations: [0.0, 0.16, 0.72, 1.0], colorSpace: .sRGB)!
        ribGrad.draw(in: ribRect, angle: -90)

        // Subtle rounded top-fold specular sheen where the ribbon wraps over the book's top edge
        if !isTiny {
            let foldSheen = NSGradient(colors: [
                color(1.0, 1.0, 1.0, 0.44),
                color(1.0, 1.0, 1.0, 0.0)
            ])!
            foldSheen.draw(in: NSRect(x: ribX, y: ribTopY - 36 * s, width: ribW, height: 36 * s), angle: -90)

            // Soft edge shading for tactile grosgrain thickness
            color(0.56, 0.78, 0.05, 0.24).setFill()
            NSRect(x: ribX, y: ribBotY, width: max(1.0, 3.0 * s), height: ribH).fill()
            NSRect(x: ribX + ribW - max(1.0, 3.0 * s), y: ribBotY, width: max(1.0, 3.0 * s), height: ribH).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        // Delicate luminous chartreuse border so the ribbon reads crisply against pale plaster
        color(0.54, 0.76, 0.04, isTiny ? 0.45 : 0.26).setStroke()
        ribbonPath.lineWidth = max(0.8, 2.0 * s)
        ribbonPath.stroke()

        // Subtle inner rim catch-light along the top edge of the outer obsidian board
        if !isTiny {
            color(1.0, 1.0, 1.0, 0.18).setStroke()
            let innerRimPath = NSBezierPath(roundedRect: boardRect.insetBy(dx: 2.0 * s, dy: 2.0 * s), xRadius: boardRadius, yRadius: boardRadius)
            innerRimPath.lineWidth = max(1.0, 3.0 * s)
            innerRimPath.stroke()
        }

        NSGraphicsContext.restoreGraphicsState() // end outer board clip

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try data.write(to: url, options: .atomic)
    }
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = repoRoot.appendingPathComponent("packaging/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for entry in IconGenerator.sizes {
    let rep = IconGenerator.render(px: entry.px)
    let outURL = iconsetDir.appendingPathComponent(entry.name)
    try IconGenerator.writePNG(rep, to: outURL)
}

let icnsURL = repoRoot.appendingPathComponent("packaging/AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetDir.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
print("Generated \(iconsetDir.path) and \(icnsURL.path)")
