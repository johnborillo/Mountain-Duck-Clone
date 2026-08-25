import Foundation

open class XCTestCase {
    public init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
}

public func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        fatalError("🛑 Assertion failed: (\(a)) != (\(b)) — \(msg)", file: file, line: line)
    }
}

public func XCTAssertTrue(_ condition: Bool, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("🛑 Assertion failed: expected true — \(msg)", file: file, line: line)
    }
}

public func XCTAssertFalse(_ condition: Bool, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if condition {
        fatalError("🛑 Assertion failed: expected false — \(msg)", file: file, line: line)
    }
}

public func XCTAssertNil(_ value: Any?, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if value != nil {
        fatalError("🛑 Assertion failed: expected nil but got \(String(describing: value)) — \(msg)", file: file, line: line)
    }
}

public func XCTAssertNotNil(_ value: Any?, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if value == nil {
        fatalError("🛑 Assertion failed: expected non-nil — \(msg)", file: file, line: line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if a <= b {
        fatalError("🛑 Assertion failed: (\(a)) not > (\(b)) — \(msg)", file: file, line: line)
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if a < b {
        fatalError("🛑 Assertion failed: (\(a)) not >= (\(b)) — \(msg)", file: file, line: line)
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    if a > b {
        fatalError("🛑 Assertion failed: (\(a)) not <= (\(b)) — \(msg)", file: file, line: line)
    }
}

public func XCTFail(_ msg: String = "", file: StaticString = #file, line: UInt = #line) {
    fatalError("🛑 Test assertion failure: \(msg)", file: file, line: line)
}
