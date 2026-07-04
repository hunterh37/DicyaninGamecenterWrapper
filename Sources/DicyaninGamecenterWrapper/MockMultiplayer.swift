import Foundation
import simd
import Combine

// Offline test harness. Populates the multiplayer state with fake remote
// players and animates their poses on a timer so the immersive arena can be
// entered and exercised with 2, 3, or 4 avatars without Game Center.
@MainActor
public final class MockMultiplayerDriver {

    private weak var owner: GameCenterService?
    private var timer: AnyCancellable?
    private var startTime = Date()
    private var players: [MockPlayer] = []

    public init(owner: GameCenterService) {
        self.owner = owner
    }

    public var isRunning: Bool { timer != nil }

    // playerCount is the total number of avatars in the arena including the
    // local player, so the number of mocked remotes is playerCount - 1.
    public func start(playerCount: Int) {
        stop()
        let remotes = max(1, min(3, playerCount - 1))
        let palette: [AvatarColor] = [
            AvatarColor(r: 0.95, g: 0.35, b: 0.35),
            AvatarColor(r: 0.40, g: 0.85, b: 0.45),
            AvatarColor(r: 0.95, g: 0.80, b: 0.30)
        ]
        players = (0..<remotes).map { index in
            let angle = Float.pi * (0.25 + 0.5 * Float(index) / Float(max(1, remotes - 1)))
            return MockPlayer(
                id: "mock-\(index)",
                color: palette[index % palette.count],
                baseAngle: remotes == 1 ? .pi / 2 : angle,
                phase: Float(index) * 1.3
            )
        }
        startTime = Date()
        for (index, player) in players.enumerated() {
            owner?.mockSetColor(player.color, for: player.id)
            owner?.mockSetName("Player \(index + 1)", for: player.id)
        }
        timer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        for player in players {
            owner?.mockRemovePlayer(player.id)
        }
        players = []
    }

    private func tick() {
        let t = Float(Date().timeIntervalSince(startTime))
        for player in players {
            // Walk slowly around the ring so pose smoothing and extrapolation
            // are exercised exactly like real 15 Hz match traffic.
            let radius: Float = 1.6 + 0.2 * sin(t * 0.5 + player.phase)
            let angle = player.baseAngle + 0.35 * t
            let x = radius * cos(angle)
            let z = -radius * sin(angle)
            let bob = 0.05 * sin(t * 1.5 + player.phase)
            let y: Float = 1.5 + bob
            let yaw = atan2(-x, -z) + 0.15 * sin(t * 0.7 + player.phase)

            let head = Self.transform(position: [x, y, z], yaw: yaw)
            let handSwing = 0.12 * sin(t * 2.0 + player.phase)
            let left = Self.transform(position: [x - 0.25, y - 0.45 + handSwing, z + 0.1], yaw: yaw)
            let right = Self.transform(position: [x + 0.25, y - 0.45 - handSwing, z + 0.1], yaw: yaw)

            let pose = PlayerPose(
                head: CodableTransform(head),
                leftHand: CodableTransform(left),
                rightHand: CodableTransform(right)
            )
            owner?.mockSetPose(pose, for: player.id)
        }
    }

    public func sendEmote(_ emote: EmoteKind) {
        guard let player = players.randomElement() else { return }
        owner?.mockEmote(emote, for: player.id)
    }

    private static func transform(position: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(position, 1)
        return m
    }
}

private struct MockPlayer {
    public let id: String
    public let color: AvatarColor
    public let baseAngle: Float
    public let phase: Float
}
