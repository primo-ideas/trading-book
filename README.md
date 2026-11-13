# Trading Book

[![CI](https://github.com/primo-ideas/trading-book/actions/workflows/ci.yml/badge.svg)](https://github.com/primo-ideas/trading-book/actions/workflows/ci.yml)

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

Item tooltips, wherever the game shows them (bags, bank, auction house, chat links), get Trading Book's lines, together at the bottom and without a title, to save room: the account's stock of that item by character and place and its value, your average sale price over 90 days, and your last sale. Over the same 90 days they also give what a unit earned you, how much of what you listed sold, how long a sale took after its listing, and a word of advice (see the Stats tab). Without a price from Auctionator, which shows its own, they also give the auction house price from Trading Book's scan, how long ago it was seen, the quantity on sale, and the change since the latest daily price at least a week old. A watched item also shows its price targets. Nothing is added for an item that has none of these, nor in Trading Book's own windows, which already show the same. `/tradingbook tooltip` hides the lines or brings them back.

The auction house window gets a Trading Book tab, after its own and in line with Auctionator's when it is installed. At its top: when the auction house was last scanned, when the game allows the next scan, and a button to scan it. Below, three views:

- **Quick sell** lists what your bags can sell. Click an item: the whole stack is ready to list for 48 hours, at the lowest price on sale once the auction house has answered. Change the quantity, the price (written like `12g50s` or `12.5`) or the duration for that item if you like, then **Post**, or press Enter in a box. The next item of the list is then selected, ready to post. **Next** and **Previous** go through the list without posting. With the keys on, Space posts, Shift-Space goes to the next item and Backspace to the previous one. A price below what a vendor pays, or far under the usual price of a commodity, takes a second press.
- **Purchases** turns your tracked recipes into a shopping list. On the left, each recipe with how many times to craft it and what a craft earns once sold. On the right, the components to buy, and never the crafted item unless another tracked recipe needs it. The quantity to buy is what the crafts need, less what you hold and what your recipes will make. Click a component, then **Buy**: the game gives the exact price, which **Confirm** accepts, and the next component to buy is selected. Changing the quantity after that drops the price given, and **Buy** asks for the new one. A quantity that climbs into much dearer auctions takes a second press, and **Good price** limits it to what is close to the lowest price. **Based on my sales** sets each recipe to a week of your recent sales, beyond the stock you have. A recraft improves an item you already have and makes no new one: its components are on the list, but it covers no other recipe's need and gets no suggestion. Recipes come with the most profitable first. A component one of your tracked recipes makes for less than it sells for says so, with what a unit costs to craft. A price well above the usual price of a component, from Trading Book's daily prices, takes a second press. A component sold by the unit rather than as a commodity is bought one auction at a time, at its buyout.
- **Tracking** shows your undercut auctions with the cheaper price on sale, and the watched items with their targets and the lowest price on sale, in green when a target is reached.

Trading Book scans the auction house only when you ask, with the button of its tab or `/tradingbook scan`: opening the auction house never starts a scan. One request reads every auction of the realm, at most every 15 minutes, as the game allows. The request waits until the game can take it, and is sent again if the game drops it. If the auction house does not answer within a minute, for instance because another addon scanned it less than 15 minutes ago, the chat says so and the scan button can try again at once. With Auctionator, its prices serve too: what it saw today counts for the undercuts, the watched items and the auction house tab, unless Trading Book scanned that day. Each item keeps its lowest buyout per unit and the quantity on sale. Connected realms share their prices, which are kept 30 days after the item was last seen. The items your account holds or traded also keep one price a day for 30 days, which gives the change shown in their tooltip.

After each scan, and as Auctionator's prices change, your auctions on sale that a cheaper offer beats are undercut: the chat says how many, and the Active list of the Auctions tab marks them, with the cheaper price and where it comes from in their tooltip. With Auctionator, which reports after each search, the chat only speaks when something changed. Your characters' auctions on the same auction house do not undercut each other: an item is undercut when the lowest price on sale is below your own lowest.

When you leave the mailbox, one line in the chat sums up the auction house mail you collected: the sales and the money they brought, the purchases and what they cost, and the expiries.

The settings are in the game's options, under AddOns > Trading Book. A right-click on the minimap icon or on the addon menu entry opens them, as does `/tradingbook settings`.

| Setting | Effect |
| --- | --- |
| **Minimap icon** | Shows or hides the icon, like `/tradingbook minimap`. |
| **Item tooltips** | Adds Trading Book's lines to item tooltips or not, like `/tradingbook tooltip`. |
| **Mail summary** | Sums up the collected auction house mail in the chat when you leave the mailbox. |
| **Sale duration** | How long quick selling lists an auction: 12, 24 or 48 hours. 48 by default. |
| **Proposed price** | What quick selling proposes against the lowest price on sale: the same price by default, or 1 silver, 1 gold, 1%, 5% or 10% less. Your own lowest price is never undercut. |
| **Next item after posting** | Moves on to the next item of the list once an item is posted. |
| **Trading Book tab keys** | Space, Shift-Space and Backspace in the Quick sell and Purchases views. Turned off, those keys keep their usual use. |
| **Stock counted for purchases** | What comes off the components to buy: this character and the Warband bank, or the whole account. |
| **Component quality** | Which quality of a component the shopping list buys: the cheapest, or the highest. Whatever quality you hold counts towards the need. |
| **Custom window scale** | Gives the window a scale of its own, which replaces the game's UI scale: the window then keeps its size when the game's scale changes. Turned on, it starts from the game's current scale, so nothing moves yet. Turned off, the window follows the game's scale again. |
| **Window scale** | That scale, from 50% to 120% in steps of 5%, in the same percent as the game's UI scale. Greyed out while the window follows the game. The window stays centred on the same spot when it changes. |

The **Order** page, under Trading Book in the same options, puts three things in the order you like, with arrows to move each item up or down: the window's tabs, the first of which is the one the window opens on, the blocks of item tooltips (stock, auction house price, price targets, sales, profit), and the tiles of the Stats tab. The window follows at once, even open. **Default order**, or the options' Defaults button, brings back the original order.

| Tab | Content |
| --- | --- |
| **Auctions** | History of sales, purchases, listings, expiries and cancellations, plus your active auctions, marked when undercut. |
| **Stock** | Tradable items, filtered by location (bags, personal bank, shared stock, mail, auction house), with the change over 7 days and an estimated value. |
| **Stats** | Net result, profit on sales, sales, purchases, fees, sell-through, stock value and gold change, over 7, 30 or 90 days or all time, with the result per day and per item. See [What each item earns](#what-each-item-earns). |
| **Gold** | Gold curve, change, average per day, best and worst day, peak, the auctions' share of the gains, and the breakdown by holder. |

The data covers the whole account. The menu at the top right narrows the display to one character, including one you are not logged in on. "Shared stock" means the Warband bank: since it belongs to no one, its filter shows it whichever character is selected.

A gold change only counts what changed since Trading Book started following the holder: a character's first login is not a gain, and moving gold to the shared stock does not change the total. "Outside auctions" is the difference between the gold change and the auction result, so a sale not yet collected from the mail can temporarily shift that split.

Stock value comes from Auctionator if it has a price, otherwise from Trading Book's auction house scan, otherwise from the average of your sales over 90 days. An item with no known price counts as zero.

## What each item earns

The Stats tab's item table deduces, for each item of the period:

- **Profit**: the sales after the auction house cut, less the deposits lost on listings that did not sell and the cancellation costs, less what the units sold cost. That cost is the average price you paid for the item on the auction house, whenever you bought it; or, for an item you never bought, what one of your tracked recipes takes to craft it at today's prices. An item neither bought nor crafted (gathered, looted) counts as free. Hovering the row details each part.
- **Sold %**: the share of what you listed that sold, among the auctions that ended (sold, expired or cancelled).
- **Time to sell**: on average, how long a sale came after its listing, from the latest listing of that item on that character that the auction could have lasted from.
- **Advice**: *Unsold* when nothing sold and deposits were lost, *Loss* when it sells for less than it costs, *Slow* when under 30% of at least four ended units sold, *Fees* when lost deposits and cancellations take over a quarter of what it brings, and *Good* when it earns money and 70% or more of at least four units sold.

The **Profit on sales** tile adds up the items' profits. Unlike **Net profit**, which follows the money in and out, it leaves out the stock bought but not sold yet, and takes off the cost of what was sold.

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
| Auction house prices | `ReplicateItems`, read back with `GetReplicateItemInfo` | On the tab's scan button or `/tradingbook scan`, at most every 15 minutes |

Net profit = sales - purchases - fees, where fees = cut + unrefunded deposits + cancellation costs. This follows the money actually received and spent: the deposit paid when listing comes back with the sale's payment.

## Known limitations

- A sale only appears once its mail is collected. It is still dated from the mail's remaining time, so the per-day statistics stay correct.
- The bank and the Warband bank show their content as of your last visit.
- Stock in the mail only sees the first 50 messages loaded by the client.
- Items are grouped by ID: variants of one item (item level) and caged pets are merged. The auction house price of an item is that of its cheapest variant, and caged pets get none.
- An auction house price is the lowest buyout of the latest scan, so a single cheap auction is enough to lower it.
- Undercuts come from the latest prices known: an offer listed since is not seen, and a piece of gear can look undercut by a cheaper variant of the same item.
- Auctionator's prices only count on the day it saw the item, as it gives neither the time nor the quantity on sale: an item it saw yesterday is left out until it sees it again or Trading Book scans.
- A purchase whose mail invoice cannot be read has no price: its row shows it as unknown, it counts as zero in the totals, and the Purchases tile of the Stats tab says how many there are.
- After an interrupted multi-post, the listed quantity stays the one first requested.
- The cost of crafting an item is not known: profit only counts auction house purchases.
- The icon follows a circle around the minimap: on a square minimap (ElvUI, for example), it does not reach the corners.
- Trading Book adds its tooltip lines after the other addons that use the game's tooltip calls, but an addon that adds its own once the tooltip is filled still puts them after Trading Book's.

## Check in game

The fake client used by the tests draws nothing and reflects my reading of the API. These points remain to be confirmed:

1. **Interface**: window and portrait, tabs, character menu, columns, scrolling, charts, minimap icon (appearance, dragging, position kept after relogging). The tests check the margins, but with an estimated text width.
2. **Settings**: the page appears under AddOns, opens from a right-click on the icon and on the addon menu entry, greys out the scale slider while the custom scale is off, and "Defaults" brings back the game's scale. With a custom scale, the window keeps its size when the game's UI scale changes, stays where it was when its scale changes, and its menus and tooltips still line up with it.
3. **Sale**: the cut and deposit shown match the mail's invoice. This is the most uncertain point: if the invoice cannot be read when collecting, the amount falls back to the mail's money and the cut to zero.
4. **Purchase**: the price is filled in after collecting the mail. If it is not, the purchase shows an unknown price and the Purchases tile counts it.
5. **Listing**: a single row with the right deposit, including with Auctionator and in a multi-post.
6. **Cancellation**: the cost is filled in.
7. **Warband bank**: its content and gold appear when the bank opens.
8. **Full mailbox**: a collection that fails on full bags, then succeeds, only counts once.
9. **Item tooltips**: the lines appear at the bottom, with no title, on items in the bags, the banks, the auction house and chat links, but neither in Trading Book's windows nor on the comparison tooltips, and hovering an item in combat raises no error.
10. **Auction house scan**: the request is answered by `REPLICATE_ITEM_LIST_UPDATE`, indexes start at 0, the buyout covers the whole stack, the game does not freeze or disconnect while it is read, a request within 15 minutes is refused without harm, and the prices match those of the auction house. Undercut auctions are the ones the auction house shows beaten, which relies on the price of an owned commodity auction being per unit.
11. **Translations**: none has been reviewed by a native speaker or seen in the client. The game's vocabulary (Warband bank, deposit, auction house) should be compared with each version, and long strings checked on screen, German and Russian above all.
12. **Order page**: it appears under Trading Book in the AddOns options, its arrows and labels fit, the options' Defaults button resets it, and after a change the window's selected tab is still the one highlighted.
13. **Auction house tab**: it sits after the game's tabs, in line with Auctionator's when it is installed. Clicking it replaces the auction house's content with its panel, above the player's money, and changes the title. Clicking any other tab, the game's or Auctionator's, brings that tab's content and highlight back, and reopening the auction house starts on the game's first tab. Using bag items in combat after a visit to the auction house raises no "action blocked" message. The status counts down to the next scan and the button scans.
14. **Auctionator's prices**: after a scan in Auctionator, the undercuts, the watched items and the Trading Book tab follow its prices, and its searches do not fill the chat.
15. **Quick sell**: the list holds what the bags can sell, a stack posts in one press, the price shown is the one the auction house shows, the deposit matches, and the game's confirmation dialog appears when it wants one. Space, Shift-Space and Backspace work, and Space jumps again once the tab is left. Several copies of an item that does not stack post one after the other.
16. **Shopping list**: tracked recipes appear with their components, including recrafts. The price given before confirming is what is charged, the purchase arrives in the mail, and the list counts it straight away. Space buys then confirms.

To inspect the data in game: `/dump TradingBook.db.ledger[#TradingBook.db.ledger]`.

## Development

Tests, continuous integration, publishing on CurseForge and the layout of the code are in [docs/development.md](docs/development.md).
