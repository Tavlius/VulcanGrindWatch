# Vulcan GrindWatch

Kills, XP and gold per hour while you farm or level in **World of Warcraft: Forever**.
A small window shows your totals, your rate for the whole session, and your rate over the
last few minutes, so you can tell when a spot stops paying. If a group member also runs
GrindWatch, you see their gold rate too and a combined duo rate.

**Display only, no automation.** GrindWatch reads what happens and shows numbers. It never
casts, targets, moves, loots, sells or clicks anything for you. The one thing it ever sends is
the rate summary described under [Duo sync](#duo-sync), and only to your own group.

Part of the **Vulcan Suite**: Vulcan RunBook · Vulcan DuoQuest · Vulcan SimBench.

## Install

- **CurseForge app** or **WowUp**: search for *Vulcan GrindWatch* and install it for World of
  Warcraft: Forever.
- **By hand**: download the zip from CurseForge, Wago or the GitHub releases page and unzip it.
  Copy the `VulcanGrindWatch` folder into the `Interface\AddOns\` folder of your Forever game
  folder. To find that folder, open Battle.net, select the Forever game, click the gear icon
  and choose *Show in Explorer*.

At the character screen, click **AddOns** and make sure Vulcan GrindWatch is ticked. If it's
greyed out as "out of date", tick **Load out of date AddOns**.

## The window

| Row | Meaning |
| --- | --- |
| Time | Active farming time. It starts at your first pull. Breaks don't count: after 5 minutes with no pull, kill or loot (the idle cutoff, a setting), the time since your last activity is dropped, except one minute for looting and drinking. Typing /afk stops the clock at once and drops the time since your last activity (unless "Pause while AFK" is off). After a login or /reload it waits until you're active again. |
| Kills | XP kills, plus looted corpses that gave no XP (grey mobs, or any mob at level 60). Pickpocketing and skinning never add kills. |
| XP | XP from kills and exploration. Quest turn-in XP is left out. |
| Coin | Coin you picked up. Money from vendors, mail, trade, the bank and the auction house is left out. |
| Loot | Value of looted items: vendor price, or auction price with `/gw price ah` if you use Auctionator. |
| Gold | Coin plus loot. |
| To level | Time to level at your recent pace, allowing for rested XP running out. |
| Partner / Duo gold | A group member's gold rate and the combined rate, if they run GrindWatch too. |

Columns: **Total**, **/hr** for the whole session, and **Last 15m**, a rolling rate that's
best for judging a spot (the length is a setting).

The status at the top right shows a trend once you've farmed longer than that window: your
recent pace against the whole session. If it falls below 60% after 20 minutes or more, you get
a "this spot is slowing down" alert, at most every 15 minutes. Farming 10 minutes or more in
another zone suggests `/gw reset`, so each spot gets its own numbers. All of these numbers are
settings.

## Settings

Point at the window and click the small gear at its top right. The menu has **Settings...**,
Pause/Resume, Lock, Compact, Report, Export history, **Back up data...**, **Restore from
backup...**, Hide window and Reset session (click twice to confirm). You can also open the
settings with `/gw settings`, by right-clicking GrindWatch in the add-on menu by the minimap,
or from Options > AddOns > Vulcan GrindWatch.

| Section | Settings |
| --- | --- |
| Window | lock position, compact, show trend %, scale, background opacity, reset position |
| Clock | pause while AFK, idle cutoff (0 = off), recent window (5-30 minutes) |
| Loot value | vendor or Auctionator price, re-value loot now |
| Alerts | slowing-down alert, sound, threshold %, judge after, cooldown, zone hint (0 = off) |
| Duo | share rates with your group |
| Diagnostics | debug log, print to chat, export or clear the log, teach a skinning or pickpocket spell |

Changes apply at once, and changed settings show in light blue with the default in the
tooltip. Settings are account-wide. Saved values that are damaged or hand-edited are repaired
at login, with a message saying which.

## Commands and key bindings

`/gw` and `/grindwatch` work everywhere below. The older `/ft` and `/farmtracker` still work too.

**Session**
- `/gw` show or hide the window; `/gw pause`, `/gw resume` (or right-click the window)
- `/gw reset` save the session to history and start a new one
- `/gw note murlocs by the coast` label the session (shown in history and exports)

**Results**
- `/gw report` full report in your chat window; `/gw report party` (or raid, guild, instance,
  say) or `/gw report w Name` sends a one-line summary
- `/gw loot` every item looted this session, most valuable first
- `/gw history` the latest 10 sessions (`all` for up to 50; `clear yes` deletes them)
- `/gw spots` your best zones: XP per hour while leveling, gold per hour at 60
- `/gw export` history as CSV in a copy box (Ctrl+C), for a spreadsheet

**Your data**
- `/gw backup` all your history and settings as one line of text to keep outside the game
- `/gw restore` paste a backup back (you see what's in it before anything changes)

**Settings**
- `/gw settings` open or close the settings window; `/gw set` list or change any setting by
  name (`/gw set alertPercent 50`); `/gw defaults` put every setting back (asks first)
- `/gw price vendor|ah`, `/gw reprice`, `/gw idle <minutes>`, `/gw afk`, `/gw alert`,
  `/gw sync`, `/gw compact`, `/gw lock`, `/gw unlock`, `/gw scale 0.5-2`

**Troubleshooting**
- `/gw help` lists every command; `/gw check` shows what your client supports and whether your
  saved data loaded
- `/gw debug on` records what the add-on sees (loot windows, casts, money, quests);
  `/gw export debug` copies the log
- `/gw spell gather <id>` teaches a skinning spell the add-on doesn't know (also
  `pickpocket`, `remove`, `list`)

**Key bindings** (Options > Key Bindings > AddOns > Vulcan GrindWatch): show/hide the window,
and pause/resume.

## Duo sync

When a group member also runs GrindWatch, each window shows the other's gold, gold per hour and
recent rate, plus a combined **Duo gold** row. A rate appears once you both have a few minutes
of data. Turn sharing off with `/gw sync` (or in Settings > Duo). Your partner's window drops
you at once.

**What it sends.** Every 30 seconds while you're grouped and sharing is on, GrindWatch sends
one addon message to your **party or raid only** (never whisper, guild or public channels). It
contains: the sync protocol number, your session's active seconds, kills, XP, coin, loot value
at vendor price and at auction price, the same three values for your recent window, and that
window's length in minutes. Turning sharing off sends one "bye" message. Nothing else is sent:
no character details, no location, no history.

Both of you need a version that speaks the same sync protocol. If one of you is out of date,
you each get a one-time message saying so.

## Known Forever client issue: saved data

The Forever beta client has been reported to write add-on data to disk but sometimes fail to
load it back, and then overwrite the good file the next time you log out or /reload. Add-ons
can't read or write files, so GrindWatch does what's possible from inside the game:

- **It notices a failed load.** Your account file (settings and history) and each character's
  file (the current session) record that the other exists. If one comes back empty while the
  other says it should have data, GrindWatch shows a warning instead of quietly starting over.
  It tells you which file to copy before you log out or /reload. If both files fail at once,
  that looks exactly like a fresh install and can't be detected, so keep a backup.
- **`/gw backup`** gives you all your history and settings as one line of text. Paste it into a
  text file somewhere safe. **`/gw restore`** puts it back. It checks the text is complete,
  undamaged, and from GrindWatch, and shows what it holds before you confirm. After you
  save a session to history, GrindWatch suggests a backup at most once a week.
- **Backing up by hand:** with the game closed, copy the `WTF` folder in your Forever game
  folder. GrindWatch's files are `WTF\Account\<account>\SavedVariables\VulcanGrindWatch.lua`
  (settings and history) and `WTF\Account\<account>\<realm>\<character>\SavedVariables\VulcanGrindWatch.lua`
  (that character's current session).

Community workaround tools exist. GrindWatch doesn't need or rely on any of them, and some
work by editing add-on files that your add-on updater replaces.

## Limits

- Forever blocks the combat log for add-ons, so kills come from XP messages and looted corpses.
  At level 60 a mob only counts if you loot it.
- Spending (repairs, ammo, food, flights, training) is listed in `/gw report` but not subtracted
  from the rates, since one big purchase would wreck them.
- Vendor prices undervalue cloth, herbs and leather; use `/gw price ah` if you run Auctionator.

## Development

The repository is the add-on folder. Run every check (luacheck, the test suites, the
personal-data guard, and a real package build) in the pinned container, from Git Bash or any
shell with Docker:

    sh tests/docker.sh

After cloning (or right after `git init`), run this once before the first commit, from Git Bash on Windows (PowerShell has no `sh`). It sets this repository's commit identity and installs a pre-push hook that runs the personal-data guard over the tree and the whole history:

    sh tests/init_repo.sh

Commits must carry a GitHub noreply email address (`<id>+<username>` at `users.noreply.github.com`); the guard refuses any other address.

The GitHub Actions workflow runs exactly the same container on every push and pull request.
Pushing a tag `vX.Y.Z` packages the add-on with the BigWigs packager and uploads it to
CurseForge and Wago. The tag needs a matching `## vX.Y.Z` section in `CHANGELOG.md`.

- **Client version:** `## Interface: 16001` matches Forever 1.60.1. When the Forever client
  version changes, bump it in `VulcanGrindWatch.toc` and in `tests/tests_release.lua`.
- **Version:** the TOC's `## Version:` line holds the packager's version token (`project-version` between two `@` signs), and the packager replaces it with
  the tag. Nothing in the code reads the version.
- **Retiring the saved-data safety layer** once Blizzard fixes the client: delete `Persist.lua`
  and its line in the TOC, delete `tests/tests_persist.lua`, and remove the "Your data"
  paragraph and the "Known Forever client issue" section from this README. The rest of the
  add-on only reaches that module through `ns.Persist` / `ns.extra*` checks, so nothing else
  needs to change.

## License

MIT. See [LICENSE](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).
