import Foundation
import UIKit

enum Platform {
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    @MainActor
    static func ensureMacWindowMinimumSize(_ minimumSize: CGSize, in scene: UIWindowScene) {
#if targetEnvironment(macCatalyst)
        let frame = scene.effectiveGeometry.systemFrame
        guard !frame.isNull, !frame.isEmpty,
              frame.width > 0, frame.height > 0,
              frame.width < minimumSize.width || frame.height < minimumSize.height else {
            return
        }
        let target = CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: max(frame.width, minimumSize.width),
            height: max(frame.height, minimumSize.height)
        )
        scene.requestGeometryUpdate(.Mac(systemFrame: target))
#endif
    }

    @MainActor
    static func hideMacWindowTitle(in scene: UIWindowScene) {
#if targetEnvironment(macCatalyst)
        scene.titlebar?.titleVisibility = .hidden
#endif
    }
}
