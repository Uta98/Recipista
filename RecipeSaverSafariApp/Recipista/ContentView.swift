import SwiftUI
import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

private struct StoredRecipe: Codable, Identifiable {
    var id: String
    var name: String
    var sourceUrl: String?
    var siteName: String?
    var imageUrl: String?
    var yieldText: String?
    var ingredients: [IngredientValue]
    var multiplier: Double?
}

private enum IngredientValue: Codable {
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

private struct SyncPayload: Codable {
    var recipes: [StoredRecipe]
    var selectedRecipeIds: [String]
    var shoppingDone: [String: Bool]
}

private enum AdConfiguration {
    static let appShoppingNativeAdUnitID = "ca-app-pub-2083362073572230/8922047327"
    static let appStartupAdUnitID = "ca-app-pub-2083362073572230/3426178067"
    static let applicationID = "ca-app-pub-2083362073572230~7833867956"
}

#if canImport(WatchConnectivity)
private final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private let session: WCSession?

    private override init() {
        if WCSession.isSupported() {
            session = WCSession.default
        } else {
            session = nil
        }
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func update(payload: SyncPayload) {
        guard let session,
              session.activationState == .activated,
              let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let context = ["payload": json]
        try? session.updateApplicationContext(context)
        if session.isPaired && session.isWatchAppInstalled {
            session.transferUserInfo(context)
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif

private struct ShoppingIngredient: Identifiable {
    var id: String { key }
    let key: String
    var name: String
    var quantity: String
    var category: String
    var recipeImages: [String]
}

private enum RecipeAddMode: Identifiable {
    case link
    case manual

    var id: String {
        switch self {
        case .link: "link"
        case .manual: "manual"
        }
    }
}

private struct EditingShoppingIngredient: Identifiable {
    let id: String
    var name: String
    var quantity: String
    var category: String
}

private let defaultQuantityTerms = ["適量", "適宜", "少々", "お好みで", "ひとつまみ"]
private let defaultRecipeCategories = ["肉・魚", "野菜", "卵・乳製品", "調味料", "その他"]

@MainActor
private final class RecipistaStore: ObservableObject {
    @Published var recipes: [StoredRecipe] = []
    @Published var selectedRecipeIds: [String] = []
    @Published var shoppingDone: [String: Bool] = [:]
    @Published var pastedURL = ""
    @Published var statusMessage = ""
    @Published var isLoadingURL = false
    @Published var recipesExpanded = false
    @Published var unitDisplay = "spoons"
    @Published var manualRecipeName = ""
    @Published var manualIngredients = ""
    @Published var categoryOverrides: [String: String] = [:]
    @Published var quantityTerms: [String] = defaultQuantityTerms
    @Published var categories: [String] = defaultRecipeCategories

    private let defaults = UserDefaults(suiteName: "group.com.recipista.ios") ?? .standard
    private let recipesKey = "recipista.recipes"
    private let selectedKey = "recipista.selectedRecipeIds"
    private let doneKey = "recipista.shoppingDone"
    private let preferencesKey = "recipista.preferences"

    init() {
        load()
    }

    func reload() {
        load()
    }

    var availableCategories: [String] {
        categories
    }

    func addCategory(_ value: String) {
        let category = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { return }
        categories = Array(Set(categories + [category])).sorted { lhs, rhs in
            let leftIndex = defaultRecipeCategories.firstIndex(of: lhs)
            let rightIndex = defaultRecipeCategories.firstIndex(of: rhs)
            if let leftIndex, let rightIndex { return leftIndex < rightIndex }
            if leftIndex != nil { return true }
            if rightIndex != nil { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        save()
    }

    func removeCategory(_ value: String) {
        guard !defaultRecipeCategories.contains(value) else { return }
        categories.removeAll { $0 == value }
        categoryOverrides = categoryOverrides.mapValues { $0 == value ? "その他" : $0 }
        save()
    }

    var shoppingItems: [ShoppingIngredient] {
        let selected = recipes.filter { selectedRecipeIds.contains($0.id) }
        var groups: [String: AggregatedIngredient] = [:]

        for recipe in selected {
            let multiplier = max(0.5, recipe.multiplier ?? 1)
            for ingredient in recipe.ingredients {
                let parsed = Self.parseIngredient(ingredient.line, quantityTerms: quantityTerms)
                guard !parsed.name.isEmpty else { continue }
                let category = ingredient.category ?? categoryOverrides[Self.key(parsed.name)] ?? Self.category(for: parsed.name)
                var item = groups[parsed.key] ?? AggregatedIngredient(key: parsed.key, name: parsed.name, category: category, quantities: [:], notes: [], recipeImages: [])
                if let amount = parsed.amount {
                    item.quantities[parsed.unit, default: 0] += amount * multiplier
                } else if !parsed.note.isEmpty {
                    item.notes.append(parsed.note)
                }
                if let imageUrl = recipe.imageUrl, !imageUrl.isEmpty, item.recipeImages.count < 3 {
                    item.recipeImages.append(imageUrl)
                }
                groups[parsed.key] = item
            }
        }

        return groups.values.map {
            ShoppingIngredient(
                key: $0.key,
                name: $0.name,
                quantity: Self.formatQuantity(quantities: $0.quantities, notes: $0.notes, unitDisplay: unitDisplay),
                category: $0.category,
                recipeImages: $0.recipeImages
            )
        }.sorted {
            let categoryDiff = categories.firstIndex(of: $0.category, or: categories.count) - categories.firstIndex(of: $1.category, or: categories.count)
            return categoryDiff == 0 ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : categoryDiff < 0
        }
    }

    var activeShoppingItems: [ShoppingIngredient] {
        shoppingItems.filter { shoppingDone[$0.key] != true }
    }

    var doneShoppingItems: [ShoppingIngredient] {
        shoppingItems.filter { shoppingDone[$0.key] == true }
    }

    var shoppingShareText: String {
        let items = activeShoppingItems
        guard !items.isEmpty else { return "Recipista 買い物リスト" }
        var lines = ["Recipista 買い物リスト"]
        for category in categories {
            let categoryItems = items.filter { $0.category == category }
            guard !categoryItems.isEmpty else { continue }
            lines.append("")
            lines.append("【\(category)】")
            lines.append(contentsOf: categoryItems.map { item in
                item.quantity.isEmpty ? "- \(item.name)" : "- \(item.name) \(item.quantity)"
            })
        }
        return lines.joined(separator: "\n")
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == "recipista",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = Data(base64URLEncoded: encoded),
              let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
            return
        }

        recipes = payload.recipes
        selectedRecipeIds = payload.selectedRecipeIds
        shoppingDone = payload.shoppingDone
        save()
        statusMessage = "Safari拡張機能から買い物リストを同期しました。"
    }

    func isSelected(_ recipe: StoredRecipe) -> Bool {
        selectedRecipeIds.contains(recipe.id)
    }

    func toggleRecipe(_ recipe: StoredRecipe) {
        if selectedRecipeIds.contains(recipe.id) {
            selectedRecipeIds.removeAll { $0 == recipe.id }
        } else {
            selectedRecipeIds.insert(recipe.id, at: 0)
        }
        pruneDoneState()
        save()
    }

    func toggleDone(_ item: ShoppingIngredient) {
        shoppingDone[item.key] = !(shoppingDone[item.key] ?? false)
        save()
    }

    func clearDone() {
        shoppingDone = [:]
        save()
    }

    func updateMultiplier(for recipe: StoredRecipe, value: Double) {
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        recipes[index].multiplier = Self.normalizedMultiplier(value)
        pruneDoneState()
        save()
    }

    func deleteRecipe(_ recipe: StoredRecipe) {
        recipes.removeAll { $0.id == recipe.id }
        selectedRecipeIds.removeAll { $0 == recipe.id }
        pruneDoneState()
        save()
    }

    func updateUnitDisplay(_ value: String) {
        unitDisplay = value
        save()
    }

    func updateCategoryOverride(name: String, category: String) {
        let key = Self.key(name)
        guard !key.isEmpty, categories.contains(category) else { return }
        categoryOverrides[key] = category
        save()
    }

    func removeCategoryOverride(key: String) {
        categoryOverrides.removeValue(forKey: key)
        save()
    }

    func addQuantityTerm(_ value: String) {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        quantityTerms = Array(Set(quantityTerms + [term])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        save()
    }

    func removeQuantityTerm(_ value: String) {
        quantityTerms.removeAll { $0 == value }
        save()
    }

    func checkAllSeasonings() {
        for item in shoppingItems where item.category == "調味料" {
            shoppingDone[item.key] = true
        }
        save()
    }

    func editingItem(for item: ShoppingIngredient) -> EditingShoppingIngredient {
        EditingShoppingIngredient(id: item.key, name: item.name, quantity: item.quantity, category: item.category)
    }

    func updateShoppingItem(_ editing: EditingShoppingIngredient) {
        let oldKey = editing.id
        let newName = editing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newQuantity = editing.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let newCategory = categories.contains(editing.category) ? editing.category : "その他"
        guard !newName.isEmpty else { return }

        for recipeIndex in recipes.indices where selectedRecipeIds.contains(recipes[recipeIndex].id) {
            for ingredientIndex in recipes[recipeIndex].ingredients.indices {
                let ingredient = recipes[recipeIndex].ingredients[ingredientIndex]
                let parsed = Self.parseIngredient(ingredient.line, quantityTerms: quantityTerms)
                guard parsed.key == oldKey else { continue }
                recipes[recipeIndex].ingredients[ingredientIndex] = .edited(name: newName, quantityText: newQuantity, category: newCategory)
                categoryOverrides[Self.key(newName)] = newCategory
            }
        }

        if let wasDone = shoppingDone.removeValue(forKey: oldKey), wasDone {
            shoppingDone[Self.key(newName)] = true
        }
        save()
    }

    func moveShoppingItem(key: String, to category: String) {
        guard categories.contains(category) else { return }
        for recipeIndex in recipes.indices where selectedRecipeIds.contains(recipes[recipeIndex].id) {
            for ingredientIndex in recipes[recipeIndex].ingredients.indices {
                let ingredient = recipes[recipeIndex].ingredients[ingredientIndex]
                let parsed = Self.parseIngredient(ingredient.line, quantityTerms: quantityTerms)
                guard parsed.key == key else { continue }
                let quantityText = parsed.amount.map { amount in
                    ["大さじ", "小さじ"].contains(parsed.unit)
                        ? "\(parsed.unit)\(Self.format(amount))"
                        : "\(Self.format(amount))\(parsed.unit)"
                } ?? ""
                recipes[recipeIndex].ingredients[ingredientIndex] = .edited(
                    name: parsed.name,
                    quantityText: [quantityText, parsed.note].filter { !$0.isEmpty }.joined(separator: " "),
                    category: category
                )
                categoryOverrides[Self.key(parsed.name)] = category
            }
        }
        save()
    }

    func addManualRecipe() {
        let ingredients = manualIngredients
            .components(separatedBy: CharacterSet(charactersIn: "\n、,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { IngredientValue.text($0) }
        guard !ingredients.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let name = manualRecipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = StoredRecipe(
            id: "manual-\(Int(now))",
            name: name.isEmpty ? "手入力レシピ" : name,
            sourceUrl: nil,
            siteName: "手入力",
            imageUrl: nil,
            yieldText: nil,
            ingredients: ingredients,
            multiplier: 1
        )
        recipes.insert(recipe, at: 0)
        selectedRecipeIds.insert(recipe.id, at: 0)
        manualRecipeName = ""
        manualIngredients = ""
        save()
    }

    func loadRecipeFromPastedURL() async {
        let text = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
            statusMessage = "有効なレシピURLを入力してください。"
            return
        }

        isLoadingURL = true
        defer { isLoadingURL = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) else {
                statusMessage = "ページを読み込めませんでした。"
                return
            }
            guard let recipe = Self.extractRecipe(from: html, url: url) else {
                statusMessage = "レシピ情報を取得できませんでした。"
                return
            }
            recipes.insert(recipe, at: 0)
            selectedRecipeIds.insert(recipe.id, at: 0)
            pastedURL = ""
            save()
            statusMessage = "レシピを読み込み、買い物リストに追加しました。"
        } catch {
            statusMessage = "URLの読み込みに失敗しました。"
        }
    }

    private func load() {
        if let object = defaults.object(forKey: recipesKey),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let decoded = try? JSONDecoder().decode([StoredRecipe].self, from: data) {
            recipes = decoded
        } else if let data = defaults.data(forKey: recipesKey),
                  let decoded = try? JSONDecoder().decode([StoredRecipe].self, from: data) {
            recipes = decoded
        }
        selectedRecipeIds = defaults.stringArray(forKey: selectedKey) ?? []
        shoppingDone = defaults.dictionary(forKey: doneKey) as? [String: Bool] ?? [:]
        if let preferences = defaults.dictionary(forKey: preferencesKey) {
            if let unit = preferences["unitDisplay"] as? String {
                unitDisplay = unit
            }
            if let overrides = preferences["categoryOverrides"] as? [String: String] {
                categoryOverrides = overrides
            }
            if let terms = preferences["quantityTerms"] as? [String], !terms.isEmpty {
                quantityTerms = terms
            }
            if let savedCategories = preferences["categories"] as? [String], !savedCategories.isEmpty {
                categories = Array(Set(defaultRecipeCategories + savedCategories))
                    .sorted { lhs, rhs in
                        let leftIndex = defaultRecipeCategories.firstIndex(of: lhs)
                        let rightIndex = defaultRecipeCategories.firstIndex(of: rhs)
                        if let leftIndex, let rightIndex { return leftIndex < rightIndex }
                        if leftIndex != nil { return true }
                        if rightIndex != nil { return false }
                        return lhs.localizedStandardCompare(rhs) == .orderedAscending
                    }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recipes),
           let object = try? JSONSerialization.jsonObject(with: data) {
            defaults.set(object, forKey: recipesKey)
        }
        defaults.set(selectedRecipeIds, forKey: selectedKey)
        defaults.set(shoppingDone, forKey: doneKey)
        defaults.set([
            "unitDisplay": unitDisplay,
            "categoryOverrides": categoryOverrides,
            "quantityTerms": quantityTerms,
            "categories": categories
        ], forKey: preferencesKey)
        defaults.synchronize()
#if canImport(WatchConnectivity)
        WatchSyncManager.shared.update(
            payload: SyncPayload(
                recipes: recipes,
                selectedRecipeIds: selectedRecipeIds,
                shoppingDone: shoppingDone
            )
        )
#endif
    }

    private func pruneDoneState() {
        let validKeys = Set(shoppingItems.map(\.key))
        shoppingDone = shoppingDone.filter { validKeys.contains($0.key) }
    }

    private static func extractRecipe(from html: String, url: URL) -> StoredRecipe? {
        let scripts = html.matches(pattern: #"<script[^>]+application/ld\+json[^>]*>([\s\S]*?)</script>"#)
        for script in scripts {
            guard let data = script.htmlDecoded.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let recipe = findRecipeNode(object) else { continue }

            let name = recipe["name"] as? String ?? url.host ?? "読み込みレシピ"
            let ingredients = asStringArray(recipe["recipeIngredient"]).map { IngredientValue.text($0) }
            guard !ingredients.isEmpty else { continue }
            let imageUrl = imageURL(from: recipe["image"])
            let yieldText = asStringArray(recipe["recipeYield"]).first
            return StoredRecipe(
                id: "\(url.absoluteString)|\(name)".data(using: .utf8)?.base64EncodedString() ?? UUID().uuidString,
                name: name,
                sourceUrl: url.absoluteString,
                siteName: url.host,
                imageUrl: imageUrl,
                yieldText: yieldText,
                ingredients: ingredients,
                multiplier: 1
            )
        }
        return nil
    }

    private static func findRecipeNode(_ object: Any) -> [String: Any]? {
        if let array = object as? [Any] {
            return array.compactMap(findRecipeNode).first
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        let type = dictionary["@type"]
        if asStringArray(type).contains(where: { $0.lowercased() == "recipe" }) {
            return dictionary
        }
        if let graph = dictionary["@graph"] {
            return findRecipeNode(graph)
        }
        return nil
    }

    private static func asStringArray(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private static func imageURL(from value: Any?) -> String? {
        if let value = value as? String { return value }
        if let values = value as? [Any] { return imageURL(from: values.first) }
        if let dictionary = value as? [String: Any] {
            return dictionary["url"] as? String ?? dictionary["contentUrl"] as? String
        }
        return nil
    }

    private static func parseIngredient(_ line: String, quantityTerms: [String] = defaultQuantityTerms) -> (key: String, name: String, amount: Double?, unit: String, note: String) {
        let normalized = normalizeDigits(line.replacingOccurrences(of: "　", with: " "))
        let unitFirstPattern = #"^(.+?)\s*(大さじ|小さじ)\s*(\d+(?:\.\d+)?(?:/\d+)?)(.*)$"#
        if let match = normalized.firstMatch(pattern: unitFirstPattern) {
            let name = match[0].trimmingCharacters(in: .whitespaces)
            let unit = match[1]
            let amount = parseNumber(match[2])
            let note = match[3].trimmingCharacters(in: .whitespaces)
            return (key(name), name, amount, unit, note)
        }

        let units = ["大さじ", "小さじ", "g", "kg", "ml", "cc", "個", "本", "枚", "束", "袋", "カップ", "合", "株"] + quantityTerms
        let unitAlternation = units.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let numberFirstPattern = #"^(.+?)\s*(\d+(?:\.\d+)?(?:/\d+)?)\s*("# + unitAlternation + #")?(.*)$"#
        if let match = normalized.firstMatch(pattern: numberFirstPattern) {
            let name = match[0].trimmingCharacters(in: .whitespaces)
            let amount = parseNumber(match[1])
            let unit = match[2]
            let note = match[3].trimmingCharacters(in: .whitespaces)
            return (key(name), name, amount, unit, note)
        }

        for word in quantityTerms where normalized.hasSuffix(word) {
            let name = String(normalized.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { break }
            return (key(name), name, nil, "", word)
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
        if name.range(of: #"水|しょうゆ|醤油|みそ|味噌|砂糖|塩|こしょう|胡椒|みりん|酒|酢|油|ごま油|オリーブオイル|だし|ソース|ケチャップ|マヨネーズ|コンソメ|鶏ガラ|カレー粉"#, options: .regularExpression) != nil { return "調味料" }
        return "その他"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func normalizedMultiplier(_ value: Double) -> Double {
        min(5, max(0.5, (value * 2).rounded() / 2))
    }

    private static func parseNumber(_ value: String) -> Double? {
        if value.contains("/") {
            let parts = value.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        }
        return Double(value)
    }

    private static func normalizeDigits(_ value: String) -> String {
        value
            .replacingOccurrences(of: "一", with: "1")
            .replacingOccurrences(of: "二", with: "2")
            .replacingOccurrences(of: "三", with: "3")
            .replacingOccurrences(of: "四", with: "4")
            .replacingOccurrences(of: "五", with: "5")
            .replacingOccurrences(of: "六", with: "6")
            .replacingOccurrences(of: "七", with: "7")
            .replacingOccurrences(of: "八", with: "8")
            .replacingOccurrences(of: "九", with: "9")
    }

    private static func formatQuantity(quantities: [String: Double], notes: [String], unitDisplay: String) -> String {
        var parts: [String] = []
        let tablespoon = quantities["大さじ"] ?? 0
        let teaspoon = quantities["小さじ"] ?? 0
        let milliliter = (quantities["ml"] ?? 0) + (quantities["cc"] ?? 0)
        let totalTeaspoon = tablespoon * 3 + teaspoon + (unitDisplay == "spoons" ? milliliter / 5 : 0)
        if totalTeaspoon > 0 {
            if unitDisplay == "ml" {
                parts.append("\(format(totalTeaspoon * 5 + milliliter))ml")
            } else if totalTeaspoon >= 3 {
                parts.append("大さじ\(format(totalTeaspoon / 3))")
            } else {
                parts.append("小さじ\(format(totalTeaspoon))")
            }
        }
        for (unit, amount) in quantities where !["大さじ", "小さじ", "ml", "cc"].contains(unit) && amount > 0 {
            parts.append("\(format(amount))\(unit)")
        }
        parts.append(contentsOf: notes.filter { !$0.isEmpty })
        return parts.joined(separator: " + ")
    }

    private struct AggregatedIngredient {
        var key: String
        var name: String
        var category: String
        var quantities: [String: Double]
        var notes: [String]
        var recipeImages: [String]
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}

private extension String {
    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { result in
            guard result.numberOfRanges > 1, let matchRange = Range(result.range(at: 1), in: self) else { return nil }
            return String(self[matchRange])
        }
    }

    func firstMatch(pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let result = regex.firstMatch(in: self, range: range) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let matchRange = Range(result.range(at: index), in: self) else { return "" }
            return String(self[matchRange])
        }
    }

    var htmlDecoded: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x2F;", with: "/")
    }
}

private extension Array where Element: Equatable {
    func firstIndex(of element: Element, or defaultValue: Int) -> Int {
        firstIndex(of: element) ?? defaultValue
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipeAddMode: RecipeAddMode?
    @State private var isEditingShoppingList = false
    @State private var showsStartupAd = false
    @StateObject private var store = RecipistaStore()

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        appHeader
                        appShoppingList
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
                }
                .background(Color.recipistaBackground.ignoresSafeArea())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("買い物リスト", systemImage: "basket.fill")
            }

            NavigationStack {
                settingsView
                    .navigationTitle("設定")
                    .background(Color.recipistaBackground.ignoresSafeArea())
            }
            .tabItem {
                Label("設定", systemImage: "gearshape")
            }
        }
        .tint(Color.recipistaGreen)
        .sheet(item: $recipeAddMode) { mode in
            switch mode {
            case .link:
                LinkRecipeAddView(store: store)
            case .manual:
                ManualRecipeAddView(store: store)
            }
        }
        .onOpenURL { url in
            store.handleOpenURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reload()
            }
        }
        .onAppear {
            showsStartupAd = true
        }
        .fullScreenCover(isPresented: $showsStartupAd) {
            StartupAdView(adUnitID: AdConfiguration.appStartupAdUnitID) {
                showsStartupAd = false
            }
        }
    }

    private var appHeader: some View {
        HStack(alignment: .center) {
            Text("Recipista")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.recipistaGreen)
            Spacer()
            Menu {
                Button {
                    recipeAddMode = .link
                } label: {
                    Label("リンクから追加", systemImage: "link")
                }
                Button {
                    recipeAddMode = .manual
                } label: {
                    Label("手入力で追加", systemImage: "square.and.pencil")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.recipistaGreen, in: Circle())
            }
        }
        .padding(.top, 2)
    }

    private var appShoppingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            savedRecipeSelector
            Divider()

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("買い物リスト")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.recipistaGreen)
                }
                Spacer()
                if !store.shoppingItems.isEmpty {
                    ShareLink(item: store.shoppingShareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.recipistaGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.recipistaLine)
                    }

                    Button {
                        isEditingShoppingList.toggle()
                    } label: {
                        Image(systemName: isEditingShoppingList ? "checkmark" : "pencil")
                            .font(.system(size: 16, weight: .black))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.recipistaGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.recipistaLine)
                    }

                    Button {
                        store.clearDone()
                    } label: {
                        Text("すべてチェック解除")
                            .frame(height: 30)
                            .padding(.horizontal, 10)
                    }
                    .font(.caption2.weight(.bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.recipistaGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.recipistaLine)
                    }
                }
            }

            if store.shoppingItems.isEmpty {
                Text("保存済みレシピにチェックを入れると材料がまとまります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.recipistaLine, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
            } else {
                if isEditingShoppingList {
                    ShoppingEditListView(store: store)
                        .frame(minHeight: 320)
                } else {
                    VStack(spacing: 0) {
                    shoppingGroups(for: store.activeShoppingItems)

                    if !store.doneShoppingItems.isEmpty {
                        NativeAdSlotView(adUnitID: AdConfiguration.appShoppingNativeAdUnitID)
                            .padding(.top, 12)
                            .padding(.bottom, 2)

                        Text("チェック済み")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .overlay(alignment: .top) {
                                Divider()
                            }
                        shoppingGroups(for: store.doneShoppingItems)
                    }
                    }
                }
            }

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.recipistaPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var settingsView: some View {
        Form {
            Section {
                Picker("分量表示", selection: Binding(
                    get: { store.unitDisplay },
                    set: { store.updateUnitDisplay($0) }
                )) {
                    Text("大さじ/小さじ").tag("spoons")
                    Text("ml表示").tag("ml")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("表示")
            } footer: {
                Text("調味料の大さじ/小さじを見慣れた単位で表示します。")
            }

            Section {
                NavigationLink {
                    CategorySettingsView(store: store)
                } label: {
                    HStack {
                        Text("カテゴリー")
                        Spacer()
                        Text("\(store.availableCategories.count)件")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    CategoryOverrideSettingsView(store: store)
                } label: {
                    HStack {
                        Text("材料カテゴリ")
                        Spacer()
                        Text("\(store.categoryOverrides.count)件")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    QuantityTermSettingsView(store: store)
                } label: {
                    HStack {
                        Text("数量単位")
                        Spacer()
                        Text("\(store.quantityTerms.count)件")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("分類と数量")
            } footer: {
                Text("カテゴリや数量単位は、使い方に合わせて追加できます。")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var savedRecipeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("買い物対象レシピ")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.recipistaGreen)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) {
                        store.recipesExpanded.toggle()
                    }
                } label: {
                    Image(systemName: store.recipesExpanded ? "chevron.down" : "chevron.right")
                        .font(.headline.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.recipistaGreen)
            }

            if store.recipes.isEmpty {
                Text("まだ保存されたレシピはありません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.recipistaLine, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
            } else if store.recipesExpanded {
                VStack(spacing: 0) {
                    ForEach(store.recipes) { recipe in
                        AppRecipeListRow(
                            recipe: recipe,
                            isSelected: store.isSelected(recipe),
                            onToggle: {
                            store.toggleRecipe(recipe)
                            },
                            onMultiplierChange: { value in
                                store.updateMultiplier(for: recipe, value: value)
                            },
                            onDelete: {
                                store.deleteRecipe(recipe)
                            }
                        )
                        if recipe.id != store.recipes.last?.id { Divider() }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.recipes.filter { store.selectedRecipeIds.contains($0.id) }) { recipe in
                            AppSelectedRecipeChip(
                                recipe: recipe,
                                onToggle: { store.toggleRecipe(recipe) },
                                onMultiplierChange: { store.updateMultiplier(for: recipe, value: $0) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func shoppingGroups(for items: [ShoppingIngredient]) -> some View {
        ForEach(store.availableCategories, id: \.self) { category in
            let categoryItems = items.filter { $0.category == category }
            if !categoryItems.isEmpty {
                HStack {
                    Text(category)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.recipistaGreen)
                    Spacer()
                    if category == "調味料" && categoryItems.contains(where: { store.shoppingDone[$0.key] != true }) {
                        Button {
                            store.checkAllSeasonings()
                        } label: {
                            Text("すべてチェック")
                                .frame(height: 28)
                                .padding(.horizontal, 9)
                        }
                        .font(.caption2.weight(.bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.recipistaGreen)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.recipistaLine)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 3)
                .dropDestination(for: String.self) { keys, _ in
                    guard isEditingShoppingList, let key = keys.first else { return false }
                    store.moveShoppingItem(key: key, to: category)
                    return true
                }

                ForEach(categoryItems) { item in
                    if isEditingShoppingList {
                        AppShoppingEditRow(item: store.editingItem(for: item), categories: store.availableCategories) { updated in
                            store.updateShoppingItem(updated)
                        }
                    } else {
                        AppShoppingRow(
                            item: item,
                            isDone: store.shoppingDone[item.key] == true,
                            onToggle: { store.toggleDone(item) }
                        )
                    }
                    Divider()
                }
            }
        }
    }

    private var extensionPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipistaで材料を確認")
                .font(.headline)
                .foregroundStyle(Color.recipistaGreen)

            ExtensionPopupMock()

            VStack(spacing: 0) {
                StepRow(number: "1", title: "抽出材料プレビューで、材料が取れているか確認します。")
                Divider().padding(.leading, 44)
                StepRow(number: "2", title: "倍率を選んでからプラスボタンで保存します。")
                Divider().padding(.leading, 44)
                StepRow(number: "3", title: "買い物リストで材料をまとめてチェックします。")
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var safariOpenGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SafariからRecipistaを開く")
                .font(.headline)
                .foregroundStyle(Color.recipistaGreen)

            SafariOpenMock()

            VStack(spacing: 0) {
                StepRow(number: "1", title: "Safariでレシピページを開き、検索バー左の拡張機能アイコンをタップします。")
                Divider().padding(.leading, 44)
                StepRow(number: "2", title: "表示されたメニューから「拡張機能を管理」またはRecipistaを選びます。")
                Divider().padding(.leading, 44)
                StepRow(number: "3", title: "Recipistaのポップアップが開いたら、材料プレビューを確認します。")
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Safari拡張機能を有効にする")
                .font(.headline)
                .foregroundStyle(Color.recipistaGreen)

            SafariSettingsMock()

            Text("設定アプリの「アプリ」からSafariを開き、その中の拡張機能メニューでRecipistaをオンにしてください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            Button {
            } label: {
                Label("Safari拡張機能の設定手順を見る", systemImage: "safari")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.recipistaGreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CategorySettingsView: View {
    @ObservedObject var store: RecipistaStore
    @State private var categoryName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("カテゴリー", text: $categoryName)
                    Button("追加") {
                        store.addCategory(categoryName)
                        categoryName = ""
                    }
                    .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("登録済み") {
                ForEach(store.availableCategories, id: \.self) { category in
                    HStack {
                        Text(category)
                        Spacer()
                        if defaultRecipeCategories.contains(category) {
                            Text("標準")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !defaultRecipeCategories.contains(category) {
                            Button("削除", role: .destructive) {
                                store.removeCategory(category)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("カテゴリー")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.recipistaBackground.ignoresSafeArea())
    }
}

private struct CategoryOverrideSettingsView: View {
    @ObservedObject var store: RecipistaStore
    @State private var ingredientName = ""
    @State private var category = "その他"

    var body: some View {
        Form {
            Section {
                LabeledContent("材料名") {
                    TextField("例: 水", text: $ingredientName)
                        .multilineTextAlignment(.trailing)
                }
                Picker("カテゴリ", selection: $category) {
                    ForEach(store.availableCategories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                HStack {
                    Spacer()
                    Button("追加") {
                        store.updateCategoryOverride(name: ingredientName, category: category)
                        ingredientName = ""
                    }
                    .disabled(ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("ここに登録した材料は、登録先カテゴリで優先して表示されます。")
            }

            Section("登録済み") {
                if store.categoryOverrides.isEmpty {
                    Text("まだ登録がありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.categoryOverrides.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key)
                            Spacer()
                            Text(store.categoryOverrides[key] ?? "")
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                store.removeCategoryOverride(key: key)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("材料カテゴリ")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.recipistaBackground.ignoresSafeArea())
    }
}

private struct QuantityTermSettingsView: View {
    @ObservedObject var store: RecipistaStore
    @State private var term = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("例: 少量", text: $term)
                    Button("追加") {
                        store.addQuantityTerm(term)
                        term = ""
                    }
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("登録した単位や語句は、材料名ではなく数量側に表示します。")
            }

            Section("登録済み") {
                ForEach(store.quantityTerms, id: \.self) { term in
                    Text(term)
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                store.removeQuantityTerm(term)
                            }
                        }
                }
            }
        }
        .navigationTitle("数量単位")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.recipistaBackground.ignoresSafeArea())
    }
}

private struct NativeAdSlotView: View {
    let adUnitID: String

    var body: some View {
        VStack(spacing: 4) {
            Text("広告")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Color.recipistaSecondaryPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.recipistaLine, style: StrokeStyle(lineWidth: 1, dash: [4]))
        }
        .accessibilityLabel("広告")
        .accessibilityIdentifier("native-ad-\(adUnitID)")
    }
}

private struct StartupAdView: View {
    let adUnitID: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.recipistaBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                NativeAdSlotView(adUnitID: adUnitID)
                    .padding(.horizontal, 24)
                Text("Recipista")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.recipistaGreen)
                Spacer()
                Button("閉じる") {
                    onClose()
                }
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.recipistaGreen, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
    }
}

private struct ExtensionPopupMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recipista")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.recipistaGreen)

                Spacer()

                Capsule()
                    .fill(Color.recipistaGreen.opacity(0.18))
                    .frame(width: 58, height: 7)
            }

            HStack(spacing: 8) {
                MockTab(title: "買い物リスト", isActive: true)
                MockTab(title: "保存済みレシピ", isActive: false)
            }

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.recipistaGreen.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(Color.recipistaGreen)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text("閲覧中")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.recipistaGreen)
                    Text("肉じゃが")
                        .font(.headline)
                    Text("材料 6件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("×1")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Image(systemName: "plus")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.recipistaGreen, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("抽出材料プレビュー")
                    .font(.subheadline.weight(.bold))

                MockIngredient(name: "じゃがいも", amount: "3個")
                MockIngredient(name: "玉ねぎ", amount: "1個")
                MockIngredient(name: "しょうゆ", amount: "大さじ2")
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.recipistaLine)
        }
    }
}

private struct AppRecipeListRow: View {
    let recipe: StoredRecipe
    let isSelected: Bool
    let onToggle: () -> Void
    let onMultiplierChange: (Double) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.recipistaGreen)
            }
            .buttonStyle(.plain)

            RecipeThumb(recipe: recipe, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let sourceUrl = recipe.sourceUrl, let url = URL(string: sourceUrl), recipe.siteName != "手入力" {
                    Link(recipe.siteName ?? sourceUrl, destination: url)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.recipistaGreen)
                        .underline()
                        .lineLimit(1)
                } else {
                    Text(recipe.siteName ?? "手入力")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(stride(from: 0.5, through: 5.0, by: 0.5).map { $0 }, id: \.self) { value in
                    Button(recipePortionLabel(recipe: recipe, multiplier: value)) {
                        onMultiplierChange(value)
                    }
                }
            } label: {
                Text(recipePortionLabel(recipe: recipe, multiplier: recipe.multiplier ?? 1))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.recipistaGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 64, alignment: .trailing)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct AppSelectedRecipeChip: View {
    let recipe: StoredRecipe
    let onToggle: () -> Void
    let onMultiplierChange: (Double) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RecipeThumb(recipe: recipe, size: 62)

            Button(action: onToggle) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.recipistaGreen, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 1.5)
                    }
            }
            .offset(x: 9, y: -9)

            Menu {
                ForEach(stride(from: 0.5, through: 5.0, by: 0.5).map { $0 }, id: \.self) { value in
                    Button(recipePortionLabel(recipe: recipe, multiplier: value)) {
                        onMultiplierChange(value)
                    }
                }
            } label: {
                Text(recipeCompactPortionLabel(recipe))
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                    .frame(width: 30, height: 20)
                    .background(Color.recipistaGreen.opacity(0.92), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.9), lineWidth: 1.2)
                    }
            }
            .buttonStyle(.plain)
            .offset(x: 1, y: 41)
        }
        .frame(width: 72, height: 72)
    }
}

private struct RecipeThumb: View {
    let recipe: StoredRecipe
    let size: CGFloat

    var body: some View {
        Group {
            if let imageUrl = recipe.imageUrl, let url = URL(string: imageUrl), !imageUrl.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.recipistaGreen.opacity(0.15)
                }
            } else {
                Color.recipistaGreen.opacity(0.14)
                    .overlay {
                        Text(String(recipe.name.prefix(1)))
                            .font(.headline.weight(.black))
                            .foregroundStyle(Color.recipistaGreen)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ShoppingEditListView: View {
    @ObservedObject var store: RecipistaStore

    var body: some View {
        List {
            ForEach(store.availableCategories, id: \.self) { category in
                let items = store.shoppingItems.filter { $0.category == category }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            AppShoppingEditRow(item: store.editingItem(for: item), categories: store.availableCategories) { updated in
                                store.updateShoppingItem(updated)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.recipistaPanel)
                        }
                    } header: {
                        Text(category)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.recipistaGreen)
                            .dropDestination(for: String.self) { keys, _ in
                                guard let key = keys.first else { return false }
                                store.moveShoppingItem(key: key, to: category)
                                return true
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.recipistaPanel)
    }
}

private struct AppShoppingRow: View {
    let item: ShoppingIngredient
    let isDone: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isDone ? Color.recipistaGreen : Color.recipistaLine)
            }
            .buttonStyle(.plain)

            Text(item.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isDone ? .secondary : .primary)
                .strikethrough(isDone)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.quantity)
                .font(.callout.weight(.bold))
                .foregroundStyle(.secondary)
                .strikethrough(isDone)
                .frame(width: 68, alignment: .trailing)

            HStack(spacing: -12) {
                ForEach(Array(item.recipeImages.prefix(3).enumerated()), id: \.offset) { _, imageURL in
                    AsyncImage(url: URL(string: imageURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.recipistaGreen.opacity(0.15)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.background, lineWidth: 1)
                    }
                }
            }
            .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

private struct AppShoppingEditRow: View {
    @State private var item: EditingShoppingIngredient
    @State private var currentKey: String
    let onSave: (EditingShoppingIngredient) -> Void
    let categories: [String]

    init(item: EditingShoppingIngredient, categories: [String], onSave: @escaping (EditingShoppingIngredient) -> Void) {
        _item = State(initialValue: item)
        _currentKey = State(initialValue: item.id)
        self.categories = categories
        self.onSave = onSave
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .draggable(currentKey)

            TextField("材料名", text: $item.name)
                .textFieldStyle(.roundedBorder)

            TextField("数量", text: $item.quantity)
                .textFieldStyle(.roundedBorder)
                .frame(width: 82)

            Picker("カテゴリ", selection: $item.category) {
                ForEach(categories, id: \.self) { category in
                    Text(category).tag(category)
                }
            }
            .labelsHidden()
            .frame(width: 86)
        }
        .font(.caption)
        .padding(.vertical, 7)
        .onChange(of: item.name) { _, _ in persist() }
        .onChange(of: item.quantity) { _, _ in persist() }
        .onChange(of: item.category) { _, _ in persist() }
    }

    private func persist() {
        let updated = EditingShoppingIngredient(
            id: currentKey,
            name: item.name,
            quantity: item.quantity,
            category: item.category
        )
        onSave(updated)
        currentKey = item.name.replacingOccurrences(of: " ", with: "").lowercased()
    }
}

private struct ShoppingIngredientEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: EditingShoppingIngredient
    let onSave: (EditingShoppingIngredient) -> Void
    private let categories = ["肉・魚", "野菜", "卵・乳製品", "調味料", "その他"]

    init(item: EditingShoppingIngredient, onSave: @escaping (EditingShoppingIngredient) -> Void) {
        _item = State(initialValue: item)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("材料") {
                    TextField("材料名", text: $item.name)
                    TextField("数量", text: $item.quantity)
                    Picker("カテゴリ", selection: $item.category) {
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                }
            }
            .navigationTitle("材料を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LinkRecipeAddView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecipistaStore

    var body: some View {
        NavigationStack {
            Form {
                Section("リンクからレシピを追加") {
                    TextField("レシピURLをペースト", text: $store.pastedURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                if !store.statusMessage.isEmpty {
                    Section {
                        Text(store.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("レシピ追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await store.loadRecipeFromPastedURL()
                            if store.pastedURL.isEmpty {
                                dismiss()
                            }
                        }
                    } label: {
                        if store.isLoadingURL {
                            ProgressView()
                        } else {
                            Text("追加")
                        }
                    }
                    .disabled(store.isLoadingURL || store.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ManualRecipeAddView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecipistaStore

    var body: some View {
        NavigationStack {
            Form {
                Section("レシピ") {
                    TextField("レシピ名", text: $store.manualRecipeName)
                }
                Section("材料") {
                    TextEditor(text: $store.manualIngredients)
                        .frame(minHeight: 140)
                    Text("1行に1材料ずつ入力してください。例: じゃがいも 3個")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手入力で追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.addManualRecipe()
                        dismiss()
                    }
                    .disabled(store.manualIngredients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private func formatMultiplier(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}

private func recipePortionLabel(recipe: StoredRecipe, multiplier: Double) -> String {
    guard let yieldText = recipe.yieldText?.trimmingCharacters(in: .whitespacesAndNewlines),
          !yieldText.isEmpty else {
        return "×\(formatMultiplier(multiplier))"
    }
    if let people = recipeYieldPeople(yieldText) {
        return "\(formatMultiplier(people * multiplier))人分"
    }
    return multiplier == 1 ? yieldText : "\(yieldText) ×\(formatMultiplier(multiplier))"
}

private func recipeCompactPortionLabel(_ recipe: StoredRecipe) -> String {
    recipePortionLabel(recipe: recipe, multiplier: recipe.multiplier ?? 1)
}

private func recipeYieldPeople(_ value: String) -> Double? {
    let normalized = value
        .replacingOccurrences(of: "１", with: "1")
        .replacingOccurrences(of: "２", with: "2")
        .replacingOccurrences(of: "３", with: "3")
        .replacingOccurrences(of: "４", with: "4")
        .replacingOccurrences(of: "５", with: "5")
        .replacingOccurrences(of: "６", with: "6")
        .replacingOccurrences(of: "７", with: "7")
        .replacingOccurrences(of: "８", with: "8")
        .replacingOccurrences(of: "９", with: "9")
    guard let match = normalized.firstMatch(pattern: #"(\d+(?:\.\d+)?)\s*(?:人|人分| servings?|名)"#),
          let value = Double(match[0]) else { return nil }
    return value
}

private struct SafariOpenMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SafariBrowserMock()

            HStack(alignment: .top, spacing: 10) {
                OpenStepIllustration(
                    number: "1",
                    symbol: "textformat.size",
                    title: "アドレスバー左をタップ"
                )

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 30)

                OpenStepIllustration(
                    number: "2",
                    symbol: "puzzlepiece.extension",
                    title: "拡張機能を開く"
                )

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 30)

                OpenStepIllustration(
                    number: "3",
                    symbol: "basket.fill",
                    title: "Recipistaを選ぶ"
                )
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.recipistaLine)
        }
    }
}

private struct SafariBrowserMock: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.recipistaGreen.opacity(0.12))
                .frame(height: 84)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.recipistaGreen.opacity(0.24))
                            .frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.recipistaGreen.opacity(0.18))
                            .frame(width: 180, height: 10)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.recipistaGreen.opacity(0.16))
                            .frame(width: 150, height: 10)
                    }
                    .padding(14)
                }

            HStack(spacing: 10) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: Circle())

                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text("delishkitchen.tv")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(.systemBackground), in: Capsule())

                Image(systemName: "ellipsis")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: Circle())
            }
            .padding(10)
            .background(Color.recipistaSecondaryPanel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 8)
        }
    }
}

private struct OpenStepIllustration: View {
    let number: String
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.recipistaGreen)
                    .frame(width: 46, height: 46)
                    .background(Color.recipistaGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(number)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.recipistaGreen, in: Circle())
                    .offset(x: -5, y: -5)
            }

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MockTab: View {
    let title: String
    let isActive: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(isActive ? Color.recipistaGreen : .secondary)
            .frame(width: 104, height: 34)
            .background(isActive ? Color.recipistaGreen.opacity(0.12) : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? Color.recipistaGreen : Color.recipistaLine)
            }
    }
}

private struct MockIngredient: View {
    let name: String
    let amount: String

    var body: some View {
        HStack {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(Color.recipistaGreen)
            Text(name)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(amount)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.recipistaLine)
                .frame(height: 1)
        }
    }
}

private struct SafariSettingsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsScreenMock(
                title: "設定",
                highlightedTitle: "アプリ",
                highlightedSymbol: "square.grid.2x2",
                rows: [
                    ("person.crop.circle", "Apple Account"),
                    ("gearshape", "一般"),
                    ("square.grid.2x2", "アプリ")
                ]
            )

            HierarchyArrow()

            SettingsScreenMock(
                title: "アプリ",
                highlightedTitle: "Safari",
                highlightedSymbol: "safari",
                rows: [
                    ("calendar", "カレンダー"),
                    ("camera", "カメラ"),
                    ("safari", "Safari")
                ]
            )

            HierarchyArrow()

            SettingsScreenMock(
                title: "Safari",
                highlightedTitle: "拡張機能",
                highlightedSymbol: "puzzlepiece.extension",
                rows: [
                    ("magnifyingglass", "検索"),
                    ("hand.raised", "プライバシー"),
                    ("puzzlepiece.extension", "拡張機能")
                ]
            )

            HierarchyArrow()

            SettingsScreenMock(
                title: "拡張機能",
                highlightedTitle: "Recipista",
                highlightedSymbol: "basket.fill",
                rows: [
                    ("basket.fill", "Recipista")
                ],
                trailing: "オン"
            )
        }
    }
}

private struct SettingsScreenMock: View {
    let title: String
    let highlightedTitle: String
    let highlightedSymbol: String
    let rows: [(String, String)]
    var trailing: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SettingsPathRow(
                        symbol: row.0,
                        title: row.1,
                        detail: row.1 == highlightedTitle ? trailing : "",
                        isHighlighted: row.1 == highlightedTitle
                    )
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(Color.recipistaSecondaryPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct HierarchyArrow: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.recipistaLine)
                .frame(height: 1)

            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.recipistaGreen)

            Rectangle()
                .fill(Color.recipistaLine)
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
    }
}

private struct SettingsPathRow: View {
    let symbol: String
    let title: String
    let detail: String
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.recipistaGreen)
                .frame(width: 24)

            Text(title)
                .font(.callout.weight(.semibold))

            Spacer()

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.recipistaGreen)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(isHighlighted ? Color.recipistaGreen.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct StepRow: View {
    let number: String
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.recipistaGreen, in: Circle())

            Text(title)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SafariExtensionSetupGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SafariSettingsMock()

                    VStack(alignment: .leading, spacing: 12) {
                        GuideStep(title: "1. 設定アプリを開く", detail: "ホーム画面から設定アプリを開きます。")
                        GuideStep(title: "2. アプリを選ぶ", detail: "設定内の「アプリ」を開きます。")
                        GuideStep(title: "3. Safariを選ぶ", detail: "アプリ一覧からSafariを開きます。")
                        GuideStep(title: "4. 拡張機能を開く", detail: "Safariの設定内にある拡張機能を選びます。")
                        GuideStep(title: "5. Recipistaをオン", detail: "Recipistaを有効にすると、Safariでレシピを保存できます。")
                    }
                }
                .padding(20)
            }
            .background(Color.recipistaBackground)
            .navigationTitle("設定手順")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .foregroundStyle(Color.recipistaGreen)
                }
            }
        }
    }
}

private struct GuideStep: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.recipistaGreen)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension Color {
    static let recipistaGreen = Color(red: 0.125, green: 0.353, blue: 0.243)
    static let recipistaBackground = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.055, green: 0.071, blue: 0.061, alpha: 1)
                : UIColor(red: 0.984, green: 0.980, blue: 0.969, alpha: 1)
        }
    )
    static let recipistaPanel = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.095, green: 0.110, blue: 0.098, alpha: 1)
                : UIColor.white
        }
    )
    static let recipistaLine = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.215, green: 0.250, blue: 0.225, alpha: 1)
                : UIColor(red: 0.902, green: 0.875, blue: 0.831, alpha: 1)
        }
    )
    static let recipistaSecondaryPanel = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.125, green: 0.145, blue: 0.130, alpha: 1)
                : UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1)
        }
    )
}

#Preview {
    ContentView()
}
