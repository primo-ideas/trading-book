# Development

## Tests

The tests run on Lua 5.1, the version WoW uses, against a strict fake client where any unknown global or method raises an error. The layout tests run in every language. They need Python with [lupa](https://pypi.org/project/lupa/) 2.0 or later, the first version to ship its Lua 5.1 module. lupa has no wheels for brand-new Python releases yet; Python 3.12 works, and is what CI uses.

```powershell
python -m pip install "lupa>=2.0"
python tests/run.py
```

On Windows, with the Python install manager, `py install 3.12` adds that version and `py -V:3.12 tests/run.py` runs the tests with it.

## Continuous integration

`.github/workflows/ci.yml` runs the test suite on every push to `main`, on pull requests and by hand. It is the only check: the addon itself only runs in the game client, so there is nothing to deploy from CI. Releases go through CurseForge, below.

## Publishing on CurseForge

`.pkgmeta` describes the package: a `TradingEssentials` folder holding the `.toc`, the files it lists and `Media/`, the same as `install.ps1`.

The summary and description of the project page are in [curseforge.md](curseforge.md), to paste into the project settings whenever they change.

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
| `Core.lua` | Events, saved data, formatting, `/tradingessentials` command |
| `Ledger.lua` | History of operations |
| `Auctions.lua` | Listings, cancellations, active auctions |
| `Mail.lua` | Sales, purchases and expiries read from the mail |
| `Stockpile.lua` | Stock and its history |
| `Gold.lua` | Gold history per holder and its analysis |
| `Stats.lua` | Statistics and price estimates |
| `Market.lua` | Auction house scan and the prices it keeps |
| `Selling.lua` | Quick selling: what can be listed, the price to propose, the listing |
| `Shopping.lua` | The shopping list of the tracked recipes, its quantities and buying |
| `Profit.lua` | What each item earns, how well it sells, and the advice deduced from them |
| `Locales.lua`, `Locales/` | Language selection and translations (English is the key and the fallback) |
| `UI/` | Window, tables, tabs, settings page and its order section, item tooltips, the auction house tab and its quick sell and shopping views |
| `Media/` | Textures: `Icon.tga`, the addon's icon (minimap, window portrait, addon list) |
| `art/` | Source images, left out of the package: `icon.svg`, the icon's drawing (CC0), and `icon.png`, the icon at 512 x 512, also the CurseForge project icon |
| `tests/` | Fake client and tests |
| `docs/` | This documentation |
| `.github/workflows/` | Continuous integration |
| `install.ps1`, `.pkgmeta` | Local install and CurseForge package |

## The icon

The icon is a pile of gold coins, "Pile of Golden Coins Vector" from OpenClipart, in the public domain (CC0): <https://freesvg.org/pile-of-golden-coins-vector>. Its source is `art/icon.svg`. `art/icon.png` is that drawing at 512 x 512 on a transparent background, the coins 496 pixels wide and centered, rendered with a headless browser (for instance Chrome's `--headless --screenshot --default-background-color=00000000 --window-size=512,512` on a page holding only the image).

The client reads TGA (and BLP) textures, with sides a power of two. After changing `art/icon.png`, rebuild `Media/Icon.tga` from it, an uncompressed 32-bit TGA of 64 x 64, with Pillow (`pip install pillow`):

```powershell
python -c "from PIL import Image; Image.open('art/icon.png').convert('RGBA').resize((64, 64), Image.LANCZOS).save('Media/Icon.tga')"
```

Then restart WoW: a texture file new to the addon folder is only found at launch. On CurseForge, upload `art/icon.png` as the project icon.

## Settings and taint

The settings page is a canvas: one frame of Trading Essentials' own, registered with `Settings.RegisterCanvasLayoutCategory`, with its own checkboxes, dropdowns and slider. It must not go back to the game's settings objects (`Settings.RegisterProxySetting`, `Settings.CreateCheckbox` and the like, or an element initializer):

- The options panel looks a setting up by going through every registered setting, and the action bars do so on every click. An addon's setting carries the addon's taint, so a click on an action button could be blocked (`UseAction`).
- The panel reuses the frames of its list for every category. A row once filled for an addon's setting keeps its taint, and the game's own options shown in it later get blocked, for instance when searching the key bindings (`IsUserOAuthed`).

A test checks that the page only uses the canvas functions. To find the source of a "blocked from an action" message, type `/console taintLog 1`, reproduce it, leave the game, and read `World of Warcraft\_retail_\Logs\taint.log`; `/console taintLog 0` turns it off again.
