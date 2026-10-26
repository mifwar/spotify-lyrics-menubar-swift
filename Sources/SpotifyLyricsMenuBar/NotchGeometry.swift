import Cocoa

/// The notch (real or simulated) on one screen, in screen coordinates.
///
/// Screen coordinates put the origin at the bottom-left of the primary display
/// with y growing up, so the top edge of a screen is `frame.maxY` even when the
/// display sits above or beside the primary one.
///
/// Main thread only: this holds an `NSScreen`, and its geometry is a snapshot.
/// Callers recompute it after a screen configuration change.
struct NotchGeometry {
    let screen: NSScreen
    /// The cutout at the top center of the screen.
    let notchFrame: NSRect
    /// True when the display has no hardware notch and `notchFrame` describes
    /// the fallback pill. Renderers use it to draw a detached pill instead of
    /// attaching to glass the display does not have.
    let isSimulated: Bool
}

/// Resolves where notch-attached UI belongs. Every display gets a notch: the
/// hardware cutout on notched Macs, a simulated pill everywhere else, so the
/// notch surface is a shipping mode rather than a MacBook-only one.
enum NotchDisplays {
    /// Roughly the cutout of a 14"/16" MacBook Pro, small enough to read as a
    /// notch on an external display and concrete enough to aim a window at.
    private static let simulatedSize = NSSize(width: 200, height: 32)

    /// Never returns nil: notch-less displays get the simulated pill.
    static func geometry(for screen: NSScreen) -> NotchGeometry {
        if let frame = hardwareNotchFrame(for: screen) {
            return NotchGeometry(screen: screen, notchFrame: frame, isSimulated: false)
        }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - simulatedSize.width / 2,
            y: frame.maxY - simulatedSize.height
        )
        return NotchGeometry(
            screen: screen,
            notchFrame: NSRect(origin: origin, size: simulatedSize),
            isSimulated: true
        )
    }

    /// Built-in notched display if present, else the menu-bar display, unless
    /// `override` names a screen that is still attached.
    static func preferredScreen(override: String?) -> NSScreen? {
        let screens = NSScreen.screens
        if let override, let picked = screens.first(where: { id(of: $0) == override }) {
            return picked
        }
        if let builtInNotched = screens.first(where: { isBuiltIn($0) && hardwareNotchFrame(for: $0) != nil }) {
            return builtInNotched
        }
        // AppKit puts the menu-bar display first in `screens`.
        return screens.first
    }

    /// Stable id for persistence. The display UUID comes from the panel's EDID,
    /// so it survives reconnects and the display-id reshuffling that happens
    /// when monitors are plugged in a different order.
    static func id(of screen: NSScreen) -> String {
        guard let displayID = displayID(of: screen) else {
            return "name:\(screen.localizedName)"
        }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display:\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The hardware cutout: the inset AppKit reserves at the top of the screen,
    /// spanning the gap between the auxiliary areas beside it. Both auxiliary
    /// areas are nil on a display without a camera housing, which is what makes
    /// them the reliable "has a notch" signal.
    private static func hardwareNotchFrame(for screen: NSScreen) -> NSRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard width > 0, width <= screen.frame.width else { return nil }
        return NSRect(
            x: left.maxX,
            y: screen.frame.maxY - inset,
            width: width,
            height: inset
        )
    }
}
