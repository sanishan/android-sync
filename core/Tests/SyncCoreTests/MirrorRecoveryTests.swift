import XCTest
@testable import SyncCore

final class MirrorRecoveryTests: XCTestCase {
    func testDecoderDropsDependentsUntilAKeyFrameAfterCongestion() throws {
        var gate = H264DecodeGate(limit: 2)
        XCTAssertNil(gate.reserve(keyFrame: false))
        let first = try XCTUnwrap(gate.reserve(keyFrame: true))
        let second = try XCTUnwrap(gate.reserve(keyFrame: false))
        XCTAssertNil(gate.reserve(keyFrame: false))
        XCTAssertEqual(gate.pending,2)
        gate.finish(first)
        XCTAssertNil(gate.reserve(keyFrame: false))
        gate.finish(second)
        XCTAssertNotNil(gate.reserve(keyFrame: true))
        XCTAssertNotNil(gate.reserve(keyFrame: false))
        XCTAssertFalse(gate.waitingForKeyFrame)
    }

    func testDecoderResetInvalidatesAlreadyQueuedFrames() throws {
        var gate = H264DecodeGate()
        let previous = try XCTUnwrap(gate.reserve(keyFrame: true))
        gate.reset()
        XCTAssertNotEqual(previous,gate.generation)
        XCTAssertNil(gate.reserve(keyFrame: false))
        let current = try XCTUnwrap(gate.reserve(keyFrame: true))
        gate.finish(previous)
        XCTAssertEqual(gate.pending,1)
        gate.finish(current)
        XCTAssertEqual(gate.pending,0)
    }

    func testKeepaliveDoesNotDependOnVideoFrameCount() {
        var health = MirrorStreamHealth(); health.start(at: 10)
        for second in 10...55 { XCTAssertTrue(health.feedbackDue(at: Double(second))) }
        XCTAssertFalse(health.feedbackDue(at: 55.5))
    }

    func testFrozenDisplayRequestsRateLimitedRecoveryWithoutRestart() {
        var health = MirrorStreamHealth(); health.start(at: 10)
        XCTAssertFalse(health.recoveryDue(at: 11.9))
        XCTAssertTrue(health.recoveryDue(at: 12))
        XCTAssertFalse(health.recoveryDue(at: 12.5))
        XCTAssertTrue(health.recoveryDue(at: 13))
        health.displayedFrame(at: 13.1)
        XCTAssertFalse(health.recoveryDue(at: 14))
        XCTAssertTrue(health.recoveryDue(at: 14,decoderFailed: true))
        XCTAssertFalse(health.recoveryDue(at: 14.5,decoderFailed: true))
    }
}
