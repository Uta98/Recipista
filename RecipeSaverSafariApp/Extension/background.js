chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(["recipista.recipes", "recipista.selectedRecipeIds", "recipista.shoppingDone"], (items) => {
    const defaults = {};

    if (!Array.isArray(items["recipista.recipes"])) {
      defaults["recipista.recipes"] = [];
    }

    if (!Array.isArray(items["recipista.selectedRecipeIds"])) {
      defaults["recipista.selectedRecipeIds"] = [];
    }

    if (!items["recipista.shoppingDone"] || typeof items["recipista.shoppingDone"] !== "object") {
      defaults["recipista.shoppingDone"] = {};
    }

    if (Object.keys(defaults).length > 0) {
      chrome.storage.local.set(defaults);
    }
  });
});
