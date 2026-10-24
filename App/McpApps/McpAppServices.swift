// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import MonoAgentStore
import UIKit

struct McpConsentPrompt: Equatable {
  let method: String
  let title: String
  let detail: String
  let argumentPreview: String?
}

@MainActor protocol McpConsentPresenting: AnyObject {
  func confirm(_ prompt: McpConsentPrompt) async -> Bool
  /// Must dismiss/settle any pending native presentation, including on scene/selection change.
  func cancel()
}
@MainActor protocol McpLinkOpening: AnyObject {
  func open(_ url: URL) async -> Bool
}
@MainActor final class McpSystemLinkOpener: McpLinkOpening {
  func open(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url, options: [:])
  }
}

@MainActor protocol McpAppRequestGateway: AnyObject {
  var isActive: Bool { get }
  var retryRequiresConsent: Bool { get }
  var onInvalidation: (@MainActor () -> Void)? { get set }
  func request(_ body: ApiMcpAppRequest) async throws -> JSONValue
  func renew() async throws
  func close()
}

/// App has no API client or console headers. This is the only production forwarding adapter.
@MainActor final class McpStoreGateway: McpAppRequestGateway {
  private weak var store: ConsoleStore?
  private let session: McpAppAccess
  var isActive: Bool { store != nil && !session.isClosed }
  var retryRequiresConsent: Bool { session.retryRequiresConsent }
  var onInvalidation: (@MainActor () -> Void)? {
    didSet { session.onClose = onInvalidation }
  }
  init(store: ConsoleStore, session: McpAppAccess) {
    self.store = store
    self.session = session
  }
  func request(_ body: ApiMcpAppRequest) async throws -> JSONValue {
    guard let store, isActive else { throw CancellationError() }
    return try await store.requestMcpApp(body, session: session)
  }
  func renew() async throws {
    guard let store, isActive else { throw CancellationError() }
    try await store.renewMcpApp(session)
  }
  func close() { store?.closeMcpApp(session) }
}

struct McpHostEnvironment {
  var theme = "light"
  var width: Double = 880
  var locale = Locale.current.identifier
  var timeZone = TimeZone.current.identifier
  var userAgent = "mono-agent iOS"
  var touch = true
  var hover = false
  func context(height: Double) -> JSONValue {
    .object([
      "theme": .string(theme == "dark" ? "dark" : "light"), "displayMode": .string("inline"),
      "availableDisplayModes": .array([.string("inline")]),
      "containerDimensions": .object([
        "maxWidth": .number(max(240, min(1400, width.isFinite ? width : 880))),
        "maxHeight": .number(max(160, min(1600, height))),
      ]),
      "locale": .string(locale), "timeZone": .string(timeZone), "userAgent": .string(userAgent),
      "platform": .string("mobile"),
      "deviceCapabilities": .object(["touch": .bool(touch), "hover": .bool(hover)]),
    ])
  }
}
