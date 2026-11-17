# CLAUDE.md

Memory of the `trading-book` repository (`https://github.com/primo-ideas/trading-book`): project
context, standing rules and current status. The global rules are in `~/.claude/CLAUDE.md` (versioned in
`primo-ideas/claude/CLAUDE.md`); technical documentation is in `docs/` (index: `docs/README.md`).

## What it is

Trading Book, a World of Warcraft addon (Retail, 12.1.5) that keeps a record of the player's auctions
and stock, with statistics: tabs for auctions, stock, stats and gold, item tooltip lines, a watch list,
quick selling at the auction house, Auctionator prices when present and a manual auction house scan
otherwise. Published on CurseForge: <https://www.curseforge.com/wow/addons/trading-book>.

## Layout

The addon is at the repository root (`TradingBook.toc`, the `.lua` files it lists, `UI/`, `Locales/`,
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
