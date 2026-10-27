import Cocoa

/// Exercise the native control's action, rather than bypassing it with a
/// controller-space click. The button tracks mouse-up in the running app.
func clickPinButton() {
    let view = cardView()
    let button = view.pinButton
    let centre = NSPoint(x: button.frame.midX, y: button.frame.midY)
    check(!button.isHidden && button.isEnabled && view.hitTest(view.convert(centre, to: view.superview)) === button,
          "pin button is visible and hittable")
    button.performClick(nil)
}

func checkPinInteraction(_ variant: String, geometry: NotchGeometry) {
    let view = cardView()
    let button = view.pinButton
    let layout = NotchCardLayout.make(
        for: baseWindow,
        width: view.bounds.width,
        contentTop: NotchStyle.contentTop(for: geometry),
        showsTransport: false
    )
    check(!button.isHidden && button.frame == layout.pinButton, "\(variant): hover exposes the pin button")
    check(view.hitTest(view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: view.superview)) === button,
          "\(variant): clicks on the pin reach the native button")
    check(button.frame.minY >= NotchStyle.contentTop(for: geometry), "\(variant): pin clears the hardware cutout")
    check(!layout.rows.contains { $0.rect.intersects(button.frame) }, "\(variant): pin never overlaps lyrics")
    check(button.state == .off && button.toolTip == "Pin lyrics open", "\(variant): unpinned control offers pinning")
    check(button.accessibilityLabel() == "Keep lyrics open", "\(variant): pin has an accessible label")

    for pinned in [false, true] {
        if pinned { clickPinButton() }
        let seeksBefore = seeks.count
        let transportsBefore = transports.count
        let points = [
            NSPoint(x: 4, y: view.bounds.midY),
            NSPoint(x: layout.artwork.midX, y: layout.artwork.midY),
            NSPoint(x: view.bounds.midX, y: view.bounds.height - 2),
        ] + layout.rows.filter { $0.slot == NotchStyle.rowRadius }.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }
        for point in points { controller.click(at: point) }
        check(controller.isPinned == pinned, "\(variant): lyrics, artwork and padding preserve pin state \(pinned)")
        check(seeks.count == seeksBefore && transports.count == transportsBefore,
              "\(variant): inactive content sends no seek or transport")
    }
    check(button.state == .on && button.toolTip == "Unpin lyrics", "\(variant): pinned control offers unpinning")
    controller.setHovered(true)
    wait(0.25)
    clickPinButton()
    check(!controller.isPinned && view.isExpanded, "\(variant): unpin under hover keeps the control reachable")
    check(button.state == .off, "\(variant): unpin clears the selected state")
}

/// Puts the card in the state the footer lives in: pinned on the base window.
func pinBaseWindow(_ variant: String, geometry: NotchGeometry) {
    controller.dismiss()
    controller.present(presentation(.playing), geometry: geometry, isObscured: false)
    wait(0.15)
    controller.setHovered(true)
    wait(0.5)
    clickPinButton()
    wait(0.4)
    check(controller.isPinned, "\(variant): the pinned footer fixture is pinned")
}

func unpinBaseWindow() {
    clickPinButton()
    wait(0.6)
    controller.dismiss()
    seeks.removeAll()
}
