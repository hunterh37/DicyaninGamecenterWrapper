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
    // Offline test session driven by MockMultiplayerDriver. When true the app
    // enters the immersive arena with fake avatars and no Game Center match.
    @Published public var isMockSession = false
    // Single source of truth. Views observe it through the forwarders below.
    @Published public private(set) var state = MultiplayerState(localPlayerID: GKLocalPlayer.local.gamePlayerID)
    // Display names keyed by gamePlayerID, for the in-session player list.
    @Published public private(set) var playerNames: [String: String] = [:]

    // View-facing forwarders (API preserved from the pre-reducer design).
    public var localColor: AvatarColor { state.localColor }
    public var remotePoses: [String: PlayerPose] { state.remotePoses }
    public var remoteColors: [String: AvatarColor] { state.remoteColors }
    public var remoteProps: [Int: PropState] { state.remoteProps }
    public var pendingEmotes: [(playerID: String, emote: EmoteKind)] {
        get { state.pendingEmotes.map { ($0.playerID, $0.emote) } }
        set { state.pendingEmotes = newValue.map { PendingEmote(playerID: $0.playerID, emote: $0.emote) } }
    }

    private var invites: [String: GKInvite] = [:]
    private let lobbyService: LobbyService
    private var hostedLobbyGroup: Int?
    private var cancellables: Set<AnyCancellable> = []
    private lazy var mockDriver = MockMultiplayerDriver(owner: self)
    private let log = MultiplayerLog.shared

    // True whenever the immersive arena should be open: real match or mock.
    public var inSession: Bool { match != nil || isMockSession }

    public init(containerID: String = "iCloud.com.dicyanin.avatararena") {
        self.lobbyService = LobbyService(containerID: containerID)
        super.init()
        lobbyService.$lobbies
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLobbies() }
            .store(in: &cancellables)
    }

    public var localPlayerID: String { GKLocalPlayer.local.gamePlayerID }
    public var localName: String {
        let name = GKLocalPlayer.local.displayName
        return name.isEmpty ? "Me" : name
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
                let display = GKLocalPlayer.local.displayName
                name = display.isEmpty ? "You" : display
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
    public func quickPlay(maxPlayers: Int = 4) {
        log.info("Join", "Quick play into global group 1")
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: 1))
    }

    // MARK: - Create / join

    public func createLobby(maxPlayers: Int = 4) {
        guard isAuthenticated else {
            log.error("Lobby", "Create blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to create a lobby."
            return
        }
        let group = Int.random(in: 2...1_000_000)
        hostedLobbyGroup = group
        let name = GKLocalPlayer.local.displayName.isEmpty ? "Open Arena" : "\(GKLocalPlayer.local.displayName)'s Arena"
        log.info("Lobby", "Creating lobby name=\(name) group=\(group) maxPlayers=\(maxPlayers)")
        lobbyService.publish(name: name, hostID: localPlayerID, playerGroup: group, maxPlayers: maxPlayers)
        startMatchmaking(request: standardRequest(maxPlayers: maxPlayers, playerGroup: group))
    }

    public func join(_ lobby: LobbyListing) {
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
            startMatchmaking(request: standardRequest(maxPlayers: 4, playerGroup: 1))
        case .global(let global):
            log.info("Join", "Joining global lobby \(global.name) group=\(global.playerGroup)")
            startMatchmaking(request: standardRequest(maxPlayers: 4, playerGroup: global.playerGroup))
        }
    }

    private func standardRequest(maxPlayers: Int, playerGroup: Int) -> GKMatchRequest {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = maxPlayers
        request.playerGroup = playerGroup
        return request
    }

    private func startMatchmaking(request: GKMatchRequest) {
        guard isAuthenticated else {
            log.error("Matchmaking", "Blocked: not authenticated with Game Center")
            authError = "Sign in to Game Center to find a match."
            return
        }
        log.info("Matchmaking", "findMatch min=\(request.minPlayers) max=\(request.maxPlayers) group=\(request.playerGroup)")
        isMatchmaking = true
        GKMatchmaker.shared().findMatch(for: request) { [weak self] match, error in
            Task { @MainActor in
                self?.matchmakingFinished(match: match, error: error)
            }
        }
    }

    public func cancelMatchmaking() {
        log.warn("Matchmaking", "Cancelled by user")
        GKMatchmaker.shared().cancel()
        isMatchmaking = false
        hostedLobbyGroup = nil
        lobbyService.closeHostedLobby()
    }

    private func matchmakingFinished(match: GKMatch?, error: Error?) {
        if let error {
            isMatchmaking = false
            log.error("Matchmaking", "Failed: \(error.localizedDescription)")
            authError = error.localizedDescription
            return
        }
        guard let match else {
            isMatchmaking = false
            log.warn("Matchmaking", "Completed with no match (likely cancelled)")
            return
        }
        log.info("Matchmaking", "Match found, \(match.players.count) connected, expecting \(match.expectedPlayerCount) more")
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
    }

    // Matchmaking is only over once every expected peer has actually connected.
    // GKMatchmaker can hand back a match while expectedPlayerCount > 0; peers
    // arrive later via the connection-state delegate.
    private func finishMatchmakingIfReady() {
        guard let match else { return }
        if match.expectedPlayerCount == 0 {
            GKMatchmaker.shared().finishMatchmaking(for: match)
            isMatchmaking = false
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
        match?.disconnect()
        match = nil
        let keepColor = state.localColor
        state = MultiplayerState(localPlayerID: localPlayerID)
        state.localColor = keepColor
        playerNames.removeAll()
        hostedLobbyGroup = nil
        lobbyService.closeHostedLobby()
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
        send([MultiplayerReducer.makePose(pose)])
    }

    public func setColor(_ color: AvatarColor) {
        send(MultiplayerReducer.setColor(color, into: &state))
    }

    public func sendProps(_ props: [PropState], reliable: Bool = false) {
        guard !props.isEmpty else { return }
        send([MultiplayerReducer.makeProps(props, reliable: reliable, into: &state)])
    }

    public func sendEmote(_ emote: EmoteKind) {
        send(MultiplayerReducer.sendEmote(emote, into: &state))
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
        send(MultiplayerReducer.receive(data, from: playerID, into: &state))
    }

    fileprivate func playerConnectionChanged(_ playerID: String, name: String?, connected: Bool) {
        log.info("Match", "Peer \(playerID) \(connected ? "connected" : "disconnected")")
        if connected {
            if let name { playerNames[playerID] = name }
        } else {
            playerNames.removeValue(forKey: playerID)
        }
        send(MultiplayerReducer.peerChanged(playerID, connected: connected, into: &state))
        if connected { finishMatchmakingIfReady() }
        syncHostedPlayerCount()
    }

    fileprivate func matchFailed(_ error: Error?) {
        log.error("Match", "Match failed: \(error?.localizedDescription ?? "unknown error")")
        authError = error?.localizedDescription ?? "Match connection failed."
        leaveMatch()
        isMatchmaking = false
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
