import Foundation

public enum CityIOError: Error, CustomStringConvertible {
    case unsupportedSchema(found: Int, supported: Int)
    case decoding(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(found, supported):
            "city.json schema \(found) is newer than this build supports (\(supported)); update commitcity"
        case let .decoding(detail):
            "city.json could not be read: \(detail)"
        }
    }
}

extension City {
    /// Stable bytes: sorted keys, no pretty printing, so identical cities produce identical files
    /// and the Action only publishes when something actually changed.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> City {
        struct SchemaProbe: Decodable { var schema: Int }
        let probe: SchemaProbe
        do {
            probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
        } catch {
            throw CityIOError.decoding(String(describing: error))
        }
        guard probe.schema <= City.currentSchema else {
            throw CityIOError.unsupportedSchema(found: probe.schema, supported: City.currentSchema)
        }
        do {
            return try JSONDecoder().decode(City.self, from: data)
        } catch {
            throw CityIOError.decoding(String(describing: error))
        }
    }
}
