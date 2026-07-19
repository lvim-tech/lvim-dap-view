-- lvim-dap-view.state: the view's runtime (NOT config — nothing here is persisted or user-set).
-- Holds the open dock handle, the per-section tree handles, the variables cache (invalidated on
-- every stop), the REPL/console scrollback, and the user's watch expressions. All in memory: a
-- debug UI is session-scoped, so none of it outlives the editor.
--
---@module "lvim-dap-view.state"

---@class LvimDapViewState
---@field handle? table                      the lvim-ui.tabs handle for the open dock
---@field trees table<string, table>         section name → lvim-ui.tree handle
---@field open boolean                       whether the dock is open
---@field current string?                    the active section
---@field var_cache table<integer, table[]>  variablesReference → fetched variables (per-stop)
---@field var_fetching table<integer, boolean> variablesReference → an in-flight `variables` request (dedup)
---@field expanded_gen integer               bumped on each stop; the generation guard for lazy fetches
---@field repl_lines string[]                REPL scrollback
---@field console_lines string[]             debuggee output scrollback
---@field console_partial string             trailing debuggee output not yet terminated by a newline
---@field watches string[]                   watch expressions (user-added)
---@field watch_results table<string, table> expression → last evaluate result/err
local M = {
    handle = nil,
    trees = {},
    open = false,
    current = nil,
    var_cache = {},
    var_fetching = {},
    expanded_gen = 0,
    repl_lines = {},
    console_lines = {},
    console_partial = "",
    watches = {},
    watch_results = {},
}

--- Reset the per-stop caches (called on every `stopped`/frame change). Bumping `expanded_gen` also
--- INVALIDATES every lazy fetch in flight: a `variables`/`evaluate` request that returns after this ran
--- captured the OLD generation and drops its (now stale) result instead of writing it back — DAP
--- variablesReferences are stop-scoped and adapters reuse the small integers, so a late write could shadow
--- a different container in the new stop. `var_fetching` is likewise cleared so a fresh stop refetches.
function M.invalidate()
    M.var_cache = {}
    M.var_fetching = {}
    M.expanded_gen = M.expanded_gen + 1
end

return M
