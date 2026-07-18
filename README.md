# lvim-dap-view

The debugger UI for the [lvim-dap](https://github.com/lvim-tech/lvim-dap) engine.

lvim-dap-view is a dock of tabbed panels — **Watches, Scopes, Stack, Breakpoints, Exceptions,
REPL, Console, Sessions** — rendered through the shared lvim-ui primitives (the tree panels are
built on `lvim-ui.tree`, never hand-rolled). It subscribes to the engine's listener bus, so a
stop, a step, program output, or a session change repaints the active panel live, and it drives
run control through the engine's public API (a controls band of clickable, hotkeyed buttons).

## Requirements

- Neovim >= 0.10
- [lvim-dap](https://github.com/lvim-tech/lvim-dap) (the engine)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) (tabs + tree primitives)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils)

## Installation

With the lvim-tech **lvim-installer**, or Neovim's native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-dap" },
    { src = "https://github.com/lvim-tech/lvim-dap-view" },
})
```

## Quick start

```lua
require("lvim-dap").setup()
require("lvim-dap").use("python")
require("lvim-dap-view").setup()

vim.keymap.set("n", "<F7>", require("lvim-dap-view").toggle)
```

The dock opens automatically on a session (`auto_open`) and closes when the last session ends
(`auto_close`).

## Sections

| Section     | Content | Keys |
|-------------|---------|------|
| Watches     | watch expressions → value trees | `a` add, `e` edit, `d` delete, `<CR>` expand |
| Scopes      | current frame's scopes → variables (lazy) | `<CR>` expand, `s` set value, `y` copy |
| Stack       | threads → frames (current marked `➤`) | `<CR>` focus + jump to frame |
| Breakpoints | grouped by file → lines (kind icon) | `<CR>` jump, `d` delete |
| Exceptions  | adapter filters as toggles | `<CR>` toggle |
| REPL        | evaluate scrollback | `i` prompt |
| Console     | debuggee output | scroll |
| Sessions    | session tree (parents/children) | `<CR>` focus session |

Controls band (clickable + hotkeys): continue `c`, step over `o`, step in `i`, step out `O`,
terminate `x`. `g?` shows the help window. (`i` opens the REPL eval prompt while the REPL tab is
active, and steps in on every other tab.)

**Tabs**: `]v` / `[v` cycle to the next / previous tab (wrapping), or `L` / `H` in the panel body
(upper-case), or the tab bar itself (`<C-k>` focuses it, `h`/`l` move, `<C-j>` returns). Lower-case `l`/`h`
belong to the CONTENT: they expand / collapse the tree node under the cursor — a variable's children are
fetched only when you open it (never eagerly: expanding everything recursively would walk the debuggee's
whole object graph). Panel keys are bound frame-wide and act on whichever tab is active, so every section's
keys work regardless of the tab you opened on.

## Commands

`:LvimDapView <subcommand>` — `toggle` (default), `open`, `close`, or a section name
(`watches`, `scopes`, `stack`, `breakpoints`, `exceptions`, `repl`, `console`, `sessions`)
to open the dock focused on that tab.

## Default configuration

Every option at its default value (mirrors `lua/lvim-dap-view/config.lua`):

```lua
require("lvim-dap-view").setup({
    sections = { "watches", "scopes", "stack", "breakpoints", "exceptions", "repl", "console", "sessions" },
    default_section = "scopes",
    layout = "bottom", -- bottom | area | float
    height = 14, -- docked content row budget
    auto_open = true, -- open the dock when a session starts
    auto_close = true, -- close the dock when the last session ends
    scrollback = 2000, -- max REPL / Console rows kept (0 = unlimited)
    icons = {
        scope = "",
        variable = "",
        value = "",
        thread = "",
        frame = "",
        frame_focused = "➤",
        breakpoint = "",
        breakpoint_condition = "",
        logpoint = "",
        watch = "",
        session = "",
        exception = "",
        play = "",
        pause = "",
        step_over = "",
        step_into = "",
        step_out = "",
        step_back = "",
        run_last = "",
        terminate = "",
        disconnect = "",
    },
    keys = {
        expand = "<CR>",
        set_value = "s",
        copy_value = "y",
        add_watch = "a",
        edit = "e",
        delete = "d",
        jump = "<CR>",
        toggle_exception = "<CR>",
        eval = "i",
        next_section = "]v",
        prev_section = "[v",
        help = "g?",
    },
})
```

## Health

`:checkhealth lvim-dap-view` verifies the engine and lvim-ui (tabs + tree) are present and checks
the configured section list.

## License

BSD-3-Clause. See [LICENSE](./LICENSE).
