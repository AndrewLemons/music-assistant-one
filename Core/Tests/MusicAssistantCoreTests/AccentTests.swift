import Foundation
@testable import MusicAssistantCore
import Testing

@Test func accentHexRoundTripsAndRejectsInvalidValues() throws {
    #expect(AccentRGB.default.hex == "#1ABCF2")
    #expect(try #require(AccentRGB(rawValue: "#5e5ce6")).rawValue == "#5E5CE6")
    #expect(AccentRGB(hex: "1ABCF2") == .default)
    for invalid in ["", "#12345", "#GGGGGG", "#1ABCF2FF", "red"] {
        #expect(AccentRGB(hex: invalid) == nil)
    }
}

@Test func accentStaysLegibleAndPicksAReadableForeground() throws {
    // The default and system-like hues are used as chosen, with white symbols.
    for hex in ["#1ABCF2", "#007AFF", "#5E5CE6", "#AF52DE", "#FF2D55", "#F5820D", "#2DAA4F", "#8E8E93"] {
        let color = try #require(AccentRGB(hex: hex))
        #expect(color.legible(on: .white) == color)
        #expect(color.legible(on: .darkBackground) == color)
        #expect(color.foreground == .white)
    }
    // Yellow is darkened for text on white, and filled yellow uses black symbols.
    let yellow = try #require(AccentRGB(hex: "#FFCC00"))
    #expect(yellow.foreground == .black)
    #expect(yellow.legible(on: .darkBackground) == yellow)
    let adjusted = yellow.legible(on: .white)
    #expect(adjusted.contrast(with: .white) >= AccentRGB.minimumTintContrast)
    #expect(adjusted.contrast(with: .white) < 2.2)
    // Very dark colors lighten in dark appearance.
    let navy = try #require(AccentRGB(hex: "#101040"))
    #expect(navy.legible(on: .darkBackground).contrast(with: .darkBackground) >= AccentRGB.minimumTintContrast)
}
