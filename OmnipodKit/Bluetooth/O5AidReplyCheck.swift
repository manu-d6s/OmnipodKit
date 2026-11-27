//
//  O5AidReplyCheck.swift
//  OmnipodKit
//

import Foundation

enum O5AidReplyError: Error, LocalizedError {
    case rejected(command: String, code: Int)
    case malformedReply(command: String, reply: Data)
    case readbackMismatch(command: String, expected: Data, reply: Data)
    case malformedRequest(command: String)

    var errorDescription: String? {
        switch self {
        case .rejected(let command, let code):
            return "O5 AID \(command) rejected by the pod (\(code))"
        case .malformedReply(let command, let reply):
            return "O5 AID \(command) unexpected reply: \(reply.hexadecimalString)"
        case .readbackMismatch(let command, let expected, let reply):
            return "O5 AID \(command) read back \(reply.hexadecimalString) instead of \(expected.hexadecimalString)"
        case .malformedRequest(let command):
            return "O5 AID \(command) request is not a SET+GET"
        }
    }
}

enum O5AidReplyCheck {

    /// An Extended SET (`SE[f].[a]=...`) replies with an ASCII result code: "0" on success,
    /// a nonzero code (e.g. "-5") when the pod rejects the value.
    static func extendedSet(_ reply: Data, responsePrefix: String) throws {
        let command = commandName(responsePrefix)
        let bytes = Array(reply)
        let digits = bytes.first == UInt8(ascii: "-") ? Array(bytes.dropFirst()) : bytes
        guard !digits.isEmpty,
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let text = String(data: reply, encoding: .ascii),
              let code = Int(text)
        else {
            throw O5AidReplyError.malformedReply(command: command, reply: reply)
        }
        guard code == 0 else {
            throw O5AidReplyError.rejected(command: command, code: code)
        }
    }

    /// A SET+GET (`S[f].[a]=value,G[f].[a]`) replies with the attribute's value after the SET,
    /// which must be the value that was sent.
    static func setGet(_ reply: Data, request: Data, responsePrefix: String) throws {
        let command = commandName(responsePrefix)
        let start = Data(("S" + responsePrefix).utf8)
        let end = Data((",G" + command).utf8)
        guard responsePrefix.hasSuffix("="),
              request.count >= start.count + end.count,
              request.starts(with: start),
              request.suffix(end.count) == end
        else {
            throw O5AidReplyError.malformedRequest(command: command)
        }
        let expected = Data(request.dropFirst(start.count).dropLast(end.count))
        guard Data(reply) == expected else {
            throw O5AidReplyError.readbackMismatch(command: command, expected: expected, reply: Data(reply))
        }
    }

    /// "3.2=" -> "3.2", "ES2.1=" -> "2.1"
    private static func commandName(_ responsePrefix: String) -> String {
        var name = responsePrefix.hasSuffix("=") ? String(responsePrefix.dropLast()) : responsePrefix
        if name.hasPrefix("ES") {
            name = String(name.dropFirst(2))
        }
        return name
    }
}
