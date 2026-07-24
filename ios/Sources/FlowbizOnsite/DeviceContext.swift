import Foundation

/// Device-derived envelope context values (SPEC §4), injected into
/// `FlowbizCore` so tests control language/screen/timezone
/// deterministically.
///
/// `screen` is a closure because the production value is captured on the
/// main actor (`UIScreen` is main-actor-isolated) and may not be available
/// synchronously at initialize when called off-main — see
/// `Flowbiz.makeDeviceContext()`. `timezoneOffsetMinutes` is evaluated per
/// event (in **minutes**, covering half-hour zones) so DST transitions are
/// honored.
struct DeviceContext: Sendable {
    /// BCP-47 language tag, e.g. `pt-BR`.
    let language: String

    /// Physical screen size `WxH` in pixels, e.g. `1170x2532`.
    let screen: @Sendable () -> String

    /// Device UTC offset in minutes at the given wall-clock epoch millis.
    let timezoneOffsetMinutes: @Sendable (Int64) -> Int
}
