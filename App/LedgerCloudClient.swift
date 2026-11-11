import CloudKit
import Foundation

struct RemoteLedgerDiscovery {
    let records: [RemoteLedgerState]
    let visibleLedgerIDs: Set<String>
    let warnings: [String]
}

@MainActor
protocol LedgerCloudClient: AnyObject {
    func accountIdentifier() async throws -> String
    func fetchRemoteLedgers() async throws -> RemoteLedgerDiscovery
    func uploadLedger(_ stored: StoredLedger) async throws -> RemoteLedgerState
    func preparePresentation(for ledger: Ledger) async throws -> SharePresentation
    func accept(_ metadata: CKShare.Metadata) async throws
}

#if DEBUG
@MainActor
final class SlowUITestCloudClient: LedgerCloudClient {
    func accountIdentifier() async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "ui-test-account"
    }

    func fetchRemoteLedgers() async throws -> RemoteLedgerDiscovery {
        throw CloudLedgerError.configuration
    }

    func uploadLedger(_ stored: StoredLedger) async throws -> RemoteLedgerState {
        throw CloudLedgerError.configuration
    }

    func preparePresentation(for ledger: Ledger) async throws -> SharePresentation {
        throw CloudLedgerError.configuration
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        throw CloudLedgerError.configuration
    }
}
#endif
