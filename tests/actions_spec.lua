-- One list for the keys and for the cheatsheet.
--
-- The module header makes a specific promise: "the SINGLE `ACTIONS` table feeds BOTH the keymaps
-- AND the `g?` cheatsheet, so a key can never be advertised without a handler". It says so
-- because the drift it prevents has already happened once -- it had left `copy_value`, `edit`,
-- `]v` and `[v` advertised and dead. A correspondence like that is cheap to re-check and
-- expensive to notice by hand, so it is checked here.
--
-- The panels themselves need nvim-dap to produce a single node, so everything that would exercise
-- them SKIPS when it is absent rather than pretending.

local view = require("lvim-dap-view")
local config = require("lvim-dap-view.config")

local actions = view._actions

describe("lvim-dap-view: the action list")

it("there is a list to check at all", function()
    truthy(type(actions) == "table" and #actions > 0, "the suite needs the live list, not a copy")
end)

it("every action has a name and something to show in the cheatsheet", function()
    for i, a in ipairs(actions) do
        truthy(type(a.name) == "string" and a.name ~= "", "action " .. i .. " has no name")
        truthy(type(a.desc) == "string" and a.desc ~= "", a.name .. " has no description to advertise")
    end
end)

it("every action's name has a key configured for it", function()
    for _, a in ipairs(actions) do
        local lhs = config.keys[a.name]
        truthy(
            type(lhs) == "string",
            ("%s is in the action list but config.keys has no entry for it, so it can never fire"):format(a.name)
        )
    end
end)

it("every configured key belongs to an action", function()
    local named = {}
    for _, a in ipairs(actions) do
        named[a.name] = true
    end
    for name, lhs in pairs(config.keys) do
        truthy(
            named[name],
            ("config.keys.%s = %q is advertised to the user but no action answers to that name"):format(
                name,
                tostring(lhs)
            )
        )
    end
end)

it("an action that runs somewhere says where", function()
    for _, a in ipairs(actions) do
        if a.run then
            truthy(
                type(a.sections) == "table" and #a.sections > 0,
                a.name .. " has a handler but names no section, so the dispatch cannot gate it"
            )
        end
    end
end)

it("the sections an action claims are sections that exist", function()
    local known = {}
    for _, s in ipairs(config.sections) do
        known[s] = true
    end
    for _, a in ipairs(actions) do
        for _, s in ipairs(a.sections or {}) do
            truthy(known[s], ("%s claims section %q, which is not in config.sections"):format(a.name, s))
        end
    end
end)

it("two actions may share a key only when they cannot both apply", function()
    -- <CR> is expand / jump / toggle_exception: three actions, three different sections, one key.
    -- What must never happen is two actions with the SAME key and overlapping sections.
    local by_key = {}
    for _, a in ipairs(actions) do
        local lhs = config.keys[a.name]
        if lhs and lhs ~= "" then
            by_key[lhs] = by_key[lhs] or {}
            table.insert(by_key[lhs], a)
        end
    end
    for lhs, group in pairs(by_key) do
        for i = 1, #group do
            for j = i + 1, #group do
                local a, b = group[i], group[j]
                if a.sections and b.sections then
                    for _, s in ipairs(a.sections) do
                        eq(
                            false,
                            vim.tbl_contains(b.sections, s),
                            ("%s and %s both answer to %q in section %q"):format(a.name, b.name, lhs, s)
                        )
                    end
                end
            end
        end
    end
end)

describe("lvim-dap-view: the configured sections")

it("the default section is one of the sections that show", function()
    truthy(
        vim.tbl_contains(config.sections, config.default_section),
        ("default_section %q is not in sections %s"):format(config.default_section, vim.inspect(config.sections))
    )
end)

it("no section is listed twice", function()
    local seen = {}
    for _, s in ipairs(config.sections) do
        eq(nil, seen[s], s .. " is listed twice, so one tab would shadow the other")
        seen[s] = true
    end
end)

describe("lvim-dap-view: the panel itself")

it("it is closed before anything opens it, and closing again is harmless", function()
    eq(false, view.is_open())
    local ok, err = pcall(view.close)
    truthy(ok, tostring(err))
    eq(false, view.is_open())
end)

it("opening a panel needs nvim-dap", function()
    if pcall(require, "dap") then
        skip("opening a panel", "this case is the ABSENCE path; nvim-dap is installed here")
        return
    end
    -- Without the engine there is nothing to show, and the refusal must be a refusal rather than an
    -- error from deep inside a panel builder.
    local ok, err = pcall(view.open)
    truthy(ok, "open() raised instead of declining: " .. tostring(err))
end)
