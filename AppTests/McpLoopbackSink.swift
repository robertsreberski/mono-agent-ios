// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network

/// TCP HTTP and UDP ICE canaries on the same loopback port. Every connection/datagram counts,
/// even when no valid HTTP request follows (preconnect, WebSocket and TURN included).
@MainActor
final class McpLoopbackSink {
  private let tcp: NWListener
  private var udp: NWListener?
  private var connections: [NWConnection] = []
  private(set) var inboundConnections = 0
  private(set) var requests = 0
  private(set) var datagrams = 0
  private(set) var ready = false
  private(set) var udpReady = false
  var port: UInt16 { tcp.port?.rawValue ?? 0 }
  var origin: String { "http://127.0.0.1:\(port)" }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    tcp = try NWListener(using: parameters)
    tcp.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        if case .ready = state { self?.ready = true }
      }
    }
    tcp.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection, udp: false) }
    }
    tcp.start(queue: .main)
  }

  func startUDP() throws {
    guard let port = tcp.port else { throw URLError(.cannotConnectToHost) }
    let parameters = NWParameters.udp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
    let listener = try NWListener(using: parameters, on: port)
    udp = listener
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        if case .ready = state { self?.udpReady = true }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection, udp: true) }
    }
    listener.start(queue: .main)
  }

  private func accept(_ connection: NWConnection, udp: Bool) {
    inboundConnections += 1
    connections.append(connection)
    connection.start(queue: .main)
    if udp {
      connection.receiveMessage { [weak self] data, _, _, _ in
        Task { @MainActor in
          if data != nil { self?.datagrams += 1 }
          connection.cancel()
        }
      }
    } else {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        [weak self] data, _, _, _ in
        Task { @MainActor in
          if let data, !data.isEmpty { self?.requests += 1 }
          let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
          connection.send(
            content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
      }
    }
  }

  func stop() {
    tcp.cancel()
    udp?.cancel()
    for connection in connections { connection.cancel() }
    connections.removeAll()
  }
}
