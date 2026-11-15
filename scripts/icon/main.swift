// Renders LogoMark (Sources/DevSweepApp/LogoMark.swift) into an .iconset.
// Built and run by scripts/make_icon.sh.
import AppKit
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

MainActor.assumeIsolated {
    for (name, px) in sizes {
        let renderer = ImageRenderer(content: LogoMark(size: CGFloat(px)))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("render failed for \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
        try! png.write(to: out.appendingPathComponent("\(name).png"))
    }
}
print("Wrote \(out.path)")
