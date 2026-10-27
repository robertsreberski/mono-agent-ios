// SPDX-License-Identifier: GPL-3.0-only
import MonoAgentDesign
import MonoAgentKit
import MonoAgentStore
import SwiftUI

struct CronConfigView: View {
  let config: WebChannelConfigView
  let close: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      WebSheetHeader(
        ProviderPresentation.boundedText(config.label), subtitle: "Redacted agent view",
        closeLabel: "Close", closeIdentifier: "cron-config-close", onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(config.fields, id: \.id) { field in
            VStack(alignment: .leading, spacing: 5) {
              Text(ProviderPresentation.boundedText(field.label)).webFont(.eyebrow)
              Text(
                field.redacted == true ? "••••••••" : ProviderPresentation.boundedText(field.value)
              )
              .webFont(.code).textSelection(.enabled)
              Text(
                ProviderPresentation.boundedText(field.source)
                  + (field.redacted == true ? " · redacted" : "")
              )
              .webFont(.system).foregroundStyle(WebGlass.textMuted.color)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }.padding(20)
      }
    }.webSheetVeil().presentationDetents([.medium, .large])
      .accessibilityElement(children: .contain).accessibilityIdentifier("cron-config-view")
  }
}
