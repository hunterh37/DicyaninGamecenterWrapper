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
    // Tap shimmer effects received (from any peer, including a local echo) that
    // the app has not yet spawned in the scene, oldest first.
    public var pendingTaps: [TapSparkle] = []
    // keyed by player id with the moment they departed. Their last pose and
    // color are kept in remotePoses/remoteColors until pruned or they rejoin.
    public var ghostPeers: [String: Date] = [:]

    public init(localPlayerID: String) {
        self.localPlayerID = localPlayerID
    }

    // Host is the lowest id among every connected participant plus self.
    public var isHost: Bool {
        connectedPeers.union([localPlayerID]).min() == localPlayerID
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

// Pure reducer. Every function returns the messages the transport must send.
public enum MultiplayerReducer {

    // Most recent chat lines to retain per participant.
    public static let chatLogLimit = 100

    // Most recent paint strokes to retain on the shared board.
    public static let paintStrokeLimit = 500

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

    static func applySign(_ sign: SignState, into state: inout MultiplayerState) {
        if let current = state.signMessages[sign.id], current.editedAt > sign.editedAt { return }
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
        state.pendingChats.append(PendingChat(playerID: message.senderID, text: message.text))
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
        state.pendingEmotes.append(PendingEmote(playerID: state.localPlayerID, emote: emote))
        return [RelayMessage(message: .emote(emote), reliable: true)]
    }

    // MARK: Dance

    public static func requestDance(target: String) -> [RelayMessage] {
        [RelayMessage(message: .danceRequest(target: target), reliable: true)]
    }

    public static func respondDance(to requester: String, accepted: Bool, into state: inout MultiplayerState) -> [RelayMessage] {
        state.pendingDanceRequests.removeAll { $0 == requester }
        if accepted { state.dancingPartners.insert(requester) }
        return [RelayMessage(message: .danceResponse(target: requester, accepted: accepted), reliable: true)]
    }

    public static func endDance(with partner: String, into state: inout MultiplayerState) -> [RelayMessage] {
        state.dancingPartners.remove(partner)
        return [RelayMessage(message: .danceEnd(partner: partner), reliable: true)]
    }

    // MARK: Gifting

    public static func sendGift(_ gift: GiftPayload, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .gift(gift), reliable: true)]
    }

    // MARK: Hearts

    public static func sendHeart(_ heart: HeartPayload, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .heart(heart), reliable: true)]
    }

    // MARK: Taps

    public static func sendTap(_ tap: TapSparkle, into state: inout MultiplayerState) -> [RelayMessage] {
        [RelayMessage(message: .tap(tap), reliable: true)]
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
        return [RelayMessage(message: .roster(roster), reliable: true)]
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
            state.pendingEmotes.append(PendingEmote(playerID: playerID, emote: emote))
            return []
        case .chat(let message):
            appendChat(message, into: &state)
            return []
        case .props(let props):
            for prop in props {
                let current = state.remoteProps[prop.id]
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
            for (id, color) in roster where id != state.localPlayerID {
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
            // Only the original requester acts on the answer.
            if target == state.localPlayerID {
                if accepted { state.dancingPartners.insert(playerID) }
            }
            return []
        case .gift(let gift):
            guard gift.target == state.localPlayerID,
                  !state.pendingGifts.contains(where: { $0.id == gift.id }) else { return [] }
            state.pendingGifts.append(gift)
            return []
        case .heart(let heart):
            guard heart.target == state.localPlayerID,
                  !state.pendingHearts.contains(where: { $0.id == heart.id }) else { return [] }
            state.pendingHearts.append(heart)
            return []
        case .danceEnd(let partner):
            // Partner is the requester's view of the pair; either id ending
            // the dance stops it locally.
            if partner == state.localPlayerID || state.dancingPartners.contains(playerID) {
                state.dancingPartners.remove(playerID)
            }
            state.pendingDanceRequests.removeAll { $0 == playerID }
            return []
        case .tap(let tap):
            guard !state.pendingTaps.contains(where: { $0.id == tap.id }) else { return [] }
            state.pendingTaps.append(tap)
            return []
        case .name:
            // Names live on the service (playerNames), not in pure state.
            // Intercepted by the transport layer before reaching the reducer.
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
            return broadcastColor(state) + hostRoster(state)
        } else {
            state.connectedPeers.remove(playerID)
            state.dancingPartners.remove(playerID)
            state.pendingDanceRequests.removeAll { $0 == playerID }
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
