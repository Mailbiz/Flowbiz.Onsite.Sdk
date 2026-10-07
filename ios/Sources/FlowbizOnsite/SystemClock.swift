import Foundation

// mach_continuous_time, not DispatchTime or mach_absolute_time: those stop while the device sleeps.
struct SystemClock: Clock, Sendable {

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
