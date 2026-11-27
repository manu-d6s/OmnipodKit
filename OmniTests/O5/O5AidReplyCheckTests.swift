//
//  O5AidReplyCheckTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class O5AidReplyCheckTests: XCTestCase {

    // MARK: - Captured setup exchanges pass

    func testCapturedExtendedSetRepliesPass() throws {
        try O5AidReplyCheck.extendedSet(O5CommLogFixtures.utcRecvBody, responsePrefix: "ES255.2=")
        try O5AidReplyCheck.extendedSet(O5CommLogFixtures.insulinHistoryRecvBody, responsePrefix: "ES2.1=")
    }

    func testCapturedSetGetRepliesPass() throws {
        try O5AidReplyCheck.setGet(O5CommLogFixtures.tdiRecvBody, request: O5CommLogFixtures.tdiSend, responsePrefix: "3.2=")
        try O5AidReplyCheck.setGet(O5CommLogFixtures.targetBgProfileRecvBody, request: O5CommLogFixtures.targetBgProfileSend, responsePrefix: "3.1=")
        try O5AidReplyCheck.setGet(O5CommLogFixtures.diaRecvBody, request: O5CommLogFixtures.diaSend, responsePrefix: "3.9=")
        try O5AidReplyCheck.setGet(O5CommLogFixtures.egvRecvBody, request: O5CommLogFixtures.egvSend, responsePrefix: "3.7=")
    }

    func testDefaultSetupCommandsPassWithEchoedValues() throws {
        let (tdi, tdiPrefix) = O5AidCommands.TdiCommand.payload()
        try O5AidReplyCheck.setGet(O5AidCommands.TdiCommand.defaultBinaryData, request: tdi, responsePrefix: tdiPrefix)

        let (dia, diaPrefix) = O5AidCommands.DiaCommand.payload()
        try O5AidReplyCheck.setGet(Data(O5AidCommands.DiaCommand.defaultValue.utf8), request: dia, responsePrefix: diaPrefix)
    }

    // MARK: - Extended SET

    func testExtendedSetRejection() {
        XCTAssertThrowsError(try O5AidReplyCheck.extendedSet(Data("-5".utf8), responsePrefix: "ES2.1=")) { error in
            guard case O5AidReplyError.rejected(let command, let code) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(command, "2.1")
            XCTAssertEqual(code, -5)
        }
        XCTAssertThrowsError(try O5AidReplyCheck.extendedSet(Data("3".utf8), responsePrefix: "ES255.2="))
    }

    func testExtendedSetMalformedReply() {
        for reply in [Data(), Data("-".utf8), Data("0x".utf8), Data(" 0".utf8), Data([0x00])] {
            XCTAssertThrowsError(try O5AidReplyCheck.extendedSet(reply, responsePrefix: "ES2.1=")) { error in
                guard case O5AidReplyError.malformedReply = error else {
                    return XCTFail("Unexpected error \(error) for \(reply.hexadecimalString)")
                }
            }
        }
    }

    // MARK: - SET+GET

    func testSetGetReadbackMismatch() {
        let (dia, diaPrefix) = O5AidCommands.DiaCommand.payload()
        XCTAssertThrowsError(try O5AidReplyCheck.setGet(Data("10".utf8), request: dia, responsePrefix: diaPrefix)) { error in
            guard case O5AidReplyError.readbackMismatch(let command, _, _) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(command, "3.9")
        }

        var tdiReply = O5AidCommands.TdiCommand.defaultBinaryData
        tdiReply[3] = 0x0F
        let (tdi, tdiPrefix) = O5AidCommands.TdiCommand.payload()
        XCTAssertThrowsError(try O5AidReplyCheck.setGet(tdiReply, request: tdi, responsePrefix: tdiPrefix))
        XCTAssertThrowsError(try O5AidReplyCheck.setGet(Data(), request: tdi, responsePrefix: tdiPrefix))
    }

    func testSetGetReplyFromDataSlice() throws {
        let (dia, diaPrefix) = O5AidCommands.DiaCommand.payload()
        let packet = Data("3.9=8".utf8)
        try O5AidReplyCheck.setGet(packet.dropFirst(4), request: dia, responsePrefix: diaPrefix)
    }

    func testSetGetRejectsRequestThatIsNotSetGet() {
        let (history, _) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
        XCTAssertThrowsError(try O5AidReplyCheck.setGet(Data("0".utf8), request: history, responsePrefix: "3.2=")) { error in
            guard case O5AidReplyError.malformedRequest = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }
}
