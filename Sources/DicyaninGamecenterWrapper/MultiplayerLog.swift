import Foundation
import Combine

// High-signal in-app debug console for the multiplayer core. Every meaningful
// state transition in matchmaking, lobby publishing, and match traffic routes
// through here so a stuck "loading forever" can be read off the screen without
// a cable attached.

public enum MultiplayerLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    public var symbol: String {
        switch self {
        case .debug: return "•"
        case .info: return "›"
        case .warn: return "!"
        case .error: return "x"
        }
    }
}

public struct MultiplayerLogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let time: Date
    public let level: MultiplayerLogLevel
    public let category: String
    public let message: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public var line: String {
        "\(Self.formatter.string(from: time)) \(level.rawValue) [\(category)] \(message)"
    }
}

@MainActor
public final class MultiplayerLog: ObservableObject {

    public static let shared = MultiplayerLog()

    @Published public private(set) var entries: [MultiplayerLogEntry] = []

    private let maxEntries = 500

    public func log(_ level: MultiplayerLogLevel, _ category: String, _ message: String) {
        let entry = MultiplayerLogEntry(time: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        print("MP \(entry.line)")
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warn(_ category: String, _ message: String) { log(.warn, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public func clear() { entries.removeAll() }

    public var joined: String {
        entries.map(\.line).joined(separator: "\n")
    }
}
