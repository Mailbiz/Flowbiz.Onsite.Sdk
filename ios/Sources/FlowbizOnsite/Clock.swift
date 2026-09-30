import Foundation

// Shadows the stdlib Clock (iOS 16+) inside the module.
protocol Clock {
    func monotonicMillis() -> Int64
    func wallMillis() -> Int64
}
