import Foundation
import os

/// Unified logging (Console.app, subsystem com.tommyyau.wisprlocal).
///
/// SEC-1 (STRUCTURAL): NO dictated content ever reaches the unified log — not raw/final text,
/// cleanup candidates, guard payloads, snippets or dictionary entries. Log verdict KINDS, outcome
/// names, counts, durations and error descriptions only. Messages are logged `.public` because
/// they must be useful in a pasted bug report, so the caller is responsible for content:
/// `LogHygieneTests` scans every `Log.`/`logger.` call in Sources and fails on interpolation of
/// content-bearing identifiers (text/raw/final/transcript/candidate/…).
public enum Log {
    static let logger = Logger(subsystem: AppPaths.bundleID, category: "app")
    public static func info(_ s: String) { logger.info("\(s, privacy: .public)") }
    public static func warning(_ s: String) { logger.warning("\(s, privacy: .public)") }
    public static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
    /// Persisted by the unified log (info is memory-only): for once-per-session diagnostics that
    /// must still be readable hours later with `log show` (e.g. the Fn poll's armed/blind status).
    public static func notice(_ s: String) { logger.notice("\(s, privacy: .public)") }
}

import Synchronization

/// Thread-safe value read live from non-main contexts (e.g. a setting read per cleanup call).
public final class LiveValue<T: Sendable>: Sendable {
    private let m: Mutex<T>
    public init(_ v: T) { m = Mutex(v) }
    public var value: T {
        get { m.withLock { $0 } }
    }
    public func set(_ v: T) { m.withLock { $0 = v } }
}
