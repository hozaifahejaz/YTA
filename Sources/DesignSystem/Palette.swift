import SwiftUI

/// Light mode only. Near-white surfaces, soft greys, one muted accent (section 6.2).
/// Every text colour here meets 4.5 to 1 against `surface` and `background`.
public enum Palette {
    /// Window background.
    public static let background = Color(hex: 0xF6F6F4)
    /// Cards, inspector, sheets.
    public static let surface = Color(hex: 0xFFFFFF)
    /// Quiet fills: wells, selected rows, connector track.
    public static let surfaceMuted = Color(hex: 0xEFEFEC)
    public static let border = Color(hex: 0xE2E2DE)
    public static let borderStrong = Color(hex: 0xC9C9C4)

    /// 16.3 : 1 on white.
    public static let textPrimary = Color(hex: 0x1D2025)
    /// 6.9 : 1 on white.
    public static let textSecondary = Color(hex: 0x555B64)
    /// 5.6 : 1 on white, 4.9 : 1 on surfaceMuted. Use for captions only.
    public static let textTertiary = Color(hex: 0x62686F)

    /// Muted slate blue. Used only for the node that needs the owner and the primary button.
    public static let accent = Color(hex: 0x4A5F82)
    public static let accentSoft = Color(hex: 0xE8ECF3)

    public static let success = Color(hex: 0x3D6F55)
    public static let successSoft = Color(hex: 0xE6F0EA)
    public static let danger = Color(hex: 0x9C3B36)
    public static let dangerSoft = Color(hex: 0xF6E7E5)
    public static let caution = Color(hex: 0x7A5E14)
    public static let cautionSoft = Color(hex: 0xF5EFDD)
}

public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum Radius {
    public static let s: CGFloat = 6
    public static let m: CGFloat = 10
    public static let l: CGFloat = 14
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
