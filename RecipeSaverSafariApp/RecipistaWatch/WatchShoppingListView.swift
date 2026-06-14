import SwiftUI
import WatchConnectivity

private struct WatchRecipe: Codable, Identifiable {
    var id: String
    var name: String
    var ingredients: [WatchIngredientValue]
    var multiplier: Double?
}

private enum WatchIngredientValue: Codable {
    case text(String)
    case edited(name: String, quantityText: String, category: String?)

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .edited(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            quantityText: try container.decodeIfPresent(String.self, forKey: .quantityText) ?? "",
            category: try container.decodeIfPresent(String.self, forKey: .category)
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .edited(let name, let quantityText, let category):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(quantityText, forKey: .quantityText)
            try container.encodeIfPresent(category, forKey: .category)
        }
    }

    var line: String {
        switch self {
        case .text(let value):
            return value
        case .edited(let name, let quantityText, _):
            return [name, quantityText].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    var category: String? {
        switch self {
        case .text:
            return nil
        case .edited(_, _, let category):
            return category
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case quantityText
        case category
    }
}

private struct WatchSyncPayload: Codable {
    var recipes: [WatchRecipe]
    var selectedRecipeIds: [String]
    var shoppingDone: [String: Bool]
}

private struct WatchShoppingItem: Identifiable {
    var id: String { key }
    var key: String
    var name: String
    var quantity: String
    var category: String
}

private final class WatchShoppingStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var items: [WatchShoppingItem] = []
    @Published private(set) var done: [String: Bool] = [:]

    private let payloadKey = "recipista.watch.payload"
    private let categories = ["肉・魚", "野菜", "卵・乳製品", "調味料", "その他"]

    override init() {
        super.init()
        loadSavedPayload()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var activeItems: [WatchShoppingItem] {
        items.filter { done[$0.key] != true }
    }

    var doneItems: [WatchShoppingItem] {
        items.filter { done[$0.key] == true }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let json = session.receivedApplicationContext["payload"] as? String {
            applyPayload(json)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let json = applicationContext["payload"] as? String {
            applyPayload(json)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let json = userInfo["payload"] as? String {
            applyPayload(json)
        }
    }

    private func loadSavedPayload() {
        if let json = UserDefaults.standard.string(forKey: payloadKey) {
            applyPayload(json)
        }
    }

    private func applyPayload(_ json: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WatchSyncPayload.self, from: data) else { return }

        UserDefaults.standard.set(json, forKey: payloadKey)
        let selected = payload.recipes.filter { payload.selectedRecipeIds.contains($0.id) }
        var groups: [String: (name: String, category: String, quantities: [String: Double], notes: [String])] = [:]

        for recipe in selected {
            let multiplier = max(0.5, recipe.multiplier ?? 1)
            for ingredient in recipe.ingredients {
                let parsed = Self.parseIngredient(ingredient.line)
                guard !parsed.name.isEmpty else { continue }
                var item = groups[parsed.key] ?? (
                    name: parsed.name,
                    category: ingredient.category ?? Self.category(for: parsed.name),
                    quantities: [:],
                    notes: []
                )
                if let amount = parsed.amount {
                    item.quantities[parsed.unit, default: 0] += amount * multiplier
                } else if !parsed.note.isEmpty {
                    item.notes.append(parsed.note)
                }
                groups[parsed.key] = item
            }
        }

        let nextItems = groups.map { key, value in
            WatchShoppingItem(
                key: key,
                name: value.name,
                quantity: Self.formatQuantity(quantities: value.quantities, notes: value.notes),
                category: value.category
            )
        }
        .sorted {
            let categoryDiff = categories.firstIndex(of: $0.category, or: categories.count) - categories.firstIndex(of: $1.category, or: categories.count)
            return categoryDiff == 0 ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : categoryDiff < 0
        }

        DispatchQueue.main.async {
            self.items = nextItems
            self.done = payload.shoppingDone
        }
    }

    private static func parseIngredient(_ line: String) -> (key: String, name: String, amount: Double?, unit: String, note: String) {
        let normalized = line.replacingOccurrences(of: "　", with: " ")
        let unitFirstPattern = #"^(.+?)\s*(大さじ|小さじ)\s*(\d+(?:\.\d+)?(?:/\d+)?)(.*)$"#
        if let match = normalized.firstMatch(pattern: unitFirstPattern) {
            return (key(match[0]), match[0].trimmingCharacters(in: .whitespaces), parseNumber(match[2]), match[1], match[3].trimmingCharacters(in: .whitespaces))
        }
        let numberFirstPattern = #"^(.+?)\s*(\d+(?:\.\d+)?(?:/\d+)?)\s*(大さじ|小さじ|g|kg|ml|cc|個|本|枚|束|袋|カップ|合|株)?(.*)$"#
        if let match = normalized.firstMatch(pattern: numberFirstPattern) {
            return (key(match[0]), match[0].trimmingCharacters(in: .whitespaces), parseNumber(match[1]), match[2], match[3].trimmingCharacters(in: .whitespaces))
        }
        for word in ["適量", "適宜", "少々", "お好みで", "ひとつまみ"] where normalized.hasSuffix(word) {
            let name = String(normalized.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return (key(name), name, nil, "", word)
            }
        }
        let name = normalized.trimmingCharacters(in: .whitespaces)
        return (key(name), name, nil, "", "")
    }

    private static func key(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }

    private static func category(for name: String) -> String {
        if name.range(of: #"牛|豚|鶏|肉|ひき肉|挽き肉|ベーコン|ハム|ソーセージ|鮭|魚|えび|海老|いか|たこ|ツナ|さば|鯖"#, options: .regularExpression) != nil { return "肉・魚" }
        if name.range(of: #"じゃがいも|ジャガイモ|玉ねぎ|玉葱|たまねぎ|にんじん|人参|キャベツ|白菜|ねぎ|長ねぎ|トマト|きゅうり|なす|ピーマン|大根|きのこ|しめじ|えのき|しいたけ|椎茸|もやし|レタス|ごぼう|かぼちゃ|ブロッコリー|にら|ほうれん草|小松菜"#, options: .regularExpression) != nil { return "野菜" }
        if name.range(of: #"卵|たまご|玉子|牛乳|チーズ|バター|ヨーグルト|生クリーム"#, options: .regularExpression) != nil { return "卵・乳製品" }
        if name.range(of: #"しょうゆ|醤油|みそ|味噌|砂糖|塩|こしょう|胡椒|みりん|酒|酢|油|ごま油|オリーブオイル|だし|ソース|ケチャップ|マヨネーズ|コンソメ|鶏ガラ|カレー粉"#, options: .regularExpression) != nil { return "調味料" }
        return "その他"
    }

    private static func parseNumber(_ value: String) -> Double? {
        if value.contains("/") {
            let parts = value.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        }
        return Double(value)
    }

    private static func formatQuantity(quantities: [String: Double], notes: [String]) -> String {
        var parts: [String] = []
        let totalTeaspoon = (quantities["大さじ"] ?? 0) * 3 + (quantities["小さじ"] ?? 0)
        if totalTeaspoon >= 3 {
            parts.append("大さじ\(format(totalTeaspoon / 3))")
        } else if totalTeaspoon > 0 {
            parts.append("小さじ\(format(totalTeaspoon))")
        }
        for (unit, amount) in quantities where !["大さじ", "小さじ"].contains(unit) && amount > 0 {
            parts.append("\(format(amount))\(unit)")
        }
        parts.append(contentsOf: notes.filter { !$0.isEmpty })
        return parts.joined(separator: " + ")
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct WatchShoppingListView: View {
    @StateObject private var store = WatchShoppingStore()

    var body: some View {
        List {
            if store.items.isEmpty {
                Text("iPhoneでレシピを選ぶと、買い物リストが表示されます。")
                    .foregroundStyle(.secondary)
            } else {
                WatchItemSection(title: "買うもの", items: store.activeItems)
                if !store.doneItems.isEmpty {
                    WatchItemSection(title: "チェック済み", items: store.doneItems)
                }
            }
        }
        .navigationTitle("Recipista")
    }
}

private struct WatchItemSection: View {
    let title: String
    let items: [WatchShoppingItem]

    var body: some View {
        Section(title) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                    if !item.quantity.isEmpty {
                        Text(item.quantity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private extension Array where Element: Equatable {
    func firstIndex(of element: Element, or defaultValue: Int) -> Int {
        firstIndex(of: element) ?? defaultValue
    }
}

private extension String {
    func firstMatch(pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let result = regex.firstMatch(in: self, range: range) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let matchRange = Range(result.range(at: index), in: self) else { return "" }
            return String(self[matchRange])
        }
    }
}
