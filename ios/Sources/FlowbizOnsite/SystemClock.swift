import Foundation

/// `mach_continuous_time` keeps counting through sleep, like Android's
/// `elapsedRealtime()`; `mach_absolute_time` and `DispatchTime` stop while the
/// device sleeps, so a phone asleep for an hour would resume a stale session.
/// It resets at reboot, which `SessionManager`'s wall-clock fallback covers.
struct SystemClock: Clock, Sendable {

    /// Ticks→ns (125/3 on Apple silicon); `UInt64` math overflows only after
    /// centuries of uptime.
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
