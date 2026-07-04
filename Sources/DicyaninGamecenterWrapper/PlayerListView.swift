import SwiftUI

// Roster of everyone in the current session. The host sees a kick control
// next to every other player; kicked players are dropped from the match.
public struct PlayerListView: View {

    @ObservedObject public var gameCenter: GameCenterService

    public init(gameCenter: GameCenterService) {
        self.gameCenter = gameCenter
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Players (\(gameCenter.sessionPlayers.count))")
                .font(.headline)

            ForEach(gameCenter.sessionPlayers) { player in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(
                            red: Double(player.color.r),
                            green: Double(player.color.g),
                            blue: Double(player.color.b)
                        ))
                        .frame(width: 16, height: 16)

                    Text(player.name)
                        .lineLimit(1)

                    if player.isHost {
                        Text("Host")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }

                    Spacer(minLength: 8)

                    if gameCenter.isHost, !player.isLocal {
                        Button(role: .destructive) {
                            gameCenter.kick(player.id)
                        } label: {
                            Image(systemName: "person.fill.xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
