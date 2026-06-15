const storageKeys = {
  recipes: "recipista.recipes",
  selectedRecipeIds: "recipista.selectedRecipeIds",
  shoppingDone: "recipista.shoppingDone",
  preferences: "recipista.preferences"
};

const nativeAppIds = ["com.recipista.ios", "com.recipista.ios.Extension"];
const adUnitIds = {
  extensionNative: "ca-app-pub-2083362073572230/1387508942"
};

const showShoppingListInExtension = false;

const baseUnits = [
  "大さじ", "小さじ", "カップ", "パック", "切れ", "ふさ", "つまみ", "少々",
  "kg", "g", "ml", "l", "cc", "個", "本", "枚", "束", "袋", "缶", "合", "尾", "粒", "株"
];

const defaultQuantityTerms = ["適量", "適宜", "少々", "お好みで", "ひとつまみ"];

const categoryRules = [
  {
    name: "肉・魚",
    pattern: /(牛|豚|鶏|肉|ひき肉|挽き肉|ベーコン|ハム|ソーセージ|鮭|魚|えび|海老|いか|たこ|ツナ|さば|鯖)/
  },
  {
    name: "野菜",
    pattern: /(じゃがいも|ジャガイモ|玉ねぎ|玉葱|たまねぎ|にんじん|人参|キャベツ|白菜|ねぎ|長ねぎ|トマト|きゅうり|なす|ピーマン|大根|きのこ|しめじ|えのき|しいたけ|椎茸|もやし|レタス|ごぼう|かぼちゃ|ブロッコリー|にら|ほうれん草|小松菜)/
  },
  {
    name: "卵・乳製品",
    pattern: /(卵|たまご|玉子|牛乳|チーズ|バター|ヨーグルト|生クリーム)/
  },
  {
    name: "調味料",
    pattern: /(水|しょうゆ|醤油|みそ|味噌|砂糖|塩|こしょう|胡椒|みりん|酒|酢|油|ごま油|オリーブオイル|だし|ソース|ケチャップ|マヨネーズ|コンソメ|鶏ガラ|カレー粉)/
  }
];

const defaultCategoryOrder = ["肉・魚", "野菜", "卵・乳製品", "調味料", "その他"];
let categoryOrder = [...defaultCategoryOrder];

let state = {
  currentRecipe: null,
  currentRecipeLoaded: false,
  registrationDismissed: false,
  registrationSaved: false,
  editingCurrentRecipe: false,
  editingShoppingList: false,
  recipesExpanded: false,
  activeTab: "shopping",
  recipes: [],
  selectedRecipeIds: [],
  shoppingDone: {},
  preferences: {
    unitDisplay: "spoons",
    categoryOverrides: {},
    quantityTerms: defaultQuantityTerms,
    categories: defaultCategoryOrder
  }
};

const sampleRecipe = {
  name: "鮭ときのこの炊き込みご飯",
  sourceUrl: "sample-recipe.html",
  siteName: "サンプルレシピ",
  imageUrl: "",
  yieldText: "2人分",
  totalTime: "PT35M",
  ingredients: ["米 2合", "鮭 2切れ", "しめじ 1パック", "しょうゆ 大さじ2", "みりん 大さじ1", "水 適量"],
  instructions: [],
  extractedAt: new Date().toISOString(),
  extractionMethod: "preview"
};

const api = getExtensionApi();

function sendNativeStorageMessage(message) {
  if (!api.runtime || typeof api.runtime.sendNativeMessage !== "function") {
    return Promise.resolve(null);
  }

  const attempts = [
    ...nativeAppIds.map((appId) => [appId, message]),
    [message]
  ];

  return attempts.reduce(
    (previous, args) => previous.then((response) => response || tryNativeStorageMessage(args)),
    Promise.resolve(null)
  );
}

function tryNativeStorageMessage(args) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (response) => {
      if (settled) return;
      settled = true;
      const runtimeError = api.runtime && api.runtime.lastError;
      resolve(runtimeError ? null : response);
    };

    try {
      const result = api.runtime.sendNativeMessage(...args, finish);
      if (result && typeof result.then === "function") {
        result.then(finish).catch(() => finish(null));
      }
      setTimeout(() => finish(null), 800);
    } catch (error) {
      try {
        const result = api.runtime.sendNativeMessage(...args);
        if (result && typeof result.then === "function") {
          result.then(finish).catch(() => finish(null));
        } else {
          finish(result || null);
        }
      } catch (promiseError) {
        finish(null);
      }
    }
  });
}

function getExtensionApi() {
  if (typeof browser !== "undefined" && browser.storage && browser.tabs) return browser;
  if (typeof chrome !== "undefined" && chrome.storage && chrome.tabs) return chrome;

  return {
    storage: {
      local: {
        get(defaults, callback) {
          const values = { ...defaults };
          for (const key of Object.keys(defaults)) {
            const storedValue = localStorage.getItem(key);
            if (storedValue) values[key] = JSON.parse(storedValue);
          }
          callback(values);
        },
        set(values, callback) {
          for (const [key, value] of Object.entries(values)) {
            localStorage.setItem(key, JSON.stringify(value));
          }
          callback();
        }
      }
    },
    tabs: {
      query(options, callback) {
        callback([{ id: 1, url: location.href }]);
      },
      sendMessage(tabId, message, callback) {
        callback({ ok: true, recipe: sampleRecipe });
      }
    },
    runtime: {}
  };
}

async function storageGet(defaults) {
  const nativeResponse = await sendNativeStorageMessage({ command: "get", defaults });
  if (nativeResponse && nativeResponse.ok && nativeResponse.values) {
    return nativeResponse.values;
  }

  return new Promise((resolve) => {
    const result = api.storage.local.get(defaults, resolve);
    if (result && typeof result.then === "function") {
      result.then(resolve);
    }
  });
}

async function storageSet(values) {
  const nativeResponse = await sendNativeStorageMessage({ command: "set", values });
  if (nativeResponse && nativeResponse.ok) return;

  return new Promise((resolve) => {
    const result = api.storage.local.set(values, resolve);
    if (result && typeof result.then === "function") {
      result.then(resolve);
    }
  });
}

function base64UrlEncode(value) {
  return btoa(unescape(encodeURIComponent(value)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

async function storageRemove(keys) {
  const nativeResponse = await sendNativeStorageMessage({ command: "remove", keys });
  if (nativeResponse && nativeResponse.ok) return;

  return new Promise((resolve) => {
    if (!api.storage.local.remove) {
      resolve();
      return;
    }

    const result = api.storage.local.remove(keys, resolve);
    if (result && typeof result.then === "function") {
      result.then(resolve);
    }
  });
}

function queryActiveTab() {
  return new Promise((resolve) => {
    api.tabs.query({ active: true, currentWindow: true }, (tabs) => resolve(tabs[0]));
  });
}

function sendMessageToTab(tabId, message) {
  return new Promise((resolve) => {
    api.tabs.sendMessage(tabId, message, (response) => {
      const runtimeError = api.runtime && api.runtime.lastError;
      if (runtimeError) {
        resolve({ ok: false, error: runtimeError.message });
        return;
      }
      resolve(response || { ok: false });
    });
  });
}

function normalizeText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function normalizeDigits(value) {
  return String(value || "")
    .replace(/[一二三四五六七八九十百]+/g, (match) => {
      const converted = kanjiNumber(match);
      return converted === null ? match : String(converted);
    })
    .replace(/[０-９．／]/g, (char) => {
    if (char === "．") return ".";
    if (char === "／") return "/";
    return String.fromCharCode(char.charCodeAt(0) - 0xfee0);
  });
}

function kanjiNumber(value) {
  const digits = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const text = String(value || "");
  if (!/^[一二三四五六七八九十百]+$/.test(text)) return null;

  let total = 0;
  let current = 0;
  for (const char of text) {
    if (char === "百") {
      total += (current || 1) * 100;
      current = 0;
    } else if (char === "十") {
      total += (current || 1) * 10;
      current = 0;
    } else {
      current = digits[char] || 0;
    }
  }

  return total + current;
}

function normalizeFractionUnitOrder(value) {
  return normalizeText(value)
    .replace(/(\d+)\/(\d+)\s*(大さじ|小さじ)\s*\1\b/g, "$3$1/$2")
    .replace(/(^|\s)\/(\d+)\s*(大さじ|小さじ)\s*(\d+)\b/g, "$1$3$4/$2");
}

function recipeId(recipe) {
  return btoa(unescape(encodeURIComponent(`${recipe.sourceUrl}|${recipe.name}`))).replace(/[=/+]/g, "");
}

function ingredientKeyName(name) {
  return normalizeText(name)
    .replace(/[（）()]/g, "")
    .replace(/[：:、,。]/g, "")
    .toLowerCase();
}

function parseAmount(value) {
  const normalized = normalizeText(value).replace(/½/g, "1/2").replace(/⅓/g, "1/3").replace(/⅔/g, "2/3");
  const mixed = normalized.match(/^(\d+(?:\.\d+)?)\s*(?:と|\+)?\s*(\d+)\/(\d+)$/);
  if (mixed) return Number(mixed[1]) + Number(mixed[2]) / Number(mixed[3]);

  const fraction = normalized.match(/^(\d+)\/(\d+)$/);
  if (fraction) return Number(fraction[1]) / Number(fraction[2]);

  const number = Number(normalized);
  return Number.isNaN(number) ? null : number;
}

function amountWordFromLine(line) {
  return quantityTerms().find((word) => line.includes(word)) || "";
}

function amountNoteFromRest(rest, baseNote = "") {
  const text = normalizeText(rest);
  const amountLike = /^[（(]?\d+(?:\.\d+)?\s*(?:g|kg|ml|l|cc|個|本|枚|株|束|袋|カップ)[）)]?$/.test(text);
  return [baseNote, amountLike ? text : ""].filter(Boolean).join(" ");
}

function restForIngredientName(rest) {
  const text = normalizeText(rest);
  return /^[（(]?\d+(?:\.\d+)?\s*(?:g|kg|ml|l|cc|個|本|枚|株|束|袋|カップ)[）)]?$/.test(text) ? "" : text;
}

function categoryForIngredient(name) {
  const text = normalizeText(name);
  const override = state.preferences.categoryOverrides?.[ingredientKeyName(text)];
  if (override && categoryOrder.includes(override)) return override;
  const rule = categoryRules.find((item) => item.pattern.test(text));
  return rule ? rule.name : "その他";
}

function quantityTerms() {
  const stored = Array.isArray(state.preferences.quantityTerms) ? state.preferences.quantityTerms : [];
  return Array.from(new Set([...defaultQuantityTerms, ...stored].map(normalizeText).filter(Boolean)));
}

function allUnits() {
  return Array.from(new Set([...baseUnits, ...quantityTerms()]));
}

function escapedAlternation(values) {
  return values.map((value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
}

function splitIngredient(line) {
  const normalized = normalizeFractionUnitOrder(normalizeDigits(normalizeText(line)
    .replace(/[〜～]/g, "~")
    .replace(/\s*~\s*/g, "~")));
  const escapedUnits = escapedAlternation(allUnits());
  const amountPattern = "(\\d+\\/\\d+|\\d+(?:\\.\\d+)?(?:\\s*(?:と|\\+)?\\s*\\d+\\/\\d+)?)";
  const note = amountWordFromLine(normalized);
  const range = normalized.match(/^(.+?)\s*(\d+(?:\.\d+)?)~(\d+(?:\.\d+)?)(.*)$/);

  if (range) {
    return {
      name: ingredientKeyName(range[1]),
      displayName: normalizeText(range[1]),
      quantity: null,
      unit: "",
      note: `${range[2]}~${range[3]}${normalizeText(range[4])}`
    };
  }

  const amountThenUnit = new RegExp(`^(.+?)\\s*${amountPattern}\\s*(${escapedUnits})\\s*(.*)$`, "i");
  const unitThenAmount = new RegExp(`^(.+?)\\s*(${escapedUnits})\\s*${amountPattern}\\s*(.*)$`, "i");
  const leadingAmount = new RegExp(`^${amountPattern}\\s*(${escapedUnits})?\\s+(.+)$`, "i");

  let match = normalized.match(unitThenAmount);
  if (match) {
    const restName = restForIngredientName(match[4] || "");
    return {
      name: ingredientKeyName(`${match[1]} ${restName}`),
      displayName: normalizeText(`${match[1]} ${restName}`),
      quantity: parseAmount(match[3]),
      unit: match[2],
      note: amountNoteFromRest(match[4] || "", note)
    };
  }

  match = normalized.match(amountThenUnit);
  if (match) {
    const restName = restForIngredientName(match[4] || "");
    return {
      name: ingredientKeyName(`${match[1]} ${restName}`),
      displayName: normalizeText(`${match[1]} ${restName}`),
      quantity: parseAmount(match[2]),
      unit: match[3],
      note: amountNoteFromRest(match[4] || "", note)
    };
  }

  match = normalized.match(leadingAmount);
  if (match) {
    return {
      name: ingredientKeyName(match[3]),
      displayName: normalizeText(match[3]),
      quantity: parseAmount(match[1]),
      unit: match[2] || "",
      note
    };
  }

  return {
    name: ingredientKeyName(normalized.replace(new RegExp(`(${escapedAlternation(quantityTerms())})$`), "")),
    displayName: normalizeText(normalized.replace(new RegExp(`(${escapedAlternation(quantityTerms())})$`), "")),
    quantity: null,
    unit: "",
    note
  };
}

function aggregateIngredients(recipes) {
  const groups = new Map();

  for (const recipe of recipes) {
    const multiplier = normalizeMultiplier(recipe.multiplier);

    for (const [ingredientIndex, ingredient] of (recipe.ingredients || []).entries()) {
      const ingredientLine = typeof ingredient === "string"
        ? ingredient
        : normalizeText(`${ingredient.name || ""} ${ingredient.quantityText || ingredient.quantity || ""}`);
      const parsed = splitIngredient(ingredientLine);
      const key = parsed.name;
      if (!key) continue;

      const displayName = typeof ingredient === "object" && ingredient.name
        ? normalizeText(ingredient.name)
        : parsed.displayName || parsed.name;
      const category = typeof ingredient === "object" && categoryOrder.includes(ingredient.category)
        ? ingredient.category
        : categoryForIngredient(displayName);
      const existing = groups.get(key) || {
        key,
        name: displayName,
        category,
        quantities: new Map(),
        notes: new Set(),
        unknownAmounts: [],
        raw: [],
        recipes: new Map()
      };

      if (typeof parsed.quantity === "number" && !Number.isNaN(parsed.quantity)) {
        existing.quantities.set(parsed.unit, (existing.quantities.get(parsed.unit) || 0) + parsed.quantity * multiplier);
      } else if (parsed.note) {
        existing.notes.add(parsed.note);
      } else {
        existing.unknownAmounts.push(ingredientLine);
      }

      existing.raw.push(ingredientLine);
      existing.recipes.set(recipe.id || recipeId(recipe), {
        name: recipe.name,
        imageUrl: recipe.imageUrl || "",
        sourceUrl: recipe.sourceUrl || "",
        multiplier
      });
      if (!existing.sources) existing.sources = [];
      existing.sources.push({ recipeId: recipe.id || recipeId(recipe), ingredientIndex });
      groups.set(key, existing);
    }
  }

  return Array.from(groups.values()).sort((a, b) => {
    const categoryDiff = categoryOrder.indexOf(a.category) - categoryOrder.indexOf(b.category);
    return categoryDiff || a.name.localeCompare(b.name, "ja");
  });
}

function formatNumber(value) {
  const commonFractions = [
    [1 / 4, "1/4"],
    [1 / 3, "1/3"],
    [1 / 2, "1/2"],
    [2 / 3, "2/3"],
    [3 / 4, "3/4"]
  ];
  const whole = Math.floor(value);
  const fraction = value - whole;
  const fractionMatch = commonFractions.find(([amount]) => Math.abs(fraction - amount) < 0.001);
  if (fractionMatch) {
    return whole > 0 ? `${whole}と${fractionMatch[1]}` : fractionMatch[1];
  }

  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function normalizeMultiplier(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return 1;
  return Math.min(10, Math.max(0.1, number));
}

function recipeYieldPeople(value) {
  const normalized = normalizeDigits(normalizeText(value));
  const match = normalized.match(/(\d+(?:\.\d+)?)\s*(?:人|人分|servings?|名)/i);
  return match ? Number(match[1]) : null;
}

function recipePortionLabel(recipe, multiplier = normalizeMultiplier(recipe?.multiplier)) {
  const yieldText = normalizeText(recipe?.yieldText || "");
  if (!yieldText) return `×${formatNumber(multiplier)}`;
  const people = recipeYieldPeople(yieldText);
  if (people) return `${formatNumber(people * multiplier)}人分`;
  return multiplier === 1 ? yieldText : `${yieldText} ×${formatNumber(multiplier)}`;
}

function compactPortionLabel(recipe, multiplier = normalizeMultiplier(recipe?.multiplier)) {
  return recipePortionLabel(recipe, multiplier);
}

function portionMultiplierOptions(recipe) {
  const people = recipeYieldPeople(normalizeText(recipe?.yieldText || ""));
  if (people) {
    return Array.from({ length: 10 }, (_, index) => (index + 1) / people);
  }
  return Array.from({ length: 10 }, (_, index) => (index + 1) * 0.5);
}

function refreshPortionSelect(select, recipe, selectedValue) {
  if (!select || !recipe) return;
  const normalizedSelected = Number(selectedValue || recipe.multiplier || 1);
  select.innerHTML = "";
  for (const value of portionMultiplierOptions(recipe)) {
    const option = document.createElement("option");
    option.value = String(value);
    option.textContent = recipePortionLabel(recipe, value);
    select.append(option);
  }
  const closest = Array.from(select.options).reduce((best, option) => {
    const distance = Math.abs(Number(option.value) - normalizedSelected);
    return !best || distance < best.distance ? { value: option.value, distance } : best;
  }, null);
  if (closest) select.value = closest.value;
}

function formatQuantityPart(unit, quantity) {
  if (state.preferences.unitDisplay === "ml") {
    if (unit === "大さじ") {
      return `${formatNumber(quantity * 15)}ml`;
    }
    if (unit === "小さじ") {
      return `${formatNumber(quantity * 5)}ml`;
    }
  }

  const value = formatNumber(quantity);
  if (unit) {
    if (["大さじ", "小さじ"].includes(unit)) {
      return `${unit}${value}`;
    }
    return `${value}${unit}`;
  }
  return value;
}

function formatSpoonQuantities(quantities) {
  const tablespoon = quantities.get("大さじ") || 0;
  const teaspoon = quantities.get("小さじ") || 0;
  const milliliter = (quantities.get("ml") || 0) + (quantities.get("cc") || 0);
  if (tablespoon <= 0 && teaspoon <= 0 && milliliter <= 0) return [];

  const totalTeaspoon = tablespoon * 3 + teaspoon + (state.preferences.unitDisplay === "spoons" ? milliliter / 5 : 0);
  if (state.preferences.unitDisplay === "ml") {
    return [`${formatNumber(totalTeaspoon * 5 + milliliter)}ml`];
  }

  if (totalTeaspoon >= 3) {
    return [`大さじ${formatNumber(totalTeaspoon / 3)}`];
  }

  return [`小さじ${formatNumber(totalTeaspoon)}`];
}

function formatQuantity(item) {
  const spoonQuantities = formatSpoonQuantities(item.quantities);
  const quantities = Array.from(item.quantities.entries())
    .filter(([unit]) => !["大さじ", "小さじ", "ml", "cc"].includes(unit))
    .filter(([, quantity]) => quantity > 0)
    .map(([unit, quantity]) => formatQuantityPart(unit, quantity));

  const notes = Array.from(item.notes);
  const parentheticalNotes = notes.filter((note) => /^[（(]/.test(note));
  const plainNotes = notes.filter((note) => !/^[（(]/.test(note));
  const quantityParts = [...spoonQuantities, ...quantities];
  if (quantityParts.length > 0 && parentheticalNotes.length > 0) {
    quantityParts[quantityParts.length - 1] += parentheticalNotes.join("");
  }
  const parts = [...quantityParts, ...plainNotes];
  return parts.length > 0 ? parts.join(" + ") : "";
}

function shoppingItems() {
  const selectedRecipes = state.recipes.filter((recipe) => state.selectedRecipeIds.includes(recipe.id));
  return aggregateIngredients(selectedRecipes);
}

function currentRecipeId() {
  return state.currentRecipe ? recipeId(state.currentRecipe) : "";
}

function currentRecipeSaved() {
  const id = currentRecipeId();
  return Boolean(id && state.recipes.some((recipe) => recipe.id === id));
}

function savedCurrentRecipe() {
  const id = currentRecipeId();
  return id ? state.recipes.find((recipe) => recipe.id === id) || null : null;
}

function shouldShowCurrentPreview() {
  return Boolean(!state.registrationDismissed && currentRecipeHasIngredients());
}

function currentRecipeHasIngredients() {
  return Boolean(state.currentRecipe && Array.isArray(state.currentRecipe.ingredients) && state.currentRecipe.ingredients.length > 0);
}

function scaledIngredientForSave(ingredient, multiplier) {
  const line = typeof ingredient === "string"
    ? ingredient
    : normalizeText(`${ingredient.name || ""} ${ingredient.quantityText || ingredient.quantity || ""}`);
  const parsed = splitIngredient(line);
  if (typeof parsed.quantity !== "number" || Number.isNaN(parsed.quantity)) return ingredient;

  const quantityText = formatQuantityPart(parsed.unit, parsed.quantity * multiplier);
  if (typeof ingredient === "object") {
    return {
      ...ingredient,
      name: ingredient.name || parsed.displayName,
      quantityText,
      category: ingredient.category || categoryForIngredient(ingredient.name || parsed.displayName)
    };
  }
  return `${parsed.displayName} ${quantityText}`;
}

function scaledRecipeForSave(recipe, multiplier) {
  return {
    ...recipe,
    ingredients: (recipe.ingredients || []).map((ingredient) => scaledIngredientForSave(ingredient, multiplier)),
    multiplier: 1
  };
}

function shouldShowExtractionFailure() {
  return Boolean(!state.registrationDismissed && state.currentRecipeLoaded && !currentRecipeHasIngredients());
}

function visibleShoppingItems() {
  return shoppingItems();
}

function uncheckedShoppingItems() {
  return shoppingItems().filter((item) => !state.shoppingDone[item.key]);
}

function currentMultiplier() {
  return normalizeMultiplier(document.querySelector("#recipe-multiplier")?.value);
}

function editedRecipeDraft() {
  if (!state.currentRecipe) return null;

  const name = normalizeText(document.querySelector("#edit-recipe-name")?.value) || state.currentRecipe.name;
  const yieldText = normalizeText(document.querySelector("#edit-recipe-yield")?.value);
  const rows = Array.from(document.querySelectorAll(".edit-ingredient-row"));
  const ingredients = rows.map((row) => {
    const itemName = normalizeText(row.querySelector(".edit-ingredient-name")?.value);
    const quantityText = normalizeText(row.querySelector(".edit-ingredient-quantity")?.value);
    const category = row.querySelector(".edit-ingredient-category")?.value || categoryForIngredient(itemName);
    return itemName ? { name: itemName, quantityText, category } : null;
  }).filter(Boolean);

  return {
    ...state.currentRecipe,
    name,
    yieldText,
    ingredients
  };
}

function currentPreviewRecipe() {
  const saved = savedCurrentRecipe();
  if (state.editingCurrentRecipe) return editedRecipeDraft() || saved || state.currentRecipe;
  return saved || state.currentRecipe;
}

function editableIngredientFromLine(line) {
  if (typeof line === "object" && line) {
    return {
      name: normalizeText(line.name),
      quantityText: normalizeText(line.quantityText || line.quantity),
      category: categoryOrder.includes(line.category) ? line.category : categoryForIngredient(line.name)
    };
  }

  const parsed = splitIngredient(line);
  const quantityText = [
    typeof parsed.quantity === "number" ? formatQuantityPart(parsed.unit, parsed.quantity) : "",
    parsed.note || ""
  ].filter(Boolean).join(" ");

  return {
    name: parsed.displayName || normalizeText(line),
    quantityText,
    category: categoryForIngredient(parsed.displayName || line)
  };
}

function updateCategoryOverride(name, category) {
  const key = ingredientKeyName(name);
  if (!key || !categoryOrder.includes(category)) return;
  state.preferences.categoryOverrides = {
    ...(state.preferences.categoryOverrides || {}),
    [key]: category
  };
}

async function persistEditedCategory(name, category) {
  updateCategoryOverride(name, category);
  await persistState();
}

function renderEditFields(recipe, force = false) {
  const container = document.querySelector("#edit-ingredient-groups");
  if (!container || !recipe) return;
  if (!force && container.contains(document.activeElement)) return;

  const ingredients = (recipe.ingredients || []).map(editableIngredientFromLine).filter((item) => item.name);
  const grouped = categoryOrder.map((category) => [
    category,
    ingredients.filter((item) => item.category === category)
  ]);

  container.innerHTML = "";
  for (const [category, items] of grouped) {
    const group = document.createElement("section");
    group.className = "edit-category-group";
    group.dataset.category = category;

    const title = document.createElement("p");
    title.className = "edit-category-title";
    title.textContent = category;
    group.append(title);

    for (const item of items) {
      const row = document.createElement("div");
      row.className = "edit-ingredient-row";
      const ingredientIndex = ingredients.indexOf(item);
      row.dataset.ingredientIndex = String(ingredientIndex);

      const nameInput = document.createElement("input");
      nameInput.className = "edit-ingredient-name";
      nameInput.value = item.name;
      nameInput.placeholder = "材料名";

      const quantityInput = document.createElement("input");
      quantityInput.className = "edit-ingredient-quantity";
      quantityInput.value = item.quantityText;
      quantityInput.placeholder = "数量";

      const categorySelect = document.createElement("select");
      categorySelect.className = "edit-ingredient-category";
      for (const categoryName of categoryOrder) {
        const option = document.createElement("option");
        option.value = categoryName;
        option.textContent = categoryName;
        categorySelect.append(option);
      }
      categorySelect.value = item.category;
      categorySelect.addEventListener("change", async () => {
        const draft = editedRecipeDraft();
        const ingredient = draft.ingredients[ingredientIndex];
        if (ingredient) {
          ingredient.name = normalizeText(nameInput.value) || ingredient.name;
          ingredient.quantityText = normalizeText(quantityInput.value);
          ingredient.category = categorySelect.value;
        }
        await persistEditedCategory(nameInput.value, categorySelect.value);
        renderEditFields(draft, true);
        renderRegistrationSheet();
      });

      row.append(nameInput, quantityInput, categorySelect);
      group.append(row);
    }
    container.append(group);
  }
}

function shoppingShareText(items = uncheckedShoppingItems()) {
  const lines = [];

  for (const [category, categoryItems] of groupedShoppingItems(items)) {
    lines.push(`【${category}】`);
    lines.push(...categoryItems.map((item) => {
      const quantity = formatQuantity(item);
      return `☐ ${[item.name, quantity].filter(Boolean).join(" ")}`;
    }));
    lines.push("");
  }

  return ["Recipista 買い物リスト", "", ...lines].join("\n");
}

function groupedShoppingItems(items) {
  return categoryOrder
    .map((category) => [category, items.filter((item) => item.category === category)])
    .filter(([, categoryItems]) => categoryItems.length > 0);
}

function splitDoneItems(items, isPreview) {
  if (isPreview) return { activeItems: items, doneItems: [] };

  return {
    activeItems: items.filter((item) => !state.shoppingDone[item.key]),
    doneItems: items.filter((item) => state.shoppingDone[item.key])
  };
}

function recipeInitial(name) {
  return normalizeText(name).charAt(0) || "R";
}

function createThumbnail(recipe, sizeClass = "") {
  const thumb = document.createElement("span");
  thumb.className = `thumb ${sizeClass}`.trim();
  thumb.title = recipe.name || "";
  thumb.setAttribute("aria-label", recipe.name || "レシピ");

  if (recipe.imageUrl) {
    thumb.style.backgroundImage = `url("${recipe.imageUrl}")`;
  } else {
    thumb.textContent = recipeInitial(recipe.name);
  }

  return thumb;
}

async function loadState() {
  const items = await storageGet({
    [storageKeys.recipes]: [],
    [storageKeys.selectedRecipeIds]: [],
    [storageKeys.shoppingDone]: {},
    [storageKeys.preferences]: { unitDisplay: "spoons", categoryOverrides: {}, quantityTerms: defaultQuantityTerms, categories: defaultCategoryOrder }
  });

  state.recipes = items[storageKeys.recipes] || [];
  state.selectedRecipeIds = items[storageKeys.selectedRecipeIds] || [];
  state.shoppingDone = items[storageKeys.shoppingDone] || {};
  state.preferences = {
    unitDisplay: "spoons",
    categoryOverrides: {},
    quantityTerms: defaultQuantityTerms,
    categories: defaultCategoryOrder,
    ...(items[storageKeys.preferences] || {})
  };
  state.preferences.quantityTerms = quantityTerms();
  categoryOrder = Array.isArray(state.preferences.categories) && state.preferences.categories.length > 0
    ? [...state.preferences.categories]
    : [...defaultCategoryOrder];
}

async function loadCurrentRecipe() {
  const tab = await queryActiveTab();
  if (!tab || !tab.id || !/^https?:|^file:/.test(tab.url || "")) {
    updateCurrentRecipe(null);
    return;
  }

  const response = await sendMessageToTab(tab.id, { type: "RECIPISTA_EXTRACT_RECIPE" });
  updateCurrentRecipe(response && response.ok ? response.recipe : null);
}

function updateCurrentRecipe(recipe) {
  state.currentRecipe = recipe;
  state.currentRecipeLoaded = true;
  state.registrationDismissed = false;
  state.registrationSaved = false;
  state.editingCurrentRecipe = false;
  const name = document.querySelector("#current-recipe-name");
  const meta = document.querySelector("#current-recipe-meta");
  const image = document.querySelector("#current-recipe-image");
  const saveButton = document.querySelector("#save-current");

  if (!currentRecipeHasIngredients()) {
    name.textContent = "レシピを取得できません";
    meta.textContent = recipe?.notRecipe
      ? "レシピ用の構造化データを確認できませんでした。"
      : "材料情報を取得できませんでした。";
    image.hidden = true;
    saveButton.disabled = true;
    renderRegistrationSheet();
    return;
  }

  name.textContent = recipe.name || "名称未取得のレシピ";
  meta.textContent = [
    recipe.siteName || "レシピサイト",
    recipe.yieldText ? recipe.yieldText : "",
    `材料 ${recipe.ingredients.length}件`
  ].filter(Boolean).join(" ・ ");
  saveButton.disabled = false;

  if (recipe.imageUrl) {
    image.style.backgroundImage = `url("${recipe.imageUrl}")`;
    image.hidden = false;
  } else {
    image.hidden = true;
  }

  renderRegistrationSheet();
}

async function saveCurrentRecipe() {
  if (!currentRecipeHasIngredients()) return;

  const multiplier = normalizeMultiplier(document.querySelector("#recipe-multiplier").value);
  const baseRecipe = currentPreviewRecipe();
  const recipe = {
    ...baseRecipe,
    multiplier,
    id: recipeId(state.currentRecipe),
    savedAt: new Date().toISOString()
  };

  if (state.editingCurrentRecipe) {
    for (const ingredient of recipe.ingredients || []) {
      if (ingredient && typeof ingredient === "object") {
        updateCategoryOverride(ingredient.name, ingredient.category);
      }
    }
  }

  const existingIndex = state.recipes.findIndex((item) => item.id === recipe.id);
  if (existingIndex >= 0) {
    state.recipes.splice(existingIndex, 1, recipe);
  } else {
    state.recipes.unshift(recipe);
  }

  if (!state.selectedRecipeIds.includes(recipe.id)) {
    state.selectedRecipeIds.unshift(recipe.id);
  }

  await persistState();
  state.registrationDismissed = false;
  state.registrationSaved = true;
  state.editingCurrentRecipe = false;
  render();
  const toast = document.querySelector("#save-toast");
  if (toast) {
    toast.textContent = "Recipistaに登録しました";
    toast.hidden = false;
  }
  setTimeout(() => window.close(), 900);
}

function closeRegistrationSheet() {
  state.registrationDismissed = true;
  state.registrationSaved = false;
  state.editingCurrentRecipe = false;
  render();
}

function renderRegistrationSheet() {
  const sheet = document.querySelector("#registration-sheet");
  const previewList = document.querySelector("#preview-list");
  const previewEmpty = document.querySelector("#preview-empty");
  const template = document.querySelector("#shopping-row-template");
  const noResultActions = document.querySelector("#no-result-actions");
  const failureAd = document.querySelector("#failure-ad");
  const saveButton = document.querySelector("#save-current");
  const editButton = document.querySelector("#edit-current");
  const editFields = document.querySelector("#recipe-edit-fields");
  const editName = document.querySelector("#edit-recipe-name");
  const editYield = document.querySelector("#edit-recipe-yield");
  const savedNotice = document.querySelector("#current-recipe-saved");
  const multiplierControl = document.querySelector("#recipe-multiplier");
  const shouldShow = state.registrationSaved || shouldShowCurrentPreview() || shouldShowExtractionFailure();

  sheet.hidden = !shouldShow;
  if (!shouldShow) return;

  const isFailure = shouldShowExtractionFailure();
  const saved = currentRecipeSaved();
  const recipe = currentPreviewRecipe();
  const items = currentRecipeHasIngredients()
    ? aggregateIngredients([{ ...recipe, id: "current-recipe-preview", multiplier: currentMultiplier() }])
    : [];

  editButton.hidden = isFailure;
  editButton.textContent = state.editingCurrentRecipe ? "編集を閉じる" : "編集";
  editFields.hidden = !state.editingCurrentRecipe || isFailure;
  savedNotice.hidden = !(state.registrationSaved || saved) || state.editingCurrentRecipe || isFailure;
  savedNotice.textContent = state.registrationSaved ? "Recipistaに登録しました" : "このレシピはすでに保存済みです";
  if (state.registrationSaved) {
    previewList.innerHTML = "";
    previewList.hidden = true;
    previewEmpty.hidden = true;
    noResultActions.hidden = true;
    failureAd.hidden = true;
    editButton.hidden = true;
    editFields.hidden = true;
    saveButton.disabled = true;
    saveButton.textContent = "保存済み";
    return;
  }
  if (state.editingCurrentRecipe && recipe) {
    if (document.activeElement !== editName) editName.value = recipe.name || "";
    if (document.activeElement !== editYield) editYield.value = recipe.yieldText || "";
    renderEditFields(recipe);
  }

  previewList.innerHTML = "";
  previewList.hidden = state.editingCurrentRecipe;
  previewEmpty.hidden = items.length > 0 || state.editingCurrentRecipe;
  previewEmpty.textContent = isFailure
    ? "材料を取得できませんでした。手入力するか、別のレシピページで試してください。"
    : "抽出された材料はありません。";
  noResultActions.hidden = !isFailure;
  failureAd.hidden = !isFailure;
  saveButton.disabled = isFailure || items.length === 0 || state.registrationSaved;
  saveButton.textContent = saved ? "更新する" : "保存する";
  if (multiplierControl && recipe) {
    refreshPortionSelect(multiplierControl, recipe, currentMultiplier());
  }

  if (!isFailure && !state.editingCurrentRecipe) {
    renderShoppingGroup(previewList, template, items, true);
  }
}

async function persistState() {
  const values = {
    [storageKeys.recipes]: state.recipes,
    [storageKeys.selectedRecipeIds]: state.selectedRecipeIds,
    [storageKeys.shoppingDone]: state.shoppingDone,
    [storageKeys.preferences]: state.preferences
  };

  await storageRemove(Object.values(storageKeys));
  await storageSet(values);
}

function storageBytes() {
  const payload = JSON.stringify({
    [storageKeys.recipes]: state.recipes,
    [storageKeys.selectedRecipeIds]: state.selectedRecipeIds,
    [storageKeys.shoppingDone]: state.shoppingDone,
    [storageKeys.preferences]: state.preferences
  });

  if (typeof TextEncoder !== "undefined") {
    return new TextEncoder().encode(payload).length;
  }
  return unescape(encodeURIComponent(payload)).length;
}

function formatStorageSize(bytes) {
  const kb = bytes / 1024;
  return `${kb >= 10 ? Math.round(kb) : kb.toFixed(1)}KB`;
}

function renderSettings() {
  const unit = state.preferences.unitDisplay || "spoons";
  for (const input of document.querySelectorAll('input[name="unit-display"]')) {
    input.checked = input.value === unit;
  }
  const categoryCount = document.querySelector("#category-override-count");
  if (categoryCount) {
    categoryCount.textContent = `${Object.keys(state.preferences.categoryOverrides || {}).length}件`;
  }
  const quantityCount = document.querySelector("#quantity-term-count");
  if (quantityCount) {
    quantityCount.textContent = `${quantityTerms().length}件`;
  }

  const list = document.querySelector("#category-override-list");
  if (list) {
    list.innerHTML = "";
    const overrides = state.preferences.categoryOverrides || {};
    for (const key of Object.keys(overrides).sort()) {
      const row = document.createElement("div");
      row.className = "category-override-row";
      const name = document.createElement("span");
      name.textContent = key;
      const category = document.createElement("span");
      category.textContent = overrides[key];
      const remove = document.createElement("button");
      remove.className = "icon-button danger";
      remove.type = "button";
      remove.textContent = "×";
      remove.addEventListener("click", async () => {
        delete state.preferences.categoryOverrides[key];
        await persistState();
        render();
      });
      row.append(name, category, remove);
      list.append(row);
    }
  }

  const termList = document.querySelector("#quantity-term-list");
  if (termList) {
    termList.innerHTML = "";
    for (const term of quantityTerms()) {
      const row = document.createElement("div");
      row.className = "category-override-row";
      const name = document.createElement("span");
      name.textContent = term;
      const spacer = document.createElement("span");
      spacer.textContent = "数量";
      const remove = document.createElement("button");
      remove.className = "icon-button danger";
      remove.type = "button";
      remove.textContent = "×";
      remove.addEventListener("click", async () => {
        state.preferences.quantityTerms = quantityTerms().filter((item) => item !== term);
        await persistState();
        render();
      });
      row.append(name, spacer, remove);
      termList.append(row);
    }
  }
}

function renderRecipes() {
  const list = document.querySelector("#recipe-strip");
  const selectedList = document.querySelector("#selected-recipe-strip");
  const listPanel = document.querySelector("#recipe-list-panel");
  const toggleButton = document.querySelector("#toggle-recipes");
  const empty = document.querySelector("#recipe-empty");
  const template = document.querySelector("#recipe-chip-template");

  list.innerHTML = "";
  selectedList.innerHTML = "";
  empty.hidden = state.recipes.length > 0;
  document.querySelector("#clear-recipes").hidden = state.recipes.length === 0 || !state.recipesExpanded;
  listPanel.hidden = !state.recipesExpanded || state.recipes.length === 0;
  selectedList.hidden = state.recipesExpanded || state.recipes.length === 0;
  toggleButton.hidden = state.recipes.length === 0;
  toggleButton.textContent = "›";
  toggleButton.classList.toggle("open", state.recipesExpanded);
  toggleButton.title = state.recipesExpanded ? "保存レシピを閉じる" : "保存レシピを開く";
  toggleButton.setAttribute("aria-label", toggleButton.title);
  toggleButton.setAttribute("aria-expanded", String(state.recipesExpanded));

  const renderRecipeChip = (recipe, compact = false) => {
    const row = template.content.firstElementChild.cloneNode(true);
    row.classList.toggle("compact", compact);
    const thumb = row.querySelector(".recipe-thumb");
    const checkbox = row.querySelector("input");
    const title = row.querySelector(".recipe-pick span:last-child");
    const pick = row.querySelector(".recipe-pick");
    const link = row.querySelector("a");
    const multiplierSelect = row.querySelector(".recipe-multiplier");
    const deleteButton = row.querySelector("button");

    checkbox.checked = state.selectedRecipeIds.includes(recipe.id);
    checkbox.addEventListener("change", async () => {
      if (checkbox.checked) {
        state.selectedRecipeIds = Array.from(new Set([...state.selectedRecipeIds, recipe.id]));
      } else {
        state.selectedRecipeIds = state.selectedRecipeIds.filter((id) => id !== recipe.id);
      }
      await persistState();
      renderRecipes();
      renderShopping();
    });

    const multiplier = normalizeMultiplier(recipe.multiplier);
    title.textContent = recipe.name;
    link.href = recipe.sourceUrl || "#";
    link.textContent = recipe.siteName || recipe.sourceUrl || "レシピを開く";
    link.hidden = recipe.extractionMethod === "manual" || recipe.siteName === "手入力";
    refreshPortionSelect(multiplierSelect, recipe, multiplier);
    multiplierSelect.addEventListener("change", async () => {
      recipe.multiplier = normalizeMultiplier(multiplierSelect.value);
      await persistState();
      renderRecipes();
      renderShopping();
    });
    if (recipe.imageUrl) {
      thumb.style.backgroundImage = `url("${recipe.imageUrl}")`;
      thumb.textContent = "";
    } else {
      thumb.textContent = recipeInitial(recipe.name);
    }
    if (compact) {
      checkbox.disabled = true;
      deleteButton.textContent = "✓";
      deleteButton.title = "このレシピを使わない";
      deleteButton.setAttribute("aria-label", "このレシピを使わない");
    }
    deleteButton.addEventListener("click", async () => {
      if (compact) {
        state.selectedRecipeIds = state.selectedRecipeIds.filter((id) => id !== recipe.id);
        await persistState();
        renderRecipes();
        renderShopping();
        return;
      }

      state.recipes = state.recipes.filter((item) => item.id !== recipe.id);
      state.selectedRecipeIds = state.selectedRecipeIds.filter((id) => id !== recipe.id);
      if (currentRecipeId() === recipe.id) {
        state.registrationDismissed = true;
      }
      for (const key of Object.keys(state.shoppingDone)) {
        if (!shoppingItems().some((item) => item.key === key)) {
          delete state.shoppingDone[key];
        }
      }
      await persistState();
      render();
    });

    return row;
  };

  for (const recipe of state.recipes) {
    list.append(renderRecipeChip(recipe));
    if (state.selectedRecipeIds.includes(recipe.id)) {
      selectedList.append(renderRecipeChip(recipe, true));
    }
  }
}

function renderShopping() {
  const list = document.querySelector("#shopping-list");
  const empty = document.querySelector("#shopping-empty");
  const template = document.querySelector("#shopping-row-template");
  const title = document.querySelector("#shopping-title");
  const shareButton = document.querySelector("#share-notes");
  const clearButton = document.querySelector("#clear-done");
  const editButton = document.querySelector("#edit-shopping");
  const items = shoppingItems();
  const uncheckedItems = uncheckedShoppingItems();
  const { activeItems, doneItems } = splitDoneItems(items, false);

  if (!showShoppingListInExtension) {
    list.innerHTML = "";
    list.hidden = true;
    empty.hidden = true;
    shareButton.hidden = true;
    clearButton.hidden = true;
    editButton.hidden = true;
    return;
  }

  list.innerHTML = "";
  empty.hidden = items.length > 0;
  title.textContent = "買い物リスト";
  shareButton.hidden = uncheckedItems.length === 0;
  clearButton.hidden = items.length === 0;
  editButton.hidden = items.length === 0;
  editButton.textContent = state.editingShoppingList ? "✓" : "✎";
  editButton.classList.toggle("editing", state.editingShoppingList);
  editButton.title = state.editingShoppingList ? "編集を終了" : "材料をまとめて編集";
  editButton.setAttribute("aria-label", editButton.title);
  empty.textContent = "保存済みレシピにチェックを入れると材料がまとまります。";

  renderShoppingGroup(list, template, activeItems, false);

  if (items.length > 0) {
    appendShoppingAd(list);
  }

  if (doneItems.length > 0) {
    const heading = document.createElement("li");
    heading.className = "checked-heading";
    heading.textContent = "チェック済み";
    list.append(heading);
    renderShoppingGroup(list, template, doneItems, false);
  }

  updateTabState();
}

function appendShoppingAd(list) {
  const row = document.createElement("li");
  row.className = "ad-row";
  const slot = document.createElement("aside");
  slot.className = "ad-slot";
  slot.dataset.adUnitId = adUnitIds.extensionNative;
  const label = document.createElement("span");
  label.textContent = "広告";
  slot.append(label);
  row.append(slot);
  list.append(row);
}

function renderShoppingGroup(list, template, items, isPreview) {
  for (const [category, categoryItems] of groupedShoppingItems(items)) {
    const categoryRow = document.createElement("li");
    categoryRow.className = "category-row";
    categoryRow.append(document.createTextNode(category));
    if (!isPreview && category === "調味料" && categoryItems.some((item) => !state.shoppingDone[item.key])) {
      const checkAllButton = document.createElement("button");
      checkAllButton.className = "text-button";
      checkAllButton.type = "button";
      checkAllButton.textContent = "すべてチェック";
      checkAllButton.addEventListener("click", async () => {
        for (const item of categoryItems) {
          state.shoppingDone[item.key] = true;
        }
        await persistState();
        renderShopping();
      });
      categoryRow.append(checkAllButton);
    }
    list.append(categoryRow);

    for (const item of categoryItems) {
      if (!isPreview && state.editingShoppingList) {
        list.append(renderShoppingEditRow(item));
        continue;
      }

      const row = template.content.firstElementChild.cloneNode(true);
      const checkbox = row.querySelector("input");
      const itemName = row.querySelector(".item-name");
      const itemQuantity = row.querySelector(".item-quantity");
      const thumbs = row.querySelector(".recipe-thumbs");

      checkbox.checked = !isPreview && Boolean(state.shoppingDone[item.key]);
      checkbox.disabled = isPreview;
      row.classList.toggle("done", checkbox.checked);
      row.classList.toggle("preview", isPreview);
      itemName.textContent = item.name;
      itemQuantity.textContent = formatQuantity(item);
      thumbs.innerHTML = "";
      for (const recipe of Array.from(item.recipes.values()).slice(0, 6)) {
        thumbs.append(createThumbnail(recipe, "small"));
      }
      checkbox.addEventListener("change", async () => {
        if (isPreview) return;
        state.shoppingDone[item.key] = checkbox.checked;
        await persistState();
        renderShopping();
      });

      list.append(row);
    }
  }
}

function renderShoppingEditRow(item) {
  const row = document.createElement("li");
  row.className = "shopping-row shopping-edit-row";

  const nameInput = document.createElement("input");
  nameInput.className = "shopping-edit-name";
  nameInput.value = item.name;
  nameInput.placeholder = "材料名";

  const quantityInput = document.createElement("input");
  quantityInput.className = "shopping-edit-quantity";
  quantityInput.value = formatQuantity(item);
  quantityInput.placeholder = "数量";

  const categorySelect = document.createElement("select");
  categorySelect.className = "shopping-edit-category";
  for (const category of categoryOrder) {
    const option = document.createElement("option");
    option.value = category;
    option.textContent = category;
    option.selected = category === item.category;
    categorySelect.append(option);
  }

  let currentKey = item.key;
  const persistEdit = async () => {
    const next = {
      name: normalizeText(nameInput.value),
      quantityText: normalizeText(quantityInput.value),
      category: categorySelect.value
    };
    await updateShoppingIngredient(currentKey, next);
    currentKey = ingredientKeyName(next.name);
  };

  nameInput.addEventListener("change", persistEdit);
  quantityInput.addEventListener("change", persistEdit);
  categorySelect.addEventListener("change", persistEdit);

  row.append(nameInput, quantityInput, categorySelect);
  return row;
}

async function updateShoppingIngredient(oldKey, next) {
  if (!next.name) return;

  for (const recipe of state.recipes) {
    if (!state.selectedRecipeIds.includes(recipe.id)) continue;
    recipe.ingredients = (recipe.ingredients || []).map((ingredient) => {
      const line = typeof ingredient === "string"
        ? ingredient
        : normalizeText(`${ingredient.name || ""} ${ingredient.quantityText || ingredient.quantity || ""}`);
      const parsed = splitIngredient(line);
      if (parsed.name !== oldKey) return ingredient;
      updateCategoryOverride(next.name, next.category);
      return {
        name: next.name,
        quantityText: next.quantityText,
        category: next.category || categoryForIngredient(next.name)
      };
    });
  }

  const newKey = ingredientKeyName(next.name);
  if (state.shoppingDone[oldKey]) {
    delete state.shoppingDone[oldKey];
    state.shoppingDone[newKey] = true;
  }

  await persistState();
  render();
}

function render() {
  renderRecipes();
  renderShopping();
  renderRegistrationSheet();
  renderSettings();
  updateTabState();
}

function activateTab(tabName) {
  state.activeTab = tabName;

  document.querySelectorAll(".panel").forEach((panel) => {
    panel.classList.toggle("active", panel.id === `${tabName}-panel`);
  });
  document.querySelector("#manual-entry").hidden = tabName !== "shopping" || document.querySelector("#manual-entry").hidden;
  renderShopping();
  renderRegistrationSheet();
  renderSettings();
  updateTabState();
}

function updateTabState() {
  for (const tab of document.querySelectorAll(".tab")) {
    const isActive = tab.dataset.tab === state.activeTab;
    tab.classList.toggle("active", isActive);
    tab.classList.toggle("dimmed", false);
  }
}

function setupTabs() {
  activateTab("shopping");
}

async function setupActions() {
  document.querySelector("#save-current").addEventListener("click", saveCurrentRecipe);
  document.querySelector("#open-app").addEventListener("click", openAppWithShoppingList);
  document.querySelector("#open-manual").addEventListener("click", openManualEntry);
  document.querySelector("#open-manual-from-failure").addEventListener("click", openManualEntry);
  document.querySelector("#close-registration").addEventListener("click", closeRegistrationSheet);
  document.querySelector("#cancel-manual").addEventListener("click", closeManualEntry);
  document.querySelector("#save-manual").addEventListener("click", saveManualRecipe);
  document.querySelector("#share-notes").addEventListener("click", shareShoppingList);
  document.querySelector("#edit-shopping").addEventListener("click", () => {
    state.editingShoppingList = !state.editingShoppingList;
    renderShopping();
  });
  document.querySelector("#open-settings").addEventListener("click", () => activateTab("settings"));
  document.querySelector("#close-settings").addEventListener("click", () => activateTab("shopping"));
  document.querySelector("#open-category-settings").addEventListener("click", () => activateTab("category-settings"));
  document.querySelector("#close-category-settings").addEventListener("click", () => activateTab("settings"));
  document.querySelector("#open-quantity-settings").addEventListener("click", () => activateTab("quantity-settings"));
  document.querySelector("#close-quantity-settings").addEventListener("click", () => activateTab("settings"));
  document.querySelector("#toggle-recipes").addEventListener("click", () => {
    state.recipesExpanded = !state.recipesExpanded;
    renderRecipes();
  });
  for (const input of document.querySelectorAll('input[name="unit-display"]')) {
    input.addEventListener("change", async () => {
      state.preferences.unitDisplay = input.value;
      await persistState();
      renderShopping();
      renderRegistrationSheet();
      renderSettings();
    });
  }
  document.querySelector("#add-category-override").addEventListener("click", async () => {
    const nameInput = document.querySelector("#category-override-name");
    const categorySelect = document.querySelector("#category-override-category");
    const key = ingredientKeyName(nameInput.value);
    if (!key) {
      nameInput.focus();
      return;
    }
    state.preferences.categoryOverrides = {
      ...(state.preferences.categoryOverrides || {}),
      [key]: categorySelect.value
    };
    nameInput.value = "";
    await persistState();
    render();
  });
  document.querySelector("#add-quantity-term").addEventListener("click", async () => {
    const input = document.querySelector("#quantity-term-name");
    const term = normalizeText(input.value);
    if (!term) {
      input.focus();
      return;
    }
    state.preferences.quantityTerms = Array.from(new Set([...quantityTerms(), term])).sort((a, b) => a.localeCompare(b, "ja"));
    input.value = "";
    await persistState();
    render();
  });
  document.querySelector("#recipe-multiplier").addEventListener("change", () => {
    if (currentRecipeHasIngredients() && !currentRecipeSaved()) {
      state.registrationDismissed = false;
    }
    renderRegistrationSheet();
    updateTabState();
  });
  document.querySelector("#edit-current").addEventListener("click", () => {
    state.editingCurrentRecipe = !state.editingCurrentRecipe;
    if (state.editingCurrentRecipe) {
      const recipe = savedCurrentRecipe() || state.currentRecipe;
      document.querySelector("#edit-recipe-name").value = recipe?.name || "";
      document.querySelector("#edit-recipe-yield").value = recipe?.yieldText || "";
      renderEditFields(recipe);
    }
    renderRegistrationSheet();
  });
  document.querySelector("#clear-recipes").addEventListener("click", clearRecipes);
  document.querySelector("#clear-done").addEventListener("click", async () => {
    state.shoppingDone = {};
    await persistState();
    renderShopping();
  });
}

function openAppWithShoppingList() {
  const payload = {
    recipes: state.recipes,
    selectedRecipeIds: state.selectedRecipeIds,
    shoppingDone: state.shoppingDone
  };
  location.href = `recipista://shopping?data=${base64UrlEncode(JSON.stringify(payload))}`;
}

function openManualEntry() {
  state.registrationDismissed = true;
  activateTab("shopping");
  const panel = document.querySelector("#manual-entry");
  const nameInput = document.querySelector("#manual-recipe-name");
  panel.hidden = false;
  nameInput.focus();
}

function closeManualEntry() {
  document.querySelector("#manual-entry").hidden = true;
  document.querySelector("#manual-recipe-name").value = "";
  document.querySelector("#manual-ingredients").value = "";
}

async function saveManualRecipe() {
  const nameInput = document.querySelector("#manual-recipe-name");
  const ingredientsInput = document.querySelector("#manual-ingredients");
  const ingredients = ingredientsInput.value
    .split(/\n|、|,/)
    .map(normalizeText)
    .filter(Boolean);

  if (ingredients.length === 0) {
    ingredientsInput.focus();
    return;
  }

  const now = new Date().toISOString();
  const recipe = {
    name: normalizeText(nameInput.value) || "手入力レシピ",
    sourceUrl: `manual:${Date.now()}`,
    siteName: "手入力",
    imageUrl: "",
    yieldText: "",
    totalTime: "",
    ingredients,
    instructions: [],
    multiplier: 1,
    extractedAt: now,
    extractionMethod: "manual"
  };

  recipe.id = recipeId({ ...recipe, sourceUrl: `${recipe.sourceUrl}|${now}` });
  recipe.savedAt = now;
  state.recipes.unshift(recipe);
  state.selectedRecipeIds.unshift(recipe.id);
  state.registrationDismissed = true;

  await persistState();
  ingredientsInput.value = "";
  closeManualEntry();
  activateTab("shopping");
  render();
}

async function clearRecipes() {
  state.recipes = [];
  state.selectedRecipeIds = [];
  state.shoppingDone = {};
  await persistState();
  render();
}

async function shareShoppingList() {
  const text = shoppingShareText();
  const button = document.querySelector("#share-notes");
  const originalText = button.textContent;

  try {
    if (navigator.share) {
      await navigator.share({ title: "Recipista 買い物リスト", text });
      return;
    }

    await navigator.clipboard.writeText(text);
    button.textContent = "✓";
    setTimeout(() => {
      button.textContent = originalText;
    }, 1200);
  } catch (error) {
    if (error && error.name === "AbortError") return;
    button.textContent = "!";
    setTimeout(() => {
      button.textContent = originalText;
    }, 1200);
  }
}

async function boot() {
  setupTabs();
  await setupActions();
  await loadState();
  render();
  await loadCurrentRecipe();
}

boot();
