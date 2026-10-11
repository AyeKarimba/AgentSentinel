import Foundation

/// The adapters read a handful of string fields out of a JSON object. `JSONSerialization`
/// rather than `Codable` because each agent's payload has a different shape, and a missing
/// optional field must never make the whole payload undecodable.
enum HookJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any]
        else { throw HookDecodeError.notAnObject }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    static func required(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = string(object, key) else { throw HookDecodeError.missingField(key) }
        return value
    }

    /// Nested lookup, e.g. `tool_input.description`.
    static func string(_ object: [String: Any], _ key: String, _ nested: String) -> String? {
        (object[key] as? [String: Any]).flatMap { $0[nested] as? String }
    }
}
