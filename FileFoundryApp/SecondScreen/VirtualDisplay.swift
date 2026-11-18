import AppKit
import CVirtualDisplay
import CoreGraphics

// CGVirtualDisplay setup adapted from SideScreen (MIT, see THIRD_PARTY_NOTICES.md).

enum SSVirtualDisplayError: LocalizedError {
    case creationFailed, settingsFailed
    var errorDescription: String? {
        switch self {
        case .creationFailed: "macOS refused to create the virtual display."
        case .settingsFailed: "macOS refused the virtual display mode."
        }
    }
}

/// Owns one CGVirtualDisplay. Releasing it (destroy / deinit) removes the display.
final class SSVirtualDisplay: @unchecked Sendable {
    private var display: CGVirtualDisplay?
    let displayID: CGDirectDisplayID
    let geometry: SSStreamGeometry

    init(geometry: SSStreamGeometry, refreshRate: Int, name: String) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(geometry.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(geometry.pixelHeight)
        // ≥ 200 ppi makes macOS treat the panel as Retina.
        let ppi: Double = geometry.hiDPI ? 220 : 110
        descriptor.sizeInMillimeters = CGSize(width: Double(geometry.pixelWidth) * 25.4 / ppi,
                                              height: Double(geometry.pixelHeight) * 25.4 / ppi)
        descriptor.vendorID = 0xEEEE
        descriptor.productID = UInt32(truncatingIfNeeded: geometry.pixelWidth * 10000 + geometry.pixelHeight)
        descriptor.serialNum = 0x0F0F
        descriptor.queue = DispatchQueue.global(qos: .userInitiated)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw SSVirtualDisplayError.creationFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = geometry.hiDPI ? 1 : 0
        let hz = Double(min(max(refreshRate, 60), 120))
        var modes: [CGVirtualDisplayMode] = []
        if geometry.hiDPI {
            // Physical anchor mode unlocks the 2x logical mode.
            modes.append(CGVirtualDisplayMode(width: UInt32(geometry.pixelWidth), height: UInt32(geometry.pixelHeight), refreshRate: hz))
        }
        modes.append(CGVirtualDisplayMode(width: UInt32(geometry.pointWidth), height: UInt32(geometry.pointHeight), refreshRate: hz))
        settings.modes = modes

        guard display.apply(settings) else { throw SSVirtualDisplayError.settingsFailed }

        self.display = display
        self.displayID = display.displayID
        self.geometry = geometry
    }

    /// Display bounds in global points (used for input).
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// Place the virtual display to the right of every other display, top-aligned with the main one.
    /// Session-only: the user's permanent arrangement is not touched.
    func arrangeRightOfMain() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let others = ids.prefix(Int(count)).filter { $0 != displayID }
        let rightEdge = others.map { CGDisplayBounds($0).maxX }.max() ?? 0
        let top = CGDisplayBounds(CGMainDisplayID()).minY

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if CGConfigureDisplayOrigin(config, displayID, Int32(rightEdge), Int32(top)) == .success {
            CGCompleteDisplayConfiguration(config, .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    func destroy() { display = nil }
    deinit { display = nil }
}
