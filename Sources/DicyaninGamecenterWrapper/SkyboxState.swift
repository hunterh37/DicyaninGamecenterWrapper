import Foundation

// Shared room skybox selection. The room agrees on one skybox at a time; any
// player can change it and the new choice propagates to every peer, including
// late joiners via the host roster handshake. Last write wins per room.
public struct SkyboxState: Codable, Equatable {
    // App-defined skybox id (see App/Scene/Skybox.swift). 0 means the default
    // procedural night-sky backdrop, no textured dome. Optional so old clients
    // decode without it.
    public var skyboxID: Int
    // Player who last picked, so peers can attribute the change in UI. Optional
    // so old clients decode without it.
    public var pickerID: String?
    public var changedAt: Date

    public init(skyboxID: Int = 0, pickerID: String? = nil, changedAt: Date = Date()) {
        self.skyboxID = skyboxID
        self.pickerID = pickerID
        self.changedAt = changedAt
    }

    // Tolerant decode: a client that predates either field must not make the
    // whole skybox packet fail to decode (which would drop it silently).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skyboxID = try c.decodeIfPresent(Int.self, forKey: .skyboxID) ?? 0
        pickerID = try c.decodeIfPresent(String.self, forKey: .pickerID)
        changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public static let `default` = SkyboxState(skyboxID: 0)
}