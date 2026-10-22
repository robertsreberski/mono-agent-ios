// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Opaque extension data. No cost normalization or interpretation is applied inside it.
public enum JSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

/// A request field distinguishes inheritance (omitted), reset (null), and a value.
public enum InputField<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
  case omitted, null
  case value(Value)
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    self = c.decodeNil() ? .null : .value(try c.decode(Value.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .omitted:
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: "Omitted fields require a keyed container"))
    case .null: try c.encodeNil()
    case .value(let value): try c.encode(value)
    }
  }
}

extension KeyedDecodingContainer {
  public func decodeIfPresent(_ type: JSONValue.Type, forKey key: Key) throws -> JSONValue? {
    contains(key) ? try decode(type, forKey: key) : nil
  }

  public func decode<T>(_ type: InputField<T>.Type, forKey key: Key) throws -> InputField<T> {
    contains(key) ? try superDecodeField(type, forKey: key) : .omitted
  }
  private func superDecodeField<T>(_ type: InputField<T>.Type, forKey key: Key) throws
    -> InputField<T>
  {
    if try decodeNil(forKey: key) { return .null }
    return .value(try decode(T.self, forKey: key))
  }
}
extension KeyedEncodingContainer {
  public mutating func encode<T>(_ field: InputField<T>, forKey key: Key) throws {
    switch field {
    case .omitted: break
    case .null: try encodeNil(forKey: key)
    case .value(let value): try encode(value, forKey: key)
    }
  }
}

/// Missing amounts, including an explicit unknown marker, never become a priced zero.
public enum CostAmount: Sendable, Equatable {
  case known(Double)
  case unknown(knownSpend: Double?)
  public init(amount: Double?, unknown: Bool? = nil, knownSpend: Double? = nil) {
    if unknown != true, let amount, amount.isFinite, amount >= 0 {
      self = .known(amount)
    } else {
      self = .unknown(knownSpend: knownSpend)
    }
  }
}

/// Required nullable response fields must re-encode as null, not silently disappear.
/// Optional nullable request fields continue to use InputField for three-way semantics.
@propertyWrapper
public struct RequiredNullable<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable
{
  public var wrappedValue: Value?
  public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    wrappedValue = c.decodeNil() ? nil : try c.decode(Value.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
  }
}
