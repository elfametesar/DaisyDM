import AppKit

/// Progress windows use an AppKit-backed NSTabView. macOS can provide the
/// native tab-label customization menu before the tab view's `menu` property
/// is consulted, so suppress right-click events at the window event level.
private let progressWindowRightClickMonitor: Any? = {
    NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { event in
        guard let window = event.window,
              let contentView = window.contentView else {
            return event
        }

        func containsTabView(_ view: NSView) -> Bool {
            if view is NSTabView { return true }
            return view.subviews.contains(where: containsTabView)
        }

        // The progress dialog is the only app window backed by an NSTabView.
        // Consume both halves of the right-click so AppKit cannot present its
        // Icon/Text tab customization menu.
        if containsTabView(contentView) {
            return nil
        }

        return event
    }
}()
