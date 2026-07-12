-- lvim-dap-view.util_win: jump to a source location in a CODE window (never the dock).
-- Clicking a stack frame / a breakpoint must move a normal editor window, not the docked panel
-- the click came from. So this picks a window that is NOT one of the plugin's dock/panel buffers
-- (by filetype), reuses one already showing the target file, else the first ordinary window, and
-- moves it. Kept tiny and dependency-free so any panel can call it.
--
---@module "lvim-dap-view.util_win"

local M = {}

--- Filetypes that belong to floating/docked UI we must never hijack for source display.
local PANEL_FT = { LvimDapView = true, lvimuiframe = true, ["lvim-ui-frame"] = true }

--- Whether a window shows a normal editable code buffer (not a panel / float).
---@param win integer
---@return boolean
local function is_code_win(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" then
        return false -- a floating window
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return not PANEL_FT[vim.bo[buf].filetype]
end

--- Open `path` at `line` (1-based) in a suitable code window and place the cursor.
---@param path string
---@param line integer
function M.goto_location(path, line)
    if not path or path == "" then
        return
    end
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    -- Prefer a window already showing the file.
    local target = vim.fn.bufwinid(bufnr)
    if target == -1 then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if is_code_win(win) then
                target = win
                break
            end
        end
    end
    if target == -1 then
        return
    end
    vim.api.nvim_win_set_buf(target, bufnr)
    pcall(vim.api.nvim_win_set_cursor, target, { line, 0 })
    vim.api.nvim_set_current_win(target)
    vim.cmd("normal! zz")
end

return M
