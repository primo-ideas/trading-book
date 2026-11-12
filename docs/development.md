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
| `Market.lua` | Auction house scan and the prices it keeps |
| `Selling.lua` | Quick selling: what can be listed, the price to propose, the listing |
| `Shopping.lua` | The shopping list of the tracked recipes, its quantities and buying |
| `Locales.lua`, `Locales/` | Language selection and translations (English is the key and the fallback) |
| `UI/` | Window, tables, tabs, settings and their order page, item tooltips, the auction house tab and its quick sell and shopping views |
| `tests/` | Fake client and tests |
| `docs/` | This documentation |
| `.github/workflows/` | Continuous integration |
| `install.ps1`, `.pkgmeta` | Local install and CurseForge package |
