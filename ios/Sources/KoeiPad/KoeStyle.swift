import SwiftUI
import UIKit

/// The Mac app's washi palette (KoeTheme.swift), dynamic for light/dark.
enum Koe {
    static let shu = Color(hex: 0xC0432D)
    static let paper = dyn(0xFAF4E8, 0x252019)
    static let paper2 = dyn(0xF6EEDD, 0x201B15)
    static let desk = dyn(0xE3DCCD, 0x2B2620)
    static let readerBg = dyn(0xD6D1C4, 0x2A2620)
    static let ink = dyn(0x2C2620, 0xEAE3D6)
    static let ink2 = dyn(0x544B3D, 0xC9C0B0)
    static let faint = dyn(0x8C8472, 0x8F8676)
    static let line = dyn(0xE6DABF, 0x3A3328)
    static let green = Color(hex: 0x7C8A5B)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Reader face: Hiragino Mincho like the Mac; falls back to the system serif.
    static func readerFont(_ size: CGFloat) -> UIFont {
        UIFont(name: "HiraMinProN-W3", size: size)
            ?? UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static var highlightFill: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xC0432D, alpha: 0.34) : UIColor(hex: 0xC0432D, alpha: 0.26) }
    }
    static var inkUI: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xEAE3D6) : UIColor(hex: 0x2C2620) } }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(UIColor(hex: hex, alpha: alpha)) }
}

extension KoeHighlightColor {
    /// Soft washes that stay readable under black ink, light and dark.
    var ui: UIColor {
        switch self {
        case .yellow: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.85, green: 0.72, blue: 0.20, alpha: 0.42) : UIColor(red: 0.98, green: 0.85, blue: 0.30, alpha: 0.48) }
        case .green:  return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.45, green: 0.68, blue: 0.35, alpha: 0.42) : UIColor(red: 0.60, green: 0.80, blue: 0.45, alpha: 0.45) }
        case .pink:   return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.85, green: 0.45, blue: 0.58, alpha: 0.42) : UIColor(red: 0.97, green: 0.62, blue: 0.72, alpha: 0.45) }
        case .blue:   return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.60, blue: 0.85, alpha: 0.42) : UIColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 0.45) }
        }
    }
    var swatch: Color { Color(ui.withAlphaComponent(1)) }
}
