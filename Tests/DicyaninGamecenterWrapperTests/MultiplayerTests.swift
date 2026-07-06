import XCTest
import simd
@testable import DicyaninGamecenterWrapper

final class MultiplayerTests: XCTestCase {

    // MARK: - Stage 1: wire format

    func testWireRoundTripForEveryMessageKind() throws {
        let pose = Self.pose(x: 1, y: 2, z: 3)
        let color = AvatarColor(r: 0.1, g: 0.2, b: 0.3)
        let messages: [NetMessage] = [
            .pose(pose),
            .color(color),
            .emote(.fire),
            .roster(["p1": color, "p2": .default])
        ]
        for message in messages {
            let data = try XCTUnwrap(message.encoded(), "encode failed for \(message)")
            let decoded = try XCTUnwrap(NetMessage.decode(data), "decode failed for \(message)")
            XCTAssertEqual(decoded, message)
        }
    }

    func testCodableTransformPreservesPositionAndRotation() {
        let angle: Float = .pi / 3
        let m = simd_float4x4(simd_quatf(angle: angle, axis: [0, 1, 0]))
        var withTranslation = m
        withTranslation.columns.3 = [4, 5, 6, 1]
        let t = CodableTransform(withTranslation)
        XCTAssertEqual(t.position, [4, 5, 6])
        let q = t.rotation
        XCTAssertEqual(q.angle, angle, accuracy: 1e-4)
        XCTAssertEqual(q.axis.y, 1, accuracy: 1e-4)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(NetMessage.decode(Data([0x00, 0x01, 0x02, 0x03])))
    }

    // MARK: - Stage 2: host election

    func testLowestIDIsHost() {
        var host = MultiplayerState(localPlayerID: "p1")
        host.connectedPeers = ["p2", "p3"]
        XCTAssertTrue(host.isHost)

        var client = MultiplayerState(localPlayerID: "p2")
        client.connectedPeers = ["p1", "p3"]
        XCTAssertFalse(client.isHost)
    }

    func testSoloParticipantIsHost() {
        XCTAssertTrue(MultiplayerState(localPlayerID: "p9").isHost)
    }

    // MARK: - Stage 3: pose replication

    func testPoseReplicatesToAllPeers() {
        let net = LoopbackNetwork()
        net.addNode("p1"); net.addNode("p2"); net.addNode("p3")
        let pose = Self.pose(x: 7, y: 8, z: 9)
        net.send(from: "p1", [MultiplayerReducer.makePose(pose)])

        XCTAssertEqual(net.nodes["p2"]?.state.remotePoses["p1"], pose)
        XCTAssertEqual(net.nodes["p3"]?.state.remotePoses["p1"], pose)
        XCTAssertNil(net.nodes["p1"]?.state.remotePoses["p1"], "sender must not store its own pose")
    }

    func testPoseUsesUnreliableChannel() {
        XCTAssertFalse(MultiplayerReducer.makePose(Self.pose(x: 0, y: 0, z: 0)).reliable)
    }

    // MARK: - Stage 4: color + host-authoritative roster

    func testClientColorPropagatesAndHostRelaysRoster() {
        let net = LoopbackNetwork()
        net.addNode("p1"); net.addNode("p2"); net.addNode("p3")
        let color = AvatarColor(r: 0.9, g: 0.1, b: 0.4)

        var p2 = net.nodes["p2"]!.state
        let relays = MultiplayerReducer.setColor(color, into: &p2)
        net.nodes["p2"]!.state = p2
        net.send(from: "p2", relays)

        XCTAssertEqual(net.nodes["p2"]?.state.localColor, color)
        XCTAssertEqual(net.nodes["p1"]?.state.remoteColors["p2"], color)
        XCTAssertEqual(net.nodes["p3"]?.state.remoteColors["p2"], color)
    }

    func testOnlyHostEmitsRoster() {
        var host = MultiplayerState(localPlayerID: "p1")
        host.connectedPeers = ["p2"]
        XCTAssertFalse(MultiplayerReducer.hostRoster(host).isEmpty)

        var client = MultiplayerState(localPlayerID: "p2")
        client.connectedPeers = ["p1"]
        XCTAssertTrue(MultiplayerReducer.hostRoster(client).isEmpty)
    }

    func testRosterNeverOverwritesLocalColor() {
        var s = MultiplayerState(localPlayerID: "p2")
        s.localColor = AvatarColor(r: 1, g: 1, b: 1)
        _ = MultiplayerReducer.apply(.roster(["p2": .default, "p1": .default]), from: "p1", into: &s)
        XCTAssertEqual(s.localColor, AvatarColor(r: 1, g: 1, b: 1))
        XCTAssertNil(s.remoteColors["p2"])
        XCTAssertEqual(s.remoteColors["p1"], .default)
    }

    // MARK: - Stage 5: emotes

    func testEmoteQueuesLocallyAndRemotely() {
        let net = LoopbackNetwork()
        net.addNode("p1"); net.addNode("p2")

        var p1 = net.nodes["p1"]!.state
        let relays = MultiplayerReducer.sendEmote(.heart, into: &p1)
        net.nodes["p1"]!.state = p1
        net.send(from: "p1", relays)

        XCTAssertEqual(net.nodes["p1"]?.state.pendingEmotes, [PendingEmote(playerID: "p1", emote: .heart)])
        XCTAssertEqual(net.nodes["p2"]?.state.pendingEmotes, [PendingEmote(playerID: "p1", emote: .heart)])
    }

    // MARK: - Stage 6: connection lifecycle

    func testJoinBroadcastsColorToExistingPeers() {
        let net = LoopbackNetwork()
        let a = net.addNode("p1")
        a.state.localColor = AvatarColor(r: 0.2, g: 0.4, b: 0.6)
        // Re-announce p1's chosen color as the app does after matchmaking.
        net.send(from: "p1", MultiplayerReducer.broadcastColor(a.state))

        net.addNode("p2")
        // p2's join callback broadcasts p2's default color to p1.
        XCTAssertEqual(net.nodes["p1"]?.state.remoteColors["p2"], .default)
    }

    func testDisconnectRemovesPeerStateAndReelectsHost() {
        let net = LoopbackNetwork()
        net.addNode("p1"); net.addNode("p2"); net.addNode("p3")
        net.send(from: "p2", [MultiplayerReducer.makePose(Self.pose(x: 1, y: 1, z: 1))])
        XCTAssertNotNil(net.nodes["p1"]?.state.remotePoses["p2"])
        XCTAssertFalse(net.nodes["p2"]!.state.isHost)

        net.removeNode("p1")

        XCTAssertNil(net.nodes["p2"]?.state.remotePoses["p1"])
        XCTAssertNil(net.nodes["p2"]?.state.remoteColors["p1"])
        XCTAssertTrue(net.nodes["p2"]!.state.isHost, "p2 becomes host once p1 leaves")
    }

    // MARK: - Helpers

    private static func pose(x: Float, y: Float, z: Float) -> PlayerPose {
        var m = matrix_identity_float4x4
        m.columns.3 = [x, y, z, 1]
        return PlayerPose(head: CodableTransform(m), leftHand: nil, rightHand: nil)
    }
}

// MARK: - Stage 7: props

extension MultiplayerTests {

    private static func prop(_ id: Int, holder: String?, x: Float = 0) -> PropState {
        var m = matrix_identity_float4x4
        m.columns.3 = [x, 0, 0, 1]
        return PropState(id: id, holder: holder, transform: CodableTransform(m))
    }

    func testWireRoundTripForPropsAndKick() throws {
        let messages: [NetMessage] = [
            .props([Self.prop(1, holder: "p1", x: 3), Self.prop(2, holder: nil)]),
            .kick("p2")
        ]
        for message in messages {
            let data = try XCTUnwrap(message.encoded(), "encode failed for \(message)")
            let decoded = try XCTUnwrap(NetMessage.decode(data), "decode failed for \(message)")
            XCTAssertEqual(decoded, message)
        }
    }

    func testHolderCanClaimAndMoveProp() {
        var s = MultiplayerState(localPlayerID: "p1")
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: "p2", x: 1)]), from: "p2", into: &s)
        XCTAssertEqual(s.remoteProps[1]?.holder, "p2")
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: "p2", x: 5)]), from: "p2", into: &s)
        XCTAssertEqual(s.remoteProps[1]?.transform.position.x, 5)
    }

    func testOnlyCurrentHolderCanRelease() {
        var s = MultiplayerState(localPlayerID: "p1")
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: "p2")]), from: "p2", into: &s)
        // p3 tries to release a prop held by p2: ignored.
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: nil, x: 9)]), from: "p3", into: &s)
        XCTAssertEqual(s.remoteProps[1]?.holder, "p2")
        // p2 releases its own prop: applied.
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: nil, x: 9)]), from: "p2", into: &s)
        XCTAssertNil(s.remoteProps[1]?.holder)
        XCTAssertEqual(s.remoteProps[1]?.transform.position.x, 9)
    }

    func testPlayerCannotClaimPropForSomeoneElse() {
        var s = MultiplayerState(localPlayerID: "p1")
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: "p9")]), from: "p2", into: &s)
        XCTAssertNil(s.remoteProps[1], "a sender may only claim props for itself")
    }

    func testFreePropCanBePlacedByAnyone() {
        var s = MultiplayerState(localPlayerID: "p1")
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: nil, x: 2)]), from: "p2", into: &s)
        XCTAssertEqual(s.remoteProps[1]?.transform.position.x, 2)
    }

    func testMakePropsUpdatesLocalStateAndChannel() {
        var s = MultiplayerState(localPlayerID: "p1")
        let held = MultiplayerReducer.makeProps([Self.prop(1, holder: "p1")], into: &s)
        XCTAssertFalse(held.reliable)
        XCTAssertEqual(s.remoteProps[1]?.holder, "p1")
        let release = MultiplayerReducer.makeProps([Self.prop(1, holder: nil)], reliable: true, into: &s)
        XCTAssertTrue(release.reliable)
        XCTAssertNil(s.remoteProps[1]?.holder)
    }

    func testDisconnectReleasesHeldProps() {
        var s = MultiplayerState(localPlayerID: "p1")
        s.connectedPeers = ["p2"]
        _ = MultiplayerReducer.apply(.props([Self.prop(1, holder: "p2")]), from: "p2", into: &s)
        _ = MultiplayerReducer.peerChanged("p2", connected: false, into: &s)
        XCTAssertNotNil(s.remoteProps[1])
        XCTAssertNil(s.remoteProps[1]?.holder, "props held by a leaving player must drop")
    }

    // MARK: - Stage 8: message robustness

    func testColorAndEmoteChannelsAreReliable() {
        var s = MultiplayerState(localPlayerID: "p1")
        for relay in MultiplayerReducer.setColor(.default, into: &s) { XCTAssertTrue(relay.reliable) }
        for relay in MultiplayerReducer.sendEmote(.wave, into: &s) { XCTAssertTrue(relay.reliable) }
        for relay in MultiplayerReducer.hostRoster(s) { XCTAssertTrue(relay.reliable) }
    }

    func testAvatarColorDecodesWithoutFaceField() throws {
        let legacy = Data(#"{"r":0.1,"g":0.2,"b":0.3}"#.utf8)
        let color = try JSONDecoder().decode(AvatarColor.self, from: legacy)
        XCTAssertNil(color.face)
        XCTAssertEqual(color.r, 0.1)
    }

    func testDecodeRejectsEmptyData() {
        XCTAssertNil(NetMessage.decode(Data()))
    }

    func testKickIsANoOpInReducer() {
        var s = MultiplayerState(localPlayerID: "p1")
        let before = s
        XCTAssertTrue(MultiplayerReducer.apply(.kick("p1"), from: "p2", into: &s).isEmpty)
        XCTAssertEqual(s, before)
    }

    func testEveryEmoteKindHasLabelAndPose() {
        for emote in EmoteKind.allCases {
            XCTAssertFalse(emote.label.isEmpty)
            XCTAssertFalse(emote.displayName.isEmpty)
        }
    }
}
