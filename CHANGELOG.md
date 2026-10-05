# Changelog

## v3.2.0 - first public release

- Now **Vulcan GrindWatch** (formerly FarmTracker), part of the Vulcan Suite.
  `/gw` and `/grindwatch` open it; `/ft` and `/farmtracker` still work.
- New: `/gw backup` and `/gw restore` (also in the gear menu). Copy all your history
  and settings as text to keep outside the game, and paste it back later.
- New: if the Forever client fails to load your saved data, GrindWatch says so and
  tells you how to keep your file, instead of quietly starting empty.
- Duo sync uses a new message name, so both of you need this version to see each other.
- Frame accent in the Vulcan Suite's ember orange.

## 3.1 (as FarmTracker)

- Gear menu and a settings window for every option, plus `/set`, `/defaults`, an
  Options > AddOns page and right-click in the minimap add-on menu.
- New settings: recent window length, alert threshold, timing, cooldown and sound, zone-hint
  time, background opacity (0% and locked makes the window click-through), trend on/off.
- Damaged or hand-edited saved settings are repaired at login.
- Fixed: raising the idle cutoff while idle restarted the clock; a longer recent window on a
  session from 3.0 read as a slump.
- Sync v4: partner rates respect the window length; turning sync off tells your partner at once.

## 3.0 (as FarmTracker)

- Diagnostics (`debug`, `check`, `spell`), rested-aware time to level, trend and slowing-down
  alert, zone hint, session labels, best spots, loot list, CSV export, history of 50, partner
  recent rates (sync v3), compact mode, key bindings, re-pricing.

## 2.0 (as FarmTracker)

- Rolling 15-minute rates, idle- and AFK-aware clock, kill matching, history, per-character
  sessions, duo sync, auction prices, spending.

## 1.0 (as FarmTracker)

- First version.
