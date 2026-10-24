// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Darwin
  import Foundation
  import os

  /// Opt-in synthetic-scenario counters. These never participate in Observation.
  @MainActor enum PerformanceProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--performance-probe")
    private static let logger = Logger(subsystem: "org.example.MonoAgent", category: "Performance")
    struct BodyCounts {
      private(set) var values: [String: Int] = [:]
      mutating func record(_ name: String) { values[name, default: 0] += 1 }
      mutating func reset() { values.removeAll() }
    }
    private static var counts = BodyCounts()
    static func body(_ name: String) {
      guard enabled else { return }
      counts.record(name)
    }
    static func measure(refresh: @MainActor () async -> Void = {}) async {
      guard enabled else { return }
      // Exclude initial composition, then measure a fixed idle/streaming window.
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      counts.reset()
      let start = mainCPU()
      let started = ContinuousClock.now
      if ProcessInfo.processInfo.arguments.contains("--performance-dashboard-refresh") {
        await refresh()
      }
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      let cpu = mainCPU() - start
      let values = counts.values.keys.sorted().map { "\($0)=\(counts.values[$0, default: 0])" }
        .joined(
          separator: ",")
      logger.notice(
        "PERF_WINDOW seconds=\(started.duration(to: .now).description, privacy: .public) mainCPU=\(cpu, privacy: .public) bodies=\(values, privacy: .public)"
      )
    }
    private static func mainCPU() -> Double {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
      let thread = mach_thread_self()
      defer { mach_port_deallocate(mach_task_self_, thread) }
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      guard result == KERN_SUCCESS else { return .nan }
      return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
  }
#endif
