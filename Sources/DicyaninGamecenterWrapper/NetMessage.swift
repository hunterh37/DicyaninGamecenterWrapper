import Foundation
import simd

// Wire format for all Game Center match traffic. Host authoritative:
// the host relays lobby state; clients trust everything the host sends.

public enum EmoteKind: Int, Codable, CaseIterable, Identifiable {
    case wave = 0
    case heart
    case thumbsUp
    case laugh
    case fire
    case question
    case clap
    case cry
    case party
    case cool
    case angry
    case wow
    case rocket
    case hundred

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .wave: return "Wave"
        case .heart: return "Heart"
        case .thumbsUp: return "Thumbs Up"
        case .laugh: return "Laugh"
        case .fire: return "Fire"
        case .question: return "Question"
        case .clap: return "Clap"
        case .cry: return "Cry"
        case .party: return "Party"
        case .cool: return "Cool"
        case .angry: return "Angry"
        case .wow: return "Wow"
        case .rocket: return "Rocket"
        case .hundred: return "Hundred"
        }
    }

    // 3D text shown above the avatar. No emoji, per project rules.
    public var label: String {
        switch self {
        case .wave: return "HI"
        case .heart: return "<3"
        case .thumbsUp: return "+1"
        case .laugh: return "LOL"
        case .fire: return "FIRE"
        case .question: return "?"
        case .clap: return "CLAP"
        case .cry: return "T_T"
        case .party: return "YAY"
        case .cool: return "COOL"
        case .angry: return "GRR"
        case .wow: return "WOW"
        case .rocket: return "GO"
        case .hundred: return "100"
        }
    }

    // Glyph shown as the floating 3D reaction above the avatar.
    public var emoji: String {
        switch self {
        case .wave: return "\u{1F44B}"
        case .heart: return "\u{2764}\u{FE0F}"
        case .thumbsUp: return "\u{1F44D}"
        case .laugh: return "\u{1F602}"
        case .fire: return "\u{1F525}"
        case .question: return "\u{2753}"
        case .clap: return "\u{1F44F}"
        case .cry: return "\u{1F62D}"
        case .party: return "\u{1F389}"
        case .cool: return "\u{1F60E}"
        case .angry: return "\u{1F621}"
        case .wow: return "\u{1F62E}"
        case .rocket: return "\u{1F680}"
        case .hundred: return "\u{1F4AF}"
        }
    }
}

public struct CodableTransform: Codable, Equatable {
    public var px: Float, py: Float, pz: Float
    public var qx: Float, qy: Float, qz: Float, qw: Float

    public init(_ m: simd_float4x4) {
        let p = m.columns.3
        px = p.x; py = p.y; pz = p.z
        let q = simd_quatf(m)
        qx = q.imag.x; qy = q.imag.y; qz = q.imag.z; qw = q.real
    }

    public var position: SIMD3<Float> { [px, py, pz] }
    public var rotation: simd_quatf { simd_quatf(ix: qx, iy: qy, iz: qz, r: qw) }
}

public struct PlayerPose: Codable, Equatable {
    public init(head: CodableTransform, leftHand: CodableTransform? = nil, rightHand: CodableTransform? = nil, sitting: Bool? = nil, brushCursor: CodableTransform? = nil) {
        self.head = head
        self.leftHand = leftHand
        self.rightHand = rightHand
        self.sitting = sitting
        self.brushCursor = brushCursor
    }
    public var head: CodableTransform
    public var leftHand: CodableTransform?
    public var rightHand: CodableTransform?
    // True while the player is seated. Optional so old clients decode without
    // it. Drives the seated body pose on every peer from this one flag.
    public var sitting: Bool?
    // World position (room space, same frame as `head`) of the paint brush
    // while the player is actively painting; nil the rest of the time.
    // Optional so old clients decode without it. Drives a small brush-cursor
    // prop that every peer renders following the painter's stroke live.
    public var brushCursor: CodableTransform?
}

extension CodableTransform {
    public init(position: SIMD3<Float>, rotation: simd_quatf) {
        px = position.x; py = position.y; pz = position.z
        qx = rotation.imag.x; qy = rotation.imag.y; qz = rotation.imag.z; qw = rotation.real
    }
}

// One networked grabbable object. holder is the player currently carrying
// it, nil when it sits free in the world. Same wire style as PlayerPose:
// unreliable transforms at tick rate while held, reliable release.
public struct PropState: Codable, Equatable {
    public init(id: Int, holder: String?, transform: CodableTransform) {
        self.id = id
        self.holder = holder
        self.transform = transform
    }
    public var id: Int
    public var holder: String?
    public var transform: CodableTransform
}

// One painted stroke on the shared room paint board. Points are normalized
// to the board's unit square (0...1, origin top-left) so every peer renders
// identically regardless of view size. colorIndex maps to the board palette.
public struct PaintPoint: Codable, Equatable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct PaintStroke: Codable, Equatable, Identifiable {
    public var id: String
    public var colorIndex: Int
    public var width: Float
    public var points: [PaintPoint]
    public init(id: String = UUID().uuidString, colorIndex: Int, width: Float, points: [PaintPoint]) {
        self.id = id
        self.colorIndex = colorIndex
        self.width = width
        self.points = points
    }
}

// One line of lobby chat. Carries the sender name inline so late joiners and
// peers render the author without needing a resolved roster entry.
public struct ChatMessage: Codable, Equatable, Identifiable {
    public var id: String
    public var senderID: String
    public var senderName: String
    public var text: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, senderID: String, senderName: String, text: String, sentAt: Date = Date()) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.sentAt = sentAt
    }
}

// One shared message-board sign. id maps to a fixed sign in the room; text is
// the current message carved on the sign; author travels inline so peers can
// attribute it without a roster lookup. Sent reliably so late edits never drop;
// last write wins per sign id.
public struct SignState: Codable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    public var author: String
    public var editedAt: Date

    public init(id: Int, text: String, author: String, editedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.author = author
        self.editedAt = editedAt
    }
}

// One heart reaction handed from one player to another. senderName travels
// inline so the receiver can show who sent the heart without a roster lookup.
public struct HeartPayload: Codable, Equatable, Identifiable {
    public var id: String
    public var senderID: String
    public var senderName: String
    public var target: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, senderID: String, senderName: String, target: String, sentAt: Date = Date()) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.target = target
        self.sentAt = sentAt
    }
}

// One gifted item handed from one player to another. itemID maps to the app's
// item catalog; the package stays agnostic about what the id means. senderName
// travels inline so the receiver can show who sent it without a roster lookup.
public struct GiftPayload: Codable, Equatable, Identifiable {
    public var id: String
    public var itemID: Int
    public var senderID: String
    public var senderName: String
    public var target: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, itemID: Int, senderID: String, senderName: String, target: String, sentAt: Date = Date()) {
        self.id = id
        self.itemID = itemID
        self.senderID = senderID
        self.senderName = senderName
        self.target = target
        self.sentAt = sentAt
    }
}

// A paint-for-paint trade offer handed from one player to another. offerPacked
// is the 0xRRGGBB paint the sender is putting up. senderName travels inline so
// the receiver shows who offered without a roster lookup. The receiver answers
// with a TradeResponse carrying its own paint back.
public struct TradePayload: Codable, Equatable, Identifiable {
    public var id: String
    public var offerPacked: Int
    public var senderID: String
    public var senderName: String
    public var target: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, offerPacked: Int, senderID: String, senderName: String, target: String, sentAt: Date = Date()) {
        self.id = id
        self.offerPacked = offerPacked
        self.senderID = senderID
        self.senderName = senderName
        self.target = target
        self.sentAt = sentAt
    }
}

// The receiver's answer to a TradePayload, routed back to the original offerer.
// offerID matches the offer. When accepted, returnPacked is the paint the
// receiver gives back and offerPacked echoes the offerer's paint so the
// offerer shows both sides. When declined, returnPacked is ignored.
public struct TradeResponse: Codable, Equatable, Identifiable {
    public var id: String
    public var offerID: String
    public var responderID: String
    public var responderName: String
    public var target: String
    public var accepted: Bool
    public var offerPacked: Int
    public var returnPacked: Int
    public var sentAt: Date

    public init(id: String = UUID().uuidString, offerID: String, responderID: String, responderName: String, target: String, accepted: Bool, offerPacked: Int, returnPacked: Int, sentAt: Date = Date()) {
        self.id = id
        self.offerID = offerID
        self.responderID = responderID
        self.responderName = responderName
        self.target = target
        self.accepted = accepted
        self.offerPacked = offerPacked
        self.returnPacked = returnPacked
        self.sentAt = sentAt
    }
}

// A world-space tap point that spawns a short-lived shimmer + light effect on
// every peer. Position is in the shared room frame (sceneRoot local space) so
// each client renders it at the same spot regardless of locomotion offset.
public struct TapSparkle: Codable, Equatable, Identifiable {
    public var id: String
    public var x: Float
    public var y: Float
    public var z: Float
    public var senderID: String

    public init(id: String = UUID().uuidString, x: Float, y: Float, z: Float, senderID: String) {
        self.id = id
        self.x = x
        self.y = y
        self.z = z
        self.senderID = senderID
    }
}

// A player-to-player touch spark, broadcast to the whole room and shown for a
// moment as an aura-tinted glow + shimmer at the contact point on every peer
// including the sender. r/g/b carry the sender's selected aura color so the
// effect renders in that shade everywhere. Deduped by id.
public struct CollisionGlow: Codable, Equatable, Identifiable {
    public var id: String
    public var x: Float
    public var y: Float
    public var z: Float
    public var r: Float
    public var g: Float
    public var b: Float
    public var senderID: String

    public init(id: String = UUID().uuidString, x: Float, y: Float, z: Float, r: Float, g: Float, b: Float, senderID: String) {
        self.id = id
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
        self.senderID = senderID
    }
}

// A "player looted a new color" celebration, broadcast to the whole room and
// shown for a few seconds as a floating orb over the looter's avatar on every
// peer (including a local echo). packed is the unlocked 0xRRGGBB shade so the
// orb renders in that exact color; colorName + senderName travel inline so
// peers show who unlocked what without a roster lookup.
public struct ColorUnlock: Codable, Equatable, Identifiable {
    public var id: String
    public var senderID: String
    public var senderName: String
    public var colorName: String
    public var packed: Int
    public var sentAt: Date

    public init(id: String = UUID().uuidString, senderID: String, senderName: String, colorName: String, packed: Int, sentAt: Date = Date()) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.colorName = colorName
        self.packed = packed
        self.sentAt = sentAt
    }
}

// One world-activity start (fishing, mining, bug catching, ...), broadcast
// reliably to the whole room including a local echo. stationID maps to a fixed
// seeded station in the scene; kind is the app's activity catalog raw value.
// Deduped by id so a relay never double-starts the animation.
public struct ActivityAction: Codable, Equatable, Identifiable {
    public var id: String
    public var stationID: Int
    public var kind: Int
    public var playerID: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, stationID: Int, kind: Int, playerID: String, sentAt: Date = Date()) {
        self.id = id
        self.stationID = stationID
        self.kind = kind
        self.playerID = playerID
        self.sentAt = sentAt
    }
}

public struct AvatarColor: Codable, Equatable {
    public init(r: Float, g: Float, b: Float, face: Int? = nil, hat: Int? = nil, material: Int? = nil, prop: Int? = nil, body: Int? = nil, height: Int? = nil, equippedItem: Int? = nil, hair: Int? = nil, hairR: Float? = nil, hairG: Float? = nil, hairB: Float? = nil, paint: [String: String]? = nil, flag: String? = nil, status: String? = nil, auraR: Float? = nil, auraG: Float? = nil, auraB: Float? = nil, nameEffect: Int? = nil) {
        self.r = r
        self.g = g
        self.b = b
        self.face = face
        self.hat = hat
        self.material = material
        self.prop = prop
        self.body = body
        self.height = height
        self.equippedItem = equippedItem
        self.hair = hair
        self.hairR = hairR
        self.hairG = hairG
        self.hairB = hairB
        self.paint = paint
        self.flag = flag
        self.status = status
        self.auraR = auraR
        self.auraG = auraG
        self.auraB = auraB
        self.nameEffect = nameEffect
    }
    public var r: Float
    public var g: Float
    public var b: Float
    // Face style raw value. Optional so old clients decode without it.
    public var face: Int?
    // Hat style raw value. Optional so old clients decode without it.
    public var hat: Int?
    // Surface finish raw value. Optional so old clients decode without it.
    public var material: Int?
    // Held prop raw value. Optional so old clients decode without it.
    public var prop: Int?
    // Body build raw value (masculine/feminine silhouettes). Optional so old
    // clients decode without it.
    public var body: Int?
    // Height preset raw value. Optional so old clients decode without it.
    public var height: Int?
    // Equipped inventory item id held in the avatar's hand. Distinct from
    // `prop` (the legacy hand-prop picker). Optional so old clients decode
    // without it.
    public var equippedItem: Int?
    // Hair style raw value. Optional so old clients decode without it.
    public var hair: Int?
    // Hair tint channels. Optional so old clients decode without them.
    public var hairR: Float?
    public var hairG: Float?
    public var hairB: Float?
    // Per-body-part painted surface, keyed by BodyPart.rawValue. Each value is a
    // zlib-compressed, base64-encoded RGBA8 256x256 canvas so a painted design
    // travels over the wire and every peer rebuilds the identical mesh texture.
    // Optional so old clients decode without it.
    public var paint: [String: String]?
    // Nationality flag emoji chosen for the profile. Optional so old clients
    // decode without it.
    public var flag: String?
    // Mood status emoji shown on the profile and above the avatar. Optional so
    // old clients decode without it.
    public var status: String?
    // Personal aura accent color (nametag tint, selection glow, avatar rim).
    // Optional so old clients decode without it.
    public var auraR: Float?
    public var auraG: Float?
    public var auraB: Float?
    // Animated 3D nametag style raw value (AvatarNameEffect). Optional so old
    // clients decode without it.
    public var nameEffect: Int?

    public static let `default` = AvatarColor(r: 0.55, g: 0.75, b: 0.95)
}

// MARK: - Minigames

// Catalog of battle minigames playable inside a lobby. New games add a case
// here plus app-side rules; the wire and lifecycle plumbing is shared.
public enum MinigameKind: Int, Codable, CaseIterable, Identifiable {
    case paintRush = 0
    case voxelBall = 1
    case soccer = 2

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .paintRush: return "Paint Rush"
        case .voxelBall: return "Voxel Rumble"
        case .soccer: return "Soccer Showdown"
        }
    }

    public var blurb: String {
        switch self {
        case .paintRush: return "Paint the most objects in your color before time runs out"
        case .voxelBall: return "Dash the ball into the walls. Claim the most voxels in your color."
        case .soccer: return "Two teams, one ball. Tackle to steal it, shoot it into the other goal."
        }
    }

    // Round length in seconds.
    public var duration: TimeInterval {
        switch self {
        case .paintRush: return 60
        case .voxelBall: return 90
        case .soccer: return 120
        }
    }

    public var minPlayers: Int { 2 }
}

// Authoritative flying-ball state for Voxel Rumble, broadcast unreliably at
// ~15 Hz by the player who currently owns the ball (or the round host while
// the ball is still neutral). ownerID is empty while neutral; packed is the
// owner's battle color. seq is a monotonic stamp for last-write-wins so a
// stale packet never rewinds a fresher one after an ownership handoff.
public struct BallSync: Codable, Equatable {
    public var gameID: String
    public var ownerID: String
    public var packed: Int
    public var px: Float
    public var py: Float
    public var pz: Float
    public var vx: Float
    public var vy: Float
    public var vz: Float
    public var seq: Int

    public init(gameID: String, ownerID: String, packed: Int,
                px: Float, py: Float, pz: Float,
                vx: Float, vy: Float, vz: Float, seq: Int) {
        self.gameID = gameID
        self.ownerID = ownerID
        self.packed = packed
        self.px = px; self.py = py; self.pz = pz
        self.vx = vx; self.vy = vy; self.vz = vz
        self.seq = seq
    }
}

// A lobby-wide invitation to a minigame round, broadcast by the host of the
// round. Peers accept or decline via minigameInviteResponse.
public struct MinigameInvite: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: Int
    public var hostID: String
    public var hostName: String
    public var sentAt: Date

    public init(id: String = UUID().uuidString, kind: Int, hostID: String, hostName: String, sentAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.hostID = hostID
        self.hostName = hostName
        self.sentAt = sentAt
    }
}

// Authoritative round start, sent reliably by the round host to everyone.
// Only players listed in `players` participate; everyone else ignores it.
public struct MinigameStart: Codable, Equatable {
    public var gameID: String
    public var kind: Int
    public var hostID: String
    public var players: [String]
    public var startedAt: Date
    public var endsAt: Date

    public init(gameID: String, kind: Int, hostID: String, players: [String], startedAt: Date = Date(), endsAt: Date) {
        self.gameID = gameID
        self.kind = kind
        self.hostID = hostID
        self.players = players
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

// One generic in-round action. For paint rush: key is the painted object's
// editID and value is the painter's packed 0xRRGGBB color. Future games reuse
// the same envelope with their own key/value meanings.
public struct MinigameEvent: Codable, Equatable {
    public var gameID: String
    public var playerID: String
    public var key: String
    public var value: Int

    public init(gameID: String, playerID: String, key: String, value: Int) {
        self.gameID = gameID
        self.playerID = playerID
        self.key = key
        self.value = value
    }
}

// Authoritative round results, sent reliably by the round host when the
// timer expires. Scores are final; highest score wins.
public struct MinigameEnd: Codable, Equatable {
    public var gameID: String
    public var kind: Int
    public var scores: [String: Int]
    public var endedAt: Date

    public init(gameID: String, kind: Int, scores: [String: Int], endedAt: Date = Date()) {
        self.gameID = gameID
        self.kind = kind
        self.scores = scores
        self.endedAt = endedAt
    }

    public var winnerID: String? {
        scores.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key > b.key
        }?.key
    }
}

public enum NetMessage: Codable, Equatable {
    // Sent unreliably at ~15 Hz by every player.
    case pose(PlayerPose)
    // Sent reliably.
    case color(AvatarColor)
    case emote(EmoteKind)
    // Lobby text chat, sent reliably.
    case chat(ChatMessage)
    // Grabbable prop transforms. Unreliable at ~15 Hz while held; a release
    // (holder nil) is sent reliably so props never stick to a hand.
    case props([PropState])
    // Shared paint board strokes, sent reliably as each stroke completes so
    // late traffic never drops a drawing. paintClear wipes the whole board.
    case paint([PaintStroke])
    case paintClear
    // Shared message-board signs, sent reliably as each sign is edited. Last
    // write wins per sign id so every peer converges on the latest message.
    case signs([SignState])
    // Host relay: full roster of known colors, sent when players connect.
    case roster([String: AvatarColor])
    // Host only. Instructs the named player to leave the match.
    case kick(String)
    // Social dance handshake, all sent reliably. danceRequest asks target to
    // dance; danceResponse answers the original requester; danceEnd tells a
    // partner the dance is over. Sender is the match player id of the packet.
    case danceRequest(target: String)
    case danceResponse(target: String, accepted: Bool)
    case danceEnd(partner: String)
    // Player-to-player item gift, sent reliably. Broadcast to the room; only
    // the peer whose id matches payload.target acts on it.
    case gift(GiftPayload)
    // Player-to-player paint trade handshake, both sent reliably. tradeOffer
    // proposes a paint to the target; tradeResponse routes the answer back to
    // the original offerer. Both broadcast; only the payload target acts.
    case tradeOffer(TradePayload)
    case tradeResponse(TradeResponse)
    // Player-to-player heart reaction, sent reliably. Broadcast to the room;
    // only the peer whose id matches payload.target acts on it.
    case heart(HeartPayload)
    // Custom in-game display name, sent reliably on connect and on change so
    // peers show the player-chosen name instead of the Game Center alias.
    case name(String)
    // Transient tap shimmer effect, broadcast to the whole room and shown for a
    // few seconds at the tap position on every peer including the sender.
    case tap(TapSparkle)
    // Transient player-to-player touch spark, broadcast to the whole room and
    // shown at the contact point in the sender's aura color on every peer
    // including the sender. Deduped by id.
    case collisionGlow(CollisionGlow)
    // A prop-loot color unlock celebration, broadcast to the whole room and
    // shown as a floating orb over the looter on every peer including the
    // sender. Deduped by id so a relay never double-spawns it.
    case colorUnlock(ColorUnlock)
    // A world-activity start (fishing, mining, ...), broadcast to the whole
    // room so every peer plays the performer's tool-in-hand animation at the
    // same station. Deduped by id.
    case activity(ActivityAction)
    // Shared room skybox selection, sent reliably. Last write wins per room so
    // every peer converges on the latest dome. Host replays the live value on
    // peer connect so late joiners land on the right skybox.
    case skybox(SkyboxState)
    // Minigame lifecycle, all sent reliably. Invite broadcasts a round offer
    // to the lobby; responses flow back to the round host; start locks the
    // roster and timer; events carry in-round actions; end carries the
    // authoritative final scores.
    case minigameInvite(MinigameInvite)
    case minigameInviteResponse(gameID: String, accepted: Bool)
    case minigameStart(MinigameStart)
    case minigameEvent(MinigameEvent)
    case minigameEnd(MinigameEnd)
    // Voxel Rumble flying-ball state, sent unreliably by the ball's current
    // owner. Carries position, velocity, owner, and color so peers render and
    // (on the owner) simulate a single shared ball.
    case minigameBall(BallSync)

    // Connectivity probe. Unreliable, tiny, fired on a timer. A peer that
    // receives a ping echoes it back as a pong; the origin matches the seq
    // against its send timestamp to measure round-trip time per peer.
    case ping(origin: String, seq: UInt32)
    case pong(origin: String, seq: UInt32)

    public static func decode(_ data: Data) -> NetMessage? {
        try? JSONDecoder().decode(NetMessage.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
