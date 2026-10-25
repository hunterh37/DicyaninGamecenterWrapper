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
    public let inProgress: Bool
    // The host's own capacity for this room. Joiners must respect it instead of
    // their local default, or they matchmake into a group that can never accept
    // them and hang there forever.
    public let maxPlayers: Int

    public init(id: String, name: String, hostID: String, playerGroup: Int, playerCount: Int, inProgress: Bool, maxPlayers: Int = 4) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.playerGroup = playerGroup
        self.playerCount = playerCount
        self.inProgress = inProgress
        self.maxPlayers = maxPlayers
    }

    public var hasRoom: Bool { playerCount < maxPlayers }
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
    private var isSubscribing = false
    private var isPublishing = false
    private var heartbeatTimer: Timer?

    // MARK: - Read

    public func refresh() {
        fetchOpenLobbies { [weak self] found in
            // A transient CloudKit failure must not blank the list: autoJoin
            // would then see an empty izakaya and strand everyone in group 1.
            guard let found else { return }
            self?.lobbies = found
        }
    }

    // One-shot fetch of every live open lobby, delivered on the main actor.
    // refresh() publishes through this; autoJoin uses it directly so it can
    // decide on a fresh list instead of a possibly stale published one.
    // nil means the query failed; callers keep whatever they already had.
    public func fetchOpenLobbies(_ completion: @escaping @MainActor ([GlobalLobby]?) -> Void) {
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
        op.queryResultBlock = { result in
            let harvested = found
            Task { @MainActor in
                if case .failure(let error) = result {
                    MultiplayerLog.shared.error("CloudKit", "Lobby query failed: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                completion(harvested)
            }
        }
        publicDB.add(op)
    }

    public func subscribe() {
        guard !didSubscribe, !isSubscribing else { return }
        isSubscribing = true

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

        publicDB.save(sub) { [weak self] _, error in
            Task { @MainActor in
                self?.isSubscribing = false
                // Only latch on success (or an existing subscription), otherwise
                // one offline launch kills push updates for the whole process.
                if let error {
                    if (error as? CKError)?.code == .serverRejectedRequest {
                        self?.didSubscribe = true
                        return
                    }
                    MultiplayerLog.shared.warn("CloudKit", "Subscription save failed: \(error.localizedDescription)")
                    return
                }
                self?.didSubscribe = true
            }
        }
    }

    // A count written before the publish round trip completes, replayed once
    // the record id lands.
    private var pendingPlayerCount: Int?

    // MARK: - Write

    public func publish(name: String, hostID: String, playerGroup: Int, maxPlayers: Int, playerCount: Int = 1) {
        // Never leave an earlier hosted record advertising a room nobody is
        // matchmaking in, and never let two rapid publishes both save.
        guard !isPublishing else { return }
        isPublishing = true
        closeHostedLobby()
        let record = CKRecord(recordType: Self.recordType)
        record["name"] = name as CKRecordValue
        record["hostID"] = hostID as CKRecordValue
        record["playerGroup"] = playerGroup as CKRecordValue
        record["playerCount"] = max(1, playerCount) as CKRecordValue
        pendingPlayerCount = nil
        record["maxPlayers"] = maxPlayers as CKRecordValue
        record["isOpen"] = 1 as CKRecordValue
        record["inProgress"] = 0 as CKRecordValue

        publicDB.save(record) { [weak self] saved, error in
            Task { @MainActor in
                self?.isPublishing = false
                if let error {
                    MultiplayerLog.shared.error("CloudKit", "Lobby publish failed: \(error.localizedDescription)")
                }
                guard let saved else { return }
                MultiplayerLog.shared.info("CloudKit", "Lobby published record=\(saved.recordID.recordName)")
                self?.hostedRecordID = saved.recordID
                self?.startHeartbeat()
                // Counts written while the save was in flight had no record to
                // land on, so a promoted host's room stayed advertised as empty.
                if let pending = self?.pendingPlayerCount {
                    self?.pendingPlayerCount = nil
                    self?.updatePlayerCount(pending)
                }
            }
        }
    }

    // Keeps modificationDate fresh so the lobby survives the staleness filter.
    // A host that crashes or loses connectivity stops heartbeating and its
    // lobby ages out of every client's list within staleInterval.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // .common mode, or the timer stops firing while the main run loop is
        // in a tracking mode (scroll, drag, modal) and a missed heartbeat ages
        // a live room out of every client's list.
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.touchHostedLobby() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func touchHostedLobby() {
        mutateHostedLobby(label: "heartbeat") { $0["isOpen"] = 1 as CKRecordValue }
    }

    public func updatePlayerCount(_ count: Int) {
        guard hostedRecordID != nil else {
            pendingPlayerCount = count
            return
        }
        mutateHostedLobby(label: "playerCount") { $0["playerCount"] = count as CKRecordValue }
    }

    /// Marks the hosted lobby as in-progress (a match is being played) or open
    /// again, so browsing clients can see the room state before joining.
    public func setInProgress(_ inProgress: Bool) {
        mutateHostedLobby(label: "inProgress") { $0["inProgress"] = (inProgress ? 1 : 0) as CKRecordValue }
    }

    // Heartbeat, player count and in-progress writes all race each other on the
    // same record. Fetch-then-blind-save loses those races silently (a dropped
    // heartbeat ages a live room out of every client's list), so writes go
    // through .changedKeys and retry once against the server's record.
    private func mutateHostedLobby(label: String, retrying: Bool = false, _ mutate: @escaping (CKRecord) -> Void) {
        guard let id = hostedRecordID else { return }
        publicDB.fetch(withRecordID: id) { [weak self] record, error in
            guard let self else { return }
            guard let record else {
                if let error {
                    Task { @MainActor in
                        MultiplayerLog.shared.warn("CloudKit", "Lobby \(label) fetch failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            mutate(record)
            let op = CKModifyRecordsOperation(recordsToSave: [record])
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                guard case .failure(let error) = result else { return }
                if let ckError = error as? CKError,
                   ckError.code == .serverRecordChanged,
                   !retrying {
                    Task { @MainActor in self.mutateHostedLobby(label: label, retrying: true, mutate) }
                    return
                }
                Task { @MainActor in
                    MultiplayerLog.shared.warn("CloudKit", "Lobby \(label) write failed: \(error.localizedDescription)")
                }
            }
            self.publicDB.add(op)
        }
    }

    public func closeHostedLobby() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pendingPlayerCount = nil
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
        let inProgress = (record["inProgress"] as? Int ?? 0) == 1
        let maxPlayers = record["maxPlayers"] as? Int ?? 4
        return GlobalLobby(
            id: record.recordID.recordName,
            name: name,
            hostID: hostID,
            playerGroup: group,
            playerCount: count,
            inProgress: inProgress,
            maxPlayers: maxPlayers
        )
    }
}
