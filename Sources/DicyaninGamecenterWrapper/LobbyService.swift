import Foundation
import CloudKit
import Combine

// Global public lobby directory backed by the CloudKit public database.
// Any user, signed in or not, can read open lobbies. A host writes one
// Lobby record carrying the Game Center playerGroup used to funnel joiners
// into the same GKMatch. A CKQuerySubscription pushes live list updates.

public struct GlobalLobby: Identifiable, Equatable {
    public let id: String        // CloudKit record name
    public let name: String
    public let hostID: String
    public let playerGroup: Int
    public let playerCount: Int
}

@MainActor
public final class LobbyService: ObservableObject {

    public static let recordType = "Lobby"
    public static let subscriptionID = "open-lobbies-sub"

    @Published public private(set) var lobbies: [GlobalLobby] = []

    // A lobby with no heartbeat inside this window is considered dead and is
    // hidden from the list. Hosts re-save their record every heartbeatInterval.
    public static let staleInterval: TimeInterval = 180
    private static let heartbeatInterval: TimeInterval = 60

    // The app's own CloudKit container, supplied by the host app. Must match an
    // entry in the app's iCloud container entitlements.
    private let containerID: String
    private var publicDB: CKDatabase { CKContainer(identifier: containerID).publicCloudDatabase }

    public init(containerID: String) {
        self.containerID = containerID
    }

    private var hostedRecordID: CKRecord.ID?
    private var didSubscribe = false
    private var heartbeatTimer: Timer?

    // MARK: - Read

    public func refresh() {
        let cutoff = Date().addingTimeInterval(-Self.staleInterval)
        let predicate = NSPredicate(format: "isOpen == 1 AND modificationDate > %@", cutoff as NSDate)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]

        let op = CKQueryOperation(query: query)
        op.resultsLimit = 100
        var found: [GlobalLobby] = []
        op.recordMatchedBlock = { _, result in
            if case .success(let record) = result, let lobby = Self.lobby(from: record) {
                found.append(lobby)
            }
        }
        op.queryResultBlock = { [weak self] result in
            Task { @MainActor in
                if case .failure(let error) = result {
                    MultiplayerLog.shared.error("CloudKit", "Lobby query failed: \(error.localizedDescription)")
                }
                self?.lobbies = found
            }
        }
        publicDB.add(op)
    }

    public func subscribe() {
        guard !didSubscribe else { return }
        didSubscribe = true

        let predicate = NSPredicate(format: "isOpen == 1")
        let sub = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: predicate,
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info

        publicDB.save(sub) { _, error in
            if let error, (error as? CKError)?.code != .serverRejectedRequest {
                Task { @MainActor in
                    MultiplayerLog.shared.warn("CloudKit", "Subscription save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Write

    public func publish(name: String, hostID: String, playerGroup: Int, maxPlayers: Int) {
        let record = CKRecord(recordType: Self.recordType)
        record["name"] = name as CKRecordValue
        record["hostID"] = hostID as CKRecordValue
        record["playerGroup"] = playerGroup as CKRecordValue
        record["playerCount"] = 1 as CKRecordValue
        record["maxPlayers"] = maxPlayers as CKRecordValue
        record["isOpen"] = 1 as CKRecordValue

        publicDB.save(record) { [weak self] saved, error in
            Task { @MainActor in
                if let error {
                    MultiplayerLog.shared.error("CloudKit", "Lobby publish failed: \(error.localizedDescription)")
                }
                guard let saved else { return }
                MultiplayerLog.shared.info("CloudKit", "Lobby published record=\(saved.recordID.recordName)")
                self?.hostedRecordID = saved.recordID
                self?.startHeartbeat()
            }
        }
    }

    // Keeps modificationDate fresh so the lobby survives the staleness filter.
    // A host that crashes or loses connectivity stops heartbeating and its
    // lobby ages out of every client's list within staleInterval.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.touchHostedLobby() }
        }
    }

    private func touchHostedLobby() {
        guard let id = hostedRecordID else { return }
        publicDB.fetch(withRecordID: id) { [weak self] record, _ in
            guard let record else { return }
            record["isOpen"] = 1 as CKRecordValue
            self?.publicDB.save(record) { _, error in
                if let error {
                    Task { @MainActor in
                        MultiplayerLog.shared.warn("CloudKit", "Lobby heartbeat failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    public func updatePlayerCount(_ count: Int) {
        guard let id = hostedRecordID else { return }
        publicDB.fetch(withRecordID: id) { [weak self] record, _ in
            guard let record else { return }
            record["playerCount"] = count as CKRecordValue
            self?.publicDB.save(record) { _, _ in }
        }
    }

    public func closeHostedLobby() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard let id = hostedRecordID else { return }
        hostedRecordID = nil
        publicDB.delete(withRecordID: id) { _, _ in }
    }

    // MARK: - Mapping

    private static func lobby(from record: CKRecord) -> GlobalLobby? {
        guard
            let name = record["name"] as? String,
            let hostID = record["hostID"] as? String,
            let group = record["playerGroup"] as? Int
        else { return nil }
        let count = record["playerCount"] as? Int ?? 1
        return GlobalLobby(id: record.recordID.recordName, name: name, hostID: hostID, playerGroup: group, playerCount: count)
    }
}
