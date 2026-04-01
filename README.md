# FragCounter

A World of Warcraft addon for tracking Silithid Carapace Fragment farming for the Scarab Lord questline. Built for Turtle WoW (1.12.1).

## Features

- **Session tracking** — fragments looted, deaths, gold earned, and time elapsed
- **Daily tracking** — per-day stats with 7-day history
- **Rolling rate estimate** — per-hour rate based on the last 15 minutes of farming
- **Session average** — overall session rate for comparison against the rolling estimate
- **Gold tracking** — tracks gold from mob loot and vendor sales separately
- **Death tracking** — per session and per day
- **Multi-character inventory** — scans bags on login and bank when opened, shows total across all characters
- **Brood of Nozdormu rep** — shows current standing, fragments needed to reach Neutral, and time estimate at current rate
- **Turn-in tracking** — optional turn-in count per day (toggle with `/frag turnin`)
- **Human racial bonus** — accounts for 10% rep bonus when calculating turn-ins needed
- **Draggable display frame** — small overlay showing session count, today count, rate, and total fragments
- **Persists across /reload** — session data survives UI reloads

## Installation

1. Download or clone this repo
2. Copy the `FragCounter` folder into your `Interface/AddOns/` directory
3. Restart the WoW client (or `/reload` if updating)

## Commands

All commands work with `/frag`, `/fragcount`, or `/fc`.

| Command | Description |
|---|---|
| `/frag` | Show full summary |
| `/frag show` | Show display frame |
| `/frag hide` | Hide display frame |
| `/frag lock` | Lock frame position |
| `/frag unlock` | Unlock frame (draggable) |
| `/frag goal` | Show progress toward goal |
| `/frag goal <number>` | Set custom fragment goal |
| `/frag turnin` | Toggle turn-in counts per day |
| `/frag race` | Show turn-in character race setting |
| `/frag race human\|other\|auto` | Set turn-in character race |
| `/frag reset session` | Reset session counter |
| `/frag reset today` | Reset today's counter |
| `/frag reset all` | Reset ALL saved data |

## How it works

**Fragment counting** uses `CHAT_MSG_LOOT` to detect when you loot Silithid Carapace Fragments, including stacked drops (x2, x3, etc.). Only your own loot messages are counted.

**Rate calculation** uses a rolling 15-minute window. Each loot event is timestamped, and old entries expire after 15 minutes. The rate won't display until at least 60 seconds of data is available to avoid misleading spikes. A session average is also shown for comparison.

**Gold tracking** parses `CHAT_MSG_MONEY` for mob loot gold, and diffs `GetMoney()` between `MERCHANT_SHOW` and `MERCHANT_CLOSED` for vendor income.

**Inventory tracking** scans your bags on login and on every bag change (throttled to once per frame). Bank is scanned when you open it. Counts are saved per character so the total reflects all your alts (on the same account).

## The Scarab Lord grind

The questline requires grinding Brood of Nozdormu reputation from Hated to Neutral by turning in 200 Silithid Carapace Fragments at a time for 200 reputation each (220 for Humans). That's roughly 41,400 fragments and 207 turn-ins.

FragCounter helps you track your progress and farming efficiency across the long grind.
