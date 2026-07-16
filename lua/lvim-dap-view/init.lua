-- lvim-dap-view: the debugger UI for the lvim-dap engine.
-- One DOCK of tabbed panels over `lvim-ui.tabs` (provider-tab mode): Watches, Scopes, Stack,
-- Breakpoints, Exceptions, REPL, Console, Sessions. Every tree section renders through the shared
-- `lvim-ui.tree` primitive (never a hand-rolled tree); the text sections (REPL / Console) are
-- `render` providers over scrollback. The dock subscribes to the engine's listener bus — a stop,
-- a continue, output, a session change all repaint the ACTIVE panel live — and drives run control
-- through the engine's public API (the controls band + `g?` help). Nothing here re-implements the
-- protocol; it is a projection of `require("lvim-dap")` state onto lvim-ui shapes.
--
---@module "lvim-dap-view"

local config = require("lvim-dap-view.config")
local state = require("lvim-dap-view.state")
local panels = require("lvim-dap-view.panels")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

--- The engine + UI, required lazily so load order never matters.
local function dap()
    return require("lvim-dap")
end
local function ui()
    return require("lvim-ui")
end

-- ── section registry ─────────────────────────────────────────────────────────

--- Known sections: label + the tree root factory (tree sections) or a text scrollback (text
--- sections). Order here is the default; config.sections selects/orders what shows. Each entry is
--- `{ label, tree?|text?, on_activate?, on_keys?, default_expanded? }`.
---@type table<string, table>
local SECTIONS

--- Re-evaluate every watch expression on the focused session and repaint the Watches panel.
local function refresh_watches()
    local s = dap().session()
    if not s then
        return
    end
    for _, expr in ipairs(state.watches) do
        require("lvim-dap.async").run(function()
            local err, body = s:evaluate(expr, "watch")
            state.watch_results[expr] = { err = err, body = body }
            local t = state.trees.watches
            if t and t.valid and t.valid() then
                t.refresh()
            end
        end)
    end
end

--- Jump the editor to a frame and make it the session's current frame.
---@param frame table
---@param thread_id integer
local function focus_frame(frame, thread_id)
    local s = dap().session()
    if not s then
        return
    end
    s.stopped_thread_id = thread_id
    s.current_frame = frame
    require("lvim-dap.async").run(function()
        s:fetch_scopes(frame)
        dap().listeners.dispatch("after", "frame_updated", s)
    end)
end

--- Jump the editor to a breakpoint location.
---@param data { bufnr: integer, line: integer }
local function jump_to_breakpoint(data)
    local win = require("lvim-dap-view.util_win")
    win.goto_location(vim.api.nvim_buf_get_name(data.bufnr), data.line)
end

SECTIONS = {
    watches = {
        label = "Watches",
        tree = panels.watches_root,
        default_expanded = true,
        on_keys = function(map)
            map(config.keys.add_watch, function()
                ui().input({
                    title = "Watch expression",
                    callback = function(confirmed, value)
                        if confirmed and value and value ~= "" then
                            table.insert(state.watches, value)
                            refresh_watches()
                            M.refresh("watches")
                        end
                    end,
                })
            end)
            map(config.keys.delete, function()
                local t = state.trees.watches
                local node = t and t.selected()
                if node and node.data and node.data.expr then
                    for i, e in ipairs(state.watches) do
                        if e == node.data.expr then
                            table.remove(state.watches, i)
                            break
                        end
                    end
                    M.refresh("watches")
                end
            end)
        end,
    },
    scopes = {
        label = "Scopes",
        tree = panels.scopes_root,
        default_expanded = true,
        on_keys = function(map)
            map(config.keys.set_value, function()
                local t = state.trees.scopes
                local node = t and t.selected()
                if node and node.data and node.data.var then
                    M.set_variable_flow(node)
                end
            end)
        end,
    },
    stack = {
        label = "Stack",
        tree = panels.stack_root,
        default_expanded = true,
        on_activate = function(node)
            if node.kind == "frame" and node.data then
                focus_frame(node.data.frame, node.data.thread_id)
            end
        end,
    },
    breakpoints = {
        label = "Breakpoints",
        tree = panels.breakpoints_root,
        default_expanded = true,
        on_activate = function(node)
            if node.kind == "breakpoint" and node.data then
                jump_to_breakpoint(node.data)
            end
        end,
        on_keys = function(map)
            map(config.keys.delete, function()
                local t = state.trees.breakpoints
                local node = t and t.selected()
                if node and node.kind == "breakpoint" and node.data then
                    require("lvim-dap.breakpoints").remove(node.data.bufnr, node.data.line)
                    M.refresh("breakpoints")
                end
            end)
        end,
    },
    exceptions = {
        label = "Exceptions",
        tree = panels.exceptions_root,
        default_expanded = true,
        on_activate = function(node)
            if node.kind == "exception" and node.data then
                local sel = {}
                for _, f in ipairs(dap().selected_exception_filters()) do
                    sel[f] = true
                end
                sel[node.data.filter] = not sel[node.data.filter]
                dap().set_exception_breakpoints(vim.tbl_keys(sel))
                M.refresh("exceptions")
            end
        end,
    },
    repl = {
        label = "REPL",
        text = function()
            return state.repl_lines
        end,
        on_keys = function(map)
            map(config.keys.eval, function()
                ui().input({
                    title = "REPL",
                    callback = function(confirmed, value)
                        if confirmed and value and value ~= "" then
                            M.repl_eval(value)
                        end
                    end,
                })
            end)
        end,
    },
    console = {
        label = "Console",
        text = function()
            return state.console_lines
        end,
    },
    sessions = {
        label = "Sessions",
        tree = panels.sessions_root,
        default_expanded = true,
        on_activate = function(node)
            if node.kind == "session" and node.data then
                dap().set_session(node.data.session)
                M.refresh_all()
            end
        end,
    },
}

-- ── the interactive flows ─────────────────────────────────────────────────────

--- Evaluate an expression in the REPL and append the result to the scrollback.
---@param expr string
function M.repl_eval(expr)
    table.insert(state.repl_lines, "> " .. expr)
    dap().evaluate(expr, "repl", function(err, body)
        vim.schedule(function()
            if err then
                table.insert(state.repl_lines, "  ! " .. tostring(err.message))
            elseif body then
                for line in tostring(body.result):gmatch("[^\n]+") do
                    table.insert(state.repl_lines, "  " .. line)
                end
            end
            M.refresh("repl")
        end)
    end)
end

--- Prompt for a new value and setVariable on the selected node.
---@param node table
function M.set_variable_flow(node)
    local var = node.data.var
    local parent_ref = node.data.parent_ref
    ui().input({
        title = "Set " .. var.name .. " =",
        default = var.value,
        callback = function(confirmed, value)
            if not confirmed or not value then
                return
            end
            -- The container ref is the SELECTED node's parent; the tree stores it via data.ref on
            -- the parent. We evaluate through the engine's setVariable using the variable's own
            -- container (looked up from the scopes cache is complex; use the frame's evaluate as a
            -- reliable fallback: assign via `name = value` in the current frame).
            local s = dap().session()
            if s and parent_ref then
                dap().set_variable(parent_ref, var.name, value, function()
                    state.invalidate()
                    M.refresh("scopes")
                end)
            else
                dap().evaluate(var.name .. " = " .. value, "repl", function()
                    state.invalidate()
                    M.refresh("scopes")
                end)
            end
        end,
    })
end

-- ── dock construction ──────────────────────────────────────────────────────────

--- Build (once) the tree handle for a tree section, wrapping its provider.update to record the
--- active section (so refresh only ever repaints the visible tree).
---@param name string
---@param sec table
---@return table  the tree handle
local function build_tree(name, sec)
    local t = ui().tree({
        root = sec.tree,
        default_expanded = sec.default_expanded,
        filetype = "LvimDapView",
        connectors = true,
        on_activate = sec.on_activate,
        on_keys = sec.on_keys and function(map)
            sec.on_keys(map)
        end or nil,
    })
    -- Record which section owns the shared content window on each (re)layout.
    local orig_update = t.provider.update
    t.provider.update = function(pan, ...)
        state.current = name
        return orig_update(pan, ...)
    end
    return t
end

--- The provider for a text section (records active section on render, and captures its panel so the
--- section can be REPAINTED in place while it is visible — REPL output and debuggee console lines arrive
--- continuously, and without `pan.refresh()` they only appeared on the next tab switch).
---@param name string
---@param sec table
---@return table
local function text_provider(name, sec)
    local p = panels.text_provider(sec.text, " (empty)")
    local orig = p.render
    p.render = function(...)
        state.current = name
        return orig(...)
    end
    p.keys = function(_, pan)
        state.pans[name] = pan
    end
    return p
end

--- The controls footer: run-control buttons wired to the engine (clickable + hotkeys).
---@return table[]
local show_help -- forward decl (the footer chip is built before the window it opens)

local function controls()
    local d = dap()
    return {
        {
            key = "c",
            name = "continue",
            run = function()
                d.continue()
            end,
        },
        {
            key = "o",
            name = "step over",
            run = function()
                d.step_over()
            end,
        },
        {
            key = "i",
            name = "step in",
            run = function()
                d.step_into()
            end,
        },
        {
            key = "O",
            name = "step out",
            run = function()
                d.step_out()
            end,
        },
        { type = "separator" },
        {
            key = "x",
            name = "terminate",
            run = function()
                d.terminate()
            end,
        },
        { type = "separator" },
        -- The cheatsheet's key: the panel's keys are not discoverable from the tree, so the bar must show it.
        { key = config.keys.help, name = "help", no_hotkey = true, run = show_help },
    }
end

--- The cheatsheet rows: `{ key, what it does }`, from the LIVE key config (an unmapped key is skipped).
local HELP = {
    { "expand", "expand / collapse the node" },
    { "jump", "jump to the frame / breakpoint" },
    { "set_value", "set the variable's value" },
    { "copy_value", "yank the value" },
    { "add_watch", "add a watch expression" },
    { "edit", "edit the watch expression" },
    { "delete", "delete the watch / breakpoint" },
    { "eval", "evaluate an expression" },
    { "toggle_exception", "toggle the exception filter" },
    { "next_section", "next tab" },
    { "prev_section", "previous tab" },
    { "help", "this cheatsheet" },
}

--- Open the keymap cheatsheet — the shared `lvim-ui.help` component (rows / striping / colours / window).
function show_help()
    local items = {}
    local seen = {}
    for _, e in ipairs(HELP) do
        local lhs = config.keys[e[1]]
        if lhs and lhs ~= "" and not seen[lhs .. e[2]] then
            seen[lhs .. e[2]] = true
            items[#items + 1] = { lhs, e[2] }
        end
    end
    ui().help({ title = "DAP keymaps", items = items, close_keys = { "q", "<Esc>", config.keys.help } })
end

--- Open the dock. Idempotent — focuses the existing dock if already open.
---@param section? string  initial tab (name)
function M.open(section)
    if state.open and state.handle and state.handle.valid and state.handle.valid() then
        if section then
            M.focus(section)
        end
        return
    end
    state.trees = {}
    state.pans = {}
    local tabs = {}
    for _, name in ipairs(config.sections) do
        local sec = SECTIONS[name]
        if sec then
            local provider
            if sec.tree then
                local t = build_tree(name, sec)
                state.trees[name] = t
                provider = t.provider
            else
                provider = text_provider(name, sec)
            end
            tabs[#tabs + 1] = { label = sec.label, name = name, provider = provider }
        end
    end

    state.handle = ui().tabs({
        title = "Debug",
        title_line = "statusline",
        tabs = tabs,
        layout = config.layout,
        area_height = config.height,
        height = config.layout == "float" and config.height or nil,
        tab_bar = true,
        tab_selector = section or config.default_section,
        footer_hints = controls(),
        -- The cheatsheet's key, frame-wide (every tab): the panel is modal, its keys are its own.
        keymaps = { { key = config.keys.help, run = show_help } },
        on_close = function()
            state.open = false
            state.handle = nil
            state.pans = {}
        end,
    })
    state.open = state.handle ~= nil
    state.current = section or config.default_section
end

--- Close the dock.
function M.close()
    if state.handle and state.handle.valid and state.handle.valid() then
        pcall(function()
            state.handle.close()
        end)
    end
    state.open = false
    state.handle = nil
end

--- Toggle the dock.
function M.toggle()
    if state.open then
        M.close()
    else
        M.open()
    end
end

--- Focus a section tab by name.
---@param name string
function M.focus(name)
    if state.handle and state.handle.focus then
        pcall(state.handle.focus, name)
        state.current = name
    end
end

--- Repaint section `name` — but ONLY when it is the VISIBLE one.
---
--- The tabs dock is in provider mode: every section shares ONE content panel (and its buffer). A tree
--- renders into the panel it last saw, so repainting a HIDDEN section writes its lines over whatever tab
--- the user is actually looking at — which is exactly how every tab came to show the same content (a
--- `scopes` refresh landing on the Stack tab). A hidden section needs no repaint at all: switching to it
--- re-fires its provider's update, which renders it fresh from the live state.
---@param name string
function M.refresh(name)
    if not state.open or name ~= state.current then
        return
    end
    local t = state.trees[name]
    if t and t.valid and t.valid() then
        t.refresh()
        return
    end
    -- A TEXT section (REPL / Console): re-render its panel in place, so streaming output appears live.
    local pan = state.pans[name]
    if pan and pan.refresh then
        pcall(pan.refresh)
    end
end

--- Repaint whatever section is currently visible.
function M.refresh_all()
    if state.current then
        M.refresh(state.current)
    end
end

-- ── engine listeners + lifecycle ─────────────────────────────────────────────

local wired = false

--- Subscribe to the engine bus so the dock reflects the live session.
local function wire_engine()
    if wired then
        return
    end
    wired = true
    local d = dap()
    local L = d.listeners

    -- A new stop: fresh frame/scopes → drop caches, re-eval watches, repaint.
    L.after.frame_updated["lvim-dap-view"] = function()
        vim.schedule(function()
            state.invalidate()
            if config.auto_open and not state.open then
                M.open()
            end
            refresh_watches()
            M.refresh_all()
        end)
    end
    L.after.event_continued["lvim-dap-view"] = function()
        vim.schedule(M.refresh_all)
    end
    L.after.event_stopped["lvim-dap-view"] = function()
        vim.schedule(M.refresh_all)
    end
    -- Debuggee output → the Console scrollback.
    L.after.event_output["lvim-dap-view"] = function(_, body)
        if not body or not body.output then
            return
        end
        for line in tostring(body.output):gmatch("[^\n]+") do
            table.insert(state.console_lines, line)
        end
        vim.schedule(function()
            M.refresh("console")
        end)
    end
    -- Session start / end.
    L.on_session["lvim-dap-view"] = function(_, new)
        vim.schedule(function()
            if new and config.auto_open then
                M.open()
            elseif not new then
                if config.auto_close then
                    M.close()
                else
                    M.refresh_all()
                end
            end
        end)
    end
    L.after.event_terminated["lvim-dap-view"] = function()
        vim.schedule(function()
            if config.auto_close and not next(d.sessions()) then
                M.close()
            end
        end)
    end
end

-- ── command + setup ──────────────────────────────────────────────────────────

---@type table<string, fun(arg?: string)>
local COMMANDS = {
    open = function(section)
        M.open(section)
    end,
    close = M.close,
    toggle = M.toggle,
    watches = function()
        M.open("watches")
    end,
    scopes = function()
        M.open("scopes")
    end,
    stack = function()
        M.open("stack")
    end,
    breakpoints = function()
        M.open("breakpoints")
    end,
    exceptions = function()
        M.open("exceptions")
    end,
    repl = function()
        M.open("repl")
    end,
    console = function()
        M.open("console")
    end,
    sessions = function()
        M.open("sessions")
    end,
}

local function setup_command()
    vim.api.nvim_create_user_command("LvimDapView", function(cmd)
        -- A layout token (area|float|bottom) ANYWHERE overrides `config.layout` for this open — sticky for the
        -- session (the git/forge convention; config.lua is the live authority a command may override). The
        -- remaining word is the subcommand (default `toggle`). So `:LvimDapView float`, `:LvimDapView open
        -- float`, `:LvimDapView watches area` all work.
        local LAYOUTS = { area = true, float = true, bottom = true }
        local rest = {}
        for _, w in ipairs(cmd.fargs) do
            if LAYOUTS[w] then
                config.layout = w
            else
                rest[#rest + 1] = w
            end
        end
        local sub = rest[1] or "toggle"
        local fn = COMMANDS[sub]
        if fn then
            fn(rest[2])
        else
            vim.notify("lvim-dap-view: unknown subcommand " .. sub, vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        desc = "lvim-dap-view (:LvimDapView [<section>] [area|float|bottom])",
        complete = function(arg)
            local pool = vim.list_extend(vim.tbl_keys(COMMANDS), { "area", "float", "bottom" })
            return vim.tbl_filter(function(s)
                return s:find(arg, 1, true) == 1
            end, pool)
        end,
    })
end

--- Configure the view, wire it to the engine bus, and create the :LvimDapView command.
---@param opts LvimDapViewConfig?
function M.setup(opts)
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    else
        for k, v in pairs(opts or {}) do
            config[k] = v
        end
    end
    wire_engine()
    setup_command()
end

return M
