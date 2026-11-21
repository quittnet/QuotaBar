import Foundation

/// An absolute suite name directs CFPreferences to a plist inside check.sh's private directory.
func testPreferencesDomain() -> String {
    guard let directory = ProcessInfo.processInfo.environment["QUOTABAR_TEST_PREFERENCES"],
        directory.hasPrefix("/")
    else { preconditionFailure("Run preference checks through check.sh with a temporary preferences directory.") }
    return URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString).path
}
