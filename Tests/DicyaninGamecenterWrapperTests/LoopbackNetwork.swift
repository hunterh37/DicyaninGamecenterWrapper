import Foundation
@testable import DicyaninGamecenterWrapper

// In-memory replacement for a GKMatch. Every node holds a real MultiplayerState
// and every message is JSON encoded/decoded through the production wire format,
// so a test that passes here exercises the exact code path shipped in the app.
final class LoopbackNetwork {

    final class Node {
        var state: MultiplayerState
        init(_ id: String) { state = MultiplayerState(localPlayerID: id) }
    }

    private(set) var nodes: [String: Node] = [:]
    private var order: [String] = []

    @discardableResult
    func addNode(_ id: String) -> Node {
        let node = Node(id)
        nodes[id] = node
        let existing = order
        order.append(id)
        // Mirror GameKit: every already-connected peer sees the newcomer and
        // vice versa. Relays produced by those callbacks are put on the wire.
        for other in existing {
            deliver(from: other, MultiplayerReducer.peerChanged(id, connected: true, into: &nodes[other]!.state))
            deliver(from: id, MultiplayerReducer.peerChanged(other, connected: true, into: &node.state))
        }
        return node
    }

    func removeNode(_ id: String) {
        guard nodes[id] != nil else { return }
        nodes.removeValue(forKey: id)
        order.removeAll { $0 == id }
        for other in order {
            deliver(from: other, MultiplayerReducer.peerChanged(id, connected: false, into: &nodes[other]!.state))
        }
    }

    // Send relays from `id` to all other nodes, cascading any relays they emit
    // (e.g. the host answering a color with a roster) until the network settles.
    func send(from id: String, _ relays: [RelayMessage]) {
        deliver(from: id, relays)
    }

    private func deliver(from senderID: String, _ relays: [RelayMessage]) {
        var queue: [(String, RelayMessage)] = relays.map { (senderID, $0) }
        var guardCounter = 0
        while !queue.isEmpty {
            guardCounter += 1
            precondition(guardCounter < 10_000, "loopback relay did not converge")
            let (from, relay) = queue.removeFirst()
            guard let data = relay.message.encoded() else { continue }
            for (id, node) in nodes where id != from {
                let produced = MultiplayerReducer.receive(data, from: from, into: &node.state)
                queue.append(contentsOf: produced.map { (id, $0) })
            }
        }
    }
}
