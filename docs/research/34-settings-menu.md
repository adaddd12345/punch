# 34 · The settings menu (gear) and the right-click menu

## How Apple stacks settings in menus
- Menus are for commands and simple state, not configuration surfaces. Keep the top level short and
  scannable (Apple's own menu-bar extras show roughly 8–12 rows), grouped by separators into related sets.
- Submenus: use for a related set of items, keep them one level deep; deep nesting is hard to
  navigate and hides items. A picker becomes a submenu of checkmarked choices (or an inline section).
- Verbs for commands ("Check for Updates…", "Export Presets…"); a checkmark for on/off state; an
  ellipsis only when the item opens something that needs more input before it acts.
- Titles: short, title case, no sentences; a parenthetical hint only when the name alone is opaque.
- Don't dim-and-hide churn: show items consistently, disable (not remove) what can't be used now.
- Menu-bar extras (Wi-Fi, Bluetooth, Sound in Control Center) end with "… Settings…" and keep
  configuration out of the menu; System Settings groups many settings into a few sidebar categories.
- Order: most-used first, app-level (Updates, About, Quit) last, Quit at the very bottom.

Sources: Apple HIG, *Menus* and *The menu bar* (developer.apple.com/design/human-interface-guidelines/menus,
/the-menu-bar), HIG *Pop-up buttons* and *Toggles*; macOS 26 Control Center modules (Wi-Fi, Sound, Bluetooth).

## What made it glitchy (evidence → fix)
- **Open at Login lied.** The popover cached it in a `@State` set once at launch; the right-click menu
  (or System Settings) changed it underneath, so the gear's checkmark was stale and clicking it "did
  nothing" (it set the value it already had). → `LoginItemState` (LoginItem.swift): re-read after
  every `LoginItem.set` and on app activation; both menus follow it.
- **Panels fought the tray.** Items that open a panel (Hearing Fit, My Sounds, Mic Test, Latency Lab,
  Connect Another Mac, Edit Layout) left the Live / DJ / Beats tray (a separate window, LiveDrawer)
  standing beside an unrelated panel, and four of them (Hearing Fit, Mic Test, Latency Lab, Old
  Drivers) didn't end rearranging, so Esc stayed swallowed by Reshuffle. → one `open(_:)` in
  PopoverView for every menu item: tray shut, rearranging ended, then the panel.
- **The whole menu was an inline closure in PopoverView** (~200 lines, ~80 items) rebuilt with every
  popover re-render and every footer hover/press state change while open. → `SettingsMenuContent`
  (SettingsMenu.swift), its own view taking the controller, `Updates` and one `Binding<SettingsPanel?>`.
- **Two "Check Automatically" items** (Check & Fix after sleep vs. Sparkle updates) in different places.
  → renamed "Check & Fix After Sleep" and "Check for Updates Automatically".

## Inventory: before → after (gear menu, this Mac)
| Before (22 top-level rows) | After | Note |
|---|---|---|
| Check & Fix Sound Issues | removed from gear | The footer button right beside the gear, and the right-click menu, do it |
| Check Automatically After Sleep | Devices › Check & Fix After Sleep | Renamed (clashed with update checks) |
| Ear Protector, Fair Level, Center Lock ›, Studio Ears (was in Presets & Settings), Sound Like › | Sound › | Sound features together; Studio Ears was misfiled |
| Hearing Fit…, Hearing Fit On, Remove Hearing Fit | Sound › Hearing Fit…, Use Hearing Fit, Remove Hearing Fit | |
| Lights Out › | Lights Out › | Unchanged |
| Sound › (HQ Guard, Remember per Device, No Processing on X, Quiet Floor for X, Balance Lock, Microphone ›, Mic Test…, Latency Lab…, Find Old Audio Drivers…) | Devices › | Renamed: it was devices, not sound; per-output items in a section named after the output |
| Look › (13 items, incl. Dock/menu-bar switches) | Look › (background, tiles, EQ visual, artwork, Fade, Power Saver) | Dock and menu-bar switches moved to Layout |
| Show in Dock, Header When Opened from Dock, Show in Menu Bar, Volume on Menu Bar Icon | Layout › Dock & Menu Bar | |
| Presets & Settings › Edit Layout… | Layout › Edit Layout… | |
| Presets & Settings › Show Mac Volume, Show Live Time | removed from menu | Duplicates: Edit Layout shows/hides both tiles (same settings) |
| Presets & Settings › Power Saver | Look › Power Saver | Drawing only |
| Presets & Settings › Show What's Playing, Song & Video Details, App Details ›, Show Playing App in Mini, Pause Any App with Media Keys | What's Playing › | One feature, one submenu |
| Presets & Settings › Tutorial Mode | Help › Tutorial Mode | |
| Presets & Settings › My Sounds…, Undo Sound Change | Sound › | |
| Presets & Settings › Export / Import Presets…, Reset All Settings… | General › | |
| Shortcuts › (A/B Hotkey, Open/Close Anywhere, conflict) | General › | |
| Update Options › (Check / Install Automatically), Open at Login | General › | Login now always current |
| Connect Another Mac…, Check for Updates…, Help ›, About, Quit | same | Help also holds Tutorial Mode |

**After (12 rows):** Sound › · Devices › · Lights Out › · Look › · Layout › · What's Playing › · General › |
Connect Another Mac… | Check for Updates… · Help › · About | Quit. Only two levels anywhere: Sound Like ›,
App Details ›, Microphone › and Ticker › (pickers that can't be inline). No saved setting was removed.

**Controlling another Mac:** same items as before, now from `RemoteSettingsMenuContent`; its sound
switches are the shared `SoundFeatureItems`, so the two menus can't drift.

**Right-click / Dock menu (BassShakeApp.buildMenu):** kept as is. It is already the quick-actions menu
(Open, Check & Fix, On, A/B, Preset ›, Output ›, Lights Out ›, Mute, Pin, App Icon ›, Login, Updates,
About, Help, Quit, Force Quit) with no configuration; its Open at Login now stays in step with the gear's.
