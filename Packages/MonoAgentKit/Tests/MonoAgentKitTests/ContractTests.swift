// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import MonoAgentKit

struct GoldenFile: Decodable, Sendable {
  struct Fixture: Decodable, Sendable {
    var name: String
    var type: String
    var value: JSONValue
    var frame: String?
  }
  var fixtures: [Fixture]
}
func resource(_ name: String) throws -> Data {
  try Data(
    contentsOf: #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Contracts")))
}
func goldens() throws -> [GoldenFile.Fixture] {
  try JSONDecoder().decode(GoldenFile.self, from: resource("console-api.v1.fixtures")).fixtures
}
func fixture(_ name: String) throws -> Data {
  try JSONEncoder().encode(#require(goldens().first { $0.name == name }).value)
}
private func decode<T: Codable & Sendable & Equatable>(_ type: T.Type, data: Data) throws {
  let value = try JSONDecoder().decode(T.self, from: data)
  let again = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  #expect(value == again)
  let expected = try JSONDecoder().decode(JSONValue.self, from: data)
  let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  let differences = goldenDifferences(expected, encoded)
  if intentionalGoldenNullOmissions.isEmpty {
    #expect(encoded == expected, "\(T.self): \(differences.joined(separator: ", "))")
  } else {
    #expect(differences.isEmpty, "\(T.self): \(differences.joined(separator: ", "))")
  }
}
@Test func everyGoldenDecodesThroughItsMappedType() throws {
  let fixtures = try goldens()
  #expect(fixtures.count == 35)
  for fixture in fixtures {
    let data = try JSONEncoder().encode(fixture.value)
    switch fixture.type {
    case "ApiBootstrap": try decode(ApiBootstrap.self, data: data)
    case "ApiThreadPage": try decode(ApiThreadPage.self, data: data)
    case "ApiThreadDetail": try decode(ApiThreadDetail.self, data: data)
    case "ApiMessagePage": try decode(ApiMessagePage.self, data: data)
    case "ApiCreateUpload": try decode(ApiCreateUpload.self, data: data)
    case "ApiUpload": try decode(ApiUpload.self, data: data)
    case "ApiStartSubmission": try decode(ApiStartSubmission.self, data: data)
    case "ApiSubmissionReceipt": try decode(ApiSubmissionReceipt.self, data: data)
    case "ApiAsk": try decode(ApiAsk.self, data: data)
    case "ApiAnswerAsk": try decode(ApiAnswerAsk.self, data: data)
    case "ApiWakeSchedule": try decode(ApiWakeSchedule.self, data: data)
    case "ApiProject": try decode(ApiProject.self, data: data)
    case "ApiTag": try decode(ApiTag.self, data: data)
    case "ApiProviderUsage": try decode(ApiProviderUsage.self, data: data)
    case "ApiCronOverview": try decode(ApiCronOverview.self, data: data)
    case "ApiEvent": try decode(ApiEvent.self, data: data)
    case "ApiCompaction": try decode(ApiCompaction.self, data: data)
    case "ApiDeltaVectors": try decode(ApiDeltaVectors.self, data: data)
    default: Issue.record("Unmapped golden DTO: \(fixture.type)")
    }
  }
}
@Test func everyGoldenSSEFrameParsesAndDecodesAtEveryByteBoundary() throws {
  var names: Set<String> = []
  for fixture in try goldens() {
    guard let frame = fixture.frame else { continue }
    let expected = try JSONDecoder().decode(
      ApiEvent.self, from: JSONEncoder().encode(fixture.value))
    names.insert(expected.event.name)
    var parser = SSEParser()
    var frames: [SSEFrame] = []
    for byte in frame.utf8 {
      for item in try parser.feed(Data([byte])) {
        if case .frame(let value) = item { frames.append(value) }
      }
    }
    #expect(frames.count == 1)
    #expect(try EventDecoder.decode(#require(frames.first)) == .event(expected))
  }
  #expect(names == WebEvent.names)
}
@Test func routeDescriptorsMatchEveryManifestPolicy() throws {
  struct Manifest: Decodable {
    struct Route: Decodable {
      var method: String
      var path: String
      var requestType: String
      var responseType: String
      var successStatus: [Int]
      var resultStatuses: [Int]?
      var requiresClaimedOrigin: Bool
      var originPolicy: String
    }
    var routes: [Route]
  }
  let manifest = try JSONDecoder().decode(Manifest.self, from: resource("console-api.v1.routes"))
  #expect(manifest.routes.count == 78)
  #expect(manifest.routes.count == APIRoute.allCases.count)
  for (expected, route) in zip(manifest.routes, APIRoute.allCases) {
    let actual = route.descriptor
    #expect(actual.method == expected.method)
    #expect(actual.path == expected.path)
    #expect(actual.requestType == expected.requestType)
    #expect(actual.responseType == expected.responseType)
    #expect(actual.successStatus == expected.successStatus)
    #expect(actual.resultStatuses == expected.resultStatuses ?? [])
    #expect(actual.requiresClaimedOrigin == expected.requiresClaimedOrigin)
    #expect(actual.originPolicy == expected.originPolicy)
  }
}
@Test func requestOmissionNullAndValuesRoundTripExactly() throws {
  let examples = [
    "{}", "{\"model\":null,\"projectId\":null,\"context1M\":null}",
    "{\"model\":\"example/model\",\"context1M\":false,\"tagIds\":[]}",
  ]
  for example in examples {
    let before = try JSONDecoder().decode(JSONValue.self, from: Data(example.utf8))
    let request = try JSONDecoder().decode(ApiPatchThread.self, from: Data(example.utf8))
    let after = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    #expect(before == after)
  }
  let defaults = ApiPutRunDefaults(model: .null, effort: .value("high"))
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(defaults))
      == .object(["model": .null, "effort": .string("high")]))
  let create = ApiCreateThread(sourceId: "agent-fictional", model: .null)
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(create))
      == .object(["sourceId": .string("agent-fictional"), "model": .null]))
}
@Test func costUnknownIsNeverPricedZeroAndOpaqueDataIsUntouched() throws {
  #expect(CostAmount(amount: nil) == .unknown(knownSpend: nil))
  #expect(CostAmount(amount: 0) == .known(0))
  let project = try JSONDecoder().decode(ApiProject.self, from: fixture("project"))
  #expect(project.project.monthCost == .unknown(knownSpend: 0.02))
  let value = Data(
    #"{"type":"telemetry","event":"arbitrary","data":{"costUsd":null,"newField":[false,2]}}"#.utf8)
  let part = try JSONDecoder().decode(WebMessagePart.self, from: value)
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(part))
      == JSONDecoder().decode(JSONValue.self, from: value))
}
@Test func unknownFieldsAreIgnoredAndUnknownPartsRemainRepresentable() throws {
  let health = try JSONDecoder().decode(
    ApiHealth.self, from: Data(#"{"status":"ok","version":1,"push":"ok","future":true}"#.utf8))
  #expect(health.version == 1)
  let part = try JSONDecoder().decode(
    WebMessagePart.self, from: Data(#"{"type":"future-part","new":42}"#.utf8))
  guard case .unknown = part else {
    Issue.record("Expected additive fallback")
    return
  }
}

@Test func opaqueExplicitNullAndNullableMarkerValuesSurviveCodable() throws {
  let tool = try JSONDecoder().decode(
    WebToolCall.self,
    from: Data(
      #"{"toolCallId":"fictional","toolName":"Sample","status":"complete","args":null,"result":null}"#
        .utf8))
  #expect(tool.args == .null && tool.result == .null)
  let marker = try JSONDecoder().decode(
    WebConversationMarkerPart.self,
    from: Data(
      #"{"type":"conversation-marker","kind":"project","at":"2030-01-02T12:00:00Z","before":null,"after":null}"#
        .utf8))
  #expect(marker.before == .null && marker.after == .null)
}

// No blanket null removal or ignored optional fields: only explicitly listed paths may
// differ, and only when a golden null is intentionally omitted by a response encoder.
private let intentionalGoldenNullOmissions: Set<String> = []
private func goldenDifferences(_ expected: JSONValue, _ actual: JSONValue, path: String = "")
  -> [String]
{
  switch (expected, actual) {
  case (.object(let lhs), .object(let rhs)):
    return Set(lhs.keys).union(rhs.keys).sorted().flatMap { key -> [String] in
      let child = path.isEmpty ? key : path + "." + key
      if lhs[key] == .null && rhs[key] == nil && intentionalGoldenNullOmissions.contains(child) {
        return []
      }
      guard let l = lhs[key], let r = rhs[key] else { return [child] }
      return goldenDifferences(l, r, path: child)
    }
  case (.array(let lhs), .array(let rhs)) where lhs.count == rhs.count:
    return zip(lhs, rhs).flatMap { goldenDifferences($0, $1, path: path + "[]") }
  default: return expected == actual ? [] : [path]
  }
}

@Test func malformedKnownPartFallsBackLocallyWithoutFailingItsPage() throws {
  guard
    case .object(var page) = try JSONDecoder().decode(JSONValue.self, from: fixture("message-page")),
    case .array(var messages) = page["messages"], case .object(var message) = messages[0]
  else {
    Issue.record("Missing fictional page")
    return
  }
  let malformed: JSONValue = .object(["type": .string("text"), "text": .number(42)])
  let good: JSONValue = .object(["type": .string("text"), "text": .string("Following part")])
  message["parts"] = .array([malformed, good])
  messages[0] = .object(message)
  page["messages"] = .array(messages)
  let value = try JSONDecoder().decode(
    ApiMessagePage.self, from: JSONEncoder().encode(JSONValue.object(page)))
  #expect(value.messages[0].parts[0] == .unknown(malformed))
  #expect(value.messages[0].parts[0].decodingDiagnostic == .unreadableKnownKind("text"))
  #expect(value.messages[0].parts[1] == .text(.init(text: "Following part")))
}
@Test func goldenComparisonDetectsMissingOptionalFieldsIncludingNull() {
  #expect(
    goldenDifferences(.object(["knownCostUsd": .number(0.02)]), .object([:])) == ["knownCostUsd"])
  #expect(goldenDifferences(.object(["projectId": .null]), .object([:])) == ["projectId"])
}
