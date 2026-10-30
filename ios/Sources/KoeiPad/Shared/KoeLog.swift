import Foundation
import os

/// iPad stand-in for the Mac app's KoeLog (which lives in Capture/SelectionChip.swift
/// next to AppKit). Debug builds log to the unified log; release builds are silent.
enum KoeLog {
    private static let log = Logger(subsystem: "com.readflow.ipad", category: "koe")
    static func reset() {}
    @inline(__always) static func d(_ msg: String) {
        #if DEBUG
        log.debug("\(msg, privacy: .public)")
        #endif
    }
}
