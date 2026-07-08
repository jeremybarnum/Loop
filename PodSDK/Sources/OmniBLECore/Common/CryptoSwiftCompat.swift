//
//  CryptoSwiftCompat.swift
//  OmniBLECore
//
//  Added for the watchOS port. On the Swift 6.2 / recent-SDK toolchain,
//  Foundation's `Data` gained a `var bytes: RawSpan` property which now
//  shadows CryptoSwift's `Data.bytes -> [UInt8]` extension, breaking the
//  crypto call sites (EnDecrypt, KeyExchange, Milenage). Those `.bytes`
//  references were rewritten to `.bytesArray`, defined here, to
//  unambiguously produce a `[UInt8]`.
//

import Foundation

extension Data {
    var bytesArray: [UInt8] {
        return [UInt8](self)
    }
}
