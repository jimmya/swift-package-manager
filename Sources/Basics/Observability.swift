/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Dispatch
import TSCBasic
import TSCUtility

typealias TSCDiagnostic = TSCBasic.Diagnostic

// this could become a struct when we remove the "errorsReported" pattern

// designed after https://github.com/apple/swift-log
// designed after https://github.com/apple/swift-metrics
// designed after https://github.com/apple/swift-distributed-tracing-baggage
public class ObservabilitySystem {
    public let topScope: ObservabilityScope

    /// Create an ObservabilitySystem with a handler provider providing handler such as a collector.
    public init(_ handlerProvider: ObservabilityHandlerProvider) {
        self.topScope = .init(
            description: "top scope",
            parent: .none,
            metadata: .none,
            diagnosticsHandler: handlerProvider.diagnosticsHandler
        )
    }

    /// Create an ObservabilitySystem with a single diagnostics handler.
    public convenience init(_ handler: @escaping (ObservabilityScope, Diagnostic) -> Void) {
        self.init(SingleDiagnosticsHandler(handler))
    }

    private struct SingleDiagnosticsHandler: ObservabilityHandlerProvider, DiagnosticsHandler {
        var diagnosticsHandler: DiagnosticsHandler  { self }

        let underlying: (ObservabilityScope, Diagnostic) -> Void

        init(_ underlying: @escaping (ObservabilityScope, Diagnostic) -> Void) {
            self.underlying = underlying
        }

        func handleDiagnostic(scope: ObservabilityScope, diagnostic: Diagnostic) {
            self.underlying(scope, diagnostic)
        }
    }
}

public protocol ObservabilityHandlerProvider {
    var diagnosticsHandler: DiagnosticsHandler { get }
}

// MARK: - ObservabilityScope

public final class ObservabilityScope: DiagnosticsEmitterProtocol, CustomStringConvertible {
    public let description: String
    private let parent: ObservabilityScope?
    private let metadata: ObservabilityMetadata?

    private var diagnosticsHandler: DiagnosticsHanderWrapper

    fileprivate init(
        description: String,
        parent: ObservabilityScope?,
        metadata: ObservabilityMetadata?,
        diagnosticsHandler: DiagnosticsHandler
    ) {
        self.description = description
        self.parent = parent
        self.metadata = metadata
        self.diagnosticsHandler = DiagnosticsHanderWrapper(diagnosticsHandler)
    }

    public func makeChildScope(description: String, metadata: ObservabilityMetadata? = .none) -> Self {
        let mergedMetadata = ObservabilityMetadata.mergeLeft(self.metadata, metadata)
        return .init(
            description: description,
            parent: self,
            metadata: mergedMetadata,
            diagnosticsHandler: self.diagnosticsHandler
        )
    }

    public func makeChildScope(description: String, metadataProvider: () -> ObservabilityMetadata) -> Self {
        self.makeChildScope(description: description, metadata: metadataProvider())
    }

    // diagnostics

    public func makeDiagnosticsEmitter(metadata: ObservabilityMetadata? = .none) -> DiagnosticsEmitter {
        let mergedMetadata = ObservabilityMetadata.mergeLeft(self.metadata, metadata)
        return .init(scope: self, metadata: mergedMetadata)
    }

    public func makeDiagnosticsEmitter(metadataProvider: () -> ObservabilityMetadata) -> DiagnosticsEmitter {
        self.makeDiagnosticsEmitter(metadata: metadataProvider())
    }

    // FIXME: we want to remove this functionality and move to more conventional error handling
    //@available(*, deprecated, message: "this pattern is deprecated, transition to error handling instead")
    public var errorsReported: Bool {
        self.diagnosticsHandler.errorsReported
    }

    // FIXME: we want to remove this functionality and move to more conventional error handling
    //@available(*, deprecated, message: "this pattern is deprecated, transition to error handling instead")
    public var errorsReportedInAnyScope: Bool {
        if self.errorsReported {
            return true
        }
        return parent?.errorsReportedInAnyScope ?? false
    }

    // DiagnosticsEmitterProtocol
    public func emit(_ diagnostic: Diagnostic) {
        var diagnostic = diagnostic
        diagnostic.metadata = ObservabilityMetadata.mergeLeft(self.metadata, diagnostic.metadata)
        self.diagnosticsHandler.handleDiagnostic(scope: self, diagnostic: diagnostic)
    }

    private struct DiagnosticsHanderWrapper: DiagnosticsHandler {
        private let underlying: DiagnosticsHandler
        private var _errorsReported = ThreadSafeBox<Bool>(false)

        init(_ underlying: DiagnosticsHandler) {
            self.underlying = underlying
        }

        public func handleDiagnostic(scope: ObservabilityScope, diagnostic: Diagnostic) {
            if diagnostic.severity == .error {
                self._errorsReported.put(true)
            }
            self.underlying.handleDiagnostic(scope: scope, diagnostic: diagnostic)
        }

        var errorsReported: Bool {
            self._errorsReported.get() ?? false
        }
    }
}

// MARK: - Diagnostics

public protocol DiagnosticsHandler {
    func handleDiagnostic(scope: ObservabilityScope, diagnostic: Diagnostic)
}

// helper protocol to share default behavior
public protocol DiagnosticsEmitterProtocol {
    func emit(_ diagnostic: Diagnostic)
}

extension DiagnosticsEmitterProtocol {
    public func emit(severity: Diagnostic.Severity, message: String, metadata: ObservabilityMetadata? = .none) {
        self.emit(.init(severity: severity, message: message, metadata: metadata))
    }

    public func emit(error message: String, metadata: ObservabilityMetadata? = .none) {
        self.emit(.init(severity: .error, message: message, metadata: metadata))
    }

    public func emit(error message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) {
        self.emit(error: message.description, metadata: metadata)
    }

    public func emit(_ error: Error, metadata: ObservabilityMetadata? = .none) {
        var metadata = metadata
        // FIXME: this brings in the TSC API still
        if let errorProvidingLocation = error as? DiagnosticLocationProviding, let diagnosticLocation = errorProvidingLocation.diagnosticLocation {
            metadata = metadata ?? ObservabilityMetadata()
            metadata?.legacyDiagnosticLocation = .init(diagnosticLocation)
        }

        let message: String
        // FIXME: this brings in the TSC API still
        // FIXME: string interpolation seems brittle
        if let diagnosticData = error as? DiagnosticData {
            message = "\(diagnosticData)"
        } else if let convertible = error as? DiagnosticDataConvertible {
            message = "\(convertible.diagnosticData)"
        } else {
            message = "\(error)"
        }

        self.emit(severity: .error, message: message, metadata: metadata)
    }

    public func emit(warning message: String, metadata: ObservabilityMetadata? = .none) {
        self.emit(severity: .warning, message: message, metadata: metadata)
    }

    public func emit(warning message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) {
        self.emit(warning: message.description, metadata: metadata)
    }

    public func emit(info message: String, metadata: ObservabilityMetadata? = .none) {
        self.emit(severity: .info, message: message, metadata: metadata)
    }

    public func emit(info message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) {
        self.emit(info: message.description, metadata: metadata)
    }

    public func emit(debug message: String, metadata: ObservabilityMetadata? = .none) {
        self.emit(severity: .debug, message: message, metadata: metadata)
    }

    public func emit(debug message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) {
        self.emit(debug: message.description, metadata: metadata)
    }

    public func trap<T>(_ closure: () throws -> T) -> T? {
        do  {
            return try closure()
        } catch Diagnostics.fatalError {
            // FIXME: (diagnostics) deprecate this with Diagnostics.fatalError
            return nil
        } catch {
            self.emit(error)
            return nil
        }
    }
}

// TODO: consider using @autoclosure to delay potentially expensive evaluation of data when some diagnostics may be filtered out
public struct DiagnosticsEmitter: DiagnosticsEmitterProtocol {
    private let scope: ObservabilityScope
    private let metadata: ObservabilityMetadata?

    fileprivate init(scope: ObservabilityScope, metadata: ObservabilityMetadata?) {
        self.scope = scope
        self.metadata = metadata
    }

    public func emit(_ diagnostic: Diagnostic) {
        var diagnostic = diagnostic
        diagnostic.metadata = ObservabilityMetadata.mergeLeft(self.metadata, diagnostic.metadata)
        self.scope.emit(diagnostic)
    }
}

public struct Diagnostic: CustomStringConvertible, Equatable {
    public let severity: Severity
    public let message: String
    public internal (set) var metadata: ObservabilityMetadata?

    public init(severity: Severity, message: String, metadata: ObservabilityMetadata?) {
        self.severity = severity
        self.message = message
        self.metadata = metadata
    }

    public var description: String {
        return "[\(self.severity)]: \(self.message)"
    }

    public static func error(_ message: String, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .error, message: message, metadata: metadata)
    }

    public static func error(_ message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .error, message: message.description, metadata: metadata)
    }

    public static func warning(_ message: String, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .warning, message: message, metadata: metadata)
    }

    public static func warning(_ message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .warning, message: message.description, metadata: metadata)
    }

    public static func info(_ message: String, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .info, message: message, metadata: metadata)
    }

    public static func info(_ message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .info, message: message.description, metadata: metadata)
    }

    public static func debug(_ message: String, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .debug, message: message, metadata: metadata)
    }

    public static func debug(_ message: CustomStringConvertible, metadata: ObservabilityMetadata? = .none) -> Self {
        Self(severity: .debug, message: message.description, metadata: metadata)
    }

    public enum Severity: Equatable {
        case error
        case warning
        case info
        case debug
    }
}

// MARK: - ObservabilityMetadata

/// Provides type-safe access to the ObservabilityMetadata's values.
/// This API should ONLY be used inside of accessor implementations.
///
/// End users should use "accessors" the key's author MUST define rather than using this subscript, following this pattern:
///
///     extension ObservabilityMetadata {
///       var testID: String? {
///         get {
///           self[TestIDKey.self]
///         }
///         set {
///           self[TestIDKey.self] = newValue
///         }
///       }
///     }
///
///     enum TestIDKey: ObservabilityMetadataKey {
///         typealias Value = String
///     }
///
/// This is in order to enforce a consistent style across projects and also allow for fine grained control over
/// who may set and who may get such property. Just access control to the Key type itself lacks such fidelity.
///
/// Note that specific baggage and context types MAY (and usually do), offer also a way to set baggage values,
/// however in the most general case it is not required, as some frameworks may only be able to offer reading.

// FIXME: we currently requires that Value conforms to CustomStringConvertible which sucks
// ideally Value would conform to Equatable but that has generic requirement
// luckily, this is about to change so we can clean this up soon
public struct ObservabilityMetadata: Equatable, CustomDebugStringConvertible {
    public typealias Key = ObservabilityMetadataKey

    private var _storage = [AnyKey: CustomStringConvertible]()

    public init() {}

    public subscript<Key: ObservabilityMetadataKey>(_ key: Key.Type) -> Key.Value? {
        get {
            guard let value = self._storage[AnyKey(key)] else { return nil }
            // safe to force-cast as this subscript is the only way to set a value.
            return (value as! Key.Value)
        }
        set {
            self._storage[AnyKey(key)] = newValue
        }
    }

    /// The number of items in the baggage.
    public var count: Int {
        self._storage.count
    }

    /// A Boolean value that indicates whether the baggage is empty.
    public var isEmpty: Bool {
        self._storage.isEmpty
    }

    /// Iterate through all items in this `ObservabilityMetadata` by invoking the given closure for each item.
    ///
    /// The order of those invocations is NOT guaranteed and should not be relied on.
    ///
    /// - Parameter body: The closure to be invoked for each item stored in this `ObservabilityMetadata`,
    /// passing the type-erased key and the associated value.
    public func forEach(_ body: (AnyKey, CustomStringConvertible) throws -> Void) rethrows {
        try self._storage.forEach { key, value in
            try body(key, value)
        }
    }

    public func merging(_ other: ObservabilityMetadata) -> ObservabilityMetadata {
        var merged = ObservabilityMetadata()
        self.forEach { (key, value) in
            merged._storage[key] = value
        }
        other.forEach { (key, value) in
            merged._storage[key] = value
        }
        return merged
    }

    public var debugDescription: String {
        var items = [String]()
        self._storage.forEach { key, value in
            items.append("\(key.keyType.self): \(value.description)")
        }
        return items.joined(separator: ", ")
    }

    // FIXME: this currently requires that Value conforms to CustomStringConvertible which sucks
    // ideally Value would conform to Equatable but that has generic requirement
    // luckily, this is about to change so we can clean this up soon
    public static func == (lhs: ObservabilityMetadata, rhs: ObservabilityMetadata) -> Bool {
        if lhs.count != rhs.count {
            return false
        }

        var equals = true
        lhs.forEach { (key, value) in
            if rhs._storage[key]?.description != value.description {
                equals = false
                return
            }
        }

        return equals
    }

    fileprivate static func mergeLeft(_ lhs: ObservabilityMetadata?, _ rhs: ObservabilityMetadata?) -> ObservabilityMetadata? {
        switch (lhs, rhs) {
        case (.none, .none):
            return .none
        case (.some(let left), .some(let right)):
            return left.merging(right)
        case (.some(let left), .none):
            return left
        case (.none, .some(let right)):
            return right
        }
    }

    //@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
    public func droppingLegacyKeys() -> ObservabilityMetadata? {
        var metadata = ObservabilityMetadata()
        self.forEach { (key, value) in
            if key.keyType == LegacyLocationKey.self {
                return
            }
            if key.keyType == LegacyDataKey.self {
                return
            }
            metadata._storage[key] = value
        }
        return metadata.isEmpty ? .none : metadata
    }

    /// A type-erased `ObservabilityMetadataKey` used when iterating through the `ObservabilityMetadata` using its `forEach` method.
    public struct AnyKey {
        /// The key's type represented erased to an `Any.Type`.
        public let keyType: Any.Type

        init<Key: ObservabilityMetadataKey>(_ keyType: Key.Type) {
            self.keyType = keyType
        }
    }
}

public protocol ObservabilityMetadataKey {
    /// The type of value uniquely identified by this key.
    associatedtype Value: CustomStringConvertible
}

extension ObservabilityMetadata.AnyKey: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.keyType) == ObjectIdentifier(rhs.keyType)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.keyType))
    }
}

// MARK: - Compatibility with TSC Diagnostics APIs

//@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension ObservabilityScope {
    public func makeDiagnosticsEngine() -> DiagnosticsEngine {
        return .init(handlers: [{ Diagnostic($0).map{ self.diagnosticsHandler.handleDiagnostic(scope: self, diagnostic: $0) } }])
    }
}

//@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension Diagnostic {
    init?(_ diagnostic: TSCDiagnostic) {
        var metadata = ObservabilityMetadata()
        if !(diagnostic.location is UnknownLocation) {
            metadata.legacyDiagnosticLocation = .init(diagnostic.location)
        }
        metadata.legacyDiagnosticData = .init(diagnostic.data)

        switch diagnostic.behavior {
        case .error:
            self = .error(diagnostic.message.text, metadata: metadata)
        case .warning:
            self = .warning(diagnostic.message.text, metadata: metadata)
        case .note:
            self = .info(diagnostic.message.text, metadata: metadata)
        case .remark:
            self = .info(diagnostic.message.text, metadata: metadata)
        case .ignored:
            return nil
        }
    }
}

@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension ObservabilitySystem {
    public convenience init(diagnosticEngine: DiagnosticsEngine) {
        self.init(DiagnosticsEngineAdapter(diagnosticEngine: diagnosticEngine))
    }

    private struct DiagnosticsEngineAdapter: ObservabilityHandlerProvider, DiagnosticsHandler {
        let diagnosticEngine: DiagnosticsEngine

        var diagnosticsHandler: DiagnosticsHandler { self }

        func handleDiagnostic(scope: ObservabilityScope, diagnostic: Diagnostic) {
            diagnosticEngine.emit(.init(diagnostic))
        }
    }
}

@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension TSCDiagnostic {
    init(_ diagnostic: Diagnostic) {
        let location: DiagnosticLocation
        if let legacyLocation = diagnostic.metadata?.legacyDiagnosticLocation {
            location = legacyLocation.underlying
        } else {
            location = UnknownLocation.location
        }

        let data: DiagnosticData
        if let legacyData = diagnostic.metadata?.legacyDiagnosticData {
            data = legacyData.underlying
        } else {
            data = StringDiagnostic(diagnostic.message)
        }

        switch diagnostic.severity {
        case .error:
            self = .init(message: .error(data), location: location)
        case .warning:
            self = .init(message: .warning(data), location: location)
        case .info:
            self = .init(message: .note(data), location: location)
        case .debug:
            self = .init(message: .note(data), location: location)
        }
    }
}

//@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension ObservabilityMetadata {
    public var legacyDiagnosticLocation: DiagnosticLocationWrapper? {
        get {
            self[LegacyLocationKey.self]
        }
        set {
            self[LegacyLocationKey.self] = newValue
        }
    }

    private enum LegacyLocationKey: Key {
        typealias Value = DiagnosticLocationWrapper
    }

    public struct DiagnosticLocationWrapper: CustomStringConvertible {
        let underlying: DiagnosticLocation

        public init (_ underlying: DiagnosticLocation) {
            self.underlying = underlying
        }

        public var description: String {
            self.underlying.description
        }
    }
}

//@available(*, deprecated, message: "temporary for transition DiagnosticsEngine -> DiagnosticsEmitter")
extension ObservabilityMetadata {
    var legacyDiagnosticData: DiagnosticDataWrapper? {
        get {
            self[LegacyDataKey.self]
        }
        set {
            self[LegacyDataKey.self] = newValue
        }
    }

    private enum LegacyDataKey: Key {
        typealias Value = DiagnosticDataWrapper
    }

    struct DiagnosticDataWrapper: CustomStringConvertible {
        let underlying: DiagnosticData

        public init (_ underlying: DiagnosticData) {
            self.underlying = underlying
        }

        public var description: String {
            self.underlying.description
        }
    }
}
