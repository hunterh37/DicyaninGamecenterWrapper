import Foundation
import UIKit
import GameKit
import SwiftUI
import Combine

// All multiplayer networking runs through Game Center. Host authoritative:
// the player with the lowest gamePlayerID is the host and relays roster state.
// The globally discoverable room list is backed by CloudKit (LobbyService):
// hosts publish a Lobby record carrying the Game Center playerGroup, and
// joiners quick-match into that same group to land in the host's match.

public struct SessionPlayer: Identifiable {
    public let id: String
    public let name: String
    public let color: AvatarColor
    public let isLocal: Bool
    public let isHost: Bool
}

public struct LobbyListing: Identifiable {
    public enum Source {
        case invite(GKInvite)
        case quickMatch
        case global(GlobalLobby)
    }

    public let id: String
    public let hostName: String
    public let subtitle: String?
    public let source: Source

    public init(id: String, hostName: String, subtitle: String? = nil, source: Source) {
        self.id = id
        self.hostName = hostName
        self.subtitle = subtitle
        self.source = source
    }
}

@MainActor
public final class GameCenterService: NSObject, ObservableObject {

    /// The active instance. Apps that inject a container id should construct
    /// `GameCenterService(containerID:)` once at launch and assign it here so
    /// singletons like `LobbyPushDelegate` route to the same instance.
    public static var shared = GameCenterService()

    @Published public var isAuthenticated = false
    @Published public var authError: String?
    @Published public var lobbies: [LobbyListing] = []
    @Published public var match: GKMatch?
    @Published public var isMatchmaking = false
    // True while matchmaking was started automatically (app open auto-join).
    // Lets the UI show a quiet indicator instead of a blocking overlay.
    @Published public var isAutoMatchmaking = false
    // Offline test session driven by MockMultiplayerDriver. When true the app
    // enters the immersive arena with fake avatars and no Game Center match.
    @Published public var isMockSession = false
    // True while the player is alone in their own real lobby (quick-play
    // matchmaking timed out, or a lobby created solo). The lobby stays
    // published and matchmaking keeps running so peers can join and upgrade
    // this into a real GKMatch; the flag clears the moment a match arrives.
    @Published public var isSoloSession = false
    // Single source of truth. Views observe it through the forwarders below.
    @Published public private(set) var state = MultiplayerState(localPlayerID: GKLocalPlayer.local.gamePlayerID)
    // Display names keyed by gamePlayerID, for the in-session player list.
    @Published public private(set) var playerNames: [String: String] = [:]

    // Player-chosen display name persisted on device. When set, it overrides
    // the Game Center alias everywhere the local player's name is shown.
    @Published public private(set) var customName: String =
        UserDefaults.standard.string(forKey: GameCenterService.displayNameKey) ?? ""

    // View-facing forwarders (API preserved from the pre-reducer design).
    public var localColor: AvatarColor { state.localColor }
    public var remotePoses: [String: PlayerPose] { state.remotePoses }
    public var remoteColors: [String: AvatarColor] { state.remoteColors }
    public var remoteProps: [Int: PropState] { state.remoteProps }
    public var paintStrokes: [PaintStroke] { state.paintStrokes }
    public var signMessages: [Int: SignState] { state.signMessages }
    public var chatLog: [ChatMessage] { state.chatLog }
    public var pendingEmotes: [(playerID: String, emote: EmoteKind)] {
        get { state.pendingEmotes.map { ($0.playerID, $0.emote) } }
        set { state.pendingEmotes = newValue.map { PendingEmote(playerID: $0.playerID, emote: $0.emote) } }
    }
    public var pendingChats: [(playerID: String, text: String)] {
        get { state.pendingChats.map { ($0.playerID, $0.text) } }
        set { state.pendingChats = newValue.map { PendingChat(playerID: $0.playerID, text: $0.text) } }
    }
    // Gifts received by the local player awaiting consumption by the app.
    public var pendingGifts: [GiftPayload] {
        get { state.pendingGifts }
        set { state.pendingGifts = newValue }
    }
    public var pendingHearts: [HeartPayload] {
        get { state.pendingHearts }
        set { state.pendingHearts = newValue }
    }
    // Tap shimmer effects awaiting a spawn in the scene. The app drains this.
    public var pendingTaps: [TapSparkle] {
        get { state.pendingTaps }
        set { state.pendingTaps = newValue }
    }
    // Incoming dance requests awaiting a local accept/decline, by requester id.
    public var pendingDanceRequests: [String] { state.pendingDanceRequests }
    // Peers the local player is actively dancing with.
    public var dancingPartners: Set<String> { state.dancingPartners }

    // Lobby size cap. Game Center peer-to-peer real-time matches allow at
    // most this many players; requests are clamped to it.
    public static let lobbyCapacity = 16
    // How long a departed player's avatar stays frozen in place for peers.
    public static let ghostLifetime: TimeInterval = 300
    private static let lastPoseKey = "multiplayer.lastLocalPose"
    private static let displayNameKey = "multiplayer.displayName"

    private var invites: [String: GKInvite] = [:]
    private let lobbyService: LobbyService
    private var hostedLobbyGroup: Int?
    private var ghostTimer: Timer?
    private var quickPlayTimer: Timer?
    // Bumped on every new find/cancel so completions from a superseded
    // matchmaking request are ignored instead of stomping the current one.
    private var matchmakingGeneration = 0
    // Last pose this player broadcast, kept across sessions so a rejoining
    // player reappears at the same spot they left.
    public private(set) var lastLocalPose: PlayerPose?
    private var cancellables: Set<AnyCancellable> = []
    private lazy var mockDriver = MockMultiplayerDriver(owner: self)
    private let log = MultiplayerLog.shared

    // True whenever the immersive arena should be open: real match or mock.
    public var inSession: Bool { match != nil || isMockSession || isSoloSession }

    // How long quick play searches for a real match before falling back to
    // creating the player's own solo lobby.
    public static let quickPlayTimeout: TimeInterval = 15

    public init(containerID: String = "iCloud.com.dicyanin.avatararena") {
        self.lobbyService = LobbyService(containerID: containerID)
        if let data = UserDefaults.standard.data(forKey: Self.lastPoseKey) {
            lastLocalPose = try? JSONDecoder().decode(PlayerPose.self, from: data)
        }
        super.init()
        lobbyService.$lobbies
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLobbies() }
            .store(in: &cancellables)
    }

    public var localPlayerID: String { GKLocalPlayer.local.gamePlayerID }
    public var localName: String {
        let custom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let name = GKLocalPlayer.local.displayName
        return name.isEmpty ? "Me" : name
    }

    // Persists the player-chosen name on device and broadcasts it to peers.
    // An empty value clears the override and falls back to the Game Center alias.
    public func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.displayNameKey)
        broadcastName()
    }

    private func broadcastName() {
        guard match != nil else { return }
        send([RelayMessage(message: .name(localName), reliable: true)])
    }

    // The host is the lowest id among every participant including self.
    public var hostPlayerID: String {
        state.connectedPeers.union([localPlayerID]).min() ?? localPlayerID
    }

    // Everyone in the current session, local first, for the player list.
    public var sessionPlayers: [SessionPlayer] {
        let ids = state.connectedPeers
            .union([localPlayerID])
            .union(state.remoteColors.keys)
            .union(state.remotePoses.keys)
        let host = hostPlayerID
        return ids.map { id in
            let isLocal = id == localPlayerID
            let color = isLocal ? state.localColor : (state.remoteColors[id] ?? .default)
            let name: String
            if isLocal {
                name = localName
            } else {
                name = playerNames[id] ?? "Player \(id.prefix(4))"
            }
            return SessionPlayer(id: id, name: name, color: color, isLocal: isLocal, isHost: id == host)
        }
        .sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // Host authoritative kick. Tells the target to leave, then drops it locally.
    public func kick(_ playerID: String) {
        guard playerID != localPlayerID else { return }
        if isMockSession {
            mockRemovePlayer(playerID)
            playerNames.removeValue(forKey: playerID)
            return
        }
        guard isHost, let match else { return }
        log.info("Match", "Kicking player \(playerID)")
        if let data = NetMessage.kick(playerID).encoded() {
            try? match.sendData(toAllPlayers: data, with: .reliable)
        }
        send(MultiplayerReducer.peerChanged(playerID, connected: false, into: &state))
        playerNames.removeValue(forKey: playerID)
        syncHostedPlayerCount()
    }

    public var isHost: Bool {
        guard match != nil else { return true }
        return state.isHost
    }

    private func send(_ relays: [RelayMessage]) {
        guard let match else { return }
        for relay in relays {
            guard let data = relay.message.encoded() else { continue }
            try? match.sendData(toAllPlayers: data, with: relay.reliable ? .reliable : .unreliable)
        }
    }

    // MARK: - Authentication

    public func authenticate() {
        log.info("Auth", "Requesting Game Center authentication")
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.error("Auth", "Failed: \(error.localizedDescription)")
                    self.authError = error.localizedDescription
                    self.isAuthenticated = false
                    return
                }
                if let viewController {
                    self.log.warn("Auth", "Presenting Game Center sign-in UI")
                    self.present(viewController)
                    return
                }
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                self.log.info("Auth", "isAuthenticated=\(self.isAuthenticated) player=\(GKLocalPlayer.local.gamePlayerID)")
                if self.isAuthenticated {
                    if self.state.localPlayerID != GKLocalPlayer.local.gamePlayerID {
                        let keepColor = self.state.localColor
                        self.state = MultiplayerState(localPlayerID: GKLocalPlayer.local.gamePlayerID)
                        self.state.localColor = keepColor
                    }
                    GKLocalPlayer.local.register(self)
                    self.lobbyService.subscribe()
                    self.lobbyService.refresh()
                    self.refreshLobbies()
                }
            }
        }
    }

    // MARK: - Lobby list

    public func refreshLobbies() {
        var list = invites.values.map { invite in
            LobbyListing(
                id: invite.sender.gamePlayerID,
                hostName: invite.sender.displayName,
                subtitle: "Invite",
                source: .invite(invite)
            )
        }
        // Globally discoverable rooms from the CloudKit public database.
        list += lobbyService.lobbies
            .filter { $0.hostID != localPlayerID }
            .map { lobby in
                LobbyListing(
                    id: lobby.id,
                    hostName: lobby.name,
                    subtitle: "\(lobby.playerCount) in room",
                    source: .global(lobby)
                )
            }
        lobbies = list
    }

    // MARK: - Quick play

    // Global quick-match queue, always joinable. Surfaced as its own primary
    // action in the UI instead of a row in the lobby list.
    public func quickPlay(maxPlayers: Int = lobbyCapacity) {
        log.info("Join", "Quick play into global group 1 (15s before solo lobby)")
        isAutoMatchmaking = false
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: 1))
        quickPlayTimer?.invalidate()
        quickPlayTimer = Timer.scheduledTimer(withTimeInterval: Self.quickPlayTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.quickPlayTimedOut(maxPlayers: maxPlayers) }
        }
    }

    // Quick play found no one in time: stop searching the global queue and
    // create the player's own lobby, entering it solo. The lobby stays open so
    // others can still join and upgrade it into a real match.
    private func quickPlayTimedOut(maxPlayers: Int) {
        quickPlayTimer = nil
        guard match == nil, isMatchmaking, !isSoloSession else { return }
        log.info("Matchmaking", "Quick play timed out after \(Int(Self.quickPlayTimeout))s, creating own lobby")
        matchmakingGeneration += 1
        GKMatchmaker.shared().cancel()
        isMatchmaking = false
        createLobby(maxPlayers: maxPlayers, solo: true)
    }

    // MARK: - Auto join

    // Called once when the app opens: drops the player into the fullest open
    // lobby that still has room, or the global quick-play queue when the
    // izakaya is empty. Runs quietly; the UI stays interactive throughout.
    public func autoJoin(maxPlayers: Int = lobbyCapacity) {
        guard isAuthenticated, match == nil, !isMatchmaking, !isMockSession else { return }
        log.info("Join", "Auto-join: fetching open lobbies")
        isAutoMatchmaking = true
        lobbyService.fetchOpenLobbies { [weak self] lobbies in
            guard let self, self.match == nil, self.isAutoMatchmaking, !self.isMockSession else { return }
            let best = lobbies
                .filter { $0.hostID != self.localPlayerID && $0.playerCount < maxPlayers }
                .max { $0.playerCount < $1.playerCount }
            if let best {
                self.log.info("Join", "Auto-joining lobby \(best.name) group=\(best.playerGroup) count=\(best.playerCount)")
                self.startMatchmaking(request: self.standardRequest(maxPlayers: maxPlayers, playerGroup: best.playerGroup))
            } else {
                self.log.info("Join", "Auto-join: no open lobby, entering quick-play queue")
                self.startMatchmaking(request: self.standardRequest(maxPlayers: maxPlayers, playerGroup: 1))
            }
        }
    }

    // MARK: - Create / join

    // When `solo` is true the player enters the arena immediately, alone, while
    // the lobby stays published and matchmaking keeps running in the background
    // so peers can join and upgrade the session into a real GKMatch.
    public func createLobby(maxPlayers: Int = lobbyCapacity, solo: Bool = false) {
        guard isAuthenticated else {
            log.error("Lobby", "Create blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to create a lobby."
            return
        }
        isAutoMatchmaking = false
        let group = Int.random(in: 2...1_000_000)
        hostedLobbyGroup = group
        let name = GKLocalPlayer.local.displayName.isEmpty ? "Open Arena" : "\(GKLocalPlayer.local.displayName)'s Arena"
        log.info("Lobby", "Creating lobby name=\(name) group=\(group) maxPlayers=\(maxPlayers) solo=\(solo)")
        lobbyService.publish(name: name, hostID: localPlayerID, playerGroup: group, maxPlayers: maxPlayers)
        if solo {
            let keepColor = state.localColor
            state = MultiplayerState(localPlayerID: localPlayerID)
            state.localColor = keepColor
            playerNames.removeAll()
            isSoloSession = true
        }
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: group))
    }

    public func join(_ lobby: LobbyListing) {
        isAutoMatchmaking = false
        switch lobby.source {
        case .invite(let invite):
            log.info("Join", "Accepting invite from \(invite.sender.displayName)")
            isMatchmaking = true
            GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
                Task { @MainActor in
                    self?.invites.removeValue(forKey: invite.sender.gamePlayerID)
                    self?.matchmakingFinished(match: match, error: error)
                }
            }
        case .quickMatch:
            log.info("Join", "Quick match into global group 1")
            startMatchmaking(request: standardRequest(maxPlayers: Self.lobbyCapacity, playerGroup: 1))
        case .global(let global):
            log.info("Join", "Joining global lobby \(global.name) group=\(global.playerGroup)")
            startMatchmaking(request: standardRequest(maxPlayers: Self.lobbyCapacity, playerGroup: global.playerGroup))
        }
    }

    private func standardRequest(maxPlayers: Int, playerGroup: Int) -> GKMatchRequest {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = min(
            maxPlayers,
            GKMatchRequest.maxPlayersAllowedForMatch(of: .peerToPeer)
        )
        request.playerGroup = playerGroup
        return request
    }

    private func startMatchmaking(request: GKMatchRequest) {
        guard isAuthenticated else {
            log.error("Matchmaking", "Blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to find a match."
            return
        }
        // GKMatchmaker allows one outstanding request. Cancel any in-flight
        // search first or the new findMatch fails as an invalid request.
        if isMatchmaking {
            log.warn("Matchmaking", "Cancelling in-flight matchmaking before new request")
            GKMatchmaker.shared().cancel()
        }
        matchmakingGeneration += 1
        let generation = matchmakingGeneration
        log.info("Matchmaking", "findMatch min=\(request.minPlayers) max=\(request.maxPlayers) group=\(request.playerGroup)")
        isMatchmaking = true
        GKMatchmaker.shared().findMatch(for: request) { [weak self] match, error in
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.matchmakingGeneration else {
                    self.log.debug("Matchmaking", "Ignoring completion from superseded request")
                    return
                }
                self.matchmakingFinished(match: match, error: error)
            }
        }
    }

    public func cancelMatchmaking() {
        log.warn("Matchmaking", "Cancelled by user")
        matchmakingGeneration += 1
        quickPlayTimer?.invalidate()
        quickPlayTimer = nil
        GKMatchmaker.shared().cancel()
        isMatchmaking = false
        isAutoMatchmaking = false
        isSoloSession = false
        hostedLobbyGroup = nil
        lobbyService.closeHostedLobby()
    }

    private func matchmakingFinished(match: GKMatch?, error: Error?) {
        if let error {
            isMatchmaking = false
            log.error("Matchmaking", "Failed: \(error.localizedDescription)")
            // Auto-join failures stay quiet; the player never asked for it.
            if !isAutoMatchmaking {
                authError = error.localizedDescription
            }
            isAutoMatchmaking = false
            return
        }
        guard let match else {
            isMatchmaking = false
            isAutoMatchmaking = false
            log.warn("Matchmaking", "Completed with no match (likely cancelled)")
            return
        }
        log.info("Matchmaking", "Match found, \(match.players.count) connected, expecting \(match.expectedPlayerCount) more")
        quickPlayTimer?.invalidate()
        quickPlayTimer = nil
        isSoloSession = false
        match.delegate = self
        self.match = match
        for player in match.players {
            state.connectedPeers.insert(player.gamePlayerID)
            playerNames[player.gamePlayerID] = player.displayName
            log.debug("Match", "Peer connected \(player.gamePlayerID) (\(player.displayName))")
        }
        log.info("Match", "isHost=\(isHost)")
        finishMatchmakingIfReady()
        send(MultiplayerReducer.broadcastColor(state))
        broadcastName()
        // Rejoin continuity: reliably announce the spot this player last stood
        // at so peers place (or reanimate) the avatar there before live head
        // tracking takes over.
        if let pose = lastLocalPose {
            send([MultiplayerReducer.makePose(pose, reliable: true)])
        }
        startGhostPruning()
    }

    // MARK: - Ghosts

    // Departed players linger as frozen avatars, then age out.
    private func startGhostPruning() {
        ghostTimer?.invalidate()
        ghostTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneGhosts() }
        }
    }

    private func stopGhostPruning() {
        ghostTimer?.invalidate()
        ghostTimer = nil
    }

    private func pruneGhosts() {
        let expired = MultiplayerReducer.pruneGhosts(olderThan: Self.ghostLifetime, into: &state)
        for id in expired {
            playerNames.removeValue(forKey: id)
            log.debug("Match", "Ghost expired for \(id)")
        }
    }

    // Matchmaking is only over once every expected peer has actually connected.
    // GKMatchmaker can hand back a match while expectedPlayerCount > 0; peers
    // arrive later via the connection-state delegate.
    private func finishMatchmakingIfReady() {
        guard let match else { return }
        if match.expectedPlayerCount == 0 {
            GKMatchmaker.shared().finishMatchmaking(for: match)
            isMatchmaking = false
            isAutoMatchmaking = false
            log.info("Matchmaking", "All expected players connected, matchmaking finished")
        } else {
            isMatchmaking = true
            log.info("Matchmaking", "Waiting for \(match.expectedPlayerCount) more player(s) to connect")
        }
    }

    private func present(_ viewController: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else {
            log.error("Auth", "No window available to present Game Center sign-in")
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(viewController, animated: true)
    }

    public func leaveMatch() {
        log.info("Match", "Leaving match")
        stopGhostPruning()
        persistLastPose()
        // A solo player has no GKMatch yet but is still searching in the
        // background; stop that search so leaving actually returns to the menu.
        if isSoloSession || isMatchmaking {
            matchmakingGeneration += 1
            quickPlayTimer?.invalidate()
            quickPlayTimer = nil
            GKMatchmaker.shared().cancel()
            isMatchmaking = false
            isAutoMatchmaking = false
            isSoloSession = false
        }
        match?.disconnect()
        match = nil
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        hostedLobbyGroup = nil
        lobbyService.closeHostedLobby()
        // Back on the home view the player immediately sees a fresh list of
        // tables to hop into next.
        lobbyService.refresh()
    }

    // Saves the last broadcast pose so the avatar reappears at the same spot
    // on the next join, even across app launches.
    private func persistLastPose() {
        guard let pose = lastLocalPose,
              let data = try? JSONEncoder().encode(pose) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastPoseKey)
    }

    public func refreshGlobalLobbies() {
        lobbyService.refresh()
    }

    // MARK: - Mock session (offline testing)

    public func startMockSession(playerCount: Int) {
        guard match == nil else { return }
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        isMockSession = true
        mockDriver.start(playerCount: playerCount)
    }

    public func stopMockSession() {
        mockDriver.stop()
        isMockSession = false
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
    }

    public func sendMockEmote(_ emote: EmoteKind) {
        mockDriver.sendEmote(emote)
    }

    // Applied directly to state (no wire) so mock avatars render like remotes.
    public func mockSetColor(_ color: AvatarColor, for playerID: String) {
        _ = MultiplayerReducer.apply(.color(color), from: playerID, into: &state)
    }

    public func mockSetName(_ name: String, for playerID: String) {
        playerNames[playerID] = name
    }

    public func mockSetPose(_ pose: PlayerPose, for playerID: String) {
        _ = MultiplayerReducer.apply(.pose(pose), from: playerID, into: &state)
    }

    public func mockEmote(_ emote: EmoteKind, for playerID: String) {
        _ = MultiplayerReducer.apply(.emote(emote), from: playerID, into: &state)
    }

    public func mockRemovePlayer(_ playerID: String) {
        _ = MultiplayerReducer.peerChanged(playerID, connected: false, into: &state)
    }

    // Called from the app delegate when a CloudKit subscription push arrives.
    public func handleLobbyPush() {
        lobbyService.refresh()
    }

    private func syncHostedPlayerCount() {
        guard hostedLobbyGroup != nil, let match else { return }
        lobbyService.updatePlayerCount(match.players.count + 1)
    }

    // MARK: - Sending

    public func sendPose(_ pose: PlayerPose) {
        lastLocalPose = pose
        send([MultiplayerReducer.makePose(pose)])
    }

    public func setColor(_ color: AvatarColor) {
        send(MultiplayerReducer.setColor(color, into: &state))
    }

    // Equips (or clears, when nil) the inventory item held in the local
    // avatar's hand, preserving every other style field, and rebroadcasts so
    // peers render it immediately.
    public func equipItem(_ itemID: Int?) {
        var color = state.localColor
        guard color.equippedItem != itemID else { return }
        color.equippedItem = itemID
        setColor(color)
    }

    public func sendProps(_ props: [PropState], reliable: Bool = false) {
        guard !props.isEmpty else { return }
        send([MultiplayerReducer.makeProps(props, reliable: reliable, into: &state)])
    }

    public func sendEmote(_ emote: EmoteKind) {
        send(MultiplayerReducer.sendEmote(emote, into: &state))
    }

    // Broadcasts a tap shimmer at a room-frame position and echoes it locally
    // so the tapping player sees their own effect immediately.
    public func sendTap(at position: SIMD3<Float>) {
        let tap = TapSparkle(x: position.x, y: position.y, z: position.z, senderID: localPlayerID)
        state.pendingTaps.append(tap)
        guard !isMockSession else { return }
        send(MultiplayerReducer.sendTap(tap, into: &state))
    }

    // MARK: - Gifting

    // Sends an item from the local player to a peer. The itemID maps to the
    // app's item catalog. In a mock session the gift loops back locally so the
    // receive flow can be exercised offline.
    public func sendGift(itemID: Int, to playerID: String) {
        guard playerID != localPlayerID else { return }
        let gift = GiftPayload(itemID: itemID, senderID: localPlayerID, senderName: localName, target: playerID)
        if isMockSession {
            var loop = gift
            loop.target = localPlayerID
            state.pendingGifts.append(loop)
            return
        }
        send(MultiplayerReducer.sendGift(gift, into: &state))
    }

    // Removes a consumed gift once the app has granted and revealed it.
    public func clearGift(_ id: String) {
        state.pendingGifts.removeAll { $0.id == id }
    }

    // MARK: - Hearts

    // Sends a heart reaction from the local player to a peer. In a mock session
    // the heart loops back locally so the receive flow can be tested offline.
    public func sendHeart(to playerID: String) {
        guard playerID != localPlayerID else { return }
        let heart = HeartPayload(senderID: localPlayerID, senderName: localName, target: playerID)
        if isMockSession {
            var loop = heart
            loop.target = localPlayerID
            state.pendingHearts.append(loop)
            return
        }
        send(MultiplayerReducer.sendHeart(heart, into: &state))
    }

    // Removes a consumed heart once the app has shown its banner and burst.
    public func clearHeart(_ id: String) {
        state.pendingHearts.removeAll { $0.id == id }
    }

    // MARK: - Dance

    // Asks a peer to dance. In a mock session there is no wire, so pair up
    // immediately against the fake avatar for local testing.
    public func requestDance(with playerID: String) {
        guard playerID != localPlayerID else { return }
        if isMockSession {
            state.dancingPartners.insert(playerID)
            return
        }
        send(MultiplayerReducer.requestDance(target: playerID))
    }

    public func acceptDance(from playerID: String) {
        if isMockSession {
            state.pendingDanceRequests.removeAll { $0 == playerID }
            state.dancingPartners.insert(playerID)
            return
        }
        send(MultiplayerReducer.respondDance(to: playerID, accepted: true, into: &state))
    }

    public func declineDance(from playerID: String) {
        if isMockSession {
            state.pendingDanceRequests.removeAll { $0 == playerID }
            return
        }
        send(MultiplayerReducer.respondDance(to: playerID, accepted: false, into: &state))
    }

    public func endDance(with playerID: String) {
        if isMockSession {
            state.dancingPartners.remove(playerID)
            return
        }
        send(MultiplayerReducer.endDance(with: playerID, into: &state))
    }

    // Mock helper: drives a fake incoming dance request for offline testing.
    public func mockDanceRequest(from playerID: String) {
        _ = MultiplayerReducer.apply(.danceRequest(target: localPlayerID), from: playerID, into: &state)
    }

    // Shared paint board. Each completed stroke is appended locally and
    // relayed reliably; clearPaint wipes the board for everyone.
    public func sendPaintStroke(_ stroke: PaintStroke) {
        if isMockSession {
            MultiplayerReducer.appendStroke(stroke, into: &state)
            return
        }
        send(MultiplayerReducer.sendPaint(stroke, into: &state))
    }

    public func clearPaint() {
        if isMockSession {
            state.paintStrokes.removeAll()
            return
        }
        send(MultiplayerReducer.clearPaint(into: &state))
    }

    // Shared message boards. Setting a sign updates it locally and relays the
    // new text reliably; last write wins per sign id.
    public func setSign(id: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sign = SignState(id: id, text: trimmed, author: localName)
        if isMockSession {
            MultiplayerReducer.applySign(sign, into: &state)
            return
        }
        send(MultiplayerReducer.sendSign(sign, into: &state))
    }

    // Broadcasts a chat line to the lobby (or the mock session) and appends it
    // to the local log. Empty or whitespace-only text is ignored.
    public func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = ChatMessage(senderID: localPlayerID, senderName: localName, text: trimmed)
        if isMockSession {
            _ = MultiplayerReducer.sendChat(message, into: &state)
            mockDriver.echoChat()
            return
        }
        send(MultiplayerReducer.sendChat(message, into: &state))
    }

    // Applied directly to state (no wire) so mock chat renders like a remote.
    public func mockReceiveChat(_ message: ChatMessage) {
        _ = MultiplayerReducer.apply(.chat(message), from: message.senderID, into: &state)
    }

    // MARK: - Receiving

    fileprivate func receive(_ data: Data, fromPlayerID playerID: String) {
        // Honor a kick only from the current host, and only if it targets us.
        if case .kick(let target)? = NetMessage.decode(data) {
            guard playerID == hostPlayerID else { return }
            if target == localPlayerID {
                log.warn("Match", "Kicked by host, leaving match")
                leaveMatch()
            }
            return
        }
        // Names live on the service, not in pure reducer state.
        if case .name(let name)? = NetMessage.decode(data) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { playerNames[playerID] = trimmed }
            return
        }
        send(MultiplayerReducer.receive(data, from: playerID, into: &state))
    }

    fileprivate func playerConnectionChanged(_ playerID: String, name: String?, connected: Bool) {
        log.info("Match", "Peer \(playerID) \(connected ? "connected" : "disconnected")")
        if connected, let name {
            playerNames[playerID] = name
        }
        // Disconnects keep the name and last pose: the avatar stays frozen in
        // place as a ghost until it expires or the player rejoins.
        send(MultiplayerReducer.peerChanged(playerID, connected: connected, keepGhost: !connected, into: &state))
        if connected {
            finishMatchmakingIfReady()
            broadcastName()
        }
        syncHostedPlayerCount()
    }

    fileprivate func matchFailed(_ error: Error?) {
        log.error("Match", "Match failed: \(error?.localizedDescription ?? "unknown error")")
        authError = error?.localizedDescription ?? "Match connection failed."
        leaveMatch()
        isMatchmaking = false
        isAutoMatchmaking = false
    }

    fileprivate func receivedInvite(_ invite: GKInvite) {
        log.info("Invite", "Received invite from \(invite.sender.displayName)")
        invites[invite.sender.gamePlayerID] = invite
        refreshLobbies()
    }
}

extension GameCenterService: GKMatchDelegate {

    public nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let id = player.gamePlayerID
        Task { @MainActor in
            self.receive(data, fromPlayerID: id)
        }
    }

    public nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let id = player.gamePlayerID
        let name = player.displayName
        let connected = state == .connected
        Task { @MainActor in
            self.playerConnectionChanged(id, name: name, connected: connected)
        }
    }

    public nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in
            self.matchFailed(error)
        }
    }
}

extension GameCenterService: GKLocalPlayerListener {

    public nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in
            self.receivedInvite(invite)
        }
    }
}
