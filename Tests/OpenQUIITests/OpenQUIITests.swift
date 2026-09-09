import Testing
@testable import OpenQUII

@Test func developmentVersionMatchesRelease() {
    #expect(OpenQUII.version == "0.2.2")
}
