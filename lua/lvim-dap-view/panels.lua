-- lvim-dap-view.panels: turn live engine state into the per-section content providers.
-- Every tree section (Scopes / Stack / Breakpoints / Watches / Sessions / Exceptions) is a
-- `lvim-ui.tree` handle whose `root` is a FACTORY reading the engine on each render — so a repaint
-- always reflects the current session. Variable expansion is the lazy-tree pattern the primitive is
-- built for: a variable's children function returns cached children if present, else fires an async
-- `variables` request that fills the cache and calls `refresh()` — the tree never blocks on a DAP
-- round-trip. The text sections (REPL / Console) are simple `render` providers over scrollback.
-- Nothing here talks to the surface directly; it only builds nodes + providers the dock hosts.
--
---@module "lvim-dap-view.panels"

local config = require("lvim-dap-view.config")
local state = require("lvim-dap-view.state")

local M = {}

--- The engine (lazily; the view never hard-depends on a load order).
---@return table
local function dap()
    return require("lvim-dap")
end

--- Build tree nodes for a list of DAP variables (lazy children for expandable ones).
---@param vars table[]
---@param path string  a stable id prefix
---@param parent_ref integer  the variablesReference these variables were fetched from (for setVariable)
---@param owner string  the section that owns this subtree ("scopes"|"watches") — threaded so a lazy fetch
---  refreshes the RIGHT tab (both Scopes and Watches expand variables through this same code)
---@return LvimUiTreeNode[]
local function variable_nodes(vars, path, parent_ref, owner)
    local nodes = {}
    for i, v in ipairs(vars) do
        local id = path .. "/" .. (v.name or tostring(i))
        local ref = v.variablesReference or 0
        ---@type LvimUiTreeNode
        local node = {
            id = id,
            label = v.name or "?",
            icon = config.icons.variable,
            icon_hl = "LvimUiTreeFold",
            label_hl = "Identifier",
            detail = v.value and (" = " .. tostring(v.value):gsub("\n", " ")) or nil,
            kind = "variable",
            expandable = ref > 0,
            data = { var = v, ref = ref, parent_ref = parent_ref },
        }
        if ref > 0 then
            node.children = function()
                return M.child_nodes(ref, id, owner)
            end
        end
        nodes[#nodes + 1] = node
    end
    return nodes
end

--- Lazy children for a variablesReference: cached, else kick off a fetch + refresh of the OWNING section.
--- The completion routes through the dock's guarded `refresh(owner)` (a no-op for a hidden tab, correct
--- tree otherwise) — hard-coding `state.trees.scopes` here painted a Watches expansion onto the Scopes tab.
---@param ref integer
---@param path string
---@param owner string  the owning section ("scopes"|"watches")
---@return LvimUiTreeNode[]
function M.child_nodes(ref, path, owner)
    local cached = state.var_cache[ref]
    if cached then
        return variable_nodes(cached, path, ref, owner)
    end
    local s = dap().session()
    if not s then
        return {}
    end
    -- Fire once; the refresh re-enters this function with the cache populated.
    require("lvim-dap.async").run(function()
        local vars = s:fetch_variables(ref) or {}
        state.var_cache[ref] = vars
        require("lvim-dap-view").refresh(owner)
    end)
    return { { id = path .. "/__loading", label = "loading…", icon = "", label_hl = "Comment" } }
end

--- Scopes section: the current frame's scopes → variables tree.
---@return LvimUiTreeNode[]
function M.scopes_root()
    local s = dap().session()
    local frame = s and s.current_frame
    if not frame then
        return {}
    end
    local nodes = {}
    for _, sc in ipairs(frame.scopes or {}) do
        local ref = sc.variablesReference or 0
        nodes[#nodes + 1] = {
            id = "scope/" .. sc.name,
            label = sc.name,
            icon = config.icons.scope,
            icon_hl = "LvimUiTreeFold",
            label_hl = "Title",
            expandable = ref > 0,
            kind = "scope",
            children = ref > 0 and function()
                return M.child_nodes(ref, "scope/" .. sc.name, "scopes")
            end or nil,
        }
    end
    return nodes
end

--- Stack section: threads → frames (stopped thread expanded, current frame marked).
---@return LvimUiTreeNode[]
function M.stack_root()
    local s = dap().session()
    if not s then
        return {}
    end
    local nodes = {}
    local tids = vim.tbl_keys(s.threads)
    table.sort(tids)
    for _, tid in ipairs(tids) do
        local th = s.threads[tid]
        local frame_nodes = {}
        for _, f in ipairs(th.frames or {}) do
            local focused = s.current_frame and s.current_frame.id == f.id
            local src = f.source and (f.source.name or f.source.path) or ""
            frame_nodes[#frame_nodes + 1] = {
                id = "frame/" .. tid .. "/" .. f.id,
                label = f.name,
                icon = focused and config.icons.frame_focused or config.icons.frame,
                icon_hl = focused and "LvimDapStopped" or "LvimUiTreeFold",
                label_hl = focused and "Title" or "Normal",
                detail = src ~= "" and ("  " .. vim.fn.fnamemodify(src, ":t") .. ":" .. (f.line or "?")) or nil,
                kind = "frame",
                data = { frame = f, thread_id = tid },
            }
        end
        nodes[#nodes + 1] = {
            id = "thread/" .. tid,
            label = th.name or ("Thread " .. tid),
            icon = config.icons.thread,
            icon_hl = "Function",
            label_hl = th.stopped and "Title" or "Comment",
            detail = th.stopped and "  (stopped)" or nil,
            expandable = #frame_nodes > 0,
            children = frame_nodes,
            kind = "thread",
        }
    end
    return nodes
end

--- Breakpoints section: grouped by file → line entries.
---@return LvimUiTreeNode[]
function M.breakpoints_root()
    local bpmod = require("lvim-dap.breakpoints")
    local nodes = {}
    for bufnr, list in pairs(bpmod.get()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        local children = {}
        for _, bp in ipairs(list) do
            local icon = config.icons.breakpoint
            local ihl = "LvimDapBreakpoint"
            if bp.logMessage then
                icon, ihl = config.icons.logpoint, "LvimDapLogPoint"
            elseif bp.condition then
                icon, ihl = config.icons.breakpoint_condition, "LvimDapBreakpointCondition"
            end
            if bp.verified == false then
                ihl = "LvimDapBreakpointRejected"
            end
            local line_txt = (vim.api.nvim_buf_get_lines(bufnr, bp.line - 1, bp.line, false)[1] or ""):gsub("^%s+", "")
            children[#children + 1] = {
                id = ("bp/%d/%d"):format(bufnr, bp.line),
                label = tostring(bp.line),
                icon = icon,
                icon_hl = ihl,
                label_hl = "LineNr",
                detail = "  " .. line_txt .. (bp.condition and ("  [" .. bp.condition .. "]") or ""),
                kind = "breakpoint",
                data = { bufnr = bufnr, line = bp.line, bp = bp },
            }
        end
        nodes[#nodes + 1] = {
            id = "bpfile/" .. bufnr,
            label = vim.fn.fnamemodify(name, ":t"),
            icon = "",
            icon_hl = "Directory",
            label_hl = "Directory",
            detail = "  " .. vim.fn.fnamemodify(name, ":~:."),
            expandable = #children > 0,
            children = children,
            kind = "bpfile",
        }
    end
    return nodes
end

--- Watches section: user expressions → evaluate result trees.
---@return LvimUiTreeNode[]
function M.watches_root()
    local nodes = {}
    for _, expr in ipairs(state.watches) do
        local res = state.watch_results[expr]
        local body = res and res.body
        local errm = res and res.err
        local ref = body and body.variablesReference or 0
        nodes[#nodes + 1] = {
            id = "watch/" .. expr,
            label = expr,
            icon = config.icons.watch,
            icon_hl = "LvimUiTreeFold",
            label_hl = "Identifier",
            detail = errm and ("  = <error> " .. tostring(errm))
                or (body and ("  = " .. tostring(body.result)) or "  = …"),
            expandable = ref > 0,
            kind = "watch",
            data = { expr = expr },
            children = ref > 0 and function()
                return M.child_nodes(ref, "watch/" .. expr, "watches")
            end or nil,
        }
    end
    if #nodes == 0 then
        nodes[1] = { id = "watch/__empty", label = "no watches — press a to add", icon = "", label_hl = "Comment" }
    end
    return nodes
end

--- Exceptions section: the adapter's filters as toggle rows.
---@return LvimUiTreeNode[]
function M.exceptions_root()
    local d = dap()
    local filters = d.exception_filters()
    local selected = {}
    for _, f in ipairs(d.selected_exception_filters()) do
        selected[f] = true
    end
    local nodes = {}
    for _, f in ipairs(filters) do
        local on = selected[f.filter]
        nodes[#nodes + 1] = {
            id = "exc/" .. f.filter,
            label = f.label or f.filter,
            icon = on and "" or "",
            icon_hl = on and "LvimDapStopped" or "Comment",
            label_hl = on and "Normal" or "Comment",
            detail = f.description and ("  " .. f.description) or nil,
            kind = "exception",
            data = { filter = f.filter, on = on },
        }
    end
    if #nodes == 0 then
        nodes[1] =
            { id = "exc/__none", label = "no exception filters (start a session)", icon = "", label_hl = "Comment" }
    end
    return nodes
end

--- Sessions section: root sessions → child sessions.
---@return LvimUiTreeNode[]
function M.sessions_root()
    local d = dap()
    local focused = d.session()
    local function node_for(s)
        local is_focus = focused and focused.id == s.id
        local kids = {}
        for _, child in pairs(s.children or {}) do
            kids[#kids + 1] = node_for(child)
        end
        local st = s.stopped_thread_id and "stopped" or (s.initialized and "running" or "starting")
        return {
            id = "sess/" .. s.id,
            label = (s.config and s.config.name or ("session " .. s.id)),
            icon = config.icons.session,
            icon_hl = is_focus and "LvimDapStopped" or "Function",
            label_hl = is_focus and "Title" or "Normal",
            detail = "  (" .. st .. (is_focus and ", focused)" or ")"),
            expandable = #kids > 0,
            children = kids,
            kind = "session",
            data = { session = s },
        }
    end
    local nodes = {}
    for _, s in pairs(d.sessions()) do
        nodes[#nodes + 1] = node_for(s)
    end
    if #nodes == 0 then
        nodes[1] = { id = "sess/__none", label = "no active sessions", icon = "", label_hl = "Comment" }
    end
    return nodes
end

--- A text `render` provider over a scrollback table (REPL / Console).
---@param lines_fn fun(): string[]
---@param empty string
---@return table  a surface content provider
function M.text_provider(lines_fn, empty)
    return {
        render = function()
            local lines = lines_fn()
            if #lines == 0 then
                return { empty }, {}
            end
            return lines, {}
        end,
    }
end

return M
