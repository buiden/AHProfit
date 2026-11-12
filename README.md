# AH Profit

A World of Warcraft: Forever addon that shows, on every item tooltip, what a vendor pays, the lowest auction house price, and what you gain or lose by selling on the auction house instead.

```
Vendor price                      5s 0c
AH price  scan 2m ago, 3 listed   6s 0c
AH profit  after 5% cut           +70c
```

The profit line is green with a `+` when the auction house pays more than the vendor after the cut, and red with a `-` when the vendor pays more. Hold Shift for more: the value of your whole stack, the measured deposit, and your own sold/expired record for the item.

## Where prices come from

- **Your own scan.** The addon scans the auction house when you open it (at most every 15 minutes), or when you type `/ahp scan`. The scan stands still while you are on a Sell tab or hold an item, so it does not get in the way of posting.
- **Your guild.** When a guild member with the addon finishes a full scan, the prices reach everyone else in the guild who runs it, with no reload. They are kept apart from your own scans and never change or delete them; the tooltip says `guild (Name, 20m ago)`. Your own scan wins while it is under 2 hours old.
- **The bundled snapshot.** `Data.lua` holds one snapshot of Blizzard's auction feed for the **EU PvP Alliance** house, taken when the release was built. It is used only for Alliance characters and only until a newer scan exists. On any other realm group it is wrong: scan once and it is replaced.

Each tooltip says which source the price is from and how old it is.

Treat guild-shared and bundled prices as estimates: only your own recent scan reflects your auction house right now.

## Other features

| Command | What it does |
|---|---|
| `/ahp` | Status |
| `/ahp farm` | Gold farming window: gathering, mobs, fishing and crafting ranked for your level and professions, with map pins |
| `/ahp bags` | What to auction and what to vendor from your bags and bank |
| `/ahp deals` | Auctions below vendor price, and materials well under their usual price |
| `/ahp recipes` | Profit per craft for the recipes you know |
| `/ahp auctions` | Your own auctions: what you get if they sell, who is undercut |
| `/ahp session` | Measured coin and items for a farming session |
| `/ahp scan`, `/ahp scan stop` | Start or end a scan |
| `/ahp auto on` / `off` | Scan by itself when the auction house opens |
| `/ahp sync on` / `off` | Guild sharing |
| `/ahp share` | Send your scanned prices to the guild now |
| `/ahp on` / `off` | Tooltip lines |
| `/ahp cut 5`, `/ahp cut 15` | The auction house cut in percent |

The addon never buys, sells, lists or moves anything.

## Install

1. Download `AHProfit-x.y.z.zip` from the latest release.
2. Copy the `AHProfit` folder into `World of Warcraft\_forever_\Interface\AddOns\`.
3. Restart the game, or type `/reload`.

## Limits

- Guild-shared prices are taken as sent: the addon cannot tell a real scan from made-up numbers. Scans timed more than 5 minutes ahead of your clock or more than 12 hours old are refused, received prices are dropped once they are 12 hours old, and only your own scans are ever passed on.
- The farm window's drop data and the price history are a snapshot from the release, for Alliance. Its auction prices are the snapshot's too, except for items with a newer price since (your scan or a guild member's): those use it.
- Tested against a mock game client only (see below).

## Tests

Lua 5.1, from the repository root:

```sh
for t in harness ui_test sync_test extra_test; do lua5.1 test/$t.lua; done
```

## License

MIT
