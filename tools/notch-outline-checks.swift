import Cocoa

/// The expanded outline, read from rendered alpha. A hardware card has a body
/// the cutout plus two ears wide, gains shoulders either side and casts a shadow; a simulated pill
/// is unchanged. Part of the notch-preview harness, which owns `check`, `card`
/// and `panel`.
func checkOutline(_ variant: String, geometry: NotchGeometry) {
    let inset = NotchStyle.sideInset(isSimulated: geometry.isSimulated)
    let view = card()
    check(panel().frame.width == NotchStyle.expandedBodyWidth(for: geometry) + 2 * inset, "\(variant): window is the body plus its shoulders")
    check(panel().hasShadow == !geometry.isSimulated, "\(variant): only the hardware card casts a shadow")
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        check(false, "\(variant): no bitmap for the outline")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1
    }
    let midY = view.bounds.midY
    check(alpha(inset + 1, midY) == 1, "\(variant): the body is opaque black at its edge")
    guard !geometry.isSimulated else { return }
    check(alpha(1, midY) == 0, "\(variant): the strip beside the body is transparent")
    check(alpha(inset + 1, 0.5) == 1, "\(variant): the top edge is filled beside the body")
    check(alpha(1, 4) == 0, "\(variant): the shoulder curves away below the top edge")
}
