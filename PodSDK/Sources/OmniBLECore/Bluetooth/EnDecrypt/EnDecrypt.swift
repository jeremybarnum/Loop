//
//  EnDecrypt.swift
//  OmniBLE
//
//  Created by Randall Knutson on 11/4/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift
// Modified from LoopKit/OmniBLE for watchOS port: `Data.bytes` (CryptoSwift) was
// renamed to `.bytesArray` (see Common/CryptoSwiftCompat.swift) to avoid a name
// collision with Foundation.Data.bytes: RawSpan on the Swift 6.2 toolchain.
import os.log

class EnDecrypt {
    private let MAC_SIZE = 8
    private let log = OSLog(category: "EnDecrypt")
    private let nonce: Nonce
    private let ck: Data

    init(nonce: Nonce, ck: Data) {
        self.nonce = nonce
        self.ck = ck
    }

    func decrypt(_ msg: MessagePacket, _ nonceSeq: Int) throws -> MessagePacket {
        let payload = msg.payload
        let header = msg.asData(forEncryption: false).subdata(in: 0..<16)

        let n = nonce.toData(sqn: nonceSeq, podReceiving: false)
        let ccm = CCM(iv: n.bytesArray, tagLength: MAC_SIZE, messageLength: payload.count - MAC_SIZE, additionalAuthenticatedData: header.bytesArray)
        let aes = try AES(key: ck.bytesArray, blockMode: ccm, padding: .noPadding)
        let decryptedPayload = try aes.decrypt(payload.bytesArray)
        
        var msgCopy = msg
        msgCopy.payload = Data(decryptedPayload)
        return msgCopy
    }

    func encrypt(_ headerMessage: MessagePacket, _ nonceSeq: Int) throws -> MessagePacket {
        let payload = headerMessage.payload
        let header = headerMessage.asData(forEncryption: true).subdata(in: 0..<16)

        let n = nonce.toData(sqn: nonceSeq, podReceiving: true)
        let ccm = CCM(iv: n.bytesArray, tagLength: MAC_SIZE, messageLength: payload.count, additionalAuthenticatedData: header.bytesArray)
        let aes = try AES(key: ck.bytesArray, blockMode: ccm, padding: .noPadding)
        let encryptedPayload = try aes.encrypt(payload.bytesArray)

        var msgCopy = headerMessage
        msgCopy.payload = Data(encryptedPayload)
        return msgCopy
    }
}
