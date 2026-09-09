import XCTest
@testable import OpenQUII

final class QuiiVideoProgressTests: XCTestCase {
    private func nal(_ type: UInt8, threeBytePrefix: Bool = false) -> Data {
        Data(threeBytePrefix ? [0, 0, 1, type, 0x88] : [0, 0, 0, 1, type, 0x88])
    }

    func testOnlyConfiguredIDRStartsProgressAndSubsequentVCLRenewsIt() {
        var progress = QuiiVideoProgress()
        XCTAssertFalse(progress.observe(nal(5)))
        XCTAssertFalse(progress.observe(nal(7)))
        XCTAssertFalse(progress.observe(nal(1)))
        XCTAssertFalse(progress.observe(nal(8, threeBytePrefix: true)))
        XCTAssertFalse(progress.observe(nal(1)))
        XCTAssertTrue(progress.observe(nal(5)))
        XCTAssertTrue(progress.observe(nal(1, threeBytePrefix: true)))
        XCTAssertFalse(progress.observe(nal(9)))
        XCTAssertFalse(progress.observe(nal(6)))
        XCTAssertFalse(progress.observe(nal(7) + nal(8)))
    }

    func testConcatenatedConfigurationAndIDRAreAccepted() {
        var progress = QuiiVideoProgress()
        XCTAssertTrue(progress.observe(nal(7) + nal(8) + nal(5)))
    }

    func testEmptyForbiddenAndUnframedPayloadCannotCountAsProgress() {
        var progress = QuiiVideoProgress()
        XCTAssertFalse(progress.observe(Data()))
        XCTAssertFalse(progress.observe(Data([0, 0, 0, 1, 7])))
        XCTAssertFalse(progress.observe(Data([7, 0x88])))
        XCTAssertFalse(progress.observe(nal(0x87) + nal(8) + nal(5)))
        XCTAssertFalse(progress.observe(nal(7) + nal(0x85)))
        XCTAssertTrue(progress.observe(nal(5)))
    }
}
