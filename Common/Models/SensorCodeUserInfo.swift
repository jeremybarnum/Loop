//
//  SensorCodeUserInfo.swift
//  Loop / WatchApp Extension (both targets)
//
//  Component A of the new-sensor workflow (ported from g7-build-next): the PHONE
//  captures a new G7 sensor's 4-digit pairing code once — prompted when its CGM
//  reports `.sensorStart` — and RELAYS it to the watch, so the watch's direct-G7
//  reader can authenticate the new sensor and run its pre-warm (bond + first slow
//  connection) at a time when a slow connection is costless. Queued via
//  `transferUserInfo`, so it survives the watch being asleep/off-wrist.
//

import Foundation

struct SensorCodeUserInfo {
    let version = 1
    let code: String        // 4-digit pairing code
    let sensorID: String    // the G7 sensor name/ID this code belongs to
    let activatedAt: Date?
}

extension SensorCodeUserInfo: RawRepresentable {
    typealias RawValue = [String: Any]

    static let name = "SensorCodeUserInfo"

    init?(rawValue: RawValue) {
        guard
            rawValue["v"] as? Int == version,
            rawValue["name"] as? String == SensorCodeUserInfo.name,
            let code = rawValue["code"] as? String,
            let sensorID = rawValue["sid"] as? String
            else {
                return nil
        }
        self.code = code
        self.sensorID = sensorID
        self.activatedAt = rawValue["act"] as? Date
    }

    var rawValue: RawValue {
        var r: RawValue = [
            "v": version,
            "name": SensorCodeUserInfo.name,
            "code": code,
            "sid": sensorID
        ]
        if let activatedAt { r["act"] = activatedAt }
        return r
    }
}
