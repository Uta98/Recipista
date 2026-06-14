function normalizeWhitespace(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function collapseRepeatedHalf(value) {
  const text = normalizeWhitespace(value);
  const compact = text.replace(/\s/g, "");
  if (compact.length > 0 && compact.length % 2 === 0) {
    const half = compact.length / 2;
    const first = compact.slice(0, half);
    if (first === compact.slice(half)) return first;
  }

  const spaced = text.match(/^(.{2,80})\s+\1$/);
  return spaced ? spaced[1] : text;
}

function collapseRepeatedIngredientName(value) {
  const marker = value.match(/(\d|大さじ|小さじ|少々|適量|お好みで|ひとつまみ)/);
  if (!marker || marker.index <= 1) return value;

  const name = value.slice(0, marker.index);
  const rest = value.slice(marker.index);
  const compactName = name.replace(/\s/g, "");

  if (compactName.length > 0 && compactName.length % 2 === 0) {
    const half = compactName.length / 2;
    const first = compactName.slice(0, half);
    if (first === compactName.slice(half)) return `${first}${rest}`;
  }

  const spacedName = normalizeWhitespace(name).match(/^(.+?)\s+\1$/);
  if (spacedName) return `${spacedName[1]}${rest}`;

  return value;
}

function normalizeIngredientLine(value) {
  let text = collapseRepeatedHalf(value)
    .replace(/[〜～]/g, "~")
    .replace(/\s*~\s*/g, "~")
    .replace(/\s*([()（）])\s*/g, "$1");

  text = collapseRepeatedIngredientName(text);
  text = text.replace(/^(.+?\d[^)]*(?:\([^)]*\))?)\s+\1$/, "$1");
  text = text
    .replace(/[（(]\s*[）)]\s*(\d+(?:\.\d+)?\s*(?:g|kg|ml|cc|個|本|枚|株|束|袋|カップ))/gi, "($1)")
    .replace(/[（(]\s*[）)]/g, "")
    .replace(/([（(][^）)]*)[）)]\s+(\d+(?:\.\d+)?\s*(?:g|kg|ml|cc|個|本|枚|株|束|袋|カップ))/gi, "$1 $2)")
    .replace(/\s+([）)])/g, "$1")
    .replace(/([（(])\s+/g, "$1")
    .replace(/\s{2,}/g, " ")
    .trim();
  text = collapseRepeatedHalf(text);

  return text;
}

function uniqueIngredientLines(lines) {
  const seen = new Set();
  const values = [];

  for (const line of lines.map(normalizeIngredientLine).filter(Boolean)) {
    const key = line.replace(/\s/g, "");
    if (seen.has(key)) continue;
    seen.add(key);
    values.push(line);
  }

  return values;
}

function asArray(value) {
  if (!value) return [];
  return Array.isArray(value) ? value : [value];
}

function absoluteUrl(value) {
  const text = normalizeWhitespace(value);
  if (!text) return "";

  try {
    return new URL(text, location.href).href;
  } catch (error) {
    return "";
  }
}

function flattenJsonLd(node) {
  if (!node) return [];
  if (Array.isArray(node)) return node.flatMap(flattenJsonLd);

  const values = [node];
  if (Array.isArray(node["@graph"])) {
    values.push(...node["@graph"].flatMap(flattenJsonLd));
  }

  return values;
}

function getTypeNames(node) {
  return asArray(node && node["@type"]).map((type) => String(type).toLowerCase());
}

function findJsonLdRecipe() {
  const scripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));

  for (const script of scripts) {
    try {
      const nodes = flattenJsonLd(JSON.parse(script.textContent || ""));
      const recipe = nodes.find((node) => getTypeNames(node).includes("recipe"));
      if (recipe) return recipe;
    } catch (error) {
      // Ignore invalid JSON-LD blocks from the host page.
    }
  }

  return null;
}

function hasRecipeMicrodata() {
  return Boolean(document.querySelector('[itemtype*="schema.org/Recipe"], [itemtype*="Recipe"], [typeof*="Recipe"], [itemprop="recipeIngredient"]'));
}

function pageLooksLikeRecipe() {
  const recipeSignals = [
    document.querySelector('meta[property="og:type"]')?.content || "",
    document.querySelector('meta[property="og:title"]')?.content || "",
    document.title || "",
    location.pathname || "",
    document.body?.innerText.slice(0, 3000) || ""
  ].join(" ");

  return /(recipe|recipes|レシピ|作り方|材料|分量|何人分|cookpad|delishkitchen|クラシル|kurashiru|楽天レシピ)/i.test(recipeSignals);
}

function instructionText(instruction) {
  if (typeof instruction === "string") return instruction;
  if (instruction && typeof instruction.text === "string") return instruction.text;
  if (instruction && Array.isArray(instruction.itemListElement)) {
    return instruction.itemListElement.map(instructionText).filter(Boolean).join("\n");
  }
  return "";
}

function firstTextSelector(selectors) {
  for (const selector of selectors) {
    const element = document.querySelector(selector);
    const text = normalizeWhitespace(element && element.textContent);
    if (text) return text;
  }
  return "";
}

function collectTextFromSelectors(selectors) {
  const seen = new Set();
  const values = [];

  for (const selector of selectors) {
    for (const element of document.querySelectorAll(selector)) {
      const text = normalizeIngredientLine(element.textContent);
      if (text && text.length <= 120 && !seen.has(text)) {
        seen.add(text);
        values.push(text);
      }
    }
  }

  return values;
}

function firstImageUrl() {
  const selectors = [
    'meta[property="og:image"]',
    'meta[property="og:image:secure_url"]',
    'meta[name="twitter:image"]',
    'link[rel="image_src"]'
  ];

  for (const selector of selectors) {
    const element = document.querySelector(selector);
    const value = element?.content || element?.href;
    const url = absoluteUrl(value);
    if (url) return url;
  }

  for (const image of document.querySelectorAll("img")) {
    const url = absoluteUrl(image.currentSrc || image.src || image.getAttribute("data-src"));
    const width = image.naturalWidth || image.width;
    const height = image.naturalHeight || image.height;
    if (url && width >= 120 && height >= 80) return url;
  }

  return "";
}

function jsonLdImageUrl(value) {
  const image = asArray(value)[0];
  if (typeof image === "string") return absoluteUrl(image);
  if (image && typeof image.url === "string") return absoluteUrl(image.url);
  if (image && typeof image.contentUrl === "string") return absoluteUrl(image.contentUrl);
  return "";
}

function extractRecipeFromJsonLd(recipe) {
  const imageUrl = jsonLdImageUrl(recipe.image) || firstImageUrl();

  return {
    name: normalizeWhitespace(recipe.name) || document.title,
    sourceUrl: location.href,
    siteName: normalizeWhitespace(document.querySelector('meta[property="og:site_name"]')?.content) || location.hostname,
    imageUrl,
    yieldText: normalizeWhitespace(recipe.recipeYield),
    totalTime: normalizeWhitespace(recipe.totalTime),
    ingredients: asArray(recipe.recipeIngredient).map(normalizeIngredientLine).filter(Boolean),
    instructions: asArray(recipe.recipeInstructions).map(instructionText).map(normalizeWhitespace).filter(Boolean),
    extractedAt: new Date().toISOString(),
    extractionMethod: "json-ld"
  };
}

function extractRecipeHeuristically() {
  const title = firstTextSelector([
    "h1",
    '[class*="recipe-title" i]',
    '[class*="recipe_title" i]',
    '[class*="title" i]'
  ]) || normalizeWhitespace(document.title.replace(/\s*[|-].*$/, ""));

  const selectors = hasRecipeMicrodata()
    ? ['[itemprop="recipeIngredient"]']
    : [
    '[itemprop="recipeIngredient"]',
    '[class*="ingredient" i] li',
    '[class*="ingredients" i] li',
    '[class*="material" i] li',
    '[class*="zairyo" i] li',
    '[class*="材料" i] li'
  ];

  const ingredients = collectTextFromSelectors(selectors).filter((line) => {
    const hasFoodAmount = /(\d|大さじ|小さじ|少々|適量|g|kg|ml|cc|個|本|枚|束|袋|缶|カップ)/i.test(line);
    const looksLikeNav = /(ログイン|会員|広告|コメント|レビュー|ランキング|カテゴリ|保存|シェア)/.test(line);
    return hasFoodAmount && !looksLikeNav;
  }).slice(0, 80);

  return {
    name: title || "名称未取得のレシピ",
    sourceUrl: location.href,
    siteName: normalizeWhitespace(document.querySelector('meta[property="og:site_name"]')?.content) || location.hostname,
    imageUrl: firstImageUrl(),
    yieldText: firstTextSelector(['[class*="yield" i]', '[class*="serving" i]', '[class*="人数" i]']),
    totalTime: firstTextSelector(['[class*="time" i]', "time"]),
    ingredients,
    instructions: collectTextFromSelectors([
      '[itemprop="recipeInstructions"]',
      '[class*="instruction" i] li',
      '[class*="steps" i] li',
      '[class*="作り方" i] li'
    ]).slice(0, 40),
    extractedAt: new Date().toISOString(),
    extractionMethod: "heuristic"
  };
}

function extractRecipe() {
  const jsonLdRecipe = findJsonLdRecipe();
  if (!jsonLdRecipe && !hasRecipeMicrodata() && !pageLooksLikeRecipe()) {
    return {
      name: "",
      sourceUrl: location.href,
      siteName: normalizeWhitespace(document.querySelector('meta[property="og:site_name"]')?.content) || location.hostname,
      imageUrl: "",
      yieldText: "",
      totalTime: "",
      ingredients: [],
      instructions: [],
      extractedAt: new Date().toISOString(),
      extractionMethod: "not-recipe",
      notRecipe: true
    };
  }

  const recipe = jsonLdRecipe ? extractRecipeFromJsonLd(jsonLdRecipe) : extractRecipeHeuristically();
  recipe.ingredients = uniqueIngredientLines(recipe.ingredients);
  recipe.instructions = recipe.instructions.map(normalizeWhitespace).filter(Boolean);
  if (!jsonLdRecipe && !hasRecipeMicrodata() && recipe.ingredients.length < 2) {
    recipe.ingredients = [];
    recipe.notRecipe = true;
    recipe.extractionMethod = "not-recipe";
  }
  return recipe;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "RECIPISTA_EXTRACT_RECIPE") {
    sendResponse({ ok: true, recipe: extractRecipe() });
  }
});
