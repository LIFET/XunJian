import SwiftUI

/// Keeps native disclosure semantics while making the complete provider header
/// the click target and respecting Reduce Motion.
struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    configuration.isExpanded.toggle()
                } else {
                    withAnimation(XunJianUI.standardAnimation) {
                        configuration.isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, XunJianUI.Size.rowIcon)
            }
        }
    }
}

struct AIProviderCollapsedStatusPresentation: Equatable {
    enum Tone: Equatable {
        case secondary
        case green
        case orange
        case red

        var color: Color {
            switch self {
            case .secondary: XunJianUI.Semantic.neutral
            case .green: XunJianUI.Semantic.success
            case .orange: XunJianUI.Semantic.warning
            case .red: XunJianUI.Semantic.danger
            }
        }

        var symbolName: String {
            switch self {
            case .secondary: "circle"
            case .green: "checkmark.circle.fill"
            case .orange: "exclamationmark.circle.fill"
            case .red: "xmark.octagon.fill"
            }
        }
    }

    let title: String
    let tone: Tone

    static func make(
        supportsOAuth: Bool,
        isCurrentProvider: Bool,
        activeMode: AIAuthenticationMode?,
        hasAPIKey: Bool,
        apiKeyState: AIConnectionState,
        hasCredentialError: Bool,
        hasUnsavedConfigurationChanges: Bool,
        oauthState: AIOAuthState
    ) -> Self {
        let apiKey = apiKeyPresentation(
            hasAPIKey: hasAPIKey,
            state: apiKeyState,
            hasCredentialError: hasCredentialError,
            hasUnsavedConfigurationChanges: hasUnsavedConfigurationChanges
        )
        guard supportsOAuth else { return apiKey }

        let oauth = Self(
            title: AppLanguage.localized(
                "OAuth：\(oauthState.localizedTitle)",
                english: "OAuth: \(oauthState.localizedTitle)"
            ),
            tone: oauthTone(for: oauthState)
        )
        if isCurrentProvider {
            switch activeMode {
            case .apiKey: return apiKey
            case .oauth: return oauth
            case nil: break
            }
        }

        return Self(
            title: "\(oauth.title) · \(apiKey.title)",
            tone: hasCredentialError
                ? .red
                : hasUnsavedConfigurationChanges ? .orange : .secondary
        )
    }

    private static func apiKeyPresentation(
        hasAPIKey: Bool,
        state: AIConnectionState,
        hasCredentialError: Bool,
        hasUnsavedConfigurationChanges: Bool
    ) -> Self {
        if hasCredentialError {
            return Self(
                title: AppLanguage.localized(
                    "API Key：文件不可用",
                    english: "API Key: File Unavailable"
                ),
                tone: .red
            )
        }
        if hasUnsavedConfigurationChanges {
            return Self(
                title: AppLanguage.localized(
                    "API Key：配置已修改，需保存后重测",
                    english: "API Key: Changed; Save and Retest"
                ),
                tone: .orange
            )
        }
        guard hasAPIKey else {
            return Self(
                title: AppLanguage.localized("API Key：未保存", english: "API Key: Not Saved"),
                tone: .secondary
            )
        }

        switch state {
        case .notConfigured:
            return Self(
                title: AppLanguage.localized("API Key：未保存", english: "API Key: Not Saved"),
                tone: .secondary
            )
        case .saved:
            return Self(
                title: AppLanguage.localized(
                    "API Key：已保存，需验证",
                    english: "API Key: Saved; Verification Required"
                ),
                tone: .orange
            )
        case .testing:
            return Self(
                title: AppLanguage.localized("API Key：正在验证", english: "API Key: Verifying"),
                tone: .orange
            )
        case .verified:
            return Self(
                title: AppLanguage.localized("API Key：已验证", english: "API Key: Verified"),
                tone: .green
            )
        case .failed:
            return Self(
                title: AppLanguage.localized(
                    "API Key：验证失败",
                    english: "API Key: Verification Failed"
                ),
                tone: .red
            )
        }
    }

    private static func oauthTone(for state: AIOAuthState) -> Tone {
        switch state {
        case .connected: .green
        case .starting, .authenticating, .signedInDisconnected, .signedInUnverified: .orange
        case .unavailable, .failed: .red
        case .statusUnknown, .disconnected: .secondary
        }
    }
}
