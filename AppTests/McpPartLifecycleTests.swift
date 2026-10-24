// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import MonoAgentKit
import Observation
import SwiftUI
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
  @Test func userActionRestoresVisibilityAfterCoverWithoutScrollCallback() async throws {
    let (app, store, message, part) = try await setup()
    _ = app
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    controller.visibility(true)
    try await attach(controller)
    let old = try #require(controller.bridge?.host)
    controller.visibility(false)
    controller.hide()
    #expect(!controller.isVisible && old.isRetired)
    controller.activateAction()
    try await attach(controller)
    #expect(controller.isVisible && controller.bridge?.host !== old)
    controller.hide()
    await store.stop()
  }
  @Test func expiredConfirmedEffectDegradesAllPresentationAndReopensFreshHost() async throws {
    let (app, store, message, part) = try await setup()
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    controller.visibility(true)
    try await attach(controller)
    let old = try #require(controller.bridge?.host)
    await app.mcpScript?.expireNextTool()
    try await old.sendEnvelope(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "method": .string("fixture/command"),
          "params": .object([
            "rpc": .object([
              "jsonrpc": .string("2.0"), "id": .string("expire"), "method": .string("tools/call"),
              "params": .object(["name": .string("plan"), "arguments": .object([:])]),
            ])
          ]),
        ])))
    try await wait { pool.consent.request != nil }
    let request = try #require(pool.consent.request)
    pool.consent.didPresent(requestID: request.id)
    pool.consent.settle(request.id, allowed: true)
    pool.consent.didDismiss(requestID: request.id)
    try await wait { controller.degraded }
    #expect(controller.actionTitle == "Reopen" && controller.isError && !controller.showsWebContent)
    #expect(controller.displayedStatus.contains("App access expired. Reopen"))
    #expect(controller.phase == .ready)
    controller.activateAction()
    try await attach(controller)
    #expect(old.isRetired && controller.bridge?.host !== old && !controller.degraded)
    #expect(controller.actionTitle == "Hide" && controller.showsWebContent)
    controller.hide()
    await store.stop()
  }
  @Test func streamingParentRerendersKeepOneControllerForThePartIdentity() async throws {
    let (app, store, message, part) = try await setup(lean: true)
    _ = app
    let pool = McpHostPool()
    let state = McpStreamingRenderState(message: message)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: McpStreamingRenderFixture(state: state, part: part, store: store, pool: pool))
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await wait { pool.debugCreatedControllers == 1 }
    for index in 1...12 {
      state.message.parts = [
        .mcpApp(part), .text(.init(text: String(repeating: "Garden ", count: index))),
      ]
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(pool.debugCreatedControllers == 1)
    await store.stop()
  }
  @Test func ordinaryTranscriptRowRendersNeverConstructMcpControllersOrAcquireHosts() async throws {
    let app = AppModel(scenario: .consoleOnline, storeScenario: .conversationLong)
    await app.start()
    let store = try #require(app.store)
    await store.reconciliationTask?.value
    let conversation = try #require(store.conversations[DashboardFixture.openThreadID])
    let row = try #require(conversation.messageStates["long-40"])
    let pool = McpHostPool()
    let probe = McpPlainRenderProbe()
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: McpPlainRenderFixture(row: row, store: store, pool: pool, probe: probe))
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await wait { !probe.text.isEmpty }
    for index in 1...12 {
      let text = "Synthetic field note \(index)"
      row.message.parts = [.text(.init(text: text))]
      try await wait { probe.text == text }
      #expect(pool.debugCreatedControllers == 0 && pool.activeCount == 0)
      #expect(pool.consent.request == nil)
    }
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
    let beforePeek = try #require(controller.bridge?.host)
    pool.sceneChanged(.inactive)
    #expect(pool.isActive && controller.bridge?.host === beforePeek && !beforePeek.isRetired)
    pool.sceneChanged(.background)
    #expect(controller.phase == .closed && controller.bridge == nil)
    pool.sceneChanged(.active)
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
  @Test func cancelBeforePresentationAllowsNextPromptAndStaleDismissIsScoped() async throws {
    let presenter = McpNativeConsent()
    let prompt = McpConsentPrompt(
      method: "tools/call", title: "Allow?", detail: "Synthetic", argumentPreview: nil)
    let first = UUID()
    let second = UUID()
    let cancelled = Task { await presenter.confirm(prompt, requestID: first) }
    try await wait { presenter.request?.id == first }
    // The bridge can close before SwiftUI ever renders the sheet: no dismissal will fire.
    presenter.cancel(requestID: first)
    #expect(await cancelled.value == false)
    let next = Task { await presenter.confirm(prompt, requestID: second) }
    try await wait { presenter.request?.id == second }
    presenter.didPresent(requestID: second)
    presenter.didDismiss(requestID: first)
    #expect(presenter.request?.id == second)
    presenter.settle(second, allowed: true)
    #expect(await next.value)
    #expect(await presenter.confirm(prompt, requestID: UUID()) == false)
    presenter.didDismiss(requestID: second)
    let final = UUID()
    let resumed = Task { await presenter.confirm(prompt, requestID: final) }
    try await wait { presenter.request?.id == final }
    presenter.cancel(requestID: final)
    #expect(await resumed.value == false)
  }
  @Test func unpresentedConsentDeadlineDeclinesAndReleasesPendingRequest() async throws {
    let presenter = McpNativeConsent(presentationTimeout: .milliseconds(30))
    let prompt = McpConsentPrompt(
      method: "tools/call", title: "Allow?", detail: "Synthetic", argumentPreview: nil)
    let started = ContinuousClock.now
    let result = await presenter.confirm(prompt, requestID: UUID())
    #expect(!result && presenter.request == nil && !presenter.isPresented)
    #expect(ContinuousClock.now - started >= .milliseconds(20))
    let next = await presenter.confirm(prompt, requestID: UUID())
    #expect(!next && presenter.request == nil)
  }
  @Test func anotherNativeSheetBoundsPendingConsentAndReturnsNormalDeclineWithoutPost() async throws
  {
    let (app, store, message, part) = try await setup()
    let pool = McpHostPool()
    let controller = McpPartController(part: part, message: message, store: store, pool: pool)
    controller.visibility(true)
    try await attach(controller)
    let host = try #require(controller.bridge?.host)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let hosting = UIHostingController(
      rootView: Color.clear.modifier(McpConsentPresentation(presenter: pool.consent)))
    window.rootViewController = hosting
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
      controller.hide()
    }
    try await wait { hosting.view.window != nil && pool.consent.presentationAvailable?() == true }
    let other = UIViewController()
    other.view.backgroundColor = .systemBackground
    other.modalPresentationStyle = .pageSheet
    hosting.present(other, animated: false)
    try await wait { hosting.presentedViewController === other }
    #expect(pool.consent.presentationAvailable?() == false)
    try await host.sendEnvelope(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "method": .string("fixture/command"),
          "params": .object([
            "rpc": .object([
              "jsonrpc": .string("2.0"), "id": .string("blocked-tool"),
              "method": .string("tools/call"),
              "params": .object(["name": .string("plan"), "arguments": .object([:])]),
            ])
          ]),
        ])))
    try await wait {
      host.debugSendAttempts.contains { data in
        let rpc = try? JSONDecoder().decode(JSONValue.self, from: data)
        return rpc?[mcp: "id"] == .string("blocked-tool")
      }
    }
    let reply = try #require(
      host.debugSendAttempts.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        .first { $0[mcp: "id"] == .string("blocked-tool") })
    #expect(reply[mcp: "error"]?[mcp: "code"] == .number(-32603))
    #expect(pool.consent.request == nil && !pool.consent.isPresented)
    #expect(await app.mcpScript?.diagnostics.toolPosts == 0)
    #expect(hosting.presentedViewController === other)
    other.dismiss(animated: false)
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
    presenter.didPresent(requestID: id)
    presenter.settle(id, allowed: true)
    #expect(await pending.value)
    #expect(await presenter.confirm(prompt, requestID: UUID()) == false)
    presenter.didDismiss(requestID: id)
    let cancelled = Task { await presenter.confirm(prompt, requestID: id) }
    try await wait { presenter.request != nil }
    presenter.didPresent(requestID: id)
    presenter.dismiss()
    #expect(await cancelled.value == false)
    presenter.didDismiss(requestID: id)
    await store.stop()
  }
}

@MainActor @Observable private final class McpStreamingRenderState {
  var message: WebMessage
  init(message: WebMessage) { self.message = message }
}
private struct McpStreamingRenderFixture: View {
  let state: McpStreamingRenderState
  let part: McpAppPart
  let store: ConsoleStore
  let pool: McpHostPool
  var body: some View {
    ScrollView { McpAppPartView(part: part, message: state.message, store: store) }
      .environment(\.mcpHostPool, pool)
  }
}

@MainActor @Observable private final class McpPlainRenderProbe {
  var text = ""
}
private struct McpPlainRenderFixture: View {
  let row: TranscriptMessageState
  let store: ConsoleStore
  let pool: McpHostPool
  let probe: McpPlainRenderProbe
  var body: some View {
    ScrollView {
      TranscriptMessageView(row: row, store: store)
    }
    .environment(\.mcpHostPool, pool)
    .onAppear { probe.text = QuoteFormatting.text(of: row.message) }
    .onChange(of: row.message.parts) { _, _ in
      probe.text = QuoteFormatting.text(of: row.message)
    }
  }
}
