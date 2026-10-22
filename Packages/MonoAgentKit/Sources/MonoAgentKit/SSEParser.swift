// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct SSEFrame: Sendable, Equatable {
  public let name: String
  public let data: String
  public let id: String?
}
public enum SSEItem: Sendable, Equatable {
  case line
  case frame(SSEFrame)
  case retry(milliseconds: Int)
}
public enum StreamFailure: Error, Sendable, Equatable {
  case oversizedFrame, invalidUTF8, malformedEvent, envelopeMismatch, disconnected, watchdog,
    readyTimeout, overflow
}
/// Parses bytes, not chunks of decoded strings: even a UTF-8 scalar may span receives.
public struct SSEParser: Sendable {
  private var line: [UInt8] = []
  private var skipLF = false
  private var firstLine = true
  private var event = ""
  private var data: [String] = []
  private var id: String?
  private var frameSize = 0
  public let maxFrameBytes: Int
  public init(maxFrameBytes: Int = 2 * 1024 * 1024) { self.maxFrameBytes = max(1, maxFrameBytes) }
  public mutating func feed(_ bytes: Data) throws -> [SSEItem] {
    var output: [SSEItem] = []
    for byte in bytes {
      if skipLF {
        skipLF = false
        if byte == 10 { continue }
      }
      if byte == 10 || byte == 13 {
        if firstLine && line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        firstLine = false
        guard let text = String(bytes: line, encoding: .utf8) else {
          throw StreamFailure.invalidUTF8
        }
        output.append(.line)
        try consume(text, into: &output)
        line.removeAll(keepingCapacity: true)
        skipLF = byte == 13
      } else {
        line.append(byte)
        guard line.count + frameSize <= maxFrameBytes else { throw StreamFailure.oversizedFrame }
      }
    }
    return output
  }
  private mutating func consume(_ line: String, into output: inout [SSEItem]) throws {
    if line.isEmpty {
      if !data.isEmpty {
        output.append(
          .frame(
            .init(
              name: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)))
      }
      event = ""
      data = []
      id = nil
      frameSize = 0
      return
    }
    if line.hasPrefix(":") { return }
    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let key = String(pieces[0])
    var value = pieces.count == 2 ? String(pieces[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    switch key {
    case "data":
      data.append(value)
      frameSize += value.utf8.count + 1
    case "event":
      event = value
      frameSize += value.utf8.count
    case "id":
      if !value.contains("\0") { id = value }
      frameSize += value.utf8.count
    case "retry":
      if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let ms = Int(value) {
        output.append(.retry(milliseconds: ms))
      }
    default: break
    }
    guard frameSize <= maxFrameBytes else { throw StreamFailure.oversizedFrame }
  }
}
public enum EventDiagnostic: String, Sendable, Equatable {
  case unknownName, unsupportedVersion, unreadablePayload
}
public enum DecodedFrame: Sendable, Equatable {
  case event(ApiEvent)
  case skipped(EventDiagnostic)
  case unreadable(UnreadableEvent)
}
/// The stream remains connected. Store repairs this message/thread or marks it stale.
public struct UnreadableEvent: Sendable, Equatable {
  public let name: String
  public let threadId: String?
  public let messageId: String?
  public var diagnostic: EventDiagnostic { .unreadablePayload }
}
public enum EventDecoder {
  private struct Header: Decodable {
    var version: Int
    var type: String
  }
  public static func decode(_ frame: SSEFrame) throws -> DecodedFrame {
    guard WebEvent.names.contains(frame.name) else { return .skipped(.unknownName) }
    let data = Data(frame.data.utf8)
    let header: Header
    do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
      throw StreamFailure.malformedEvent
    }
    guard header.version == 1 else { return .skipped(.unsupportedVersion) }
    guard header.type == frame.name else { throw StreamFailure.envelopeMismatch }
    let envelope: WebEventEnvelope
    do { envelope = try JSONDecoder().decode(WebEventEnvelope.self, from: data) } catch {
      throw StreamFailure.malformedEvent
    }
    if let id = frame.id, envelope.id != id { throw StreamFailure.envelopeMismatch }
    do { return .event(try ApiEvent(envelope: envelope)) } catch {
      var messageId: String?
      if case .object(let payload) = envelope.payload, case .string(let id) = payload["messageId"] {
        messageId = id
      }
      return .unreadable(
        .init(name: envelope.type, threadId: envelope.threadId, messageId: messageId))
    }
  }
}
