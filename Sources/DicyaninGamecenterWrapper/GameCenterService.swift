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
    public let inProgress: Bool
    public let source: Source

    public init(id: String, hostName: String, subtitle: String? = nil, inProgress: Bool = false, source: Source) {
        self.id = id
        self.hostName = hostName
        self.subtitle = subtitle
        self.inProgress = inProgress
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
    @Published public private(set) var state = MultiplayerState(localPlayerID: GKLocalPlayer.local.gamePlayerID) {
        didSet {
            // Dedicated chat feed so chat UI never subscribes to the ~15Hz
            // `state` firehose (poses/props/emotes). Republish only when the
            // log actually changes, using a cheap count/last-id check instead
            // of full array equality on every network tick.
            if state.chatLog.count != chatFeed.count || state.chatLog.last?.id != chatFeed.last?.id {
                chatFeed = state.chatLog
            }
        }
    }
    // Chat-only publisher. Emits solely when chatLog changes, decoupling the
    // chat composer from the high-frequency `state` updates.
    @Published public private(set) var chatFeed: [ChatMessage] = []
    // Display names keyed by gamePlayerID, for the in-session player list.
    @Published public private(set) var playerNames: [String: String] = [:]

    // Live round-trip time per remote peer in milliseconds, smoothed with an
    // exponential moving average. Driven by the unreliable ping/pong loop so
    // the player list can show connection quality without touching `state`.
    @Published public private(set) var pingMillis: [String: Int] = [:]
    private var pingTimer: Timer?
    private var pingSeq: UInt32 = 0
    private var pingSent: [UInt32: Date] = [:]

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
    // Paint trade offers received by the local player awaiting a response.
    public var pendingTradeOffers: [TradePayload] {
        get { state.pendingTradeOffers }
        set { state.pendingTradeOffers = newValue }
    }
    // Paint trade responses routed back to the local player (the offerer).
    public var pendingTradeResponses: [TradeResponse] {
        get { state.pendingTradeResponses }
        set { state.pendingTradeResponses = newValue }
    }
    // Tap shimmer effects awaiting a spawn in the scene. The app drains this.
    public var pendingTaps: [TapSparkle] {
        get { state.pendingTaps }
        set { state.pendingTaps = newValue }
    }
    // Player-to-player touch sparks awaiting a spawn in the scene. The app drains this.
    public var pendingCollisionGlows: [CollisionGlow] {
        get { state.pendingCollisionGlows }
        set { state.pendingCollisionGlows = newValue }
    }
    // Color-unlock celebrations awaiting a floating orb in the scene. The app
    // drains this to spawn the orb over the looter's avatar.
    public var pendingColorUnlocks: [ColorUnlock] {
        get { state.pendingColorUnlocks }
        set { state.pendingColorUnlocks = newValue }
    }
    // World-activity starts awaiting application to a scene station. The app
    // drains this to attach the performer's tool and run the station timer.
    public var pendingActivities: [ActivityAction] {
        get { state.pendingActivities }
        set { state.pendingActivities = newValue }
    }
    // Incoming dance requests awaiting a local accept/decline, by requester id.
    public var pendingDanceRequests: [String] { state.pendingDanceRequests }
    // Peers the local player is actively dancing with.
    public var dancingPartners: Set<String> { state.dancingPartners }
    // Current shared room skybox. Driven by the picker view and applied to the
    // immersive dome via ImmersiveView onChange.
    public var skybox: SkyboxState { state.skybox }
    // Minigame round state forwarders.
    public var pendingMinigameInvites: [MinigameInvite] { state.pendingMinigameInvites }
    public var minigameAcceptances: [String: Set<String>] { state.minigameAcceptances }
    public var activeMinigame: MinigameStart? { state.activeMinigame }
    public var minigameClaims: [String: MinigameClaim] { state.minigameClaims }
    public var minigameResults: MinigameEnd? { state.minigameResults }

    // Lobby size cap. Game Center peer-to-peer real-time matches allow at
    // most this many players; requests are clamped to it.
    public static let lobbyCapacity = 16

    // The real ceiling GameKit will grant for a peer-to-peer match. Publishing
    // an unclamped lobbyCapacity used to advertise room in a lobby GameKit
    // could never grow, so joiners matchmade into a full group and hung.
    public nonisolated static var peerToPeerCapacity: Int {
        min(lobbyCapacity, GKMatchRequest.maxPlayersAllowedForMatch(of: .peerToPeer))
    }

    // Pure lobby pick used by autoJoin: fullest room that still has space by the
    // host's own capacity, never our own room, never one already in progress,
    // and never the room we are already sitting in.
    public nonisolated static func bestLobby(
        from lobbies: [GlobalLobby],
        localID: String,
        currentGroup: Int? = nil
    ) -> GlobalLobby? {
        lobbies
            .filter { $0.hostID != localID && $0.hasRoom && !$0.inProgress && $0.playerGroup != currentGroup }
            .max { $0.playerCount < $1.playerCount }
    }
    // How long a departed player's avatar stays frozen in place for peers.
    public static let ghostLifetime: TimeInterval = 300
    private static let lastPoseKey = "multiplayer.lastLocalPose"
    private static let displayNameKey = "multiplayer.displayName"

    private var invites: [String: GKInvite] = [:]
    private let lobbyService: LobbyService
    private var hostedLobbyGroup: Int?
    // Game Center playerGroup of the session the local player is currently in
    // or matchmaking into. Shared in invite deeplinks so friends can join the
    // exact same lobby, and consumed by `joinLobby(group:)` on the far side.
    @Published public private(set) var currentLobbyGroup: Int?
    // A deeplink join requested before Game Center finished authenticating,
    // applied automatically the moment auth completes.
    private var pendingDeepLinkGroup: Int?
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
        // Ghosts (players who left/dropped) keep their last pose and color so
        // their flight avatar can freeze in place, but they are no longer in the
        // session and must not appear in the "In Formation" roster.
        let ids = state.connectedPeers
            .union([localPlayerID])
            .union(state.remoteColors.keys)
            .union(state.remotePoses.keys)
            .subtracting(state.ghostPeers.keys)
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
                        // The local id changed under a live match: every peer
                        // would recompute host election against an id that is not
                        // in anyone's roster. Tear the session down first.
                        if self.match != nil || self.isSoloSession { self.leaveMatch() }
                        let keepColor = self.state.localColor
                        self.state = MultiplayerState(localPlayerID: GKLocalPlayer.local.gamePlayerID)
                        self.state.localColor = keepColor
                        self.playerNames.removeAll()
                    }
                    // authenticateHandler fires again on re-auth and account
                    // switches; registering twice duplicates invite callbacks.
                    GKLocalPlayer.local.unregisterAllListeners()
                    GKLocalPlayer.local.register(self)
                    self.lobbyService.subscribe()
                    self.lobbyService.refresh()
                    self.refreshLobbies()
                    if let group = self.pendingDeepLinkGroup {
                        self.pendingDeepLinkGroup = nil
                        self.joinLobby(group: group)
                    }
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
            .filter { $0.hostID != localPlayerID && $0.playerGroup != currentLobbyGroup }
            .map { lobby in
                LobbyListing(
                    id: lobby.id,
                    hostName: lobby.name,
                    subtitle: lobby.inProgress ? "Match in progress" : "\(lobby.playerCount) in room",
                    inProgress: lobby.inProgress,
                    source: .global(lobby)
                )
            }
        lobbies = list
    }

    // MARK: - Quick play

    // Global quick-match queue, always joinable. Surfaced as its own primary
    // action in the UI instead of a row in the lobby list.
    public func quickPlay(maxPlayers: Int = lobbyCapacity) {
        // startMatchmaking bails on a missing auth. Checking first keeps this
        // from flipping isSoloSession (and opening the arena) on a session that
        // no peer can ever discover.
        guard isAuthenticated else {
            log.error("Matchmaking", "Quick play blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to find a match."
            return
        }
        log.info("Join", "Quick play: entering solo now, filling group 1 in background")
        isAutoMatchmaking = false
        quickPlayTimer?.invalidate()
        quickPlayTimer = nil
        // Enter the arena alone immediately; keep searching group 1 so peers can
        // connect and upgrade this into a real GKMatch without a wait.
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        isSoloSession = true
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: 1))
        armQuickPlayFallback(maxPlayers: maxPlayers)
    }

    // The fallback that makes a lonely player discoverable. Without it a solo
    // quick-play session publishes no lobby record at all, so nobody can ever
    // find the player and matchmaking waits forever.
    private func armQuickPlayFallback(maxPlayers: Int) {
        quickPlayTimer?.invalidate()
        // .common mode, or the timer stops firing while the main run loop is
        // in a tracking mode (scroll, drag, modal) and a missed heartbeat ages
        // a live room out of every client's list.
        let timer = Timer(timeInterval: Self.quickPlayTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.quickPlayTimedOut(maxPlayers: maxPlayers) }
        }
        RunLoop.main.add(timer, forMode: .common)
        quickPlayTimer = timer
    }

    // Quick play found no one in time: stop searching the global queue and
    // create the player's own lobby, entering it solo. The lobby stays open so
    // others can still join and upgrade it into a real match.
    private func quickPlayTimedOut(maxPlayers: Int) {
        quickPlayTimer = nil
        guard match == nil, isMatchmaking, hostedLobbyGroup == nil else { return }
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
            let best = Self.bestLobby(
                from: lobbies ?? [],
                localID: self.localPlayerID,
                currentGroup: self.currentLobbyGroup
            )
            if let best {
                self.log.info("Join", "Auto-joining lobby \(best.name) group=\(best.playerGroup) count=\(best.playerCount)")
                // The host's own ceiling, not this device's default: a request
                // with a different maxPlayers never merges into the host's match.
                self.startMatchmaking(request: self.standardRequest(maxPlayers: best.maxPlayers, playerGroup: best.playerGroup))
            } else {
                self.log.info("Join", "Auto-join: no open lobby, entering quick-play queue")
                self.startMatchmaking(request: self.standardRequest(maxPlayers: maxPlayers, playerGroup: 1))
                self.armQuickPlayFallback(maxPlayers: maxPlayers)
            }
        }
    }

    // MARK: - Create / join

    // When `solo` is true the player enters the arena immediately, alone, while
    // the lobby stays published and matchmaking keeps running in the background
    // so peers can join and upgrade the session into a real GKMatch.
    // `isPrivate` keeps the room out of the public CloudKit directory: only
    // someone holding the invite code can reach it.
    public func createLobby(maxPlayers: Int = lobbyCapacity, solo: Bool = false, isPrivate: Bool = false) {
        guard isAuthenticated else {
            log.error("Lobby", "Create blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to create a lobby."
            return
        }
        isAutoMatchmaking = false
        let maxPlayers = min(maxPlayers, Self.peerToPeerCapacity)
        let group = Int.random(in: 2...Int(Int32.max))
        hostedLobbyGroup = group
        let name = GKLocalPlayer.local.displayName.isEmpty ? "Open Arena" : "\(GKLocalPlayer.local.displayName)'s Arena"
        log.info("Lobby", "Creating lobby name=\(name) group=\(group) maxPlayers=\(maxPlayers) solo=\(solo)")
        if !isPrivate {
            lobbyService.publish(name: name, hostID: localPlayerID, playerGroup: group, maxPlayers: maxPlayers)
        }
        if solo {
            let keepColor = state.localColor
            state = MultiplayerState(localPlayerID: localPlayerID)
            state.localColor = keepColor
            playerNames.removeAll()
            isSoloSession = true
        }
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: group))
    }

    /// Host only: flags the published lobby record as in-progress or open so
    /// browsing clients can see the room state before joining.
    public func setHostedLobbyInProgress(_ inProgress: Bool) {
        lobbyService.setInProgress(inProgress)
    }

    public func join(_ lobby: LobbyListing) {
        guard !lobby.inProgress else {
            log.info("Join", "Blocked join: lobby \(lobby.hostName) is in progress")
            return
        }
        isAutoMatchmaking = false
        switch lobby.source {
        case .invite(let invite):
            log.info("Join", "Accepting invite from \(invite.sender.displayName)")
            // GKMatchmaker allows one outstanding request; without this the
            // match(for:) fails as invalid and the invite is consumed for good.
            if isMatchmaking {
                log.warn("Matchmaking", "Cancelling in-flight matchmaking before accepting invite")
                GKMatchmaker.shared().cancel()
            }
            isMatchmaking = true
            matchmakingGeneration += 1
            let generation = matchmakingGeneration
            GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.invites.removeValue(forKey: invite.sender.gamePlayerID)
                    // Same superseded-request guard the findMatch path uses, or
                    // an in-flight search can replace the invite match (and vice
                    // versa) and leak a still-live GKMatch into the session.
                    guard generation == self.matchmakingGeneration else {
                        self.log.debug("Matchmaking", "Ignoring superseded invite completion")
                        match?.disconnect()
                        return
                    }
                    self.matchmakingFinished(match: match, error: error)
                }
            }
        case .quickMatch:
            log.info("Join", "Quick match into global group 1")
            startMatchmaking(request: standardRequest(maxPlayers: Self.lobbyCapacity, playerGroup: 1))
        case .global(let global):
            log.info("Join", "Joining global lobby \(global.name) group=\(global.playerGroup)")
            startMatchmaking(request: standardRequest(maxPlayers: global.maxPlayers, playerGroup: global.playerGroup))
        }
    }

    /// Joins the lobby identified by a Game Center `playerGroup`, the value
    /// carried in an invite deeplink. Matchmaking drops the player into the
    /// same real-time match everyone else who shares that link lands in.
    /// `maxPlayers` must equal the host's request or matchmaking never merges the two.
    public func joinLobby(group: Int, maxPlayers: Int = lobbyCapacity) {
        guard group > 0 else {
            log.warn("Join", "Ignoring deeplink join with invalid group \(group)")
            return
        }
        // Cold launch from a link often lands before Game Center finishes
        // authenticating; stash the group and apply it once auth completes.
        guard isAuthenticated else {
            log.info("Join", "Deeplink join deferred until authenticated (group=\(group))")
            pendingDeepLinkGroup = group
            return
        }
        guard match == nil else {
            log.info("Join", "Deeplink join ignored: already in a match (group=\(group))")
            return
        }
        // An auto-join racing the link must not win: the player asked for this
        // specific room, so supersede the background search instead of yielding.
        if isMatchmaking {
            log.info("Join", "Superseding in-flight matchmaking for deeplink group=\(group)")
            matchmakingGeneration += 1
            quickPlayTimer?.invalidate()
            quickPlayTimer = nil
            GKMatchmaker.shared().cancel()
            isMatchmaking = false
            isAutoMatchmaking = false
        }
        log.info("Join", "Deeplink joining lobby group=\(group)")
        isAutoMatchmaking = false
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: group))
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
        currentLobbyGroup = request.playerGroup
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
        currentLobbyGroup = nil
        lobbyService.closeHostedLobby()
    }

    private func matchmakingFinished(match: GKMatch?, error: Error?) {
        if let error {
            isMatchmaking = false
            log.error("Matchmaking", "Failed: \(error.localizedDescription)")
            // Do not leave a phantom lobby advertising a group nobody is
            // searching, and do not strand the player in a dead solo session.
            if match == nil {
                isSoloSession = false
                hostedLobbyGroup = nil
                // Both lobby filters skip currentLobbyGroup, so leaving it set
                // hides the room the player just failed to join, with no retry.
                currentLobbyGroup = nil
                lobbyService.closeHostedLobby()
            }
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
            if !isSoloSession { currentLobbyGroup = nil }
            log.warn("Matchmaking", "Completed with no match (likely cancelled)")
            return
        }
        log.info("Matchmaking", "Match found, \(match.players.count) connected, expecting \(match.expectedPlayerCount) more")
        quickPlayTimer?.invalidate()
        quickPlayTimer = nil
        isSoloSession = false
        // Retire a match this one supersedes, otherwise it keeps its delegate
        // and keeps injecting traffic from the abandoned session.
        if let previous = self.match, previous !== match {
            previous.delegate = nil
            previous.disconnect()
        }
        match.delegate = self
        self.match = match
        startPingLoop()
        // Peers carried over from a superseded session would otherwise sit in
        // connectedPeers forever, and host election (lowest id among peers plus
        // self) would resolve to a phantom nobody can hear.
        let incoming = Set(match.players.map(\.gamePlayerID))
        for stale in state.connectedPeers.subtracting(incoming) {
            log.debug("Match", "Dropping stale peer \(stale) from a superseded session")
            _ = MultiplayerReducer.peerChanged(stale, connected: false, into: &state)
            playerNames.removeValue(forKey: stale)
        }
        for ghost in Array(state.ghostPeers.keys) where !incoming.contains(ghost) {
            _ = MultiplayerReducer.peerChanged(ghost, connected: false, into: &state)
            playerNames.removeValue(forKey: ghost)
        }
        for player in match.players {
            state.connectedPeers.insert(player.gamePlayerID)
            playerNames[player.gamePlayerID] = player.displayName
            log.debug("Match", "Peer connected \(player.gamePlayerID) (\(player.displayName))")
        }
        log.info("Match", "isHost=\(isHost)")
        finishMatchmakingIfReady()
        // Peers that arrive with the initial match never raise a connection
        // event, so without this the published room is stuck advertising 1.
        syncHostedPlayerCount()
        send(MultiplayerReducer.broadcastColor(state))
        broadcastName()
        // Rejoin continuity: reliably announce the spot this player last stood
        // at so peers place (or reanimate) the avatar there before live head
        // tracking takes over.
        if let pose = lastLocalPose {
            send([MultiplayerReducer.makePose(pose, reliable: true)])
        }
        startGhostPruning()
        onRosterChanged?()
    }

    // MARK: - Ghosts

    // Departed players linger as frozen avatars, then age out.
    private func startGhostPruning() {
        ghostTimer?.invalidate()
        // .common mode, or the timer stops firing while the main run loop is
        // in a tracking mode (scroll, drag, modal) and a missed heartbeat ages
        // a live room out of every client's list.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneGhosts() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ghostTimer = timer
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
            // finishMatchmaking closes the match to new players permanently.
            // minPlayers is 2, so calling it here capped every room at two and
            // sent everyone after that into a second, disjoint match in the
            // same group. Only seal the room once it is actually full.
            if match.players.count + 1 >= Self.peerToPeerCapacity {
                GKMatchmaker.shared().finishMatchmaking(for: match)
                log.info("Matchmaking", "Lobby full, matchmaking finished")
            }
            isMatchmaking = false
            isAutoMatchmaking = false
            log.info("Matchmaking", "All expected players connected, room stays open for late joiners")
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
        // A mock session's 15 Hz driver would otherwise keep writing poses into
        // the state this call is about to reset, keeping inSession true forever.
        if isMockSession {
            mockDriver.stop()
            isMockSession = false
        }
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
        stopPingLoop()
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        hostedLobbyGroup = nil
        currentLobbyGroup = nil
        // A link deferred during this session must not fire on the next auth,
        // and a consumed invite must not linger as a dead lobby row.
        pendingDeepLinkGroup = nil
        invites.removeAll()
        lobbyService.closeHostedLobby()
        // Back on the home view the player immediately sees a fresh list of
        // tables to hop into next.
        lobbyService.refresh()
        onRosterChanged?()
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

    // Dev-only crash bisection switches. When true the corresponding
    // subsystem is skipped inside startMockSession so a device-only crash can
    // be isolated one stage at a time. Set by the app before starting a mock
    // session; never touched by production code paths.
    public var devDisableMockDriver = false
    public var devDisablePingLoop = false

    public func startMockSession(playerCount: Int) {
        guard match == nil else { return }
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        isMockSession = true
        log.info("Mock", "startMockSession begin (driver \(devDisableMockDriver ? "skipped" : "on"), ping \(devDisablePingLoop ? "skipped" : "on"))")
        if !devDisableMockDriver {
            mockDriver.start(playerCount: playerCount)
        }
        if !devDisablePingLoop {
            startPingLoop()
        }
        log.info("Mock", "startMockSession complete")
    }

    public func stopMockSession() {
        mockDriver.stop()
        isMockSession = false
        stopPingLoop()
        stopGhostPruning()
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
        // A solo host has no GKMatch yet, and its record must still count itself
        // rather than stay pinned at the published default.
        guard hostedLobbyGroup != nil else { return }
        lobbyService.updatePlayerCount(state.connectedPeers.count + 1)
    }

    // MARK: - Raw app channel

    /// Receives frames sent with `sendRaw`, with the sender's gamePlayerID.
    /// Apps with their own wire protocol use this instead of the avatar messages.
    public var rawHandler: ((Data, String) -> Void)?
    /// Fires when the roster changes: match found, peer joined or left, session ended.
    public var onRosterChanged: (() -> Void)?

    /// Share code of the lobby the player is hosting or sitting in.
    public var inviteCode: String? { currentLobbyGroup.flatMap { InviteCode.encode(group: $0) } }
    public var connectedPeerIDs: [String] { state.connectedPeers.sorted() }

    /// Sends an app frame to every peer, or only to `playerIDs`.
    public func sendRaw(_ data: Data, reliable: Bool = true, to playerIDs: [String]? = nil) {
        guard let match else { return }
        let frame = Data([InviteCode.rawFrameMarker]) + data
        let mode: GKMatch.SendDataMode = reliable ? .reliable : .unreliable
        if let playerIDs {
            let targets = match.players.filter { playerIDs.contains($0.gamePlayerID) }
            guard !targets.isEmpty else { return }
            try? match.send(frame, to: targets, dataMode: mode)
        } else {
            try? match.sendData(toAllPlayers: frame, with: mode)
        }
    }

    /// Joins the lobby behind a typed or linked invite code. False for a malformed code.
    @discardableResult
    public func joinLobby(code: String, maxPlayers: Int = lobbyCapacity) -> Bool {
        guard let group = InviteCode.decode(code) else {
            log.warn("Join", "Rejected malformed invite code")
            return false
        }
        joinLobby(group: group, maxPlayers: maxPlayers)
        return true
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

    // Broadcasts an aura-tinted touch spark at a room-frame contact point and
    // echoes it locally so the toucher sees their own glow immediately. Sent
    // unreliably: it is a cosmetic, self-expiring effect.
    public func sendCollisionGlow(at position: SIMD3<Float>, color: SIMD3<Float>) {
        let glow = CollisionGlow(x: position.x, y: position.y, z: position.z, r: color.x, g: color.y, b: color.z, senderID: localPlayerID)
        state.pendingCollisionGlows.append(glow)
        guard !isMockSession else { return }
        send(MultiplayerReducer.sendCollisionGlow(glow, into: &state))
    }

    // Removes a consumed touch spark once the app has spawned its effect.
    public func clearCollisionGlow(_ id: String) {
        state.pendingCollisionGlows.removeAll { $0.id == id }
    }

    // MARK: - Color unlocks

    // Broadcasts a prop-loot color unlock to the whole room and echoes it
    // locally so the looter sees the celebration orb over their own avatar
    // immediately. Mock sessions skip the wire and echo only.
    public func sendColorUnlock(colorName: String, packed: Int) {
        let unlock = ColorUnlock(senderID: localPlayerID, senderName: localName, colorName: colorName, packed: packed)
        state.pendingColorUnlocks.append(unlock)
        guard !isMockSession else { return }
        send(MultiplayerReducer.sendColorUnlock(unlock, into: &state))
    }

    // Removes a consumed color unlock once the app has spawned its orb.
    public func clearColorUnlock(_ id: String) {
        state.pendingColorUnlocks.removeAll { $0.id == id }
    }

    // Broadcasts a world-activity start (fishing, mining, ...) and echoes it
    // locally so the performer's own client animates with no round-trip.
    public func sendActivity(stationID: Int, kind: Int) {
        let action = ActivityAction(stationID: stationID, kind: kind, playerID: localPlayerID)
        state.pendingActivities.append(action)
        guard !isMockSession else { return }
        send(MultiplayerReducer.sendActivity(action, into: &state))
    }

    // Removes a consumed activity start once the app has applied it.
    public func clearActivity(_ id: String) {
        state.pendingActivities.removeAll { $0.id == id }
    }

    // Picks the room's shared skybox. Local state updates immediately so the
    // picker sees their own dome swap with no round-trip, then the choice is
    // broadcast reliably so every peer adopts it. Mock sessions skip the wire
    // and stomp local state only so the offline flow can be exercised.
    public func setSkybox(id: Int) {
        let next = SkyboxState(skyboxID: id, pickerID: localPlayerID)
        if isMockSession {
            MultiplayerReducer.applySkybox(next, into: &state)
            return
        }
        send(MultiplayerReducer.setSkybox(next, into: &state))
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

    // MARK: - Paint trading

    // Offers one of the local player's paints (packed 0xRRGGBB) to a peer. In a
    // mock session the offer loops back locally so the receive flow can be
    // exercised offline.
    public func sendTradeOffer(offerPacked: Int, to playerID: String) {
        guard playerID != localPlayerID else { return }
        let offer = TradePayload(offerPacked: offerPacked, senderID: localPlayerID, senderName: localName, target: playerID)
        if isMockSession {
            var loop = offer
            loop.target = localPlayerID
            state.pendingTradeOffers.append(loop)
            return
        }
        send(MultiplayerReducer.sendTradeOffer(offer, into: &state))
    }

    // Answers a received offer with the local player's paint. When declined,
    // returnPacked is ignored. In a mock session the response loops back so the
    // offerer-side reveal can be tested offline.
    public func sendTradeResponse(to offer: TradePayload, accepted: Bool, returnPacked: Int) {
        let response = TradeResponse(
            offerID: offer.id,
            responderID: localPlayerID,
            responderName: localName,
            target: offer.senderID,
            accepted: accepted,
            offerPacked: offer.offerPacked,
            returnPacked: returnPacked
        )
        if isMockSession {
            state.pendingTradeOffers.removeAll { $0.id == offer.id }
            var loop = response
            loop.target = localPlayerID
            state.pendingTradeResponses.append(loop)
            return
        }
        send(MultiplayerReducer.sendTradeResponse(response, into: &state))
    }

    public func clearTradeOffer(_ id: String) {
        state.pendingTradeOffers.removeAll { $0.id == id }
    }

    public func clearTradeResponse(_ id: String) {
        state.pendingTradeResponses.removeAll { $0.id == id }
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
        send(MultiplayerReducer.requestDance(target: playerID, into: &state))
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

    // MARK: - Minigames

    // Offers a minigame round to the whole lobby. Returns the round id the
    // host uses to watch acceptances and start the round. In a mock session
    // every fake player accepts immediately so the flow is testable offline.
    @discardableResult
    public func inviteToMinigame(_ kind: MinigameKind) -> String {
        let invite = MinigameInvite(kind: kind.rawValue, hostID: localPlayerID, hostName: localName)
        if isMockSession {
            var accepted: Set<String> = [localPlayerID]
            for id in state.connectedPeers { accepted.insert(id) }
            state.minigameAcceptances[invite.id] = accepted
            return invite.id
        }
        send(MultiplayerReducer.sendMinigameInvite(invite, into: &state))
        return invite.id
    }

    public func respondToMinigameInvite(_ gameID: String, accepted: Bool) {
        if isMockSession {
            state.pendingMinigameInvites.removeAll { $0.id == gameID }
            return
        }
        send(MultiplayerReducer.respondMinigameInvite(gameID: gameID, accepted: accepted, into: &state))
    }

    // Round host only: locks in everyone who accepted and starts the round.
    // Refuses to start below the game's minimum player count.
    @discardableResult
    public func startMinigame(_ gameID: String, kind: MinigameKind) -> Bool {
        let players = Array(state.minigameAcceptances[gameID] ?? [localPlayerID]).sorted()
        guard players.count >= kind.minPlayers else { return false }
        let start = MinigameStart(
            gameID: gameID,
            kind: kind.rawValue,
            hostID: localPlayerID,
            players: players,
            endsAt: Date().addingTimeInterval(kind.duration)
        )
        log.info("Minigame", "Starting \(kind.displayName) players=\(players.count)")
        if isMockSession {
            MultiplayerReducer.applyMinigameStart(start, into: &state)
            return true
        }
        send(MultiplayerReducer.startMinigame(start, into: &state))
        return true
    }

    // Claims one object for the local player in the active round.
    public func sendMinigameClaim(key: String, packed: Int) {
        if isMockSession {
            guard state.activeMinigame != nil else { return }
            state.minigameClaims[key] = MinigameClaim(playerID: localPlayerID, packed: packed)
            return
        }
        send(MultiplayerReducer.sendMinigameClaim(key: key, packed: packed, into: &state))
    }

    // Latest flying-ball state for Voxel Rumble, nil outside that round.
    public var minigameBall: BallSync? { state.minigameBall }

    // Voxel Rumble: the ball's current owner broadcasts its authoritative
    // state. Echoed into local state immediately so the owner never fights its
    // own stale packet.
    public func sendMinigameBall(_ sync: BallSync) {
        if isMockSession {
            state.minigameBall = sync
            return
        }
        send(MultiplayerReducer.sendMinigameBall(sync, into: &state))
    }

    // Live per-player scores for the active round.
    public var minigameLiveScores: [String: Int] { MultiplayerReducer.minigameScores(state) }

    // Round host only: tallies final scores and ends the round everywhere.
    public func endMinigame() {
        if isMockSession {
            guard let game = state.activeMinigame else { return }
            let end = MinigameEnd(gameID: game.gameID, kind: game.kind, scores: MultiplayerReducer.minigameScores(state))
            MultiplayerReducer.applyMinigameEnd(end, into: &state)
            return
        }
        send(MultiplayerReducer.endMinigame(into: &state))
    }

    // Local only: dismisses the game over screen and returns to the lobby.
    public func clearMinigameResults() {
        state.minigameResults = nil
        state.minigameClaims = [:]
        state.minigameBall = nil
    }

    // Local only: bails out of a round (round host vanished, player left).
    public func abandonMinigame() {
        state.activeMinigame = nil
        state.minigameClaims = [:]
        state.minigameBall = nil
    }

    // MARK: - Receiving

    fileprivate func receive(_ data: Data, fromPlayerID playerID: String) {
        if data.first == InviteCode.rawFrameMarker {
            rawHandler?(data.dropFirst(), playerID)
            return
        }
        // Decode once: this runs at pose rate times peer count on the main actor.
        guard let message = NetMessage.decode(data) else { return }
        // Honor a kick only from the current host, and only if it targets us.
        if case .kick(let target) = message {
            guard playerID == hostPlayerID else { return }
            if target == localPlayerID {
                log.warn("Match", "Kicked by host, leaving match")
                leaveMatch()
            }
            return
        }
        // Names live on the service, not in pure reducer state.
        if case .name(let name) = message {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { playerNames[playerID] = trimmed }
            return
        }
        switch message {
        case .ping(let origin, let seq):
            // Echo straight back to the origin only, unreliable. Broadcasting the
            // echo made probe traffic O(N^2) on a mesh already carrying poses.
            if let match, let reply = NetMessage.pong(origin: origin, seq: seq).encoded() {
                if let sender = match.players.first(where: { $0.gamePlayerID == playerID }) {
                    try? match.send(reply, to: [sender], dataMode: .unreliable)
                } else {
                    try? match.sendData(toAllPlayers: reply, with: .unreliable)
                }
            }
            return
        case .pong(let origin, let seq):
            // Peek, never consume: the ping is broadcast, so every peer answers
            // the same seq. Removing on the first pong left every other peer
            // without a latency reading. The cutoff sweep in pingTick expires it.
            guard origin == localPlayerID, let sentAt = pingSent[seq] else { return }
            recordPing(Date().timeIntervalSince(sentAt) * 1000, for: playerID)
            return
        default:
            break
        }
        send(MultiplayerReducer.apply(message, from: playerID, into: &state))
    }

    // MARK: - Connectivity (ping)

    private static let pingInterval: TimeInterval = 2

    private func startPingLoop() {
        pingTimer?.invalidate()
        // .common mode, or the timer stops firing while the main run loop is
        // in a tracking mode (scroll, drag, modal) and a missed heartbeat ages
        // a live room out of every client's list.
        let timer = Timer(timeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
        pingTick()
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
        pingSent.removeAll()
        if !pingMillis.isEmpty { pingMillis = [:] }
    }

    private func pingTick() {
        if isMockSession {
            // Fake but lively values so the mock session exercises the UI.
            var next: [String: Int] = [:]
            for id in state.connectedPeers {
                let base = 30 + abs(id.hashValue % 90)
                next[id] = max(8, base + Int.random(in: -12...12))
            }
            pingMillis = next
            return
        }
        guard let match else { return }
        // Drop peers that left and probes that never came back.
        let peers = state.connectedPeers
        let stale = pingMillis.keys.filter { !peers.contains($0) }
        for key in stale { pingMillis.removeValue(forKey: key) }
        let cutoff = Date().addingTimeInterval(-Self.pingInterval * 5)
        pingSent = pingSent.filter { $0.value > cutoff }

        pingSeq &+= 1
        pingSent[pingSeq] = Date()
        if let data = NetMessage.ping(origin: localPlayerID, seq: pingSeq).encoded() {
            try? match.sendData(toAllPlayers: data, with: .unreliable)
        }
    }

    private func recordPing(_ rttMillis: Double, for playerID: String) {
        let clamped = max(1, min(999, Int(rttMillis.rounded())))
        if let previous = pingMillis[playerID] {
            // EMA keeps the readout steady instead of jittering every probe.
            pingMillis[playerID] = Int((Double(previous) * 0.7 + Double(clamped) * 0.3).rounded())
        } else {
            pingMillis[playerID] = clamped
        }
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
        adoptHostedLobbyIfPromoted()
        syncHostedPlayerCount()
        onRosterChanged?()
    }

    // When the creator leaves, the next host takes over the published record so
    // the still-populated room does not vanish from every client's lobby list
    // (and its player count keeps updating).
    private func adoptHostedLobbyIfPromoted() {
        guard isHost, hostedLobbyGroup == nil, let group = currentLobbyGroup, match != nil else { return }
        hostedLobbyGroup = group
        let name = GKLocalPlayer.local.displayName.isEmpty ? "Open Arena" : "\(GKLocalPlayer.local.displayName)'s Arena"
        log.info("Lobby", "Promoted to host, republishing lobby group=\(group)")
        lobbyService.publish(
            name: name,
            hostID: localPlayerID,
            playerGroup: group,
            maxPlayers: Self.peerToPeerCapacity,
            playerCount: state.connectedPeers.count + 1
        )
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
