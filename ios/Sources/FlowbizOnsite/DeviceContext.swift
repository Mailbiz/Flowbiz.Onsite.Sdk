import Foundation

struct DeviceContext: Sendable {
    /// BCP-47 language tag, e.g. `pt-BR`.
    let language: String

    /// Physical pixels `WxH`, e.g. `1170x2532`. A closure: the value comes
    /// from the main actor, possibly after initialize.
    let screen: @Sendable () -> String

    /// UTC offset in minutes at the given wall epoch millis, evaluated per
    /// event so DST changes apply.
    let timezoneOffsetMinutes: @Sendable (Int64) -> Int
}
