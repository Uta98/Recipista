# Recipista iPhone App + Safari Web Extension

Recipista is an iPhone app with a Safari Web Extension for saving recipe pages and turning selected saved recipes into a combined shopping checklist.

## What It Does

- Saves the recipe currently open in Safari.
- Stores saved recipes inside the extension using local extension storage.
- Lets the user select saved recipes for the next shopping trip.
- Combines the ingredients from selected recipes by ingredient name and unit.
- Shows the combined shopping list as a to-do list so items can be checked off while shopping.

## Project Structure

```text
RecipeSaverSafariApp.xcodeproj
RecipeSaverSafariApp/
  Recipista/
    RecipistaApp.swift
    ContentView.swift
    Info.plist
  Extension/
    Info.plist
    SafariWebExtensionHandler.swift
    manifest.json
    background.js
    content.js
    popup.html
    popup.css
    popup.js
    icons/
      icon.svg
sample-recipe.html
```

## Open In Xcode

Open `RecipeSaverSafariApp.xcodeproj` in Xcode and select the `Recipista` scheme. The project is configured for iPhone only.

The app target embeds the `RecipistaExtension` Safari Web Extension target.

## Try It In A Browser

The extension is still written as a standard Manifest V3 Web Extension. For quick popup development, load `RecipeSaverSafariApp/Extension` as an unpacked extension in Chrome or another Chromium browser.

## Use It In Safari

1. Open `RecipeSaverSafariApp.xcodeproj` in Xcode.
2. Choose an iPhone simulator or device.
3. Build and run the `Recipista` app.
4. Enable the extension in Safari Settings > Extensions.

Safari requires an app wrapper, so the iPhone app target exists mainly to package and explain the extension.

## Notes

Recipe extraction is best on sites that publish structured recipe data using JSON-LD. For sites without structured data, Recipista tries to detect a recipe title and ingredient lines from the page content.
