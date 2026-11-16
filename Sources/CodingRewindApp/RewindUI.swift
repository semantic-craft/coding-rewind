// SPDX-License-Identifier: MIT

import SwiftUI

enum RewindButtonRole {
    case primary
    case secondary
    case toolbar
}

struct RewindLaunchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.rewindFilledButtonSurface(
            isEnabled: isEnabled,
            isPressed: configuration.isPressed,
            fontSize: 13,
            enabledColor: Color(red: 0, green: 104 / 255, blue: 217 / 255),
            verticalPadding: 4
        )
    }
}

struct RewindDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.rewindFilledButtonSurface(
            isEnabled: isEnabled,
            isPressed: configuration.isPressed,
            fontSize: 12,
            enabledColor: Color(red: 214 / 255, green: 45 / 255, blue: 48 / 255),
            verticalPadding: 3
        )
    }
}

private extension View {
    func rewindFilledButtonSurface(
        isEnabled: Bool,
        isPressed: Bool,
        fontSize: CGFloat,
        enabledColor: Color,
        verticalPadding: CGFloat
    ) -> some View {
        font(.system(size: fontSize))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnabled ? enabledColor : Color.gray.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(isEnabled && isPressed ? 0.15 : 0))
                    }
            }
    }
}

private struct RewindButtonModifier: ViewModifier {
    let role: RewindButtonRole

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content.buttonStyle(.borderedProminent).controlSize(.regular).tint(.blue)
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
