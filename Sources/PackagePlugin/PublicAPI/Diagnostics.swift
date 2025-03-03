/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

/// Emits errors, warnings, and remarks to be shown as a result of running the
/// plugin. After emitting one or more errors, the plugin should return a
/// non-zero exit code.
public struct Diagnostics {
    
    // This prevents a Diagnostics from being instantiated by the script.
    internal init() {}
    
    /// Severity of the diagnostic.
    public enum Severity: String, Encodable {
        case error, warning, remark
    }

    /// Emits an error with a specified severity and message, and optional file path and line number.
    public static func emit(_ severity: Severity, _ message: String, file: Path? = #file, line: Int? = #line) {
        output.diagnostics.append(Diagnostic(severity: severity, message: message, file: file, line: line))
    }

    /// Emits an error with the specified message, and optional file path and line number.
    public static func error(_ message: String, file: Path? = nil, line: Int? = nil) {
        output.diagnostics.append(Diagnostic(severity: .error, message: message, file: file, line: line))
    }

    /// Emits a warning with the specified message, and optional file path and line number.
    public static func warning(_ message: String, file: Path? = nil, line: Int? = nil) {
        output.diagnostics.append(Diagnostic(severity: .warning, message: message, file: file, line: line))
    }

    /// Emits a remark with the specified message, and optional file path and line number.
    public static func remark(_ message: String, file: Path? = nil, line: Int? = nil) {
        output.diagnostics.append(Diagnostic(severity: .remark, message: message, file: file, line: line))
    }
}
