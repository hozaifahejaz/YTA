import SwiftUI

/// System font (SF Pro) at a small set of sizes.
public enum Typography {
    public static let largeTitle = Font.system(size: 22, weight: .semibold)
    public static let title = Font.system(size: 17, weight: .semibold)
    public static let headline = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let callout = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let captionStrong = Font.system(size: 11, weight: .semibold)
    public static let mono = Font.system(size: 12, design: .monospaced)
}
