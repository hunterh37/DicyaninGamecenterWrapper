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

// Pure reducer. Every function returns the messages the transport must send.
public enum MultiplayerReducer {

    // MARK: Outbound (local intents)

    public static func makePose(_ pose: PlayerPose) -> RelayMessage {
        RelayMessage(message: .pose(pose), reliable: false)
    }

    public static func setColor(_ color: AvatarColor, into state: inout MultiplayerState) -> [RelayMessage] {
        state.localColor = color
        return [RelayMessage(message: .color(color), reliable: true)]
    }

    public static func sendEmote(_ emote: EmoteKind, into state: inout MultiplayerState) -> [RelayMessage] {
        state.pendingEmotes.append(PendingEmote(playerID: state.localPlayerID, emote: emote))
        return [RelayMessage(message: .emote(emote), reliable: true)]
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
        case .roster(let roster):
            for (id, color) in roster where id != state.localPlayerID {
                state.remoteColors[id] = color
            }
            return []
        case .kick:
            // Enforced by the transport layer, not the pure reducer.
            return []
        }
    }

    // MARK: Connection lifecycle

    public static func peerChanged(_ playerID: String, connected: Bool, into state: inout MultiplayerState) -> [RelayMessage] {
        if connected {
            state.connectedPeers.insert(playerID)
            return broadcastColor(state) + hostRoster(state)
        } else {
            state.connectedPeers.remove(playerID)
            state.remotePoses.removeValue(forKey: playerID)
            state.remoteColors.removeValue(forKey: playerID)
            return []
        }
    }
}
