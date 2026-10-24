// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Testing
import UIKit

@testable import MonoAgent
@testable import MonoAgentStore

@Suite("MCP part lifecycle", .serialized)
@MainActor struct McpPartLifecycleTests {
  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
  private func setup(lean: Bool = false) async throws -> (
    AppModel, ConsoleStore, WebMessage, McpAppPart
  ) {
    let app = AppModel(scenario: .consoleOnline, storeScenario: .conversationMcpApp)
    await app.start()
    let store = try #require(app.store)
    store.selectedThreadID = DashboardFixture.openThreadID
    store.connection = .live
    if lean { store.dataMode = .lean }
    let message = try #require(store.conversations[DashboardFixture.openThreadID]?.messages.first)
    guard case .mcpApp(let part) = message.parts.first else { throw CocoaError(.coderInvalidValue) }
    return (app, store, message, part)
  }
  private func attach(_ controller: McpPartController) async throws {
    try await wait {
      controller.bridge != nil || controller.phase == .error || controller.phase == .closed
    }
    let host = try #require(controller.bridge?.host)
    host.webView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?
      .addSubview(host.webView)
    try await wait { controller.phase == .ready }
  }
  @Test func fullArrivesOnceOffscreenDestroysAndShowRefetchesWithoutAutoLoop() async throws {
    let (app, store, message, part) = try await setup()
    _ = app
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    #expect(controller.phase == .hidden && pool.activeCount == 0)
    controller.visibility(true)
    try await attach(controller)
    let old = try #require(controller.bridge?.host)
    #expect(pool.activeCount == 1)
    let cssWidth = try await old.webView.callAsyncJavaScript(
      "return window.innerWidth", arguments: [:], in: nil, contentWorld: .page)
    #expect(cssWidth as? Int == 320)
    controller.visibility(false)
    #expect(controller.bridge == nil && old.isRetired && pool.activeCount == 0)
    controller.visibility(true)
    #expect(controller.phase == .hidden && controller.bridge == nil)
    let recycled = McpPartController(part: part, message: message, store: store, pool: pool)
    recycled.visibility(true)
    #expect(recycled.phase == .hidden && recycled.bridge == nil)
    controller.open()
    try await attach(controller)
    #expect(controller.bridge?.host !== old)
    controller.hide()
    #expect(controller.phase == .hidden && pool.activeCount == 0)
    await store.stop()
  }
  @Test func leanRequiresShowAndBackgroundMemoryAndCrashRequireReopen() async throws {
    let (app, store, message, part) = try await setup(lean: true)
    _ = app
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    controller.visibility(true)
    #expect(controller.phase == .hidden && controller.bridge == nil)
    controller.open()
    try await attach(controller)
    pool.setActive(false)
    #expect(controller.phase == .closed && controller.bridge == nil)
    pool.setActive(true)
    #expect(controller.bridge == nil)
    controller.open()
    try await attach(controller)
    pool.closeAll("Memory pressure")
    #expect(controller.phase == .closed && pool.activeCount == 0)
    controller.open()
    try await attach(controller)
    let host = try #require(controller.bridge?.host)
    host.webView.policy.webViewWebContentProcessDidTerminate(host.webView)
    try await wait { controller.phase == .closed }
    #expect(host.isRetired && controller.bridge == nil && pool.activeCount == 0)
    controller.visibility(false)
    controller.visibility(true)
    #expect(controller.phase == .closed)
    await store.stop()
  }
  @Test func actualHostsNeverExceedTwoAndOldestVisibleIsEvictedWithoutRestart() async throws {
    let (app, store, original, part) = try await setup()
    _ = app
    var parts = [part]
    for id in ["garden-two", "garden-three"] {
      var next = part
      next.id = id
      parts.append(next)
    }
    var message = original
    message.parts = parts.map(WebMessagePart.mcpApp)
    let state = try #require(store.conversations[message.threadId])
    let pool = McpHostPool()
    let controllers = parts.map {
      McpPartController(part: $0, message: message, store: store, pool: pool)
    }
    controllers[0].visibility(true)
    try await attach(controllers[0])
    let oldest = try #require(controllers[0].bridge?.host)
    await store.reconciliationTask?.value
    state.record.messages = [message]
    state.publish()
    controllers[1].visibility(true)
    try await attach(controllers[1])
    #expect(pool.activeCount == 2)
    controllers[2].visibility(true)
    try await attach(controllers[2])
    #expect(pool.activeCount == 2 && oldest.isRetired && controllers[0].phase == .closed)
    #expect(controllers.filter { $0.bridge?.host?.isRetired == false }.count == 2)
    controllers[1].visibility(false)
    #expect(pool.activeCount == 1 && controllers[1].bridge == nil)
    pool.closeAll()
    #expect(pool.activeCount == 0)
    await store.stop()
  }
  @Test func admissionCapsTwoAndEvictsOffscreenBeforeOlderVisible() async throws {
    let (app, store, message, part) = try await setup(lean: true)
    _ = app
    let pool = McpHostPool()
    let older = McpPartController(part: part, message: message, store: store, pool: pool)
    let offscreen = McpPartController(part: part, message: message, store: store, pool: pool)
    let newest = McpPartController(part: part, message: message, store: store, pool: pool)
    older.visibility(true)
    newest.visibility(true)
    #expect(pool.acquire(older) && pool.acquire(offscreen) && pool.activeCount == 2)
    #expect(pool.acquire(newest) && pool.activeCount == 2)
    #expect(offscreen.phase == .closed && older.phase == .hidden)
    pool.selectionChanged("other-thread")
    #expect(pool.activeCount == 0 && older.phase == .closed && newest.phase == .closed)
    await store.stop()
  }
  @Test func timeoutNeverRestartsAndEnvironmentChangesKeepTheSameHost() async throws {
    let (app, store, message, part) = try await setup(lean: true)
    _ = app
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    controller.visibility(true)
    controller.open(timeout: .milliseconds(1))
    try await wait { controller.phase == .closed }
    #expect(controller.bridge == nil && pool.activeCount == 0)
    controller.open()
    try await attach(controller)
    let host = try #require(controller.bridge?.host)
    var environment = McpHostEnvironment()
    environment.theme = "dark"
    environment.locale = "fr-FR"
    controller.updateEnvironment(environment)
    try await wait {
      host.debugSendAttempts.contains { data in
        (try? JSONDecoder().decode(JSONValue.self, from: data))?[mcp: "params"]?[mcp: "locale"]
          == .string("fr-FR")
      }
    }
    #expect(controller.bridge?.host === host)
    #expect(McpPartController.displayHeight(1600, viewport: 600, compact: true) == 420)
    #expect(McpPartController.displayHeight(9000, viewport: 600, compact: false) == 1600)
    #expect(McpPartController.displayHeight(.nan, viewport: 600, compact: true) == 320)
    controller.hide()
    await store.stop()
  }
  @Test func identityIgnoresAccessUrlsButNotPublicationAndNativeConsentIsScoped() async throws {
    let (app, store, message, part) = try await setup()
    _ = app
    var access = part
    access.resourceUrl = "/fictional-resource"
    access.bridgeUrl = "/fictional-requests"
    #expect(
      McpPartIdentity(part: part, message: message, store: store)
        == McpPartIdentity(part: access, message: message, store: store))
    access.invocationId = "replacement"
    #expect(
      McpPartIdentity(part: part, message: message, store: store)
        != McpPartIdentity(part: access, message: message, store: store))
    let presenter = McpNativeConsent()
    let id = UUID()
    let prompt = McpConsentPrompt(
      method: "tools/call", title: "Allow?", detail: "Synthetic", argumentPreview: nil)
    let pending = Task { await presenter.confirm(prompt, requestID: id) }
    try await wait { presenter.request != nil }
    #expect(await presenter.confirm(prompt, requestID: UUID()) == false)
    presenter.cancel(requestID: UUID())
    #expect(presenter.request?.id == id)
    presenter.settle(id, allowed: true)
    #expect(await pending.value)
    #expect(await presenter.confirm(prompt, requestID: UUID()) == false)
    presenter.didDismiss()
    let cancelled = Task { await presenter.confirm(prompt, requestID: id) }
    try await wait { presenter.request != nil }
    presenter.dismiss()
    #expect(await cancelled.value == false)
    presenter.didDismiss()
    await store.stop()
  }
}
