// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

/// The web header's notifications position. Push notifications come from the web console
/// installed as a Home Screen app; this app sends none of its own, so the control explains that
/// and opens the configured console URL in Safari. An HTTP console cannot use web push.
struct NotificationsButton: View {
  let store: ConsoleStore
  @State private var open = false
  private var insecure: Bool { store.profile.endpoint.isInsecure }

  var body: some View {
    Button("Notifications", systemImage: insecure ? "bell.slash" : "bell") { open = true }
      .buttonStyle(WebTileButtonStyle())
      .accessibilityValue(
        insecure ? "Unavailable on this HTTP console" : "Managed by the web console"
      )
      .accessibilityIdentifier("notifications-button")
      .popover(isPresented: $open, arrowEdge: .top) {
        NotificationsExplainer(endpoint: store.profile.endpoint)
          .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
          .presentationDetents([.medium, .large])
          .presentationCompactAdaptation(.sheet)
      }
  }
}

struct NotificationsExplainer: View {
  let endpoint: ConsoleEndpoint
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWebConsole) private var openWebConsole

  var body: some View {
    VStack(spacing: 0) {
      WebSheetHeader(
        "Notifications",
        subtitle: endpoint.isInsecure
          ? "Unavailable on this HTTP console" : "Delivered by the web console",
        closeIdentifier: "notifications-close"
      ) { dismiss() }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if endpoint.isInsecure {
            Text(
              "Notifications are unavailable on this HTTP console. Web push needs a secure console URL (HTTPS)."
            )
            .accessibilityIdentifier("notifications-http-copy")
            Text(
              "Connect to the console through HTTPS, then turn notifications on from the web console's bell."
            )
          } else {
            Text(
              "Push notifications come from the web console, not from this app. Open the console in Safari, add it to your Home Screen, then turn on notifications from its bell."
            )
            .accessibilityIdentifier("notifications-https-copy")
            Text("Notification settings and the devices that receive them are managed there.")
          }
        }
        .webFont(.stateBody).foregroundStyle(WebGlass.textSoft.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
      .scrollBounceBehavior(.basedOnSize)
      VStack(alignment: .leading, spacing: 8) {
        Button("Open web console") { openWebConsole(endpoint.url) }
          .designButtonStyle(.primary, placement: .floating)
          .accessibilityHint("Opens \(endpoint.origin) in Safari")
          .accessibilityIdentifier("notifications-open-web")
        Text(endpoint.origin).webFont(.optionID).foregroundStyle(WebGlass.textMuted.color)
          .lineLimit(1).truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16).padding(.vertical, 12)
      .overlay(alignment: .top) { WebHairline() }
    }
    .webSheetVeil()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notifications-explainer")
  }
}
