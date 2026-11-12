# Changelog

## Unreleased
- Farm window: items for which the addon's own price (the one the tooltip shows) is newer than the bundled farm data use that newer auction price (gathering, mobs, fishing and crafting). Without a newer price the numbers are unchanged.
- Daily price history from your own scans: every search and full scan records, per item and day, the highest and lowest of the lowest prices and the most listed (21 days, up to 10,000 items per auction house; guild prices are not recorded). Deals measure "well under the usual price" against your own history once it covers 5 days, else the bundled history, and say which. Saved data: `AHProfitDB.v = 2`, `AHProfitDB.hist` (one compact string per item, about 1 MB for 6,000 items over 21 days; a large scan is written over several frames, each row to the house and day it was scanned on; an item with no day left in the last 21 gives its place to a new one).
- Guild sharing: received prices are kept in their own layer and never overwrite or delete your own scans. Your own scan wins while it is under 2 hours old, whatever the bundled snapshot's age; after that a newer guild scan is shown, as `guild (Name, 20m ago)`. Scans timed more than 5 minutes ahead or more than 12 hours behind your clock are refused, only your own scans are passed on, received prices older than 12 hours are dropped, a complete newer guild scan replaces the older received prices, and the shared layer is capped (60,000 items, 8 auction houses). Saved data: `AHProfitDB.v = 1`, `AHProfitDB.shared`.

## 0.5.3
- Tooltip is three lines: vendor price, AH price, AH profit after the cut (green `+` / red `-`). Extra lines with Shift.
- The automatic scan stands still while you sell, so posting is not refused with "You're doing this too fast".
- Bank advice, deals, recipe profit, own auctions, guild-shared gathering nodes.
