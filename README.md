# Trading Book

[Version française](README.fr.md)

World of Warcraft addon (Retail, 12.1.5) that keeps a record of your auctions and your stock, with statistics.

Status: first draft. The logic is tested outside the game, **but the addon has not yet run in the client**: see [Check in game](#check-in-game).

## Installation

```powershell
.\install.ps1
```

The script copies `TradingBook.toc` and the files it lists into `Interface\AddOns\TradingBook`, and nothing else: no tests, no README, no Git data. After changing the code, run it again, then `/reload` in game. If the list of files in the `.toc` changed, restart WoW, which only reads it at launch. It needs no administrator rights if your account can write to the WoW folder, which is the default.

| Option | Effect |
| --- | --- |
| `-Clean` | Also deletes Trading Book's saved data (history, stock, gold) on all accounts, including the `.bak` backup. This cannot be undone: you are asked to confirm, and WoW must be closed. |
| `-WowPath <folder>` | The WoW folder, the one containing `_retail_`, if it is not in the standard location. |
| `-WhatIf` | Shows what would be done, without changing anything. |

The installed folder is replaced every time, so keep nothing in it. Saved data lives elsewhere and only `-Clean` touches it. If an existing `TradingBook` folder did not come from this script (another addon, a link, a working copy), the script stops without touching it.

## Usage

`/tradingbook` opens the window, as do the minimap icon and the Trading Book entry in the addon menu. `/tradingbook auctions`, `stock`, `stats` and `gold` open a tab directly.

Drag the minimap icon to move it. `/tradingbook minimap` hides it or brings it back.

Item tooltips, wherever the game shows them (bags, bank, auction house, chat links), get a Trading Book section: the account's stock of that item by character and place, your average sale price over 90 days, and your last sale. Nothing is added for an item you neither hold nor ever sold, nor in Trading Book's own window, which already shows the same. `/tradingbook tooltip` hides the section or brings it back.

The settings are in the game's options, under AddOns > Trading Book. A right-click on the minimap icon or on the addon menu entry opens them, as does `/tradingbook settings`.

| Setting | Effect |
| --- | --- |
| **Minimap icon** | Shows or hides the icon, like `/tradingbook minimap`. |
| **Item tooltips** | Adds the Trading Book section to item tooltips or not, like `/tradingbook tooltip`. |
| **Custom window scale** | Gives the window a scale of its own, which replaces the game's UI scale: the window then keeps its size when the game's scale changes. Turned on, it starts from the game's current scale, so nothing moves yet. Turned off, the window follows the game's scale again. |
| **Window scale** | That scale, from 50% to 120% in steps of 5%, in the same percent as the game's UI scale. Greyed out while the window follows the game. The window stays centred on the same spot when it changes. |

| Tab | Content |
| --- | --- |
| **Auctions** | History of sales, purchases, listings, expiries and cancellations, plus your active auctions. |
| **Stock** | Tradable items, filtered by location (bags, personal bank, shared stock, mail, auction house), with the change over 7 days and an estimated value. |
| **Stats** | Profit, sales, purchases, fees, sell-through, stock value and gold, over 7, 30 or 90 days or all time, with the result per day and per item. |
| **Gold** | Gold curve, change, average per day, best and worst day, peak, the auctions' share of the gains, and the breakdown by holder. |

The data covers the whole account. The menu at the top right narrows the display to one character, including one you are not logged in on. "Shared stock" means the Warband bank: since it belongs to no one, its filter shows it whichever character is selected.

A gold change only counts what changed since Trading Book started following the holder: a character's first login is not a gain, and moving gold to the shared stock does not change the total. "Outside auctions" is the difference between the gold change and the auction result, so a sale not yet collected from the mail can temporarily shift that split.

Stock value comes from Auctionator if it is installed, otherwise from the average of your sales over 90 days. An item with no known price counts as zero.

## Languages

The addon follows the language of the client: English, French, German, Spanish (Spain and Mexico), Italian, Brazilian Portuguese, Russian, Korean, and Simplified and Traditional Chinese. The order of day and month in dates follows it too. The words of the `/tradingbook` command stay in English.

English strings are the keys and the fallback, and every other language has its file in `Locales/`. To add a string, write `L["Text in English"]` in the code and add its translation to all those files: the tests fail if one is missing or no longer used.

## How the data is collected

| Data | Source | When |
| --- | --- | --- |
| Listing | `PostItem` and `PostCommodity` calls | Confirmed by `AUCTION_HOUSE_AUCTION_CREATED` |
| Cancellation | `CancelAuction` call | Confirmed by `AUCTION_CANCELED` |
| Sale, purchase, expiry | Auction house mail and its invoice | When the mail is collected |
| Active auctions | `GetOwnedAuctions` | When the auction house opens |
| Stock | Bags, bank, Warband bank, mail | On every change; banks only while open |

Net profit = sales - purchases - fees, where fees = cut + unrefunded deposits + cancellation costs. This follows the money actually received and spent: the deposit paid when listing comes back with the sale's payment.

## Known limitations

- A sale only appears once its mail is collected. It is still dated from the mail's remaining time, so the per-day statistics stay correct.
- The bank and the Warband bank show their content as of your last visit.
- Stock in the mail only sees the first 50 messages loaded by the client.
- Items are grouped by ID: variants of one item (item level) and caged pets are merged.
- After an interrupted multi-post, the listed quantity stays the one first requested.
- The cost of crafting an item is not known: profit only counts auction house purchases.
- The icon follows a circle around the minimap: on a square minimap (ElvUI, for example), it does not reach the corners.

## Check in game

The fake client used by the tests draws nothing and reflects my reading of the API. These points remain to be confirmed:

1. **Interface**: window and portrait, tabs, character menu, columns, scrolling, charts, minimap icon (appearance, dragging, position kept after relogging). The tests check the margins, but with an estimated text width.
2. **Settings**: the page appears under AddOns, opens from a right-click on the icon and on the addon menu entry, greys out the scale slider while the custom scale is off, and "Defaults" brings back the game's scale. With a custom scale, the window keeps its size when the game's UI scale changes, stays where it was when its scale changes, and its menus and tooltips still line up with it.
3. **Sale**: the cut and deposit shown match the mail's invoice. This is the most uncertain point: if the invoice cannot be read when collecting, the amount falls back to the mail's money and the cut to zero.
4. **Purchase**: the price is filled in after collecting the mail.
5. **Listing**: a single row with the right deposit, including with Auctionator and in a multi-post.
6. **Cancellation**: the cost is filled in.
7. **Warband bank**: its content and gold appear when the bank opens.
8. **Full mailbox**: a collection that fails on full bags, then succeeds, only counts once.
9. **Item tooltips**: the section appears on items in the bags, the banks, the auction house and chat links, but neither in Trading Book's window nor on the comparison tooltips, and hovering an item in combat raises no error.
10. **Translations**: none has been reviewed by a native speaker or seen in the client. The game's vocabulary (Warband bank, deposit, auction house) should be compared with each version, and long strings checked on screen, German and Russian above all.

To inspect the data in game: `/dump TradingBook.db.ledger[#TradingBook.db.ledger]`.

## Tests

The tests run on Lua 5.1, the version WoW uses, against a strict fake client where any unknown global or method raises an error. The layout tests run in every language.

```powershell
pip install lupa
python tests/run.py
```

## Publishing on CurseForge

`.pkgmeta` describes the package: a `TradingBook` folder holding the `.toc` and the files it lists, the same as `install.ps1`.

To do once:

1. Create the project on CurseForge and note its ID, under "About This Project" on its overview page.
2. Create a token on the [API tokens page](https://www.curseforge.com/account/api-tokens).
3. In the GitHub repository settings, add a webhook with the URL `https://www.curseforge.com/api/projects/{projectID}/package?token={token}`, leaving the other settings at their defaults. The token is a secret: it must never enter the repository.

After that, each release is a tag:

```powershell
git tag v0.1.0
git push origin v0.1.0
```

The tag name becomes the addon's version. A tag containing `alpha` or `beta` publishes an alpha or beta, anything else a stable release. Installed with `install.ps1`, the addon keeps `@project-version@` as its version, as only the package replaces it.

## Structure

| File | Role |
| --- | --- |
| `Core.lua` | Events, saved data, formatting, `/tradingbook` command |
| `Ledger.lua` | History of operations |
| `Auctions.lua` | Listings, cancellations, active auctions |
| `Mail.lua` | Sales, purchases and expiries read from the mail |
| `Stockpile.lua` | Stock and its history |
| `Gold.lua` | Gold history per holder and its analysis |
| `Stats.lua` | Statistics and price estimates |
| `Locales.lua`, `Locales/` | Language selection and translations (English is the key and the fallback) |
| `UI/` | Window, tables, tabs and item tooltips |
| `tests/` | Fake client and tests |
| `install.ps1`, `.pkgmeta` | Local install and CurseForge package |
