import Foundation

/// Time sources for session management (SPEC §6), injected so tests control
/// both clocks independently.
///
/// - `monotonicMillis()` drives the 30-min inactivity window **in-process**:
///   arbitrary epoch, never affected by user clock changes / NTP / timezone
///   travel. Resets across process restarts.
/// - `wallMillis()` (epoch millis) feeds the envelope `timings` and the
///   persisted last-activity restart fallback — never in-process expiry.
///
/// Note: intentionally shadows the stdlib `Clock` protocol inside this
/// module (internal type, unqualified references resolve here; nothing in
/// the SDK uses the stdlib one — it is iOS 16+ anyway, above our floor).
protocol Clock {
    func monotonicMillis() -> Int64
    func wallMillis() -> Int64
}
