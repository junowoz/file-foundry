import ApplicationServices
import CoreGraphics
import Foundation

/// Turns INPUT events into CGEvents on the virtual display. Needs Accessibility permission.
final class SSInputInjector: @unchecked Sendable {
    private let displayBounds: @Sendable () -> CGRect
    private let lock = NSLock()
    private var buttonDown = false
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint: CGPoint = .zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .hidSystemState)

    init(displayBounds: @escaping @Sendable () -> CGRect) { self.displayBounds = displayBounds }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func handle(_ event: SSInputEvent) {
        guard Self.isTrusted, event.pointerId == 0 else { return }
        let bounds = displayBounds()
        guard !bounds.isEmpty else { return }
        let p = SSInputMapper.point(x: event.x, y: event.y, in: bounds)
        lock.lock(); defer { lock.unlock() }

        switch event.kind {
        case .down:
            post(.mouseMoved, p, .left)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDownTime < 0.4, hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 8 { clickCount += 1 } else { clickCount = 1 }
            lastDownTime = now; lastDownPoint = p
            buttonDown = true
            post(.leftMouseDown, p, .left, clicks: clickCount)
        case .move:
            post(buttonDown ? .leftMouseDragged : .mouseMoved, p, .left, clicks: clickCount)
        case .up:
            if buttonDown { buttonDown = false; post(.leftMouseUp, p, .left, clicks: clickCount) }
        case .cancel:
            if buttonDown { buttonDown = false; post(.leftMouseUp, p, .left, clicks: clickCount) }
        case .rightClick:
            post(.mouseMoved, p, .right)
            post(.rightMouseDown, p, .right)
            post(.rightMouseUp, p, .right)
        case .scroll:
            // x/y are 0 for scroll: keep the pointer where it is, unless it is off the virtual display.
            var at = CGEvent(source: nil)?.location ?? .zero
            if !bounds.contains(at) {
                at = CGPoint(x: bounds.midX, y: bounds.midY)
                post(.mouseMoved, at, .left)
            }
            let dy = SSInputMapper.scroll(event.dy), dx = SSInputMapper.scroll(event.dx)
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                e.location = at
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Release a held button (client vanished mid-drag).
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        if buttonDown {
            buttonDown = false
            post(.leftMouseUp, lastDownPoint, .left)
        }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }
}
