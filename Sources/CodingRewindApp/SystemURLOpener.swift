// SPDX-License-Identifier: MIT

import AppKit
import Foundation

public enum SystemURLOpener {
    @MainActor
    public static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
