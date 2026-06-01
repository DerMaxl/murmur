import SwiftUI

/// Window content zoom. macOS doesn't honour `dynamicTypeSize` for this kind of
/// content, so we scale fonts ourselves: a `fontScale` flows down the environment and
/// `scaledFont(_:)` multiplies a base point size by it. The result is real, crisp
/// fonts at the new size (not a blurry `scaleEffect`).
private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

extension View {
    /// A system font whose size tracks the window zoom (`AppModel.fontScale`).
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}
