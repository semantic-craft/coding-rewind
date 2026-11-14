// SPDX-License-Identifier: MIT

import SwiftUI

enum RewindButtonRole {
    case primary
    case secondary
    case toolbar
}

private struct RewindButtonModifier: ViewModifier {
    let role: RewindButtonRole

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content.buttonStyle(.borderedProminent).controlSize(.regular)
        case .secondary:
            content.buttonStyle(.bordered).controlSize(.small)
        case .toolbar:
            content.buttonStyle(.borderless).controlSize(.small)
        }
    }
}

extension View {
    func rewindButtonRole(_ role: RewindButtonRole) -> some View {
        modifier(RewindButtonModifier(role: role))
    }
}
