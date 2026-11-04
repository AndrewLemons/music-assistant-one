import Foundation

/// An opaque sRGB accent color, stored as "#RRGGBB", with WCAG contrast helpers.
public struct AccentRGB: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        func clamp(_ value: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : 0
        }
        self.red = clamp(red); self.green = clamp(green); self.blue = clamp(blue)
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var hex: String {
        let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }

    public static let `default` = AccentRGB(hex: "#1ABCF2")!
    public static let white = AccentRGB(red: 1, green: 1, blue: 1)
    public static let black = AccentRGB(red: 0, green: 0, blue: 0)
    /// The darkest system background a tint appears on (iOS grouped and Mac window backgrounds).
    public static let darkBackground = AccentRGB(hex: "#1C1C1E")!

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, from 1 to 21.
    public func contrast(with other: AccentRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Text and symbols in a tint need this contrast with the background. The default accent
    /// meets it on white; very light colors such as yellow are darkened in light appearance,
    /// and very dark ones lightened in dark appearance.
    public static let minimumTintContrast = 2.0

    /// This color, moved toward black or white just enough to reach `minimum` contrast.
    public func legible(on background: AccentRGB, minimum: Double = minimumTintContrast) -> AccentRGB {
        guard contrast(with: background) < minimum else { return self }
        let target: AccentRGB = background.luminance > 0.5 ? .black : .white
        var amount = 0.0
        var color = self
        while color.contrast(with: background) < minimum, amount < 1 {
            amount = min(1, amount + 0.02)
            color = mixed(with: target, amount: amount)
        }
        return color
    }

    /// White, unless white symbols would be hard to read on this fill, as on yellow.
    public var foreground: AccentRGB {
        contrast(with: .white) >= Self.minimumTintContrast ? .white : .black
    }

    public func mixed(with other: AccentRGB, amount: Double) -> AccentRGB {
        AccentRGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

extension AccentRGB: RawRepresentable {
    public init?(rawValue: String) {
        self.init(hex: rawValue)
    }

    public var rawValue: String {
        hex
    }
}
