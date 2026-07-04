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

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .wave: return "Wave"
        case .heart: return "Heart"
        case .thumbsUp: return "Thumbs Up"
        case .laugh: return "Laugh"
        case .fire: return "Fire"
        case .question: return "Question"
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
    public init(head: CodableTransform, leftHand: CodableTransform? = nil, rightHand: CodableTransform? = nil) {
        self.head = head
        self.leftHand = leftHand
        self.rightHand = rightHand
    }
    public var head: CodableTransform
    public var leftHand: CodableTransform?
    public var rightHand: CodableTransform?
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

public struct AvatarColor: Codable, Equatable {
    public init(r: Float, g: Float, b: Float, face: Int? = nil) {
        self.r = r
        self.g = g
        self.b = b
        self.face = face
    }
    public var r: Float
    public var g: Float
    public var b: Float
    // Face style raw value. Optional so old clients decode without it.
    public var face: Int?

    public static let `default` = AvatarColor(r: 0.55, g: 0.75, b: 0.95)
}

public enum NetMessage: Codable, Equatable {
    // Sent unreliably at ~15 Hz by every player.
    case pose(PlayerPose)
    // Sent reliably.
    case color(AvatarColor)
    case emote(EmoteKind)
    // Grabbable prop transforms. Unreliable at ~15 Hz while held; a release
    // (holder nil) is sent reliably so props never stick to a hand.
    case props([PropState])
    // Host relay: full roster of known colors, sent when players connect.
    case roster([String: AvatarColor])
    // Host only. Instructs the named player to leave the match.
    case kick(String)

    public static func decode(_ data: Data) -> NetMessage? {
        try? JSONDecoder().decode(NetMessage.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
