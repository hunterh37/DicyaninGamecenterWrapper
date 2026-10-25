import Foundation

// Transport-agnostic multiplayer core. All Game Center match traffic is
// reduced to pure state transitions here so the exact same logic that runs
// in production can be exercised end to end in unit tests without GameKit.
//
// Host authoritative: the peer with the lowest player id is the host and is
// the only peer that relays the full color roster.

// A message the caller must put on the wire, with its delivery guarantee.
public struct RelayMessage: Equatable {
    public let message: NetMessage
    public let reliable: Bool
}

// The complete observable multiplayer state for one participant.
public struct MultiplayerState: Equatable {
    public let localPlayerID: String
    public var localColor: AvatarColor = .default
    public var connectedPeers: Set<String> = []
    public var remotePoses: [String: PlayerPose] = [:]
    public var remoteColors: [String: AvatarColor] = [:]
    public var pendingEmotes: [PendingEmote] = []
    // Chat lines awaiting a floating bubble above the sender's head, oldest first.
    public var pendingChats: [PendingChat] = []
    // Incoming dance requests awaiting a local accept/decline, by requester id.
    public var pendingDanceRequests: [String] = []
    // Peers the local player is actively dancing with.
    public var dancingPartners: Set<String> = []
    // Peers the local player has sent a dance request to and not yet heard back
    // from. An unsolicited .danceResponse must never be able to force a pairing.
    public var sentDanceRequests: Set<String> = []
    // Rolling lobby chat log, oldest first, capped at chatLogLimit entries.
    public var chatLog: [ChatMessage] = []
    // Latest known state of every networked prop, keyed by prop id.
    public var remoteProps: [Int: PropState] = [:]
    // Shared room paint board strokes, oldest first, capped at paintStrokeLimit.
    public var paintStrokes: [PaintStroke] = []
    // Current message on every shared sign, keyed by sign id. Last write wins.
    public var signMessages: [Int: SignState] = [:]
    // Players who left but whose avatar stays frozen at its last spot,
    // Gifts received by the local player that the app has not yet consumed,
    // oldest first. The app drains this to grant the item and reveal it.
    public var pendingGifts: [GiftPayload] = []
    // Hearts received by the local player that the app has not yet consumed,
    // oldest first. The app drains this to show the banner and particle burst.
    public var pendingHearts: [HeartPayload] = []
    // Paint trade offers received by the local player awaiting an accept or
    // decline, oldest first. The app drains this to prompt the receiver.
    public var pendingTradeOffers: [TradePayload] = []
    // Paint trade responses routed back to the local player (the original
    // offerer), oldest first. The app drains this to reveal the outcome.
    public var pendingTradeResponses: [TradeResponse] = []
    // Tap shimmer effects received (from any peer, including a local echo) that
    // the app has not yet spawned in the scene, oldest first.
    public var pendingTaps: [TapSparkle] = []
    // Player-to-player touch sparks received (from any peer, including a local
    // echo) that the app has not yet spawned in the scene, oldest first.
    public var pendingCollisionGlows: [CollisionGlow] = []
    // Color-unlock celebrations received (from any peer, including a local echo)
    // that the app has not yet spawned as a floating orb, oldest first.
    public var pendingColorUnlocks: [ColorUnlock] = []
    // World-activity starts received (from any peer, including a local echo)
    // that the app has not yet applied to a station, oldest first.
    public var pendingActivities: [ActivityAction] = []
    // Current shared room skybox. Last write wins; host relays the live value
    // to joining peers via peerChanged so late joiners land on the right dome.
    public var skybox: SkyboxState = .default
    // keyed by player id with the moment they departed. Their last pose and
    // color are kept in remotePoses/remoteColors until pruned or they rejoin.
    public var ghostPeers: [String: Date] = [:]
    // Minigame invites received from a round host, awaiting accept/decline.
    public var pendingMinigameInvites: [MinigameInvite] = []
    // Accepted players per offered round, keyed by gameID. The round host
    // reads this to know when enough players are in to start.
    public var minigameAcceptances: [String: Set<String>] = [:]
    // The live round the local player is participating in, nil outside games.
    public var activeMinigame: MinigameStart?
    // Live per-object ownership for the active round, keyed by the game's
    // object key (paint rush: editID). Last claim wins, so repainting steals.
    public var minigameClaims: [String: MinigameClaim] = [:]
    // Final results awaiting the local game over screen. The app clears this
    // when the player taps back to the lobby.
    public var minigameResults: MinigameEnd?
    // Latest flying-ball state for Voxel Rumble, nil outside that round. Written
    // by inbound owner packets and by the local owner's simulation.
    public var minigameBall: BallSync?

    public init(localPlayerID: String) {
        self.localPlayerID = localPlayerID
    }

    // Host is the lowest id among every connected participant plus self.
    public var isHost: Bool {
        connectedPeers.union([localPlayerID]).min() == localPlayerID
    }

    // True when the given sender is the session host from the local player's
    // point of view. The sender is folded into the election set so a roster
    // arriving before that peer's connect callback is still trusted.
    public func isHost(_ playerID: String) -> Bool {
        connectedPeers.union([localPlayerID, playerID]).min() == playerID
    }
}

public struct PendingEmote: Equatable {
    public let playerID: String
    public let emote: EmoteKind
}

public struct PendingChat: Equatable {
    public let playerID: String
    public let text: String
}

// One claimed object in the active minigame round: who owns it and the
// packed 0xRRGGBB color it was painted with.
public struct MinigameClaim: Equatable {
    public let playerID: String
    public let packed: Int

    public init(playerID: String, packed: Int) {
        self.playerID = playerID
        self.packed = packed
    }
}

// Pure reducer. Every function returns the messages the transport must send.
public enum MultiplayerReducer {

    // Most recent chat lines to retain per participant.
    public static let chatLogLimit = 100

    // Most recent paint strokes to retain on the shared board.
    public static let paintStrokeLimit = 500

    // Cap for every drainable effect queue. The app drains these each frame, so
    // anything beyond this is a peer flooding a client that is not rendering
    // (window closed, immersive space shut). Without the cap the arrays grow
    // without bound and the per-insert id dedupe scan turns quadratic.
    public static let pendingQueueLimit = 200

    // Keyed maps have no natural drain, so each needs its own ceiling or a peer
    // minting fresh ids grows them for the life of the lobby.
    public static let signLimit = 256
    public static let propLimit = 512
    public static let claimLimit = 4096
    public static let acceptanceLimit = 64
    public static let rosterEntryLimit = 64

    static func appendCapped<T>(_ value: T, to queue: inout [T]) {
        queue.append(value)
        if queue.count > pendingQueueLimit {
            queue.removeFirst(queue.count - pendingQueueLimit)
        }
    }

    // Same cap, but hands back what fell off the front so callers can clean up
    // any side tables keyed off the evicted entries.
    @discardableResult
    static func appendCappedReturningEvicted<T>(_ value: T, to queue: inout [T]) -> [T] {
        queue.append(value)
        guard queue.count > pendingQueueLimit else { return [] }
        let overflow = queue.count - pendingQueueLimit
        let evicted = Array(queue.prefix(overflow))
        queue.removeFirst(overflow)
        return evicted
    }

    // MARK: Paint board

    public static func sendPaint(_ stroke: PaintStroke, into state: inout MultiplayerState) -> [RelayMessage] {
        appendStroke(stroke, into: &state)
        return [RelayMessage(message: .paint([stroke]), reliable: true)]
    }

    public static func clearPaint(into state: inout MultiplayerState) -> [RelayMessage] {
        state.paintStrokes.removeAll()
        return [RelayMessage(message: .paintClear, reliable: true)]
    }

    static func appendStroke(_ stroke: PaintStroke, into state: inout MultiplayerState) {
        guard !state.paintStrokes.contains(where: { $0.id == stroke.id }) else { return }
        state.paintStrokes.append(stroke)
        if state.paintStrokes.count > paintStrokeLimit {
            state.paintStrokes.removeFirst(state.paintStrokes.count - paintStrokeLimit)
        }
    }

    // MARK: Message boards

    public static func sendSign(_ sign: SignState, into state: inout MultiplayerState) -> [RelayMessage] {
        applySign(sign, into: &state)
        return [RelayMessage(message: .signs([sign]), reliable: true)]
    }

    // Timestamps come from each sender's own wall clock. A device whose clock
    // runs fast (or a peer sending .distantFuture) would otherwise write a sign
    // or skybox that nobody in the lobby can ever overwrite again, so incoming
    // stamps are clamped to the local clock plus a small tolerance.
    // Wide enough to keep normal cross-device clock jitter and packet reordering
    // intact, tight enough that a bogus far-future stamp unblocks within a minute
    // instead of pinning the value for the life of the lobby.
    public static let clockSkewTolerance: TimeInterval = 60

    static func clampToLocalClock(_ date: Date, now: Date = Date()) -> Date {
        min(date, now.addingTimeInterval(clockSkewTolerance))
    }

    static func applySign(_ sign: SignState, into state: inout MultiplayerState, now: Date = Date()) {
        var sign = sign
        sign.editedAt = clampToLocalClock(sign.editedAt, now: now)
        if let current = state.signMessages[sign.id], current.editedAt > sign.editedAt { return }
        // New ids past the ceiling are dropped; updates to known signs still land.
        guard state.signMessages[sign.id] != nil || state.signMessages.count < signLimit else { return }
        state.signMessages[sign.id] = sign
    }

    // MARK: Outbound (local intents)

    public static func sendChat(_ message: ChatMessage, into state: inout MultiplayerState) -> [RelayMessage] {
        appendChat(message, into: &state)
        return [RelayMessage(message: .chat(message), reliable: true)]
    }

    static func appendChat(_ message: ChatMessage, into state: inout MultiplayerState) {
        guard !state.chatLog.contains(where: { $0.id == message.id }) else { return }
        state.chatLog.append(message)
        appendCapped(PendingChat(playerID: message.senderID, text: message.text), to: &state.pendingChats)
        if state.chatLog.count > chatLogLimit {
            state.chatLog.removeFirst(state.chatLog.count - chatLogLimit)
        }
    }

    public static func makePose(_ pose: PlayerPose, reliable: Bool = false) -> RelayMessage {
        RelayMessage(message: .pose(pose), reliable: reliable)
    }

    public static func setColor(_ color: AvatarColor, into state: inout MultiplayerState) -> [RelayMessage] {
        state.localColor = color
        return [RelayMessage(message: .color(color), reliable: true)]
    }

    public static func sendEmote(_ emote: EmoteKind, into state: inout MultiplayerState) -> [RelayMessage] {
        appendCapped(PendingEmote(playerID: state.localPlayerID, emote: emote), to: &state.pendingEmotes)
        return [RelayMessage(message: .emote(emote), reliable: true)]
    }

    // MARK: Dance

    public static func requestDance(target: String, into state: inout MultiplayerState) -> [RelayMessage] {
        if state.sentDanceRequests.count < pendingQueueLimit { state.sentDanceRequests.insert(target) }
        return [RelayMessage(message: .danceRequest(target: target), reliable: true)]
    }

    public static func respondDance(to requester: String, accepted: Bool, into state: inout MultiplayerState) -> [RelayMessage] {
        state.pendingDanceRequests.removeAll { $0 == requester }
        if accepted { state.dancingPartners.insert(requester) }
        return [RelayMessage(message: .danceResponse(target: requester, accepted: accepted), reliable: true)]
    }

    public static func endDance(with partner: String, into state: inout MultiplayerState) -> [RelayMessage] {
        state.dancingPartners.remove(partner)
        state.sentDanceRequests.remove(partner)
        return [RelayMessage(message: .danceEnd(partner: partner), reliable: true)]
    }

    // MARK: Gifting

    public static func sendGift(_ gift: GiftPayload, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .gift(gift), reliable: true)]
    }

    // MARK: Paint trading

    public static func sendTradeOffer(_ offer: TradePayload, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .tradeOffer(offer), reliable: true)]
    }

    public static func sendTradeResponse(_ response: TradeResponse, into state: inout MultiplayerState) -> [RelayMessage] {
        state.pendingTradeOffers.removeAll { $0.id == response.offerID }
        return [RelayMessage(message: .tradeResponse(response), reliable: true)]
    }

    // MARK: Hearts

    public static func sendHeart(_ heart: HeartPayload, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .heart(heart), reliable: true)]
    }

    // MARK: Taps

    public static func sendTap(_ tap: TapSparkle, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .tap(tap), reliable: true)]
    }

    public static func sendCollisionGlow(_ glow: CollisionGlow, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .collisionGlow(glow), reliable: false)]
    }

    // MARK: Color unlocks

    public static func sendColorUnlock(_ unlock: ColorUnlock, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .colorUnlock(unlock), reliable: true)]
    }

    // MARK: Activities

    public static func sendActivity(_ action: ActivityAction, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .activity(action), reliable: true)]
    }

    // MARK: Skybox

    // Picks the room's shared skybox. Local write updates state immediately so
    // the picker sees their own dome swap with no round-trip latency, then the
    // choice is broadcast reliably so every peer adopts it. Last write wins:
    // an incoming older change is dropped.
    public static func setSkybox(_ skybox: SkyboxState, into state: inout MultiplayerState) -> [RelayMessage] {
        applySkybox(skybox, into: &state)
        return [RelayMessage(message: .skybox(skybox), reliable: true)]
    }

    static func applySkybox(_ skybox: SkyboxState, into state: inout MultiplayerState, now: Date = Date()) {
        var skybox = skybox
        skybox.changedAt = clampToLocalClock(skybox.changedAt, now: now)
        guard skybox.changedAt >= state.skybox.changedAt else { return }
        state.skybox = skybox
    }

    public static func makeProps(_ props: [PropState], reliable: Bool = false, into state: inout MultiplayerState) -> RelayMessage {
        for prop in props { state.remoteProps[prop.id] = prop }
        return RelayMessage(message: .props(props), reliable: reliable)
    }

    public static func broadcastColor(_ state: MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .color(state.localColor), reliable: true)]
    }

    // Only the host emits the authoritative roster.
    public static func hostRoster(_ state: MultiplayerState) -> [RelayMessage] {
        guard state.isHost else { return [] }
        var roster = state.remoteColors
        roster[state.localPlayerID] = state.localColor
        // Each entry is individually legal, but a few painted avatars sum past
        // the packet ceiling and every receiver drops the whole roster. Paint
        // already arrives on each owner's own .color packet, so shed it rather
        // than lose the colors.
        if NetMessage.rosterPaintBytes(roster) > NetMessage.maxRosterPaintBytes {
            for (id, var color) in roster {
                color.paint = nil
                roster[id] = color
            }
        }
        return [RelayMessage(message: .roster(roster), reliable: true)]
    }

    // Host replays the live room skybox so a late joiner adopts the dome
    // immediately without the picker having to re-tap.
    private static func broadcastSkybox(_ state: MultiplayerState) -> [RelayMessage] {
        guard state.isHost else { return [] }
        return [RelayMessage(message: .skybox(state.skybox), reliable: true)]
    }

    // MARK: Minigames

    // Round host offers a game to the lobby. The host counts as accepted.
    public static func sendMinigameInvite(_ invite: MinigameInvite, into state: inout MultiplayerState) -> [RelayMessage] {
        state.minigameAcceptances[invite.id] = [invite.hostID]
        return [RelayMessage(message: .minigameInvite(invite), reliable: true)]
    }

    public static func respondMinigameInvite(gameID: String, accepted: Bool, into state: inout MultiplayerState) -> [RelayMessage] {
        state.pendingMinigameInvites.removeAll { $0.id == gameID }
        let localID = state.localPlayerID
        if accepted {
            state.minigameAcceptances[gameID, default: []].insert(localID)
        } else {
            // Declining after an earlier accept must retract that acceptance.
            state.minigameAcceptances[gameID]?.remove(localID)
        }
        return [RelayMessage(message: .minigameInviteResponse(gameID: gameID, accepted: accepted), reliable: true)]
    }

    // Round host locks the roster and timer and starts the round everywhere.
    public static func startMinigame(_ start: MinigameStart, into state: inout MultiplayerState) -> [RelayMessage] {
        applyMinigameStart(start, into: &state)
        return [RelayMessage(message: .minigameStart(start), reliable: true)]
    }

    static func applyMinigameStart(_ start: MinigameStart, into state: inout MultiplayerState) {
        state.minigameAcceptances.removeValue(forKey: start.gameID)
        state.pendingMinigameInvites.removeAll { $0.id == start.gameID }
        guard start.players.contains(state.localPlayerID) else { return }
        state.activeMinigame = start
        state.minigameClaims = [:]
        state.minigameResults = nil
        state.minigameBall = nil
    }

    // Broadcasts the owner's authoritative ball state. Sent unreliably: a
    // dropped frame is harmless, the next tick supersedes it.
    public static func sendMinigameBall(_ sync: BallSync, into state: inout MultiplayerState) -> [RelayMessage] {
        state.minigameBall = sync
        return [RelayMessage(message: .minigameBall(sync), reliable: false)]
    }

    // Claims one object for the local player in the active round. Last claim
    // wins, so painting over a rival's object steals it.
    public static func sendMinigameClaim(key: String, packed: Int, into state: inout MultiplayerState) -> [RelayMessage] {
        guard let game = state.activeMinigame else { return [] }
        state.minigameClaims[key] = MinigameClaim(playerID: state.localPlayerID, packed: packed)
        let event = MinigameEvent(gameID: game.gameID, playerID: state.localPlayerID, key: key, value: packed)
        return [RelayMessage(message: .minigameEvent(event), reliable: true)]
    }

    // Live per-player object counts for the active round.
    public static func minigameScores(_ state: MultiplayerState) -> [String: Int] {
        guard let game = state.activeMinigame else { return [:] }
        // A peer may send a roster with repeated ids; uniqueKeysWithValues traps
        // on those, so collapse duplicates instead.
        var scores = Dictionary(game.players.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        for claim in state.minigameClaims.values where scores[claim.playerID] != nil {
            scores[claim.playerID, default: 0] += 1
        }
        return scores
    }

    // Round host tallies the final scores and ends the round everywhere.
    public static func endMinigame(into state: inout MultiplayerState) -> [RelayMessage] {
        guard let game = state.activeMinigame else { return [] }
        let end = MinigameEnd(gameID: game.gameID, kind: game.kind, scores: minigameScores(state))
        applyMinigameEnd(end, into: &state)
        return [RelayMessage(message: .minigameEnd(end), reliable: true)]
    }

    static func applyMinigameEnd(_ end: MinigameEnd, into state: inout MultiplayerState) {
        guard state.activeMinigame?.gameID == end.gameID else { return }
        state.activeMinigame = nil
        state.minigameResults = end
        state.minigameBall = nil
        // Round scratch has no other drain: without this it survives until some
        // later round happens to start.
        state.minigameClaims = [:]
        state.minigameAcceptances.removeValue(forKey: end.gameID)
    }

    // MARK: Inbound

    // Decode raw wire bytes and apply. Returns relay side effects (host roster).
    public static func receive(_ data: Data, from playerID: String, into state: inout MultiplayerState) -> [RelayMessage] {
        guard let message = NetMessage.decode(data) else { return [] }
        return apply(message, from: playerID, into: &state)
    }

    public static func apply(_ message: NetMessage, from playerID: String, into state: inout MultiplayerState) -> [RelayMessage] {
        switch message {
        case .pose(let pose):
            state.remotePoses[playerID] = pose
            return []
        case .color(let color):
            state.remoteColors[playerID] = color
            return hostRoster(state)
        case .emote(let emote):
            appendCapped(PendingEmote(playerID: playerID, emote: emote), to: &state.pendingEmotes)
            return []
        case .chat(let message):
            appendChat(message, into: &state)
            return []
        case .props(let props):
            for prop in props {
                let current = state.remoteProps[prop.id]
                // New prop ids past the ceiling are dropped; a peer minting ids
                // must not be able to grow the map without bound.
                guard current != nil || state.remoteProps.count < Self.propLimit else { continue }
                if prop.holder == playerID {
                    // A player may always claim and move a prop it says it holds.
                    state.remoteProps[prop.id] = prop
                } else if prop.holder == nil, current == nil || current?.holder == playerID {
                    // Only the current holder can release.
                    state.remoteProps[prop.id] = prop
                }
            }
            return []
        case .paint(let strokes):
            for stroke in strokes { appendStroke(stroke, into: &state) }
            return []
        case .paintClear:
            state.paintStrokes.removeAll()
            return []
        case .signs(let signs):
            for sign in signs { applySign(sign, into: &state) }
            return []
        case .roster(let roster):
            // Only the session host publishes the authoritative roster. A
            // non-host peer must never be able to repaint the whole lobby.
            guard state.isHost(playerID) else { return [] }
            // Only ids the transport actually knows about. A host cannot invent
            // players, and stale roster entries never accumulate.
            let known = state.connectedPeers.union(state.ghostPeers.keys).union([playerID])
            for (id, color) in roster where id != state.localPlayerID && known.contains(id) {
                state.remoteColors[id] = color
            }
            return []
        case .kick:
            // Enforced by the transport layer, not the pure reducer.
            return []
        case .danceRequest(let target):
            if target == state.localPlayerID, !state.pendingDanceRequests.contains(playerID) {
                state.pendingDanceRequests.append(playerID)
            }
            return []
        case .danceResponse(let target, let accepted):
            // Only the original requester acts on the answer, and only for a
            // request it actually sent.
            if target == state.localPlayerID, state.sentDanceRequests.contains(playerID) {
                state.sentDanceRequests.remove(playerID)
                if accepted { state.dancingPartners.insert(playerID) }
            }
            return []
        case .gift(let gift):
            guard gift.target == state.localPlayerID,
                  !state.pendingGifts.contains(where: { $0.id == gift.id }) else { return [] }
            appendCapped(gift, to: &state.pendingGifts)
            return []
        case .heart(let heart):
            guard heart.target == state.localPlayerID,
                  !state.pendingHearts.contains(where: { $0.id == heart.id }) else { return [] }
            appendCapped(heart, to: &state.pendingHearts)
            return []
        case .tradeOffer(let offer):
            guard offer.target == state.localPlayerID,
                  !state.pendingTradeOffers.contains(where: { $0.id == offer.id }) else { return [] }
            appendCapped(offer, to: &state.pendingTradeOffers)
            return []
        case .tradeResponse(let response):
            guard response.target == state.localPlayerID,
                  !state.pendingTradeResponses.contains(where: { $0.id == response.id }) else { return [] }
            appendCapped(response, to: &state.pendingTradeResponses)
            return []
        case .danceEnd(let partner):
            // Partner is the requester's view of the pair; either id ending
            // the dance stops it locally.
            if partner == state.localPlayerID || state.dancingPartners.contains(playerID) {
                state.dancingPartners.remove(playerID)
            }
            state.pendingDanceRequests.removeAll { $0 == playerID }
            state.sentDanceRequests.remove(playerID)
            return []
        case .tap(let tap):
            guard !state.pendingTaps.contains(where: { $0.id == tap.id }) else { return [] }
            appendCapped(tap, to: &state.pendingTaps)
            return []
        case .collisionGlow(let glow):
            guard !state.pendingCollisionGlows.contains(where: { $0.id == glow.id }) else { return [] }
            appendCapped(glow, to: &state.pendingCollisionGlows)
            return []
        case .colorUnlock(let unlock):
            guard !state.pendingColorUnlocks.contains(where: { $0.id == unlock.id }) else { return [] }
            appendCapped(unlock, to: &state.pendingColorUnlocks)
            return []
        case .activity(let action):
            guard !state.pendingActivities.contains(where: { $0.id == action.id }) else { return [] }
            appendCapped(action, to: &state.pendingActivities)
            return []
        case .skybox(let skybox):
            applySkybox(skybox, into: &state)
            return []
        case .name:
            // Names live on the service (playerNames), not in pure state.
            // Intercepted by the transport layer before reaching the reducer.
            return []
        case .minigameInvite(let invite):
            // Only the round host's own invite is honored, and never re-queued.
            guard invite.hostID == playerID,
                  invite.hostID != state.localPlayerID,
                  state.activeMinigame == nil,
                  !state.pendingMinigameInvites.contains(where: { $0.id == invite.id }) else { return [] }
            // Acceptance keys outlive the invite array, so an invite flood used
            // to grow the map forever and whitelist every invented gameID.
            guard state.minigameAcceptances.count < Self.acceptanceLimit
                    || state.minigameAcceptances[invite.id] != nil else { return [] }
            let evicted = appendCappedReturningEvicted(invite, to: &state.pendingMinigameInvites)
            for stale in evicted { state.minigameAcceptances.removeValue(forKey: stale.id) }
            state.minigameAcceptances[invite.id, default: []].insert(invite.hostID)
            return []
        case .minigameInviteResponse(let gameID, let accepted):
            // Only rounds this peer already knows about are tracked, otherwise a
            // peer spamming responses for invented gameIDs grows the map forever.
            guard state.minigameAcceptances[gameID] != nil else { return [] }
            if accepted {
                state.minigameAcceptances[gameID]?.insert(playerID)
            } else {
                state.minigameAcceptances[gameID]?.remove(playerID)
            }
            return []
        case .minigameStart(let start):
            // Only the round host may start its own round, and never on top of
            // a live one: a third peer must not be able to wipe the round the
            // local player is playing.
            guard start.hostID == playerID,
                  state.activeMinigame == nil || state.activeMinigame?.gameID == start.gameID else { return [] }
            applyMinigameStart(start, into: &state)
            return []
        case .minigameEvent(let event):
            // Sender identity comes from the packet, never the payload.
            guard let game = state.activeMinigame,
                  game.gameID == event.gameID,
                  game.players.contains(playerID) else { return [] }
            guard state.minigameClaims[event.key] != nil
                    || state.minigameClaims.count < Self.claimLimit else { return [] }
            state.minigameClaims[event.key] = MinigameClaim(playerID: playerID, packed: event.value)
            return []
        case .minigameEnd(let end):
            // Sent by the round host, or by the session host when the round host
            // disconnected. Any other participant ending the round is a spoof.
            guard state.activeMinigame?.gameID == end.gameID else { return [] }
            let roundHost = state.activeMinigame?.hostID
            // The session host is a fallback only for a round whose host left.
            let roundHostGone = roundHost.map { !state.connectedPeers.contains($0) && $0 != state.localPlayerID } ?? true
            guard playerID == roundHost || (state.isHost(playerID) && roundHostGone) else { return [] }
            applyMinigameEnd(end, into: &state)
            return []
        case .minigameBall(let sync):
            // Only the packet sender may drive the ball, and only for the live
            // round. Last-write-wins by seq guards against reordered packets
            // arriving right after an ownership handoff.
            guard let game = state.activeMinigame,
                  game.gameID == sync.gameID,
                  game.players.contains(playerID),
                  sync.ownerID == playerID else { return [] }
            // Seq is per-owner (each sender counts from 1 when it seizes the
            // ball), so it only orders packets within one ownership run. A
            // handoff is always accepted: peers legitimately hold divergent ball
            // state (a neutral kickoff carries no authority and is dropped), so a
            // room-global counter would let stale local state veto the new owner.
            if let current = state.minigameBall,
               current.ownerID == sync.ownerID,
               current.seq > sync.seq { return [] }
            state.minigameBall = sync
            return []
        case .ping, .pong:
            // Handled at the transport layer (GameCenterService); no state.
            return []
        }
    }

    // MARK: Connection lifecycle

    public static func peerChanged(
        _ playerID: String,
        connected: Bool,
        keepGhost: Bool = false,
        at date: Date = Date(),
        into state: inout MultiplayerState
    ) -> [RelayMessage] {
        if connected {
            state.connectedPeers.insert(playerID)
            // A rejoining ghost reanimates in place: its avatar already sits
            // at the last known spot, so live poses smooth from there.
            state.ghostPeers.removeValue(forKey: playerID)
            return broadcastColor(state) + hostRoster(state) + broadcastSkybox(state)
        } else {
            state.connectedPeers.remove(playerID)
            state.dancingPartners.remove(playerID)
            state.sentDanceRequests.remove(playerID)
            state.pendingDanceRequests.removeAll { $0 == playerID }
            // Withdraw the departed player's round offers and acceptances.
            let live = Set(state.pendingMinigameInvites.filter { $0.hostID == playerID }.map(\.id))
            state.pendingMinigameInvites.removeAll { $0.hostID == playerID }
            // Drop the acceptance bookkeeping for the withdrawn offers outright,
            // otherwise the keys linger for the life of the lobby.
            for gameID in live where state.activeMinigame?.gameID != gameID {
                state.minigameAcceptances.removeValue(forKey: gameID)
            }
            for gameID in state.minigameAcceptances.keys {
                state.minigameAcceptances[gameID]?.remove(playerID)
            }
            if keepGhost, state.remotePoses[playerID] != nil {
                state.ghostPeers[playerID] = date
            } else {
                state.remotePoses.removeValue(forKey: playerID)
                state.remoteColors.removeValue(forKey: playerID)
                state.ghostPeers.removeValue(forKey: playerID)
            }
            // Drop anything the leaving player was carrying.
            for (id, prop) in state.remoteProps where prop.holder == playerID {
                var released = prop
                released.holder = nil
                state.remoteProps[id] = released
            }
            return []
        }
    }

    // Removes ghosts older than the interval. Returns the expired player ids
    // so the transport layer can drop names and any other per-player caches.
    public static func pruneGhosts(
        olderThan interval: TimeInterval,
        now: Date = Date(),
        into state: inout MultiplayerState
    ) -> [String] {
        let expired = state.ghostPeers.filter { now.timeIntervalSince($0.value) > interval }.map(\.key)
        for id in expired {
            state.ghostPeers.removeValue(forKey: id)
            state.remotePoses.removeValue(forKey: id)
            state.remoteColors.removeValue(forKey: id)
        }
        return expired
    }
}
