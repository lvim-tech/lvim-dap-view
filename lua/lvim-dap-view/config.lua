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
---@field value    string
---@field thread   string
---@field frame    string
---@field frame_focused string
---@field breakpoint string
---@field breakpoint_condition string
---@field logpoint string
---@field watch    string
---@field session  string
---@field exception string
---@field play     string
---@field pause    string
---@field step_over string
---@field step_into string
---@field step_out string
---@field step_back string
---@field run_last string
---@field terminate string
---@field disconnect string

---@class LvimDapViewConfig
---@field sections  string[]      which tabs to show, left→right (subset of the known sections)
---@field default_section string  the tab focused on open
---@field layout    "bottom"|"area"|"float"  the dock layout (per the panel canon)
---@field height    number        docked content row budget (absolute rows) for bottom/area
---@field auto_open boolean       open the dock automatically when a session starts
---@field auto_close boolean      close the dock automatically when the last session ends
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
}
