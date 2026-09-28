#!/usr/bin/env swift
// Usage: swift scripts/generate-invite-codes.swift [count]   (default 500)
//
// Generates random invite codes, AES-256-CBC encrypts the joined list using the
// same key as scripts/encrypt-string.swift, writes plaintext to
// invite-codes-plaintext.txt (refuses if it exists — so you don't silently
// invalidate codes you've already given out), and prints the encrypted blob to
// stdout for pasting into InviteCodeManager.swift.

import CommonCrypto
import Foundation

// MARK: - Same AES key as CloudProvider / encrypt-string.swift

let kp0: [UInt8] = [0x7D, 0x90, 0x2B, 0x95, 0x1A, 0x4D, 0xED, 0x1F, 0x01, 0xF6, 0x0F, 0x19, 0x9F, 0xDB, 0x4F, 0x45, 0x16, 0x9D, 0x02, 0x24, 0xCA, 0x10, 0x49, 0xD6, 0xF8, 0x09, 0x0C, 0x32, 0x15, 0x9E, 0xEB, 0x66]
let kp1: [UInt8] = [0xB2, 0xA0, 0xD4, 0x3A, 0x64, 0xF6, 0xBA, 0x61, 0x50, 0x4E, 0x0A, 0x00, 0x21, 0x75, 0x05, 0x36, 0xBD, 0x69, 0xF3, 0xB4, 0x07, 0x24, 0x56, 0xF7, 0x2F, 0xD1, 0x93, 0x11, 0x08, 0x3D, 0x41, 0xB4]
let kp2: [UInt8] = [0xB6, 0x27, 0x28, 0x12, 0x84, 0x94, 0xD5, 0x62, 0x6A, 0xDF, 0x20, 0xBF, 0xD3, 0x28, 0x42, 0x33, 0xC0, 0xAE, 0xF7, 0x15, 0x53, 0xC2, 0x6B, 0xF7, 0x64, 0xD8, 0x4E, 0x57, 0x6F, 0xB4, 0x12, 0x8A]
let kp3: [UInt8] = [0xE2, 0x1C, 0xBC, 0x9D, 0x63, 0x0B, 0x75, 0x66, 0x98, 0xC4, 0xCB, 0x08, 0x5A, 0x00, 0x9E, 0x28, 0xB7, 0x32, 0xE8, 0x02, 0x3F, 0x77, 0xEB, 0xC5, 0x26, 0x94, 0x29, 0x70, 0x26, 0xBB, 0x12, 0x52]

let key = Data((0..<32).map { kp0[$0] ^ kp1[$0] ^ kp2[$0] ^ kp3[$0] })

func encrypt(_ plaintext: String) -> String {
    let data = plaintext.data(using: .utf8)!
    var iv = Data(count: kCCBlockSizeAES128)
    _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, $0.baseAddress!) }

    let outLen = data.count + kCCBlockSizeAES128
    var out = Data(count: outLen)
    var written = 0

    let status = key.withUnsafeBytes { k in
        iv.withUnsafeBytes { i in
            data.withUnsafeBytes { d in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, kCCKeySizeAES256, i.baseAddress,
                            d.baseAddress, data.count, o.baseAddress, outLen, &written)
                }
            }
        }
    }

    guard status == kCCSuccess else { fatalError("Encryption failed") }
    return (iv + out.prefix(written)).base64EncodedString()
}

// MARK: - Code generator

// Alphabet excludes 0/1/I/O to avoid user confusion when reading codes
let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

func randomGroup(length: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = bytes.withUnsafeMutableBufferPointer {
        SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
    }
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
}

func randomCode() -> String {
    "FLOW-\(randomGroup(length: 4))-\(randomGroup(length: 4))-\(randomGroup(length: 4))"
}

// MARK: - Main

let count: Int = {
    if CommandLine.arguments.count > 1, let n = Int(CommandLine.arguments[1]) { return n }
    return 500
}()

let plaintextPath = "invite-codes-plaintext.txt"
if FileManager.default.fileExists(atPath: plaintextPath) {
    FileHandle.standardError.write(Data("""
        Refusing to overwrite \(plaintextPath).
        This file is the master list of codes you may have already distributed.
        If you really want to regenerate, delete the file manually first.

        """.utf8))
    exit(1)
}

var codes = Set<String>()
while codes.count < count {
    codes.insert(randomCode())
}

let sorted = codes.sorted()
let plaintext = sorted.joined(separator: "\n")

try plaintext.write(toFile: plaintextPath, atomically: true, encoding: .utf8)

let encrypted = encrypt(plaintext)

print("// Generated \(count) invite codes — paste the line below into InviteCodeManager.swift")
print("// Plaintext list saved to \(plaintextPath) — KEEP PRIVATE, BACK UP, DO NOT COMMIT")
print("")
print("private let _inviteCodesBlob = \"\(encrypted)\"")
