# Changelog

## Unreleased
- Farm window: items you have scanned since the bundled farm data use your newer auction price (gathering, mobs, fishing and crafting). Without a newer scan the numbers are unchanged.
- Guild sharing: received prices are kept in their own layer and never overwrite or delete your own scans. Your own scan wins while it is under 2 hours old; after that a newer guild scan is shown, as `guild (Name, 20m ago)`. Scans timed more than 5 minutes ahead or more than 12 hours behind your clock are refused, only your own scans are passed on, and the shared layer is capped (60,000 items, 8 auction houses). Saved data: `AHProfitDB.v = 1`, `AHProfitDB.shared`.

## 0.5.3
- Tooltip is three lines: vendor price, AH price, AH profit after the cut (green `+` / red `-`). Extra lines with Shift.
- The automatic scan stands still while you sell, so posting is not refused with "You're doing this too fast".
- Bank advice, deals, recipe profit, own auctions, guild-shared gathering nodes.
