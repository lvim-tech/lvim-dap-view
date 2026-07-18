-- lvim-dap-view: the debugger UI for the lvim-dap engine.
-- One DOCK of tabbed panels over `lvim-ui.tabs` (provider-tab mode): Watches, Scopes, Stack,
-- Breakpoints, Exceptions, REPL, Console, Sessions. Every tree section renders through the shared
-- `lvim-ui.tree` primitive (never a hand-rolled tree); the text sections (REPL / Console) are
-- `render` providers over scrollback. The dock subscribes to the engine's listener bus — a stop,
-- a continue, output, a session change all repaint the ACTIVE panel live — and drives run control
-- through the engine's public API (the controls band + `g?` help). Nothing here re-implements the
-- protocol; it is a projection of `require("lvim-dap")` state onto lvim-ui shapes.
--
-- Panel keys are FRAME-WIDE (`ui.tabs { keymaps = … }`), dispatched by the ACTIVE section — NOT per-tab
-- `on_keys`. A provider-tab dock shares ONE content window across every tab, so a buffer-local map (what
-- `on_keys` installs) is only ever wired for the tab focused at OPEN — the other tabs' keys stay dead.
-- Frame-wide keymaps are bound once on the shared buffer and work on every tab; `state.current` (the
-- active section, tracked by each provider's render/update wrapper) routes each key to the right handler.
-- This is the canonical shared-panel pattern (lvim-git status, lvim-term both drive their provider docks
-- the same way), and the SINGLE `ACTIONS` table below feeds BOTH the keymaps AND the `g?` cheatsheet, so a
-- key can never be advertised without a handler.
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

--- Cap a scrollback table at `config.scrollback`, compacting the oldest entries when it grows past ~2× the
--- cap so the trim amortises to O(1) per append (a chatty debuggee must not grow the table — or the repaint
--- cost — without bound). A non-positive cap disables the limit.
---@param lines string[]
local function trim_scrollback(lines)
    local cap = config.scrollback
    if type(cap) ~= "number" or cap <= 0 or #lines <= cap * 2 then
        return
    end
    local drop = #lines - cap
    table.move(lines, drop + 1, #lines, 1) -- shift the kept tail to the front
    for i = #lines, cap + 1, -1 do
        lines[i] = nil
    end
end

-- ── section registry ─────────────────────────────────────────────────────────

--- Known sections: label + the tree root factory (tree sections) or a text scrollback (text sections).
--- Order here is the default; `config.sections` selects/orders what shows. Each entry is
--- `{ label, tree?|text?, on_activate?, default_expanded? }`. Panel KEYS are not here — they live in
--- `ACTIONS` (frame-wide, dispatched by the active section); `on_activate` is the tree's `<CR>` on a leaf.
---@type table<string, table>
local SECTIONS

--- Re-evaluate every watch expression on the focused session and repaint the Watches panel.
--- One coroutine for the whole batch (not one per watch): the evaluates run in order, and the tab repaints
--- exactly ONCE when they are all in — N watches used to spawn N coroutines and N tree refreshes per stop.
local function refresh_watches()
    local s = dap().session()
    if not s or #state.watches == 0 then
        return
    end
    require("lvim-dap.async").run(function()
        for _, expr in ipairs(state.watches) do
            local err, body = s:evaluate(expr, "watch")
            state.watch_results[expr] = { err = err, body = body }
        end
        M.refresh("watches")
    end)
end

--- Jump the editor to a frame and make it the session's current frame — but ONLY for a thread that is
--- actually stopped. The Stack tree renders every thread and keeps each stopped thread's frames until it
--- continues; activating a RUNNING thread's stale frame would mark it as the stopped thread, so the next
--- `continue`/`step` would resolve to a thread that is not paused (adapter errors) and the engine would
--- report the session stopped on the wrong thread.
---@param frame table
---@param thread_id integer
local function focus_frame(frame, thread_id)
    local s = dap().session()
    if not s then
        return
    end
    local th = s.threads[thread_id]
    if not (th and th.stopped) then
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
    },
    scopes = {
        label = "Scopes",
        tree = panels.scopes_root,
        default_expanded = true,
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
    },
    console = {
        label = "Console",
        -- The carried partial (text after the last newline of the last output event, not yet a full line)
        -- shows as a PROVISIONAL final row so a `write()` without a trailing newline still tails live.
        text = function()
            if state.console_partial ~= "" then
                local out = vim.list_extend({}, state.console_lines)
                out[#out + 1] = state.console_partial
                return out
            end
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
                -- vim.split (not gmatch "[^\n]+") so blank lines in the result are preserved.
                for _, line in ipairs(vim.split(tostring(body.result), "\n", { plain = true })) do
                    table.insert(state.repl_lines, "  " .. line)
                end
            end
            trim_scrollback(state.repl_lines)
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
            -- The container ref is the SELECTED node's parent; setVariable needs it. When we have it, use
            -- the engine's setVariable; otherwise fall back to assigning `name = value` in the current frame.
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

-- ── panel actions (single source: keymaps AND the cheatsheet) ──────────────────

--- The tree node under the cursor in the ACTIVE section (nil if that section has no tree / no selection).
---@return table?
local function selected()
    local t = state.trees[state.current or ""]
    return t and t.selected and t.selected() or nil
end

--- Expand/collapse or activate the node under the cursor in the ACTIVE tree (the `<CR>` / `l` seam). A leaf
--- with an `on_activate` (a stack frame, a breakpoint, an exception filter, a session) is activated.
local function nav_activate()
    local t = state.trees[state.current or ""]
    if t and t.valid and t.valid() then
        t.expand_or_activate()
    end
end

--- Collapse the node under the cursor (or hop to its parent) in the ACTIVE tree (the `h` seam).
local function nav_collapse()
    local t = state.trees[state.current or ""]
    if t and t.valid and t.valid() then
        t.collapse_or_parent()
    end
end

--- Copy a variable/watch value to the unnamed + system clipboard registers.
---@param node table?
local function copy_value(node)
    if not (node and node.data) then
        return
    end
    local v
    if node.data.var then
        v = node.data.var.value
    elseif node.kind == "watch" then
        local res = state.watch_results[node.data.expr]
        v = res and res.body and res.body.result
    end
    if not v or v == "" then
        vim.notify("lvim-dap-view: nothing to copy", vim.log.levels.INFO)
        return
    end
    v = tostring(v)
    vim.fn.setreg('"', v)
    vim.fn.setreg("+", v)
    vim.notify("lvim-dap-view: yanked " .. v, vim.log.levels.INFO)
end

--- Every panel action in ONE place — the keymaps AND the `g?` cheatsheet both derive from this list, so a
--- key can never be advertised without a handler (the drift that had left `copy_value`/`edit`/`]v`/`[v`
--- dead). An entry with `run` + `sections` is a letter action, fired only while the active section is one
--- of `sections`; `nav` entries drive the tab-cycle handle methods; the rest (`expand`/`jump`/
--- `toggle_exception`/`help`) are wired by the tree nav / the frame keymaps below and appear in the
--- cheatsheet for discoverability.
---@class LvimDapViewAction
---@field name string        the `config.keys` id (its lhs is `config.keys[name]`)
---@field desc string        the cheatsheet description
---@field sections? string[] sections whose active state enables this action's `run`
---@field run? fun()         the handler (reads the active section's selection)
---@field fallback? fun()    what the key does OUTSIDE its `sections` (a key shared with a run-control)
---@field nav? "next"|"prev" cycle to the next / previous tab
---@type LvimDapViewAction[]
local ACTIONS = {
    { name = "expand", desc = "expand / collapse the node" },
    { name = "jump", desc = "jump to the frame / breakpoint" },
    {
        name = "set_value",
        desc = "set the variable's value",
        sections = { "scopes" },
        run = function()
            local node = selected()
            if node and node.data and node.data.var then
                M.set_variable_flow(node)
            end
        end,
    },
    {
        name = "copy_value",
        desc = "yank the value",
        sections = { "scopes", "watches" },
        run = function()
            copy_value(selected())
        end,
    },
    {
        name = "add_watch",
        desc = "add a watch expression",
        sections = { "watches" },
        run = function()
            ui().input({
                title = "Watch expression",
                callback = function(confirmed, value)
                    if not (confirmed and value and value ~= "") then
                        return
                    end
                    if vim.tbl_contains(state.watches, value) then
                        vim.notify("lvim-dap-view: watch already exists: " .. value, vim.log.levels.WARN)
                        return
                    end
                    table.insert(state.watches, value)
                    refresh_watches()
                    M.refresh("watches")
                end,
            })
        end,
    },
    {
        name = "edit",
        desc = "edit the watch expression",
        sections = { "watches" },
        run = function()
            local node = selected()
            if not (node and node.kind == "watch" and node.data and node.data.expr) then
                return
            end
            local old = node.data.expr
            ui().input({
                title = "Edit watch",
                default = old,
                callback = function(confirmed, value)
                    if not confirmed or not value or value == "" or value == old then
                        return
                    end
                    if vim.tbl_contains(state.watches, value) then
                        vim.notify("lvim-dap-view: watch already exists: " .. value, vim.log.levels.WARN)
                        return
                    end
                    for i, e in ipairs(state.watches) do
                        if e == old then
                            state.watches[i] = value
                            break
                        end
                    end
                    state.watch_results[old] = nil
                    refresh_watches()
                    M.refresh("watches")
                end,
            })
        end,
    },
    {
        name = "delete",
        desc = "delete the watch / breakpoint",
        sections = { "watches", "breakpoints" },
        run = function()
            local node = selected()
            if not (node and node.data) then
                return
            end
            if state.current == "watches" and node.data.expr then
                for i, e in ipairs(state.watches) do
                    if e == node.data.expr then
                        table.remove(state.watches, i)
                        break
                    end
                end
                state.watch_results[node.data.expr] = nil
                M.refresh("watches")
            elseif state.current == "breakpoints" and node.kind == "breakpoint" then
                require("lvim-dap.breakpoints").remove(node.data.bufnr, node.data.line)
                M.refresh("breakpoints")
            end
        end,
    },
    {
        name = "eval",
        desc = "evaluate an expression (REPL) / step in",
        sections = { "repl" },
        run = function()
            ui().input({
                title = "REPL",
                callback = function(confirmed, value)
                    if confirmed and value and value ~= "" then
                        M.repl_eval(value)
                    end
                end,
            })
        end,
        -- `i` is also the step-in run-control; on the REPL tab it opens the eval prompt, everywhere else it
        -- steps in (the controls chip is `no_hotkey`, so this single keymap owns `i` — no double binding).
        fallback = function()
            dap().step_into()
        end,
    },
    { name = "toggle_exception", desc = "toggle the exception filter" },
    { name = "next_section", desc = "next tab", nav = "next" },
    { name = "prev_section", desc = "previous tab", nav = "prev" },
    { name = "help", desc = "this cheatsheet" },
}

-- ── dock construction ──────────────────────────────────────────────────────────

--- Build (once) the tree handle for a tree section, wrapping its provider.update to record the active
--- section (so refresh only ever repaints the visible tree). `keys = false` disables the tree's own
--- `l`/`h`/`<CR>` binding — the dock binds those FRAME-WIDE (dispatched to the active tree), the single
--- key-binding path for a shared-panel dock.
---@param name string
---@param sec table
---@return table  the tree handle
local function build_tree(name, sec)
    local t = ui().tree({
        root = sec.tree,
        default_expanded = sec.default_expanded,
        filetype = "LvimDapView",
        connectors = true,
        keys = false,
        on_activate = sec.on_activate,
    })
    -- Record which section owns the shared content window on each (re)layout.
    local orig_update = t.provider.update
    t.provider.update = function(pan, ...)
        state.current = name
        return orig_update(pan, ...)
    end
    return t
end

--- The provider for a text section, recording the active section on render (so `M.refresh` knows which tab
--- is visible; the repaint itself goes through the tabs handle's `refresh_content`).
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
            -- `i` is owned by the frame keymap (eval on the REPL tab, step-in elsewhere); this chip is the
            -- clickable label + hotkey hint only, so it must NOT bind `i` again (that would shadow eval).
            key = "i",
            name = "step in",
            no_hotkey = true,
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

--- Open the keymap cheatsheet — the shared `lvim-ui.help` component. Rows come from the LIVE `ACTIONS`
--- (deduped by key + description), so the cheatsheet and the wired keys cannot diverge.
function show_help()
    local items = {}
    local seen = {}
    for _, a in ipairs(ACTIONS) do
        local lhs = config.keys[a.name]
        if lhs and lhs ~= "" then
            local id = lhs .. "\0" .. a.desc
            if not seen[id] then
                seen[id] = true
                items[#items + 1] = { lhs, a.desc }
            end
        end
    end
    ui().help({ title = "DAP keymaps", items = items, close_keys = { "q", "<Esc>", config.keys.help } })
end

--- The frame-wide panel keymaps: navigation (the active tree's fold/activate) + the `ACTIONS` letter keys
--- (gated by the active section) + the tab-cycle keys + `g?`. Bound ONCE on the shared dock buffer; each
--- routes by `state.current`, so every tab's keys work (a per-tab `on_keys` would wire only the tab open).
---@return table[]
local function build_keymaps()
    local km = {}
    local seen = {}
    local function add(lhs, fn)
        if lhs and lhs ~= "" and not seen[lhs] then
            seen[lhs] = true
            km[#km + 1] = { key = lhs, run = fn }
        end
    end
    -- Tree navigation on the active section (README documents lower-case l/h as expand/collapse).
    add(config.keys.expand, nav_activate)
    add("l", nav_activate)
    add("h", nav_collapse)
    for _, a in ipairs(ACTIONS) do
        if a.run and a.sections then
            local sections = a.sections
            local run = a.run ---@type fun()
            local fallback = a.fallback
            add(config.keys[a.name], function()
                if vim.tbl_contains(sections, state.current) then
                    run()
                elseif fallback then
                    fallback()
                end
            end)
        elseif a.nav == "next" then
            add(config.keys[a.name], function()
                if state.handle and state.handle.next_tab then
                    state.handle.next_tab()
                end
            end)
        elseif a.nav == "prev" then
            add(config.keys[a.name], function()
                if state.handle and state.handle.prev_tab then
                    state.handle.prev_tab()
                end
            end)
        end
    end
    add(config.keys.help, show_help)
    return km
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
        -- Panel keys are frame-wide (dispatched by the active section) — see build_keymaps.
        keymaps = build_keymaps(),
        on_close = function()
            state.open = false
            state.handle = nil
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
    if state.handle and state.handle.select_tab then
        pcall(state.handle.select_tab, name)
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
    -- A TEXT section (REPL / Console): repaint the shared content panel in place, so streaming output
    -- appears live (the canonical tabs seam — no borrowing a provider hook to hold the panel).
    if state.handle and state.handle.refresh_content then
        state.handle.refresh_content()
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

--- Append a divider row to the REPL + Console scrollbacks (a run boundary) — kept, not wiped, so the
--- output history survives a terminate (useful post-mortem) but the next run's lines are not mistaken for
--- this one's.
local function mark_session_end()
    local sep = "── session ended ──"
    if #state.console_lines > 0 then
        table.insert(state.console_lines, sep)
    end
    if #state.repl_lines > 0 then
        table.insert(state.repl_lines, sep)
    end
end

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
    -- Debuggee output → the Console scrollback. DAP `output` events are STREAM chunks, not lines: a logical
    -- line can arrive split across events ("Hel" then "lo\n"). Join the carried partial, split on real
    -- newlines (vim.split keeps empty lines — gmatch "[^\n]+" dropped them), and carry the trailing fragment
    -- (text after the last \n, possibly "") to the next event.
    L.after.event_output["lvim-dap-view"] = function(_, body)
        if not body or not body.output then
            return
        end
        local data = state.console_partial .. tostring(body.output)
        local lines = vim.split(data, "\n", { plain = true })
        state.console_partial = table.remove(lines)
        if #lines > 0 then
            vim.list_extend(state.console_lines, lines)
            trim_scrollback(state.console_lines)
        end
        vim.schedule(function()
            M.refresh("console") -- always: the provisional partial row tails live even before a newline
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
            if next(d.sessions()) then
                return -- other sessions still live: their state stays valid
            end
            -- Last session gone: drop the (now stale) watch values and mark the scrollbacks, so a reopened
            -- or still-open dock never shows dead values as if live.
            state.watch_results = {}
            if state.console_partial ~= "" then
                table.insert(state.console_lines, state.console_partial)
                state.console_partial = ""
            end
            mark_session_end()
            if config.auto_close then
                M.close()
            else
                M.refresh_all()
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
        -- No lvim-utils: deep-merge into the live config IN PLACE, so nested overrides (e.g. a single icon)
        -- do not clobber the whole sub-table the way a shallow per-key copy would.
        for k, v in pairs(vim.tbl_deep_extend("force", vim.deepcopy(config), opts or {})) do
            config[k] = v
        end
    end
    wire_engine()
    setup_command()
end

return M
