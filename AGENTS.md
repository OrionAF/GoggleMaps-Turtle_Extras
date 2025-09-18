## What this is
- A World of Warcraft **1.12.1** addon for **Turtle WoW (TWOW)**.
- A companion addon for **GoggleMaps**(https://github.com/spawnedc/goggle-maps) abd **GoggleMaps-Turtle**(https://github.com/spawnedc/goggle-maps-turtle)
- Code is **Lua 5.0** (not 5.1/5.2).
- UI is **FrameXML (XML + Lua)** with the 1.12 event model.

References (read-only):
- TWOW globals dump: https://pastes.io/turtle-new-lua-global-space-dump
- 1.12 UI source mirror: https://github.com/refaim/Turtle-WoW-UI-Source

## Non-negotiable constraints
- Target **Lua 5.0**: no `string.gmatch`, no `table.unpack`, no `goto`, no `_ENV`.
- Target **WoW 1.12**: events use `event` + `arg1..argN`; `this` can be the frame; many retail APIs don’t exist.
- No “secure” templates, no mixins, no retail `C_*` APIs.
- Must run with `/console scriptErrors 1` without errors on two consecutive `/reload`.

## Repo expectations (keep it lean)
- `GoggleMaps-Turtle_Extras.toc` — manifest
- `Extras.lua` — main file
- `data/Map.Hotspots.lua` — optional shims for 1.12/Lua 5.0

If a file doesn’t exist, don’t create architecture for its own sake. Ask or stub.

## “Do / Don’t”
- DO: write 1.12/Lua 5.0-compatible code; keep diffs small; comment why, not what.
- DO: degrade gracefully if a function is nil (older client quirk).
- DO: familiarize yourself with the parent addons before writing any code.
- DON’T: add libraries that need Lua 5.1+; don’t add retail-era helpers; don’t rename XML frames casually.
- DON'T: assume the functionality of something without asking the user first.
