//
//  WCSession.swift
//  Loop
//
//  Created by Nate Racklyeft on 9/20/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import LoopCore
import WatchConnectivity
import os.log


enum MessageError: Error {
    case activation
    case decoding
    case reachability
    case send(Error)
}

enum WCSessionMessageResult<T> {
    case success(T)
    case failure(MessageError)
}

private let log = OSLog(category: "WCSession Extension")

extension WCSession {
    func sendPotentialCarbEntryMessage(_ carbEntry: PotentialCarbEntryUserInfo, replyHandler: @escaping (WatchContext) -> Void, errorHandler: @escaping (Error) -> Void) throws {
        guard activationState == .activated else {
            throw MessageError.activation
        }

        // Was `log; return` — it returned WITHOUT calling replyHandler OR errorHandler and
        // without throwing, so the caller's `isComputingRecommendedBolus = true` was never
        // cleared and the bolus screen sat on "REC: Calculating…" forever with no timeout and
        // no error. That is the on-wrist hang (2026-08-04): it only "recovered" because the
        // context observer re-fires this call every loop cycle, so it cleared whenever the
        // phone happened to come back. Throw like the other reachability guards in this file
        // (sendSettingsUpdateMessage :81, sendContextRequestMessage :167) so the caller's
        // existing catch clears the spinner and surfaces the failure.
        guard isReachable else {
            log.default("sendPotentialCarbEntryMessage: Phone is unreachable")
            throw MessageError.reachability
        }

        sendMessage(carbEntry.rawValue,
            replyHandler: { reply in
                guard let context = WatchContext(rawValue: reply as WatchContext.RawValue) else {
                    log.error("sendPotentialCarbEntryMessage: could not decode reply: %{public}@", reply)
                    errorHandler(MessageError.decoding)
                    return
                }

                replyHandler(context)
            },
            errorHandler: { error in
                log.error("sendPotentialCarbEntryMessage: message send failed with error: %{public}@", String(describing: error))
                errorHandler(error)
            }
        )
    }

    func sendBolusMessage(_ userInfo: SetBolusUserInfo, completionHandler: @escaping (Error?) -> Void) throws {
        guard activationState == .activated else {
            throw MessageError.activation
        }

        guard isReachable else {
            throw MessageError.reachability
        }

        sendMessage(userInfo.rawValue,
            replyHandler: { reply in
                completionHandler(nil)
            },
            errorHandler: { error in
                log.info("sendBolusMessage failure: %{public}@", error.localizedDescription)
                completionHandler(error)
            }
        )
    }

    func sendSettingsUpdateMessage(_ userInfo: LoopSettingsUserInfo, completionHandler: @escaping (Result<WatchContext>) -> Void) throws {
        guard activationState == .activated else {
            throw MessageError.activation
        }

        guard isReachable else {
            throw MessageError.reachability
        }

        sendMessage(userInfo.rawValue, replyHandler: { (reply) in
            if let context = WatchContext(rawValue: reply) {
                completionHandler(.success(context))
            } else {
                completionHandler(.failure(MessageError.decoding))
            }
        }, errorHandler: { (error) in
            completionHandler(.failure(error))
        })
    }

    func sendCarbBackfillRequestMessage(_ userInfo: CarbBackfillRequestUserInfo, completionHandler: @escaping (WCSessionMessageResult<WatchHistoricalCarbs>) -> Void) {
        log.default("sendCarbBackfillRequestMessage: since %{public}@", String(describing: userInfo.startDate))

        // Backfill is optional so we ignore any errors
        guard activationState == .activated else {
            log.error("sendCarbBackfillRequestMessage failed: not activated")
            completionHandler(.failure(.activation))
            return
        }

        guard isReachable else {
            log.error("sendCarbBackfillRequestMessage failed: not reachable")
            completionHandler(.failure(.reachability))
            return
        }

        sendMessage(userInfo.rawValue,
                    replyHandler: { reply in
                        if let context = WatchHistoricalCarbs(rawValue: reply as WatchHistoricalCarbs.RawValue) {
                            log.default("sendCarbBackfillRequestMessage succeeded with %d samples", context.objects.count)
                            completionHandler(.success(context))
                        } else {
                            log.error("sendCarbBackfillRequestMessage failed: could not decode reply %{public}@", reply)
                            completionHandler(.failure(.decoding))
                        }
        },
                    errorHandler: { error in
                        log.error("sendCarbBackfillRequestMessage error: %{public}@", String(describing: error))
                        completionHandler(.failure(.send(error)))
        }
        )
    }

    func sendGlucoseBackfillRequestMessage(_ userInfo: GlucoseBackfillRequestUserInfo, completionHandler: @escaping (WCSessionMessageResult<WatchHistoricalGlucose>) -> Void) {
        log.default("sendGlucoseBackfillRequestMessage: since %{public}@", String(describing: userInfo.startDate))

        // Backfill is optional so we ignore any errors
        guard activationState == .activated else {
            log.error("sendGlucoseBackfillRequestMessage failed: not activated")
            completionHandler(.failure(.activation))
            return
        }

        guard isReachable else {
            log.error("sendGlucoseBackfillRequestMessage failed: not reachable")
            completionHandler(.failure(.reachability))
            return
        }

        sendMessage(userInfo.rawValue,
            replyHandler: { reply in
                if let context = WatchHistoricalGlucose(rawValue: reply as WatchHistoricalGlucose.RawValue) {
                    log.default("sendGlucoseBackfillRequestMessage succeeded with %d samples", context.samples.count)
                    completionHandler(.success(context))
                } else {
                    log.error("sendGlucoseBackfillRequestMessage failed: could not decode reply %{public}@", reply)
                    completionHandler(.failure(.decoding))
                }
            },
            errorHandler: { error in
                log.error("sendGlucoseBackfillRequestMessage error: %{public}@", String(describing: error))
                completionHandler(.failure(.send(error)))
            }
        )
    }
    
    func sendContextRequestMessage(_ userInfo: WatchContextRequestUserInfo, completionHandler: @escaping (Result<WatchContext>) -> Void) throws {
        guard activationState == .activated else {
            throw MessageError.activation
        }

        guard isReachable else {
            throw MessageError.reachability
        }

        sendMessage(userInfo.rawValue, replyHandler: { (reply) in
            if let context = WatchContext(rawValue: reply) {
                completionHandler(.success(context))
            } else {
                completionHandler(.failure(MessageError.decoding))
            }
        }, errorHandler: { (error) in
            completionHandler(.failure(error))
        })
    }
}
