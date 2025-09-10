local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
	error("git-worktree telescope extension requires nvim-telescope/telescope.nvim")
end

local finders = require("telescope.finders")
local sorters = require("telescope.sorters")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local Job = require("plenary.job")
local Path = require("plenary.path")

-- ╭──────────────────────────────────────────────────────────────────────────╮
-- │ Config (override via telescope.setup{ extensions.git_worktree = { ... }})│
-- ╰──────────────────────────────────────────────────────────────────────────╯
local M = {}
local cfg = {
	chdir_mode = "tcd", -- "cd" | "lcd" | "tcd"
	open_after = "oil", -- "oil" | "mini-files" | "telescope" | "nvim-tree" | "none"
	close_other_explorers = true, -- close Oil/Neo-tree/NvimTree windows before opening post-switch UI
	copy_files = { ".env", ".env.local" },
	on_switch = nil, -- function(path, branch) end
}

function M.setup(user_cfg)
	cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
end

-- ╭──────────────────────────────────────────────────────────────────────────╮
-- │ Helpers                                                                  │
-- ╰──────────────────────────────────────────────────────────────────────────╯
local function sh(args, cwd)
	local job = Job:new({ command = args[1], args = { unpack(args, 2) }, cwd = cwd })
	local ok, err = pcall(function()
		job:sync()
	end)
	if not ok then
		return 1, {}, { tostring(err) }
	end
	return job.code, job:result(), job:stderr_result()
end

local function get_worktrees()
	local code, out, err = sh({ "git", "worktree", "list", "--porcelain" })
	if code ~= 0 then
		vim.notify(table.concat(err, "\n"), vim.log.levels.ERROR)
		return {}
	end
	local worktrees, current = {}, {}
	local function push()
		if next(current) ~= nil then
			table.insert(worktrees, current)
		end
		current = {}
	end
	for _, line in ipairs(out) do
		if line == "" then
			push()
		else
			local k, v = line:match("^(%S+)%s+(.*)$")
			if k and v then
				current[k] = v
			else
				current[line] = true
			end
		end
	end
	push()
	return worktrees
end

local function parse_worktree(wt)
	local path = Path:new(wt.worktree):absolute()
	local branch = wt.branch and wt.branch:gsub("^refs/heads/", "")
	if not branch then
		branch = wt.HEAD and ("detached at " .. wt.HEAD:sub(1, 7)) or "detached"
	end
	return path, branch
end

local function close_explorer_windows_in_tab()
	if not cfg.close_other_explorers then
		return
	end
	local to_close_ft = { oil = true, ["neo-tree"] = true, NvimTree = true }
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local ft = vim.bo[buf].filetype
		if to_close_ft[ft] then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

local function refresh_explorers(_)
	if package.loaded["nvim-tree.api"] then
		pcall(function()
			require("nvim-tree.api").tree.reload()
		end)
	end
	if package.loaded["neo-tree.command"] then
		pcall(function()
			require("neo-tree.command").execute({ action = "refresh", source = "filesystem" })
		end)
	end
	-- intentionally no Oil refresh/open here (we open it explicitly below)
end

local function ensure_branch_checked_out(path, branch)
	if not branch or branch:match("^detached") then
		return
	end
	local code = sh({ "git", "-C", path, "switch", branch })
	if code ~= 0 then
		sh({ "git", "-C", path, "checkout", branch })
	end
end

local function open_after_switch(path)
	local mode = cfg.open_after
	if mode == "oil" and package.loaded["oil"] then
		vim.schedule(function()
			require("oil").open(path)
		end)
	elseif mode == "mini-files" then
		vim.schedule(function()
			local ok, mf = pcall(require, "mini.files")
			if ok then
				mf.open(path)
			end
		end)
	elseif mode == "telescope" then
		vim.schedule(function()
			local ok, builtin = pcall(require, "telescope.builtin")
			if ok then
				builtin.find_files({ cwd = path, hidden = true, no_ignore = false })
			end
		end)
	elseif mode == "nvim-tree" and package.loaded["nvim-tree.api"] then
		vim.schedule(function()
			local api = require("nvim-tree.api")
			api.tree.open()
			api.tree.change_root(path)
			api.tree.reload()
		end)
	end
end

local function switch_worktree(path, branch)
	local cmd = (cfg.chdir_mode == "cd" or cfg.chdir_mode == "lcd" or cfg.chdir_mode == "tcd") and cfg.chdir_mode
		or "tcd"
	vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))

	ensure_branch_checked_out(path, branch)
	refresh_explorers(path)
	close_explorer_windows_in_tab()

	if type(cfg.on_switch) == "function" then
		pcall(cfg.on_switch, path, branch)
	end
	open_after_switch(path)

	vim.notify(("Switched to worktree: %s (%s)"):format(path, branch or "detached"))
end

local function delete_worktree(path, force, branch)
	if Path:new(path):absolute() == Path:new(vim.fn.getcwd()):absolute() then
		vim.notify("Refusing to delete the current worktree.", vim.log.levels.WARN)
		return
	end
	local args = { "git", "worktree", "remove" }
	if force then
		table.insert(args, "--force")
	end
	table.insert(args, path)
	local code, _, err = sh(args)
	if code ~= 0 then
		vim.notify("Failed to delete worktree:\n" .. table.concat(err, "\n"), vim.log.levels.ERROR)
		return
	end
	vim.notify("Deleted worktree: " .. path)

	if branch and not branch:match("^detached") then
		local confirm = vim.fn.confirm("Delete branch '" .. branch .. "' too?", "&Yes\n&No\n&Force", 2)
		if confirm == 1 or confirm == 3 then
			local del_args = { "git", "branch", (confirm == 3) and "-D" or "-d", branch }
			local bcode, _, berr = sh(del_args)
			if bcode == 0 then
				vim.notify(((confirm == 3) and "Force " or "") .. "deleted branch: " .. branch)
			else
				vim.notify("Failed to delete branch:\n" .. table.concat(berr, "\n"), vim.log.levels.ERROR)
			end
		end
	end
end

-- Copy configured files into new worktree
local function copy_env_files(to_path)
	local from = Path:new(vim.fn.getcwd())
	for _, name in ipairs(cfg.copy_files or {}) do
		local src = from:joinpath(name)
		if src:exists() then
			local dest = Path:new(to_path, name)
			src:copy({ destination = dest, parents = true, override = true })
			vim.schedule(function()
				vim.notify(("Copied %s → %s"):format(name, tostring(dest)))
			end)
		end
	end
end

-- ── branch utilities ─────────────────────────────────────────────────────────
local function branch_exists_local(branch)
	local code = sh({ "git", "show-ref", "--verify", "--quiet", "refs/heads/" .. branch })
	return code == 0
end

local function branch_exists_remote(branch)
	-- fast path (common remote 'origin')
	if sh({ "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. branch }) == 0 then
		return true
	end
	local code, out = sh({ "git", "for-each-ref", "--format=%(refname:short)", "refs/remotes" })
	if code ~= 0 then
		return false
	end
	for _, line in ipairs(out or {}) do
		if not line:find(" HEAD -> ") and line:match(".+/" .. vim.pesc(branch) .. "$") then
			return true
		end
	end
	return false
end

local function branch_in_any_worktree(branch)
	for _, wt in ipairs(get_worktrees()) do
		if wt.branch and wt.branch:gsub("^refs/heads/", "") == branch then
			return true, wt.worktree
		end
	end
	return false, nil
end

-- create worktree with smart logic based on branch presence/attachment
local function add_worktree_smart(path, branch, opts)
	opts = opts or {}
	local attached, where = branch_in_any_worktree(branch)

	if attached and not opts.allow_detach then
		local choice = vim.fn.confirm(
			("Branch '%s' is already checked out at:\n%s\n\nCreate detached worktree at HEAD instead?"):format(
				branch,
				where
			),
			"&Detached\n&Cancel\n&Rename",
			1
		)
		if choice == 2 then
			return false, "cancelled"
		end
		if choice == 3 then
			local newb = vim.fn.input("New branch name: ", branch .. "-2")
			if newb == "" then
				return false, "cancelled"
			end
			branch = newb
			attached = false
		else
			local code, _, err = sh({ "git", "worktree", "add", path })
			return code == 0, code == 0 and nil or table.concat(err, "\n"), branch
		end
	end

	if branch_exists_local(branch) then
		local code, _, err = sh({ "git", "worktree", "add", path, branch })
		return code == 0, code == 0 and nil or table.concat(err, "\n"), branch
	elseif branch_exists_remote(branch) then
		local code, _, err = sh({ "git", "worktree", "add", path, "-b", branch, "origin/" .. branch })
		return code == 0, code == 0 and nil or table.concat(err, "\n"), branch
	else
		local code, _, err = sh({ "git", "worktree", "add", path, "-b", branch })
		return code == 0, code == 0 and nil or table.concat(err, "\n"), branch
	end
end

-- collect ALL local + remote branch names (dedup, strip remote prefix)
local function list_all_branches()
	local names = {}

	-- locals
	do
		local code, out = sh({ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads" })
		if code == 0 then
			for _, b in ipairs(out or {}) do
				if b ~= "" then
					names[b] = true
				end
			end
		end
	end

	-- remotes
	do
		local code, out = sh({ "git", "for-each-ref", "--format=%(refname:short)", "refs/remotes" })
		if code == 0 then
			for _, b in ipairs(out or {}) do
				if b ~= "" and not b:find(" HEAD -> ") then
					-- strip "<remote>/" prefix (origin/feat -> feat)
					local stripped = b:gsub("^[^/]+/", "")
					names[stripped] = true
				end
			end
		end
	end

	-- to sorted list
	local list = {}
	for name in pairs(names) do
		table.insert(list, name)
	end
	table.sort(list)
	return list
end

-- ╭──────────────────────────────────────────────────────────────────────────╮
-- │ Pickers                                                                  │
-- ╰──────────────────────────────────────────────────────────────────────────╯
-- List/switch/delete worktrees. Display ONLY branch name.
local function git_worktrees(opts)
	opts = opts or {}
	local cwd = Path:new(vim.fn.getcwd()):absolute()

	local entries = {}
	for _, wt in ipairs(get_worktrees()) do
		local path, branch = parse_worktree(wt)
		local star = (path == cwd) and "* " or ""
		table.insert(entries, { path = path, branch = branch, display = star .. branch })
	end

	pickers
		.new(opts, {
			prompt_title = "Git Worktrees",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return { value = e, display = e.display, ordinal = e.branch }
				end,
			}),
			sorter = sorters.get_generic_fuzzy_sorter(),
			previewer = previewers.new_buffer_previewer({
				title = "Worktree status",
				define_preview = function(self, entry)
					local path = entry.value.path
					local _, lines = sh({ "git", "-C", path, "status", "--short", "--branch" })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, (#lines > 0 and lines or { "(clean)" }))
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					switch_worktree(selection.value.path, selection.value.branch)
				end)

				local function del(force)
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					delete_worktree(selection.value.path, force, selection.value.branch)
				end
				map("i", "<C-d>", function()
					del(false)
				end)
				map("n", "<C-d>", function()
					del(false)
				end)
				map("i", "<C-f>", function()
					del(true)
				end)
				map("n", "<C-f>", function()
					del(true)
				end)
				return true
			end,
		})
		:find()
end

-- Create from branch picker (ALL local+remote branches; displays ONLY name)
local function create_from_branch_git_worktree(opts)
	opts = opts or {}
	local branches = list_all_branches()
	if #branches == 0 then
		vim.notify("No branches found (local or remote).", vim.log.levels.INFO)
		return
	end
	local entries = vim.tbl_map(function(b)
		return { branch = b, display = b }
	end, branches)

	pickers
		.new(opts, {
			prompt_title = "Select branch for worktree (local + remote)",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return { value = e, display = e.display, ordinal = e.branch }
				end,
			}),
			sorter = sorters.get_generic_fuzzy_sorter(),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					local branch = sel.value.branch

					vim.ui.input({ prompt = "Worktree path (default: " .. branch .. "): " }, function(new_path)
						if not new_path or new_path == "" then
							new_path = branch
						end
						vim.ui.input({ prompt = "Upstream (optional): " }, function(upstream)
							local ok, err = add_worktree_smart(new_path, branch)
							if not ok then
								if err ~= "cancelled" then
									vim.notify("Failed to create worktree:\n" .. (err or ""), vim.log.levels.ERROR)
								end
								return
							end
							copy_env_files(new_path)
							if upstream and upstream ~= "" then
								sh({ "git", "-C", new_path, "branch", "--set-upstream-to", upstream })
							end
							vim.notify(("Created worktree: %s (branch %s)"):format(new_path, branch))
							if vim.fn.confirm("Switch to the new worktree?", "&Yes\n&No", 2) == 1 then
								switch_worktree(Path:new(new_path):absolute(), branch)
							end
						end)
					end)
				end)
				return true
			end,
		})
		:find()
end

-- Create NEW branch worktree (smart handling if name exists / remote-only)
local function create_new_git_worktree(opts)
	opts = opts or {}
	vim.ui.input({ prompt = "New branch name: " }, function(branch)
		if not branch or branch == "" then
			return
		end
		vim.ui.input({ prompt = "Worktree path (default: " .. branch .. "): " }, function(new_path)
			if not new_path or new_path == "" then
				new_path = branch
			end
			vim.ui.input({ prompt = "Upstream (optional): " }, function(upstream)
				local ok, err, final_branch = add_worktree_smart(new_path, branch)
				if not ok then
					if err ~= "cancelled" then
						vim.notify("Failed to create worktree:\n" .. (err or ""), vim.log.levels.ERROR)
					end
					return
				end
				copy_env_files(new_path)
				if upstream and upstream ~= "" then
					sh({ "git", "-C", new_path, "branch", "--set-upstream-to", upstream })
				end
				local bname = final_branch or branch
				vim.notify(("Created worktree: %s (branch %s)"):format(new_path, bname))
				if vim.fn.confirm("Switch to the new worktree?", "&Yes\n&No", 2) == 1 then
					switch_worktree(Path:new(new_path):absolute(), bname)
				end
			end)
		end)
	end)
end

-- Dedicated delete picker
local function delete_git_worktree(opts)
	opts = opts or {}
	local cwd = Path:new(vim.fn.getcwd()):absolute()
	local entries = {}
	for _, wt in ipairs(get_worktrees()) do
		local path, branch = parse_worktree(wt)
		local star = (path == cwd) and "* " or ""
		table.insert(entries, { path = path, branch = branch, display = star .. branch })
	end
	if #entries == 0 then
		vim.notify("No worktrees to delete.", vim.log.levels.INFO)
		return
	end

	pickers
		.new(opts, {
			prompt_title = "Delete Git Worktree",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return { value = e, display = e.display, ordinal = e.branch }
				end,
			}),
			sorter = sorters.get_generic_fuzzy_sorter(),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					local choice = vim.fn.confirm(
						"Delete worktree for branch '" .. sel.value.branch .. "'?",
						"&Yes\n&No\n&Force",
						2
					)
					if choice == 1 then
						delete_worktree(sel.value.path, false, sel.value.branch)
					elseif choice == 3 then
						delete_worktree(sel.value.path, true, sel.value.branch)
					end
				end)
				return true
			end,
		})
		:find()
end

-- Optional user commands
vim.api.nvim_create_user_command("GitWorktrees", function()
	git_worktrees({})
end, {})
vim.api.nvim_create_user_command("GitWorktreeCreate", function()
	create_new_git_worktree({})
end, {})
vim.api.nvim_create_user_command("GitWorktreeCreateFrom", function()
	create_from_branch_git_worktree({})
end, {})
vim.api.nvim_create_user_command("GitWorktreeDelete", function()
	delete_git_worktree({})
end, {})

return telescope.register_extension({
	setup = M.setup,
	exports = {
		git_worktrees = git_worktrees,
		create_from_branch_git_worktree = create_from_branch_git_worktree,
		create_new_git_worktree = create_new_git_worktree,
		delete_git_worktree = delete_git_worktree,
	},
})
