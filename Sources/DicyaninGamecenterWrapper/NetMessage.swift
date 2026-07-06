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
    public init(head: CodableTransform, leftHand: CodableTransform? = nil, rightHand: CodableTransform? = nil, sitting: Bool? = nil) {
        self.head = head
        self.leftHand = leftHand
        self.rightHand = rightHand
        self.sitting = sitting
    }
    public var head: CodableTransform
    public var leftHand: CodableTransform?
    public var rightHand: CodableTransform?
    // True while the player is seated. Optional so old clients decode without
    // it. Drives the seated body pose on every peer from this one flag.
    public var sitting: Bool?
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

public struct AvatarColor: Codable, Equatable {
    public init(r: Float, g: Float, b: Float, face: Int? = nil, hat: Int? = nil, material: Int? = nil, prop: Int? = nil, body: Int? = nil, height: Int? = nil, equippedItem: Int? = nil, paint: [String: String]? = nil) {
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
        self.paint = paint
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
    // Per-body-part painted surface, keyed by BodyPart.rawValue. Each value is a
    // zlib-compressed, base64-encoded RGBA8 256x256 canvas so a painted design
    // travels over the wire and every peer rebuilds the identical mesh texture.
    // Optional so old clients decode without it.
    public var paint: [String: String]?

    public static let `default` = AvatarColor(r: 0.55, g: 0.75, b: 0.95)
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
    // Player-to-player heart reaction, sent reliably. Broadcast to the room;
    // only the peer whose id matches payload.target acts on it.
    case heart(HeartPayload)
    // Custom in-game display name, sent reliably on connect and on change so
    // peers show the player-chosen name instead of the Game Center alias.
    case name(String)
    // Transient tap shimmer effect, broadcast to the whole room and shown for a
    // few seconds at the tap position on every peer including the sender.
    case tap(TapSparkle)

    public static func decode(_ data: Data) -> NetMessage? {
        try? JSONDecoder().decode(NetMessage.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
