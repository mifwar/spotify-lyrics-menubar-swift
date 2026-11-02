import Cocoa

/// Where the now-playing header sits. Beside a hardware cutout it moves into
/// the ears, so every part of it must stay clear of the cutout and inside the
/// ear band; a simulated pill keeps the header in its own row. Part of the
/// notch-preview harness, which owns `check`.
func checkHeaderPlacement(_ variant: String, geometry: NotchGeometry, layout: NotchCardLayout) {
    let inEars = !geometry.isSimulated
    let style: NotchHeaderStyle = inEars ? .ears : .row
    check(layout.isHeaderInEars == inEars, "\(variant): the header sits in the ears only beside a hardware cutout")
    check(layout.artwork.width == style.artworkSize && layout.artwork.height == style.artworkSize,
          "\(variant): the cover slot is \(Int(style.artworkSize)) pt")
    guard inEars else { return }

    let contentTop = NotchStyle.contentTop(for: geometry)
    let cutout = NSRect(
        x: layout.size.width / 2 - geometry.notchFrame.width / 2,
        y: 0,
        width: geometry.notchFrame.width,
        height: contentTop
    )
    for (name, rect) in [("cover", layout.artwork), ("title", layout.title), ("artist", layout.artist), ("pin", layout.pinButton)] {
        check(!rect.intersects(cutout) && rect.minY >= 0 && rect.maxY <= contentTop + NotchStyle.earBandExtra,
              "\(variant): the \(name) sits in an ear, clear of the cutout")
    }
    check(layout.title.maxX < cutout.minX && layout.pinButton.minX > cutout.maxX,
          "\(variant): the title is in the left ear and the pin in the right one")
    let title = "Bulan Setan Atau Malaikat"
    let shown = NotchText.fitted(title, font: style.titleFont, to: layout.title.width)
    print("[\(variant)] ear title \(Int(layout.title.width)) pt: \"\(shown)\"")
    check(shown.count - 1 >= title.count * 3 / 4, "\(variant): most of a typical title reads in the ear")
}
