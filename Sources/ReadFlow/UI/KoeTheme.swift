//
//  KoeTheme.swift
//  ReadFlow / Koe
//
//  The Koe visual system, extracted from docs/design/Koe v2.dc.html and
//  docs/design/KOE-STYLE-GUIDE.md. Warm washi-paper palette (light + dark), a
//  single vermilion (shu 朱) accent, and a Japanese-stationery type stack.
//
//  Fonts: we map Koe's Google fonts to fonts that SHIP with macOS so the look is
//  faithful with zero bundling/network risk —
//    Shippori Mincho      → Hiragino Mincho ProN  (a real mincho serif)
//    Zen Kaku Gothic New  → Hiragino Sans         (a clean gothic UI face)
//    DM Mono              → Menlo
//    Klee One (handwrite) → falls back to system if absent (margin notes only)
//  SwiftUI's Font.custom silently falls back to the system font if a face is
//  missing, so text never disappears.
//

import SwiftUI

// MARK: - Which main view is showing

enum KoeView: String {
    case capture   // paper "page" with the floating Listen chip
    case read      // "The Quiet Hour" — lined-paper reading column
    case canvas    // Idea Canvas — dot-grid whiteboard with sticky notes
    case boards    // Boards — named collections of saved reading snippets
}

// MARK: - Light / dark

enum KoeAppearance: String {
    case light
    case dark

    var toggled: KoeAppearance { self == .light ? .dark : .light }
}

// MARK: - Color hex helper

extension Color {
    /// `Color(hex: 0xC0432D)` — opaque. `Color(hex: 0xC0432D, alpha: 0.26)` for tints.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Palette

/// All Koe color tokens for one appearance. Built from the CSS variables in the
/// mock so the native app matches the design pixel-for-token.
struct KoePalette {
    // Surfaces
    let deskTop: Color, deskMid: Color, deskBot: Color
    let s0: Color, s1: Color, s2: Color, s3: Color
    let canvas: Color, navAct: Color
    let readerBg: Color, readerBar: Color

    // Ink / text (also drive the read/current/upcoming word colors)
    let ink: Color, ink2: Color, ink3: Color
    let soft: Color, faint: Color, faint2: Color, mute: Color

    // Lines
    let line: Color, line2: Color, dash: Color

    // Accents
    let shu: Color          // the one vermilion accent
    let noteBlue: Color, noteGreen: Color
    let tintShu: Color, tintAi: Color

    /// The current-word highlight fill (vermilion at 26%).
    var highlightFill: Color { Color(hex: 0xC0432D, alpha: appearanceIsDark ? 0.34 : 0.26) }
    /// Captured-selection tint.
    var selectionFill: Color { Color(hex: 0xC0432D, alpha: 0.15) }

    fileprivate let appearanceIsDark: Bool

    /// Radial "desk" backdrop behind the window.
    var desk: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [deskTop, deskMid, deskBot]),
            center: .top, startRadius: 0, endRadius: 900
        )
    }

    static let light = KoePalette(
        deskTop: Color(hex: 0xE3DCCD), deskMid: Color(hex: 0xD4CCBA), deskBot: Color(hex: 0xCABFA9),
        s0: Color(hex: 0xFDFAF4), s1: Color(hex: 0xFAF4E8), s2: Color(hex: 0xF6EEDD), s3: Color(hex: 0xF4ECDD),
        canvas: Color(hex: 0xF1E8D6), navAct: Color(hex: 0xEFE6D2),
        readerBg: Color(hex: 0xD6D1C4), readerBar: Color(hex: 0xCBC6B8),
        ink: Color(hex: 0x2C2620), ink2: Color(hex: 0x3F382D), ink3: Color(hex: 0x544B3D),
        soft: Color(hex: 0x6F6557), faint: Color(hex: 0x8C8472), faint2: Color(hex: 0x9A8F7C), mute: Color(hex: 0xA99F8C),
        line: Color(hex: 0xE6DABF), line2: Color(hex: 0xECE0C6), dash: Color(hex: 0xD4C4A0),
        shu: Color(hex: 0xC0432D),
        noteBlue: Color(hex: 0x33455F), noteGreen: Color(hex: 0x7C8A5B),
        tintShu: Color(hex: 0xF4DDD6), tintAi: Color(hex: 0xDDE3EC),
        appearanceIsDark: false
    )

    static let dark = KoePalette(
        deskTop: Color(hex: 0x2B2620), deskMid: Color(hex: 0x211D18), deskBot: Color(hex: 0x16130F),
        s0: Color(hex: 0x2A251E), s1: Color(hex: 0x252019), s2: Color(hex: 0x201B15), s3: Color(hex: 0x322C23),
        canvas: Color(hex: 0x1B1712), navAct: Color(hex: 0x352E23),
        readerBg: Color(hex: 0x2A2620), readerBar: Color(hex: 0x201B15),
        ink: Color(hex: 0xF2ECE0), ink2: Color(hex: 0xDDD5C6), ink3: Color(hex: 0xCBC2B1),
        soft: Color(hex: 0xB3A994), faint: Color(hex: 0x9A8F7B), faint2: Color(hex: 0x857B69), mute: Color(hex: 0x7D7361),
        line: Color(hex: 0x3A342B), line2: Color(hex: 0x332E27), dash: Color(hex: 0x4A4236),
        shu: Color(hex: 0xC0432D),
        noteBlue: Color(hex: 0xA8C0DF), noteGreen: Color(hex: 0xB7C68D),
        tintShu: Color(hex: 0x3C2620), tintAi: Color(hex: 0x26313F),
        appearanceIsDark: true
    )

    static func forAppearance(_ a: KoeAppearance) -> KoePalette { a == .dark ? .dark : .light }
}

// MARK: - Fonts

enum KoeFont {
    /// Mincho serif — headings & reading body. Hiragino Mincho ProN ships on macOS.
    static func mincho(_ size: CGFloat, bold: Bool = false) -> Font {
        Font.custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
    }

    enum GothicWeight { case regular, medium, bold }

    /// Gothic sans — UI, buttons, nav. Hiragino Sans ships on macOS.
    static func gothic(_ size: CGFloat, _ weight: GothicWeight = .regular) -> Font {
        let face: String
        switch weight {
        case .regular: face = "HiraginoSans-W3"
        case .medium:  face = "HiraginoSans-W5"
        case .bold:    face = "HiraginoSans-W7"
        }
        return Font.custom(face, size: size)
    }

    /// Monospace — metadata, filenames, timestamps.
    static func mono(_ size: CGFloat) -> Font {
        Font.custom("Menlo", size: size)
    }

    /// Handwritten — margin/sticky notes (Canvas deferred; used sparingly).
    static func hand(_ size: CGFloat) -> Font {
        Font.custom("Klee", size: size) // falls back to system if absent
    }
}
