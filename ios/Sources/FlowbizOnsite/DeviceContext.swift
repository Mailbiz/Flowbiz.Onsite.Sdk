import Foundation

struct DeviceContext: Sendable {
    let language: String

    // A closure: the value comes from the main actor, possibly after initialize.
    let screen: @Sendable () -> String

    // Evaluated per event, so DST changes apply.
    let timezoneOffsetMinutes: @Sendable (Int64) -> Int
}
