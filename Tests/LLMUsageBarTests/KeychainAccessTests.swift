import Foundation
import Security
import XCTest
@testable import LLMUsageBar

final class KeychainAccessTests: XCTestCase {
    func testInteractionDisabledDuringOperationAndRestoredAfterSuccess() throws {
        let previous = try Self.interactionAllowed()
        defer { setInteractionAllowed(previous) }

        setInteractionAllowed(true)
        let result = try KeychainAccess.withInteraction(allowed: false) {
            XCTAssertFalse(try Self.interactionAllowed())
            return "completed"
        }

        XCTAssertEqual(result, "completed")
        XCTAssertTrue(try Self.interactionAllowed())
    }

    func testInteractionDisabledDuringOperationAndRestoredAfterThrow() throws {
        enum ExpectedError: Error { case failure }

        let previous = try Self.interactionAllowed()
        defer { setInteractionAllowed(previous) }
        setInteractionAllowed(true)

        XCTAssertThrowsError(try KeychainAccess.withInteraction(allowed: false) {
            XCTAssertFalse(try Self.interactionAllowed())
            throw ExpectedError.failure
        }) { error in
            XCTAssertTrue(error is ExpectedError)
        }
        XCTAssertTrue(try Self.interactionAllowed())
    }

    func testInteractionAllowedRestoresPreviousFalseValue() throws {
        let previous = try Self.interactionAllowed()
        defer { setInteractionAllowed(previous) }
        setInteractionAllowed(false)

        try KeychainAccess.withInteraction(allowed: true) {
            XCTAssertTrue(try Self.interactionAllowed())
        }

        XCTAssertFalse(try Self.interactionAllowed())
    }

    func testConcurrentInteractiveAndNoninteractiveOperationsAreSerialized() throws {
        let previous = try Self.interactionAllowed()
        defer { setInteractionAllowed(previous) }
        setInteractionAllowed(true)

        let queue = DispatchQueue(label: "KeychainAccessTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let state = ConcurrentOperationState()

        for index in 0..<40 {
            let allowed = index.isMultiple(of: 2)
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try KeychainAccess.withInteraction(allowed: allowed) {
                        state.begin()
                        let observed = try Self.interactionAllowed()
                        state.check(observed: observed, expected: allowed)
                        Thread.sleep(forTimeInterval: 0.002)
                        state.end()
                    }
                } catch {
                    state.record("operation failed: \(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let observedViolations = state.violations
        XCTAssertTrue(observedViolations.isEmpty, observedViolations.joined(separator: "; "))
        XCTAssertTrue(try Self.interactionAllowed())
    }

    func testNoninteractiveReadOfUntrustedLegacyItemIsDeniedWithoutPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychainURL = directory.appendingPathComponent("fixture.keychain-db")
        let password = "fixture-only-password"
        var keychain: SecKeychain?
        defer {
            if let keychain { SecKeychainDelete(keychain) }
            try? FileManager.default.removeItem(at: directory)
        }

        let createStatus = keychainURL.path.withCString { path in
            password.withCString { passwordPointer in
                SecKeychainCreate(path, UInt32(password.utf8.count), passwordPointer, false, nil, &keychain)
            }
        }
        XCTAssertEqual(createStatus, errSecSuccess, "Could not create isolated test keychain")
        guard let keychain else {
            XCTFail("SecKeychainCreate succeeded without returning a keychain")
            return
        }
        let unlockStatus = password.withCString {
            SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, false)
        }
        XCTAssertEqual(unlockStatus, errSecSuccess, "Could not unlock isolated test keychain")

        var trustedApplication: SecTrustedApplication?
        let trustedStatus = "/usr/bin/security".withCString {
            SecTrustedApplicationCreateFromPath($0, &trustedApplication)
        }
        XCTAssertEqual(trustedStatus, errSecSuccess)
        guard let trustedApplication else {
            XCTFail("Could not create trusted-application fixture")
            return
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "LLMUsageBar isolated test item" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        XCTAssertEqual(accessStatus, errSecSuccess)
        guard let access else {
            XCTFail("Could not create access control for fixture")
            return
        }

        let service = "LLMUsageBar.KeychainAccessTests.\(UUID().uuidString)"
        let secret = Data("fixture-secret".utf8)
        var serviceBytes = Array(service.utf8)
        var accountBytes = Array("isolated-fixture".utf8)
        var item: SecKeychainItem?
        let addStatus = serviceBytes.withUnsafeMutableBufferPointer { serviceBuffer in
            accountBytes.withUnsafeMutableBufferPointer { accountBuffer in
                var attributes = [
                    SecKeychainAttribute(tag: 0x73766365, length: UInt32(serviceBuffer.count), data: serviceBuffer.baseAddress),
                    SecKeychainAttribute(tag: 0x61636374, length: UInt32(accountBuffer.count), data: accountBuffer.baseAddress)
                ]
                return attributes.withUnsafeMutableBufferPointer { attributeBuffer in
                    var attributeList = SecKeychainAttributeList(count: UInt32(attributeBuffer.count), attr: attributeBuffer.baseAddress)
                    return secret.withUnsafeBytes { secretBuffer in
                        SecKeychainItemCreateFromContent(
                            SecItemClass(rawValue: UInt32(0x67656e70))!,
                            &attributeList,
                            UInt32(secret.count),
                            secretBuffer.baseAddress,
                            keychain,
                            access,
                            &item
                        )
                    }
                }
            }
        }
        XCTAssertEqual(addStatus, errSecSuccess, "Could not add protected fixture item")

        let previous = try Self.interactionAllowed()
        defer { setInteractionAllowed(previous) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "isolated-fixture",
            kSecReturnData as String: true,
            kSecMatchSearchList as String: [keychain]
        ]
        let started = Date()
        let status = try KeychainAccess.withInteraction(allowed: false) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            XCTAssertFalse(try Self.interactionAllowed())
            return status
        }

        // Legacy ACL denial is reported as either status depending on the macOS release.
        XCTAssertTrue([errSecInteractionNotAllowed, errSecAuthFailed].contains(status),
                      "Expected noninteractive denial, received \(status)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Denied read took unexpectedly long")
        XCTAssertEqual(try Self.interactionAllowed(), previous)
    }

    private static func interactionAllowed() throws -> Bool {
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else {
            throw ClaudeBackendError.keychainUnavailable
        }
        return allowed.boolValue
    }

    private func setInteractionAllowed(_ allowed: Bool) {
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(allowed), errSecSuccess)
    }
}

private final class ConcurrentOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOperations = 0
    private var recordedViolations: [String] = []

    func begin() {
        lock.lock()
        activeOperations += 1
        if activeOperations != 1 {
            recordedViolations.append("operations overlapped")
        }
        lock.unlock()
    }

    func check(observed: Bool, expected: Bool) {
        guard observed != expected else { return }
        record("observed \(observed), expected \(expected)")
    }

    func end() {
        lock.lock()
        activeOperations -= 1
        lock.unlock()
    }

    func record(_ message: String) {
        lock.lock()
        recordedViolations.append(message)
        lock.unlock()
    }

    var violations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedViolations
    }
}
