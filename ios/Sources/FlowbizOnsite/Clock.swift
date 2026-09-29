import Foundation

/// Shadows the stdlib `Clock` (iOS 16+, unused here) inside the module.
protocol Clock {
    /// Arbitrary epoch, immune to wall-clock changes, reset on restart: the
    /// only input to in-process session expiry.
    func monotonicMillis() -> Int64
    /// Epoch millis: envelope `timings` and the persisted restart fallback.
    func wallMillis() -> Int64
}
