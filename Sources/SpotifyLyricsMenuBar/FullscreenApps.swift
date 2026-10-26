import Cocoa

/// Decides whether the notch pill should get out of the way because another app
/// is fullscreen on its display.
///
/// Everything here comes from the window server's window list — bounds, owner
/// pid, layer. That needs no Accessibility grant, no Screen Recording and no
/// private API; the parts of the list that *would* need permission (window
/// titles) are never read.
///
/// The predicate is deliberately conservative: a pill that wrongly hides looks
/// broken, a pill that wrongly stays on screen is only mildly annoying, so every
/// ambiguous case answers "not fullscreen".
enum FullscreenApps {
    /// One window as the window server reports it, converted to AppKit screen
    /// coordinates: origin at the bottom left of the primary display, y up.
    struct Window {
        let bounds: NSRect
        let ownerPID: pid_t
        let layer: Int
        let bundleID: String?
    }

    /// One display in the same coordinate space, so the decision is per screen:
    /// a fullscreen app on another display must not hide this display's pill.
    struct ScreenBounds {
        let frame: NSRect
        let visibleFrame: NSRect

        /// The band at the top of the display that the menu bar owns. Some
        /// "fullscreen" windows stop below it instead of covering the whole
        /// display, so the top edge gets this much slack while the other three
        /// edges only get rounding slack.
        var menuBarHeight: CGFloat {
            max(0, frame.maxY - visibleFrame.maxY)
        }
    }

    /// Apps that never count as blocking. Spotify is the app the pill exists to
    /// accompany, and a second copy of ourselves must not hide our own pill
    /// either (the running instance is already excluded by pid).
    static let ignoredBundleIDs: Set<String> = [
        "com.spotify.client",
        "local.spotify-lyrics-menubar",
    ]

    /// Windows may be off by a point on the sides and the bottom (window server
    /// rounding, shadowless fullscreen windows) and still count.
    private static let edgeSlack: CGFloat = 1

    /// True when this one window covers `screen` and belongs to a real,
    /// non-ignored app.
    static func isBlocking(
        _ window: Window,
        on screen: ScreenBounds,
        ownPID: pid_t,
        ignoredBundleIDs: Set<String> = FullscreenApps.ignoredBundleIDs
    ) -> Bool {
        // Our own windows (the pill itself, the floating panel) never block.
        guard window.ownerPID != ownPID else { return false }
        // Only ordinary app windows sit at layer 0; the Dock (20) and the menu
        // bar (24/25) are system chrome on their own, higher layers, as are the
        // window server's own windows.
        guard window.layer == 0 else { return false }
        guard !ignoredBundleIDs.contains(window.bundleID ?? "") else { return false }

        // Rejects empty, negative and NaN rectangles: every comparison below is
        // false for NaN, so bad geometry cannot read as fullscreen.
        guard window.bounds.width > 0, window.bounds.height > 0 else { return false }

        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return false }

        let bounds = window.bounds
        return bounds.minX <= frame.minX + edgeSlack
            && bounds.maxX >= frame.maxX - edgeSlack
            && bounds.minY <= frame.minY + edgeSlack
            && bounds.maxY >= frame.maxY - screen.menuBarHeight - edgeSlack
    }

    /// True when any window covers `screen`.
    static func isBlocking(
        windows: [Window],
        on screen: ScreenBounds,
        ownPID: pid_t,
        ignoredBundleIDs: Set<String> = FullscreenApps.ignoredBundleIDs
    ) -> Bool {
        windows.contains {
            isBlocking($0, on: screen, ownPID: ownPID, ignoredBundleIDs: ignoredBundleIDs)
        }
    }

    /// Live answer for one display.
    static func isBlocking(
        screen: NSScreen,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        isBlocking(
            windows: currentWindows(),
            on: ScreenBounds(frame: screen.frame, visibleFrame: screen.visibleFrame),
            ownPID: ownPID
        )
    }

    /// The window server's on-screen windows, converted to AppKit coordinates.
    ///
    /// The window list counts y downwards from the top edge of the primary
    /// display; AppKit counts upwards from its bottom edge, so every rectangle
    /// is flipped around the primary display's height.
    static func currentWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        return windows.compactMap { info in
            guard
                let rawBounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                let x = rawBounds["X"], let y = rawBounds["Y"],
                let width = rawBounds["Width"], let height = rawBounds["Height"],
                let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber
            else {
                return nil
            }

            let bounds = NSRect(
                x: x.doubleValue,
                y: primaryHeight - y.doubleValue - height.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
            return Window(
                bounds: bounds,
                ownerPID: ownerPID.int32Value,
                layer: layer.intValue,
                bundleID: NSRunningApplication(processIdentifier: ownerPID.int32Value)?.bundleIdentifier
            )
        }
    }
}
