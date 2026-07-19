-- lvim-dap-view.config: the live configuration table.
-- setup() merges user overrides in place (via lvim-utils.utils.merge), so every
-- require("lvim-dap-view.config") reader sees the effective values. The view is a dock of tabbed
-- panels over the lvim-dap engine; what is configurable is which sections show and in what order,
-- where/how big the dock opens, whether it auto-opens on a session, and the per-section icons.
--
---@module "lvim-dap-view.config"

---@class LvimDapViewIcons
---@field scope    string
---@field variable string
---@field thread   string
---@field frame    string
---@field frame_focused string
---@field breakpoint string
---@field breakpoint_condition string
---@field logpoint string
---@field watch    string
---@field session  string

---@class LvimDapViewConfig
---@field sections  string[]      which tabs to show, left→right (subset of the known sections)
---@field default_section string  the tab focused on open
---@field layout    "bottom"|"area"|"float"  the dock layout (per the panel canon)
---@field height    number        docked content row budget (absolute rows) for bottom/area
---@field auto_open boolean       open the dock automatically when a session starts
---@field auto_close boolean      close the dock automatically when the last session ends
---@field scrollback integer      max REPL / Console rows kept (0 = unlimited); older rows are dropped
---@field icons     LvimDapViewIcons
---@field keys      table<string, string>  panel-local action keys

---@type LvimDapViewConfig
return {
    sections = { "watches", "scopes", "stack", "breakpoints", "exceptions", "repl", "console", "sessions" },
    default_section = "scopes",
    layout = "bottom",
    height = 14,
    auto_open = true,
    auto_close = true,
    scrollback = 2000,
    icons = {
        scope = "",
        variable = "",
        thread = "",
        frame = "",
        frame_focused = "➤",
        breakpoint = "\u{f111}", -- kept in step with lvim-dap's gutter signs (they were EMPTY)
        breakpoint_condition = "\u{f192}",
        logpoint = "",
        watch = "",
        session = "",
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
}
