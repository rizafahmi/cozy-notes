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
        let isMedium = px <= 96     // 64px

        // 1. Apple macOS Icon Grid Squircle (824x824 centered at 100..924, r=185)
        let deskInset: CGFloat = isTiny ? 64.0 * s : 100.0 * s
        let deskSize: CGFloat = CGFloat(px) - deskInset * 2.0
        let deskRect = NSRect(x: deskInset, y: deskInset, width: deskSize, height: deskSize)
        let deskRadius: CGFloat = isTiny ? 150.0 * s : 185.0 * s
        let deskPath = NSBezierPath(roundedRect: deskRect, xRadius: deskRadius, yRadius: deskRadius)

        // Subtle drop shadow under the squircle for depth (skipped at 16px so edges stay crisp)
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let outerShadow = NSShadow()
            outerShadow.shadowColor = color(0.02, 0.03, 0.05, 0.38)
            outerShadow.shadowOffset = NSSize(width: 0, height: -10 * s)
            outerShadow.shadowBlurRadius = 24 * s
            outerShadow.set()
            color(0.075, 0.078, 0.090).setFill()
            deskPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Clip inside desk squircle
        NSGraphicsContext.saveGraphicsState()
        deskPath.addClip()

        // Desk gradient: Obsidian (#131417 -> #1B1D22) blended with Midnight Ink undertone (#0E1218)
        let deskGradient = NSGradient(colors: [
            color(0.118, 0.128, 0.156), // top: elevated obsidian-midnight slate
            color(0.075, 0.078, 0.090), // middle: Theme.canvas studyDark (#131417)
            color(0.055, 0.070, 0.098)  // bottom: Theme.canvas botanicalDark (#0E1218)
        ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
        deskGradient.draw(in: deskRect, angle: -90)

        // Subtle radial ambient glow behind folio
        if !isTiny {
            let glowColor = color(0.245, 0.420, 0.825, 0.10)
            let glowGrad = NSGradient(starting: glowColor, ending: color(0.075, 0.078, 0.090, 0.0))!
            glowGrad.draw(
                fromCenter: NSPoint(x: 512 * s, y: 540 * s),
                radius: 20 * s,
                toCenter: NSPoint(x: 512 * s, y: 512 * s),
                radius: 420 * s,
                options: []
            )
        }

        // 2. Recessed Index Slip behind the main folio (links to the Commonplace Index / dump-first stack)
        if !isTiny {
            NSGraphicsContext.saveGraphicsState()
            let backX = 250 * s
            let backY = 238 * s
            let backW = 500 * s
            let backH = 590 * s
            let backRect = NSRect(x: backX, y: backY, width: backW, height: backH)
            var transform = AffineTransform()
            transform.translate(x: 512 * s, y: 512 * s)
            transform.rotate(byDegrees: -4.2)
            transform.translate(x: -512 * s, y: -512 * s)
            (transform as NSAffineTransform).concat()

            let backPath = NSBezierPath(roundedRect: backRect, xRadius: 56 * s, yRadius: 56 * s)
            color(0.928, 0.938, 0.955, 0.22).setFill() // Porcelain translucent slip
            backPath.fill()
            color(0.835, 0.855, 0.890, 0.28).setStroke()
            backPath.lineWidth = max(1.0, 4.0 * s)
            backPath.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. Main Inset Ivory Folio Sheet (Theme.paper studyLight #FAF9F6)
        let folioX: CGFloat = isTiny ? 210 * s : 244 * s
        let folioY: CGFloat = isTiny ? 175 * s : 196 * s
        let folioW: CGFloat = isTiny ? 604 * s : 536 * s
        let folioH: CGFloat = isTiny ? 674 * s : 632 * s
        let folioRect = NSRect(x: folioX, y: folioY, width: folioW, height: folioH)
        let folioRadius: CGFloat = isTiny ? 96 * s : 72 * s
        let folioPath = NSBezierPath(roundedRect: folioRect, xRadius: folioRadius, yRadius: folioRadius)

        // Folio shadow on the obsidian desk
        NSGraphicsContext.saveGraphicsState()
        let folioShadow = NSShadow()
        folioShadow.shadowColor = color(0.0, 0.0, 0.0, isTiny ? 0.45 : 0.50)
        folioShadow.shadowOffset = NSSize(width: 0, height: isTiny ? -16 * s : -20 * s)
        folioShadow.shadowBlurRadius = isTiny ? 24 * s : 38 * s
        folioShadow.set()
        color(0.988, 0.985, 0.976).setFill()
        folioPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Clip to Folio Sheet
        NSGraphicsContext.saveGraphicsState()
        folioPath.addClip()

        // Warm Ivory to Porcelain vertical paper gradient
        let paperGradient = NSGradient(colors: [
            color(0.994, 0.992, 0.986), // top catch-light ivory
            color(0.988, 0.985, 0.976), // Theme.paper studyLight (#FAF9F6)
            color(0.958, 0.954, 0.942)  // Theme.elevated studyLight (#F4F3F0)
        ], atLocations: [0.0, 0.7, 1.0], colorSpace: .sRGB)!
        paperGradient.draw(in: folioRect, angle: -90)

        // 4. Scholarly Left Coral-Rose Margin Rule (signature of FolioPageSurface)
        let marginX: CGFloat = isTiny ? (folioX + 148 * s) : (folioX + 118 * s)
        let marginLineW: CGFloat = isTiny ? max(1.5, 48 * s) : (isSmall ? max(1.5, 30 * s) : max(2.0, 18 * s))
        // Coral-Rose accent from Theme.accent studyLight (0.820, 0.310, 0.270)
        let coralColor = color(0.845, 0.325, 0.280, isTiny ? 0.95 : 0.88)
        coralColor.setFill()
        NSRect(x: marginX - marginLineW / 2.0, y: folioRect.minY, width: marginLineW, height: folioRect.height).fill()

        // 5. Top-Right Bookmark / Capture Tab (Coral-Rose & Sage dual motif)
        if !isTiny {
            let tabW: CGFloat = (isSmall ? 76 : 64) * s
            let tabH: CGFloat = (isSmall ? 124 : 112) * s
            let tabX: CGFloat = folioRect.maxX - (isSmall ? 132 : 118) * s
            let tabY: CGFloat = folioRect.maxY - tabH
            let tabPath = NSBezierPath()
            tabPath.move(to: NSPoint(x: tabX, y: folioRect.maxY))
            tabPath.line(to: NSPoint(x: tabX + tabW, y: folioRect.maxY))
            tabPath.line(to: NSPoint(x: tabX + tabW, y: tabY))
            tabPath.line(to: NSPoint(x: tabX + tabW * 0.5, y: tabY + 26 * s))
            tabPath.line(to: NSPoint(x: tabX, y: tabY))
            tabPath.close()
            color(0.820, 0.310, 0.270).setFill() // Theme.accent studyLight
            tabPath.fill()
        }

        // 6. Typography / Prose / Capture Marks on the Folio Page
        let contentLeft: CGFloat = marginX + (isTiny ? 62 * s : 52 * s)
        let contentRight: CGFloat = folioRect.maxX - (isTiny ? 62 * s : 64 * s)
        let maxLineW: CGFloat = contentRight - contentLeft

        if isTiny {
            // 16x16 simplified optical master: 2 bold ink bars + coral capture spark
            let barH: CGFloat = 76 * s
            let r: CGFloat = barH / 2.0
            // Heading bar (Obsidian headingInk #16171B)
            color(0.085, 0.092, 0.108).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 230 * s, width: maxLineW * 0.82, height: barH), xRadius: r, yRadius: r).fill()

            // Second prose bar (Midnight ink #242B37)
            color(0.140, 0.168, 0.215, 0.88).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 385 * s, width: maxLineW * 0.58, height: barH), xRadius: r, yRadius: r).fill()

            // Sage / Neo-Acid capture pill at bottom right
            color(0.235, 0.525, 0.455).setFill() // Theme.sage
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 540 * s, width: maxLineW * 0.72, height: barH), xRadius: r, yRadius: r).fill()
        } else if isSmall {
            // 32x32 optical master: crisp heading + 2 prose lines + sage checklist badge
            let hBarH: CGFloat = 54 * s
            let pBarH: CGFloat = 40 * s

            // Heading bar
            color(0.085, 0.092, 0.108).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 205 * s, width: maxLineW * 0.68, height: hBarH), xRadius: hBarH / 2, yRadius: hBarH / 2).fill()

            // Prose line 1
            color(0.165, 0.175, 0.195, 0.88).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 315 * s, width: maxLineW * 0.90, height: pBarH), xRadius: pBarH / 2, yRadius: pBarH / 2).fill()

            // Prose line 2 + live coral caret
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 405 * s, width: maxLineW * 0.56, height: pBarH), xRadius: pBarH / 2, yRadius: pBarH / 2).fill()

            // Live spring caret right after prose line 2
            let caretX = contentLeft + maxLineW * 0.56 + 22 * s
            let caretW = max(2.0, 22 * s)
            color(0.820, 0.310, 0.270).setFill()
            NSBezierPath(roundedRect: NSRect(x: caretX, y: folioRect.maxY - 412 * s, width: caretW, height: pBarH + 14 * s), xRadius: caretW / 2, yRadius: caretW / 2).fill()

            // Bottom Sage attachment/OCR companion pill
            let pillY = folioRect.minY + 78 * s
            let pillH = 68 * s
            color(0.235, 0.525, 0.455, 0.18).setFill()
            let pillRect = NSRect(x: contentLeft, y: pillY, width: maxLineW * 0.78, height: pillH)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 20 * s, yRadius: 20 * s)
            pillPath.fill()
            color(0.235, 0.525, 0.455, 0.85).setStroke()
            pillPath.lineWidth = max(1.2, 8 * s)
            pillPath.stroke()

            // Sage dot inside pill
            let dotD = 30 * s
            color(0.235, 0.525, 0.455).setFill()
            NSBezierPath(ovalIn: NSRect(x: contentLeft + 22 * s, y: pillY + (pillH - dotD) / 2, width: dotD, height: dotD)).fill()
        } else {
            // 64px, 128px, 256px, 512px, 1024px rich commonplace folio
            // Monospace dateline stamp at top (whisper-quiet subtle ink)
            let stampH: CGFloat = 18 * s
            color(0.420, 0.430, 0.455, 0.65).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 88 * s, width: maxLineW * 0.34, height: stampH), xRadius: stampH / 2, yRadius: stampH / 2).fill()

            // Left-gutter H1 badge (in left margin)
            if !isMedium {
                let badgeW: CGFloat = 58 * s
                let badgeH: CGFloat = 34 * s
                let badgeX: CGFloat = marginX - badgeW - 22 * s
                let badgeY: CGFloat = folioRect.maxY - 178 * s
                color(0.820, 0.310, 0.270, 0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH), xRadius: 10 * s, yRadius: 10 * s).fill()
                // Small bar inside H1 badge
                color(0.820, 0.310, 0.270, 0.90).setFill()
                NSBezierPath(roundedRect: NSRect(x: badgeX + 14 * s, y: badgeY + 11 * s, width: 30 * s, height: 12 * s), xRadius: 6 * s, yRadius: 6 * s).fill()
            }

            // Luminous Heading 1 bar (Theme.headingInk #16171B)
            let h1H: CGFloat = 44 * s
            let h1Y: CGFloat = folioRect.maxY - 183 * s
            color(0.085, 0.092, 0.108).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: h1Y, width: maxLineW * 0.66, height: h1H), xRadius: h1H / 2, yRadius: h1H / 2).fill()

            // Body prose lines (Theme.ink #2A2D32)
            let pH: CGFloat = 28 * s
            color(0.165, 0.175, 0.195, 0.86).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 262 * s, width: maxLineW * 0.92, height: pH), xRadius: pH / 2, yRadius: pH / 2).fill()

            NSBezierPath(roundedRect: NSRect(x: contentLeft, y: folioRect.maxY - 318 * s, width: maxLineW * 0.84, height: pH), xRadius: pH / 2, yRadius: pH / 2).fill()

            // Active writing line + inline `code` capsule + Bike-style coral caret
            let activeY: CGFloat = folioRect.maxY - 374 * s
            // Inline code pill in Midnight Periwinkle / Coral tint
            let codeW: CGFloat = maxLineW * 0.26
            let codeRect = NSRect(x: contentLeft, y: activeY - 4 * s, width: codeW, height: pH + 8 * s)
            color(0.915, 0.938, 0.978).setFill() // botanical inlineCodeFill
            let codePath = NSBezierPath(roundedRect: codeRect, xRadius: 10 * s, yRadius: 10 * s)
            codePath.fill()
            color(0.245, 0.420, 0.825, 0.55).setStroke()
            codePath.lineWidth = max(1.0, 4 * s)
            codePath.stroke()

            color(0.180, 0.380, 0.780).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft + 14 * s, y: activeY + 3 * s, width: codeW - 28 * s, height: pH - 6 * s), xRadius: (pH - 6 * s) / 2, yRadius: (pH - 6 * s) / 2).fill()

            // Continuing prose segment on active line
            let segX = contentLeft + codeW + 18 * s
            let segW = maxLineW * 0.32
            color(0.165, 0.175, 0.195, 0.86).setFill()
            NSBezierPath(roundedRect: NSRect(x: segX, y: activeY, width: segW, height: pH), xRadius: pH / 2, yRadius: pH / 2).fill()

            // Live Coral-Rose Caret right after active prose segment
            let caretX = segX + segW + 16 * s
            let caretW = max(2.0, 14 * s)
            let caretH = 46 * s
            color(0.820, 0.310, 0.270).setFill()
            NSBezierPath(roundedRect: NSRect(x: caretX, y: activeY - 9 * s, width: caretW, height: caretH), xRadius: caretW / 2, yRadius: caretW / 2).fill()

            // Checked checklist item (Sage green celadon seal)
            let checkY: CGFloat = folioRect.maxY - 456 * s
            let boxSize: CGFloat = 38 * s
            let boxRect = NSRect(x: contentLeft, y: checkY - 5 * s, width: boxSize, height: boxSize)
            color(0.235, 0.525, 0.455).setFill() // Theme.sage
            NSBezierPath(roundedRect: boxRect, xRadius: 10 * s, yRadius: 10 * s).fill()

            // Crisp checkmark inside checkbox
            let checkPath = NSBezierPath()
            checkPath.move(to: NSPoint(x: boxRect.minX + 9 * s, y: boxRect.minY + 19 * s))
            checkPath.line(to: NSPoint(x: boxRect.minX + 17 * s, y: boxRect.minY + 10 * s))
            checkPath.line(to: NSPoint(x: boxRect.minX + 30 * s, y: boxRect.minY + 27 * s))
            checkPath.lineWidth = max(1.5, 6.5 * s)
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            color(0.988, 0.985, 0.976).setStroke()
            checkPath.stroke()

            // Checklist text bar
            color(0.420, 0.430, 0.455, 0.72).setFill()
            NSBezierPath(roundedRect: NSRect(x: contentLeft + boxSize + 20 * s, y: checkY, width: maxLineW * 0.58, height: pH), xRadius: pH / 2, yRadius: pH / 2).fill()

            // Bottom Recessed Attachment / OCR Companion Pill (dump-first screenshot/PDF card)
            let cardH: CGFloat = 86 * s
            let cardY: CGFloat = folioRect.minY + 46 * s
            let cardRect = NSRect(x: contentLeft, y: cardY, width: maxLineW, height: cardH)
            let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 22 * s, yRadius: 22 * s)
            color(0.932, 0.928, 0.915).setFill() // Theme.codeBackground studyLight
            cardPath.fill()
            color(0.825, 0.818, 0.800).setStroke() // Theme.codeBorder studyLight
            cardPath.lineWidth = max(1.0, 4 * s)
            cardPath.stroke()

            // Mini Neo-Acid / Sage OCR spark badge inside attachment pill
            let iconBoxSize: CGFloat = 52 * s
            let iconBoxRect = NSRect(x: cardRect.minX + 18 * s, y: cardY + (cardH - iconBoxSize) / 2, width: iconBoxSize, height: iconBoxSize)
            color(0.075, 0.078, 0.090).setFill() // Obsidian pill badge
            NSBezierPath(roundedRect: iconBoxRect, xRadius: 14 * s, yRadius: 14 * s).fill()

            // Neo-Acid Lime spark dot/bars inside badge (#C5F82A -> 0.773, 0.973, 0.165)
            color(0.773, 0.973, 0.165).setFill()
            let miniW = iconBoxSize * 0.52
            let miniH = 8 * s
            NSBezierPath(roundedRect: NSRect(x: iconBoxRect.minX + 12 * s, y: iconBoxRect.midY + 4 * s, width: miniW, height: miniH), xRadius: miniH / 2, yRadius: miniH / 2).fill()
            color(0.455, 0.635, 0.965).setFill() // Midnight periwinkle second scan line
            NSBezierPath(roundedRect: NSRect(x: iconBoxRect.minX + 12 * s, y: iconBoxRect.midY - 12 * s, width: miniW * 0.72, height: miniH), xRadius: miniH / 2, yRadius: miniH / 2).fill()

            // Attachment title & OCR subtitle bars
            let textLeft = iconBoxRect.maxX + 18 * s
            color(0.165, 0.175, 0.195, 0.88).setFill()
            NSBezierPath(roundedRect: NSRect(x: textLeft, y: cardY + 48 * s, width: maxLineW * 0.48, height: 18 * s), xRadius: 9 * s, yRadius: 9 * s).fill()
            color(0.235, 0.525, 0.455, 0.90).setFill()
            NSBezierPath(roundedRect: NSRect(x: textLeft, y: cardY + 22 * s, width: maxLineW * 0.30, height: 14 * s), xRadius: 7 * s, yRadius: 7 * s).fill()
        }

        // Top catch-light along the folio edge
        color(1.0, 1.0, 1.0, 0.85).setFill()
        NSRect(x: folioRect.minX + 36 * s, y: folioRect.maxY - max(1.0, 4 * s), width: folioRect.width - 72 * s, height: max(1.0, 4 * s)).fill()

        NSGraphicsContext.restoreGraphicsState() // end folio clip

        // Crisp folio border
        color(0.855, 0.850, 0.835, 0.95).setStroke()
        folioPath.lineWidth = max(1.0, 4.0 * s)
        folioPath.stroke()

        // Inner top catch-light of the Obsidian Desk Squircle
        color(0.28, 0.31, 0.37, 0.55).setStroke()
        let innerDeskRect = deskRect.insetBy(dx: max(0.5, 2.0 * s), dy: max(0.5, 2.0 * s))
        let innerDeskPath = NSBezierPath(roundedRect: innerDeskRect, xRadius: deskRadius, yRadius: deskRadius)
        innerDeskPath.lineWidth = max(1.0, 4.0 * s)
        innerDeskPath.stroke()

        NSGraphicsContext.restoreGraphicsState() // end desk clip
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
