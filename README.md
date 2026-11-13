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
- **Your guild.** When a guild member with the addon finishes a full scan, the prices reach everyone else in the guild who runs it, with no reload. They are kept apart from your own scans and never change or delete them; the tooltip says `guild (Name, 20m ago)`. Your own scan wins while it is under 2 hours old. If a transfer is cut (a `/reload`, a logout, or messages that never arrive), the addon says so and asks the guild again about 30 seconds later, and the missing scan arrives within about 10 minutes (a member sends the same scan at most once every 10 minutes, then once more for anyone who asked in between); it also asks about once an hour, so you still get a newer scan whose owner was offline when you logged in. Members who have a newer scan offer it, the newest offer is picked, and only that member sends, so one transfer serves everyone who asked (a picked member that sends nothing is skipped and the next one asked); nobody answers when you already have the newest scan. `/ahp` shows the offers heard and when the next check is due. Members still on 0.6.0 are not picked to send until they update.
- **The bundled snapshot.** `Data.lua` holds one snapshot of Blizzard's auction feed for the **EU PvP Alliance** house, taken when the release was built. It is used only for Alliance characters and only until a newer scan exists. On any other realm group it is wrong: scan once and it is replaced.

Each tooltip says which source the price is from and how old it is.

Treat guild-shared and bundled prices as estimates: only your own recent scan reflects your auction house right now.

With [Auctionator](https://www.curseforge.com/wow/addons/auctionator) installed, a price it saw today is used when
neither you nor the guild has scanned the item, or the newest such scan is more than 24 hours old (before the bundled
feed). Auctionator is not asked for an item missing from a complete scan of yours or the guild's made since
Auctionator's day began. It is read through Auctionator's public API only; its listed count is not known, so none is shown.
Auctionator fixes its day when it loads, so after midnight its new scans are not used until you `/reload`.

## Other features

| Command | What it does |
|---|---|
| `/ahp` | Status |
| `/ahp farm` | Gold farming window: gathering, mobs, fishing and crafting ranked for your level and professions, with map pins |
| `/ahp bags` | What to auction and what to vendor from your bags and bank |
| `/ahp deals` | Auctions below vendor price, and items well under their usual price (from your own scans once they cover 5 days, else the bundled history) |
| `/ahp recipes` | Profit per craft for the recipes you know |
| `/ahp auctions` | Your own auctions: what you get if they sell, who is undercut |
| `/ahp session` | Measured coin and items for a farming session |
| `/ahp scan`, `/ahp scan stop` | Start or end a scan |
| `/ahp auto on` / `off` | Scan by itself when the auction house opens |
| `/ahp sync on` / `off` | Guild sharing |
| `/ahp auctionator on` / `off` | Use Auctionator's prices when yours are missing or old (on by default when Auctionator is installed) |
| `/ahp share` | Send your scanned prices to the guild now |
| `/ahp on` / `off` | Tooltip lines |
| `/ahp cut 5`, `/ahp cut 15` | The auction house cut in percent |
| `/ahp keep <item>`, `/ahp unkeep <item>` | Never (or again) suggest this item when the bags are full |
| `/ahp bagfull <0-20>`, `/ahp bagfull off` | Warn when this many general bag slots are left (default 0) |
| `/ahp progress on` / `off` / `reset` | The scan progress window (on by default; off = chat lines only); `reset` puts it back in the centre. Any auction house search not sent by the scan stops it; a Favorites answer is rejected unless it covers half the house |

**Bags full:** when your bags are full (the game's "Inventory is full", or no free slot left), a small window says
what to do: first a free fix (merge two partial stacks), otherwise the least valuable slot to destroy, in a bag the
item can go into (herb, mining and other special bags only count for their own items). A slot's value is its count
times the vendor price, or the auction price after the cut when that is higher and the item is not bound; grey items
come first, unknown values last. Quest items, quest starters, the hearthstone, keys, tools, your class reagents,
food and potions (unless grey), equipment-set items, bound items without a vendor price and your keep list are never
suggested. With the loot window open it compares the drop with that slot ("Drop is worth 45s, your cheapest slot is
2s"). **Show** opens your bags and marks the slot, **Keep** adds the item to the keep list. It only advises.

The addon never buys, sells, lists or moves anything, and never destroys an item.

It also keeps, in its saved variables, records for tools outside the game (the Relax Coach Farming page reads them):

- **Gold ledger:** per character and day, the money in and out by source (vendor, repair, auction house, mail, trade,
  trainer, flight, quest, loot, other), taken from the change of your money and the window that was open. 180 days, up
  to 50 characters. Days are UTC days, like the price history.
- **Sessions:** each farming session you stop with `/ahp session stop` (or the Stop button): character, zone where it
  started, time, coin by source, the items gained and used, nodes gathered. The last 100.
- **Item names:** the name and vendor price of the items in your bank, your auctions and your sessions, once the game
  has loaded them. Up to 5,000 items.

## Install

1. Download `AHProfit-x.y.z.zip` from the latest release.
2. Copy the `AHProfit` folder into `World of Warcraft\_forever_\Interface\AddOns\`.
3. Restart the game, or type `/reload`.

## Limits

- Guild-shared prices are taken as sent: the addon cannot tell a real scan from made-up numbers. Scans timed more than 5 minutes ahead of your clock or more than 12 hours old are refused, received prices older than 12 hours are dropped at the next received scan or reload, and only your own scans are ever passed on.
- The farm window's drop data and the price history are a snapshot from the release, for Alliance. Its auction prices are the snapshot's too, except for items where the addon's own price for the item (your scan, a guild member's or the bundled feed, as the tooltip shows it) is newer: those use it. Your own scans also keep a daily history (21 days, up to 10,000 items per auction house) that the deals use first; it is stored compactly (one short string per item), about 1 MB for a house of 6,000 items scanned in full every day.
- Tested against a mock game client only (see below).

## Tests

Lua 5.1, from the repository root:

```sh
for t in harness ui_test sync_test extra_test ledger_test bagfull_test progress_test; do lua5.1 test/$t.lua; done
```

## License

MIT
