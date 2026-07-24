import Foundation

/// Real device clocks.
///
/// The monotonic source is `mach_continuous_time()`: monotonic since boot,
/// immune to wall-clock/NTP/timezone changes, and — crucially — **keeps
/// counting through sleep**, matching Android's `elapsedRealtime()` so the
/// 30-min session window behaves identically on both platforms. The more
/// common `mach_absolute_time` / `CLOCK_UPTIME_RAW` / `DispatchTime.now()`
/// family **stops while the device sleeps** on Apple platforms (the
/// asymmetry called out in `AndroidClock.kt`): with those, a phone asleep in
/// a pocket for an hour would resume its stale session instead of rotating.
///
/// `mach_continuous_time` resets at reboot; the persisted wall-clock
/// last-activity fallback in `SessionManager` covers restarts and reboots
/// alike. Available since iOS 10 / macOS 10.12 — under both floors.
struct SystemClock: Clock, Sendable {

    /// Ticks→nanoseconds conversion factors (1/1 on Intel, 125/3 on Apple
    /// silicon). Cached once; `UInt64` math overflows only after centuries
    /// of uptime.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func monotonicMillis() -> Int64 {
        let (numer, denom) = Self.timebase
        return Int64(mach_continuous_time() * numer / denom / 1_000_000)
    }

    func wallMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
