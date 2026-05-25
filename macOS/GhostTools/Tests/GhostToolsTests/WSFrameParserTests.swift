import XCTest
@testable import GhostTools

final class WSFrameParserTests: XCTestCase {

    func testSingleFrameRoundTrip() {
        var parser = WSFrameParser()
        let payload: [UInt8] = Array("hello".utf8)
        parser.feed(WSFrameEncoder.encode(opcode: .binary, payload: payload, mask: true))

        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .binary)
        XCTAssertEqual(frame?.payload, payload)
        XCTAssertNil(parser.nextFrame())
    }

    func testFragmentedBinaryReassembles() {
        var parser = WSFrameParser()
        let part1: [UInt8] = Array("hello ".utf8)
        let part2: [UInt8] = Array("frag".utf8)
        let part3: [UInt8] = Array("mented".utf8)

        parser.feed(WSFrameEncoder.encode(opcode: .binary, payload: part1, mask: true, fin: false))
        XCTAssertNil(parser.nextFrame(), "incomplete message must not surface")

        parser.feed(WSFrameEncoder.encode(opcode: .continuation, payload: part2, mask: true, fin: false))
        XCTAssertNil(parser.nextFrame())

        parser.feed(WSFrameEncoder.encode(opcode: .continuation, payload: part3, mask: true, fin: true))
        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .binary)
        XCTAssertEqual(frame?.payload, part1 + part2 + part3)
    }

    func testFragmentedTextPreservesOriginalOpcode() {
        var parser = WSFrameParser()
        let part1: [UInt8] = Array(#"{"type":"#.utf8)
        let part2: [UInt8] = Array(#""resize","cols":80,"rows":24}"#.utf8)

        parser.feed(WSFrameEncoder.encode(opcode: .text, payload: part1, mask: true, fin: false))
        parser.feed(WSFrameEncoder.encode(opcode: .continuation, payload: part2, mask: true, fin: true))

        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .text)
        XCTAssertEqual(frame?.payload, part1 + part2)
    }

    func testControlFrameInterleavedBetweenFragments() {
        var parser = WSFrameParser()
        let part1: [UInt8] = [0x01, 0x02]
        let part2: [UInt8] = [0x03, 0x04]
        let pingPayload: [UInt8] = [0xAA]

        parser.feed(WSFrameEncoder.encode(opcode: .binary, payload: part1, mask: true, fin: false))
        parser.feed(WSFrameEncoder.encode(opcode: .ping, payload: pingPayload, mask: true))
        parser.feed(WSFrameEncoder.encode(opcode: .continuation, payload: part2, mask: true, fin: true))

        let ping = parser.nextFrame()
        XCTAssertEqual(ping?.opcode, .ping)
        XCTAssertEqual(ping?.payload, pingPayload)

        let data = parser.nextFrame()
        XCTAssertEqual(data?.opcode, .binary)
        XCTAssertEqual(data?.payload, part1 + part2)
    }

    func testUnexpectedContinuationProducesClose() {
        var parser = WSFrameParser()
        parser.feed(WSFrameEncoder.encode(opcode: .continuation, payload: [0x01], mask: true, fin: true))

        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .close)
    }

    func testNewDataFrameWhileFragmentedProducesClose() {
        var parser = WSFrameParser()
        parser.feed(WSFrameEncoder.encode(opcode: .binary, payload: [0x01], mask: true, fin: false))
        parser.feed(WSFrameEncoder.encode(opcode: .text, payload: [0x02], mask: true, fin: true))

        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .close)
    }

    func testFragmentedControlFrameProducesClose() {
        var parser = WSFrameParser()
        // Hand-build: FIN=0, opcode=ping, mask=0, len=0.
        parser.feed([0x09, 0x00])

        let frame = parser.nextFrame()
        XCTAssertEqual(frame?.opcode, .close)
    }
}
