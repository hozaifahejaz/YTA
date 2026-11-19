import Foundation
import Testing
@testable import Secrets
import Support

@Suite struct SecretsTests {
    @Test func requestReadRegistersWithRedactor() throws {
        let store = MemorySecretStore([.ai33pro: "ai33-secret-value"])
        let redactor = Redactor()
        let value = try store.valueForRequest(.ai33pro, redactor: redactor)
        #expect(value == "ai33-secret-value")
        #expect(redactor.redact("x ai33-secret-value y") == "x [redacted] y")
    }

    @Test func missingKeyIsATypedError() {
        let store = MemorySecretStore()
        #expect(throws: YTAError.self) { try store.valueForRequest(.pexels) }
        #expect(store.has(.pexels) == false)
    }
}
