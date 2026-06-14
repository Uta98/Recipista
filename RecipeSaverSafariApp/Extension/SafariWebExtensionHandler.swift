import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let sharedDefaults = UserDefaults(suiteName: "group.com.recipista.ios")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .compactMap { $0.userInfo?[SFExtensionMessageKey] as? [String: Any] }
            .first ?? [:]

        let command = request["command"] as? String
        let message: [String: Any]

        switch command {
        case "get":
            message = handleGet(request)
        case "set":
            message = handleSet(request)
        case "remove":
            message = handleRemove(request)
        default:
            message = ["status": "ready"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }

    private func handleGet(_ request: [String: Any]) -> [String: Any] {
        guard let sharedDefaults else {
            return ["ok": false, "error": "app-group-unavailable"]
        }

        let defaults = request["defaults"] as? [String: Any] ?? [:]
        var values = defaults

        for key in defaults.keys {
            if let value = sharedDefaults.object(forKey: key) {
                values[key] = value
            }
        }

        return ["ok": true, "values": values]
    }

    private func handleSet(_ request: [String: Any]) -> [String: Any] {
        guard let sharedDefaults else {
            return ["ok": false, "error": "app-group-unavailable"]
        }

        let values = request["values"] as? [String: Any] ?? [:]
        for (key, value) in values {
            sharedDefaults.set(value, forKey: key)
        }
        sharedDefaults.synchronize()
        return ["ok": true]
    }

    private func handleRemove(_ request: [String: Any]) -> [String: Any] {
        guard let sharedDefaults else {
            return ["ok": false, "error": "app-group-unavailable"]
        }

        let keys = request["keys"] as? [String] ?? []
        for key in keys {
            sharedDefaults.removeObject(forKey: key)
        }
        sharedDefaults.synchronize()
        return ["ok": true]
    }
}
