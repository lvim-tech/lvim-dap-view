-- lvim-dap-view: :checkhealth lvim-dap-view.
-- The UI is a projection of the lvim-dap engine through lvim-ui; if either is missing the dock
-- cannot render, so those are the headline checks, plus a sanity pass over the configured section
-- list (an unknown section name is silently dropped otherwise). Read-only.
--
---@module "lvim-dap-view.health"

local config = require("lvim-dap-view.config")

local M = {}

--- The sections the view knows how to render.
local KNOWN = {
    watches = true,
    scopes = true,
    stack = true,
    breakpoints = true,
    exceptions = true,
    repl = true,
    console = true,
    sessions = true,
}

function M.check()
    local health = vim.health
    health.start("lvim-dap-view")

    local ok_dap = pcall(require, "lvim-dap")
    if ok_dap then
        health.ok("lvim-dap engine found")
    else
        health.error("lvim-dap not found — the view has no engine to project (install lvim-dap)")
    end

    local ok_ui, ui = pcall(require, "lvim-ui")
    if ok_ui and type(ui.tree) == "function" and type(ui.tabs) == "function" then
        health.ok("lvim-ui found (tabs + tree primitives)")
    else
        health.error("lvim-ui (with tabs + tree) not found — the dock cannot render")
    end

    local unknown = {}
    for _, s in ipairs(config.sections or {}) do
        if not KNOWN[s] then
            unknown[#unknown + 1] = s
        end
    end
    if #unknown > 0 then
        health.warn("unknown section(s) in config.sections (ignored): " .. table.concat(unknown, ", "))
    else
        health.ok(("%d section(s) configured: %s"):format(#config.sections, table.concat(config.sections, ", ")))
    end

    health.info(
        ("layout=%s  height=%d  auto_open=%s  auto_close=%s  scrollback=%d"):format(
            config.layout,
            config.height,
            tostring(config.auto_open),
            tostring(config.auto_close),
            config.scrollback
        )
    )
end

return M
