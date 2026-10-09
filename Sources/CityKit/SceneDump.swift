import Foundation

/// Plain JSON dump of a scene, used to prove the web viewer's JavaScript port draws exactly what
/// the Swift geometry draws (Tests/viewer-parity.mjs).
public enum SceneDump {
    public static func json(_ scene: Scene) -> Data {
        var out = "{\"buildingCount\":\(scene.buildingCount),\"items\":["
        for (itemIndex, item) in scene.items.enumerated() {
            if itemIndex > 0 { out += "," }
            out += "{\"district\":\(item.district),\"building\":\(item.building.map(String.init) ?? "null")"
            out += ",\"look\":[\(number(item.look.structureAlpha)),\(number(item.look.windowAlpha))"
            out += ",\(item.look.dashPattern.map { "[" + $0.map(number).joined(separator: ",") + "]" } ?? "null")]"
            out += ",\"prims\":["
            for (primitiveIndex, primitive) in item.primitives.enumerated() {
                if primitiveIndex > 0 { out += "," }
                switch primitive {
                case let .occluder(points):
                    out += "{\"k\":\"o\",\"p\":\(points.map(vector).joined(separator: ",").bracketed)}"
                case let .line(points, ink, closed):
                    out += "{\"k\":\"l\",\"ink\":\(ink.rawValue),\"c\":\(closed),\"p\":\(points.map(vector).joined(separator: ",").bracketed)}"
                case let .disc(center, radius, ink):
                    out += "{\"k\":\"d\",\"ink\":\(ink.rawValue),\"r\":\(number(radius)),\"p\":[\(vector(center))]}"
                }
            }
            out += "]}"
        }
        out += "]}\n"
        return Data(out.utf8)
    }

    static func vector(_ v: Vec3) -> String {
        "[\(number(v.x)),\(number(v.y)),\(number(v.z))]"
    }

    /// Shortest round-tripping decimal (Swift's description is round-trip exact, like JS).
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }
}

private extension String {
    var bracketed: String { "[" + self + "]" }
}
