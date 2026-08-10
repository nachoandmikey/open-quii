import Testing
@testable import OpenQUII

@Test func developmentVersionIsPresent() {
    #expect(!OpenQUII.version.isEmpty)
}
