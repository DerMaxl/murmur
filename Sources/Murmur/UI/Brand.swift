import SwiftUI
import AppKit

/// Murmur's brand palette - one source of truth for the colors used across the app
/// (and matched by the app icon). Teal→indigo on a deep near-black, a quiet,
/// premium "murmur" feel that stays distinct from the all-blue dictation crowd.
enum Brand {
    /// Bright teal - the leading edge of the wave.
    static let teal = Color(red: 52/255, green: 231/255, blue: 200/255)
    /// Indigo - the trailing edge of the wave and the app's accent.
    static let indigo = Color(red: 99/255, green: 102/255, blue: 241/255)

    /// The app accent (controls, selection, glyphs). Indigo reads well on both light
    /// and dark and matches the icon.
    static let accent = indigo

    /// The signature teal→indigo gradient, as used in the icon's wave.
    static let wave = LinearGradient(colors: [teal, indigo],
                                     startPoint: .leading, endPoint: .trailing)

    /// AppKit equivalents, for the few places that draw with `NSColor` (the HUD meter).
    static let tealNS = NSColor(teal)
    static let indigoNS = NSColor(indigo)
}
