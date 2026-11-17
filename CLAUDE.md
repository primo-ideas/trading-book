# CLAUDE.md

Memory of the Trading Essentials repository (`https://github.com/primo-ideas/trading-book`, the old name): project
context, standing rules and current status. The global rules are in `~/.claude/CLAUDE.md` (versioned in
`primo-ideas/claude/CLAUDE.md`); technical documentation is in `docs/` (index: `docs/README.md`).

## What it is

Trading Essentials, a World of Warcraft addon (Retail, 12.1.5) that keeps a record of the player's auctions
and stock, with statistics: tabs for auctions, stock, stats and gold, item tooltip lines, a watch list,
quick selling at the auction house, Auctionator prices when present and a manual auction house scan
otherwise. Published on CurseForge: <https://www.curseforge.com/wow/addons/trading-book>.

## Layout

The addon is at the repository root (`TradingEssentials.toc`, the `.lua` files it lists, `UI/`, `Locales/`,
`Media/`); `install.ps1` copies only those into a local WoW install. `tests/` holds the test suite,
which runs the addon's logic on Lua 5.1 against a strict fake client. `art/` holds the icon sources.

## Build, test, release

```powershell
python -m pip install "lupa>=2.0"   # Python 3.12; lupa has no wheels for newer releases yet
python tests/run.py
.\install.ps1                        # then /reload in game
```

CI (`.github/workflows/ci.yml`, every push to `main`) runs the test suite on Lua 5.1; it deploys
nothing. Releases go through CurseForge (docs/development.md).

## Decisions

- 2026-11-17: the addon is renamed Trading Essentials, everywhere: folder and `.toc`
  (`TradingEssentials`), saved variables (`TradingEssentialsDB`), globals, `/tradingessentials`. No
  migration from Trading Book: its saved data was deleted, its tags removed, and versions restart at
  v1.0.0. The GitHub repository and the CurseForge slug are still `trading-book` until renamed there.
- 2026-11-17: the icon is a CC0 drawing of a pile of gold coins (OpenClipart), `art/icon.svg`.

## Working rules

- **Language:** everything in the repository is in English, except translations (`Locales/`). Talk to
  the user in French.
- The logic is tested outside the game; what only the client can show is checked in game by the user
  (README, "Check in game").

## Status

- 2026-11-16: search in the Stats tab, recovery from a failed scan, order lists in the main settings
  page, a canvas settings page (to stop blocked actions), its own icon.
- 2026-11-17: this memory file and `docs/README.md` created; history rewritten so that every commit is
  by Claude, directed by Primo.
- 2026-11-17: renamed Trading Essentials, new pile-of-coins icon, released as v1.0.0.
