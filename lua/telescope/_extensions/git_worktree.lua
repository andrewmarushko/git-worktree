-- telescope/_extensions/git_worktree.lua
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}
local cfg = {
	chdir_mode = "tcd", -- "cd" | "lcd" | "tcd"
	open_after = "mini-files", -- "mini-files" | "telescope" | "oil" | "nvim-tree" | "none"
	copy_files = { ".env", ".env.local" },
	on_switch = nil, -- function(path, branch) end
}

function M.setup(user_cfg)
	cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Shell helper
-- ─────────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Parse `git worktree list --porcelain`
-- ─────────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────────
-- UI helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function open_after_switch(path)
	local mode = cfg.open_after

	if mode == "mini-files" then
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
	elseif mode == "oil" and package.loaded["oil"] then
		vim.schedule(function()
			require("oil").open(path)
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

local function refresh_explorers(path)
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
	if package.loaded["oil"] then
		pcall(function()
			require("oil").refresh()
		end)
	end
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

local function switch_worktree(path, branch)
	local cmd = (cfg.chdir_mode == "cd" or cfg.chdir_mode == "lcd" or cfg.chdir_mode == "tcd") and cfg.chdir_mode
		or "tcd"
	vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))

	ensure_branch_checked_out(path, branch)
	refresh_explorers(path)

	if type(cfg.on_switch) == "function" then
		pcall(cfg.on_switch, path, branch)
	end
	open_after_switch(path)

	vim.notify(("Switched to worktree: %s (%s)"):format(path, branch or "detached"))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Delete worktree (+ optional branch deletion)
-- ─────────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Build entries and pickers
-- ─────────────────────────────────────────────────────────────────────────────
local function make_entries_with_current_mark()
	local cwd = Path:new(vim.fn.getcwd()):absolute()
	local entries = {}
	for _, wt in ipairs(get_worktrees()) do
		local path, branch = parse_worktree(wt)
		local star = (path == cwd) and "* " or ""
		local display = ("%s%s (%s)"):format(star, branch, path)
		table.insert(entries, { path = path, branch = branch, display = display })
	end
	return entries
end

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

local function get_available_branches()
	local code, all = sh({ "git", "branch", "--format=%(refname:short)" })
	if code ~= 0 then
		return {}
	end

	local existing = {}
	for _, wt in ipairs(get_worktrees()) do
		if wt.branch then
			existing[wt.branch:gsub("^refs/heads/", "")] = true
		end
	end

	local avail = {}
	for _, b in ipairs(all) do
		if b ~= "" and not existing[b] then
			table.insert(avail, b)
		end
	end
	return avail
end

-- List / switch / quick delete
local function git_worktrees(opts)
	opts = opts or {}
	local entries = make_entries_with_current_mark()

	pickers
		.new(opts, {
			prompt_title = "Git Worktrees",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return { value = e, display = e.display, ordinal = e.branch .. " " .. e.path }
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

-- Create from existing branch
local function create_from_branch_git_worktree(opts)
	opts = opts or {}
	local branches = get_available_branches()
	if #branches == 0 then
		vim.notify("No available branches.", vim.log.levels.INFO)
		return
	end

	local entries = vim.tbl_map(function(b)
		return { branch = b, display = b }
	end, branches)

	pickers
		.new(opts, {
			prompt_title = "Select branch for worktree",
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
							local code, _, err = sh({ "git", "worktree", "add", new_path, branch })
							if code ~= 0 then
								vim.notify(
									"Failed to create worktree:\n" .. table.concat(err, "\n"),
									vim.log.levels.ERROR
								)
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

-- Create NEW branch worktree
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
				local code, _, err = sh({ "git", "worktree", "add", new_path, "-b", branch })
				if code ~= 0 then
					vim.notify("Failed to create worktree:\n" .. table.concat(err, "\n"), vim.log.levels.ERROR)
					return
				end
				copy_env_files(new_path)
				if upstream and upstream ~= "" then
					sh({ "git", "-C", new_path, "branch", "--set-upstream-to", upstream })
				end
				vim.notify(("Created worktree: %s (new branch %s)"):format(new_path, branch))
				if vim.fn.confirm("Switch to the new worktree?", "&Yes\n&No", 2) == 1 then
					switch_worktree(Path:new(new_path):absolute(), branch)
				end
			end)
		end)
	end)
end

-- Dedicated delete picker
local function delete_git_worktree(opts)
	opts = opts or {}
	local entries = make_entries_with_current_mark()
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
					return { value = e, display = e.display, ordinal = e.branch .. " " .. e.path }
				end,
			}),
			sorter = sorters.get_generic_fuzzy_sorter(),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					local choice = vim.fn.confirm("Delete worktree '" .. sel.value.path .. "'?", "&Yes\n&No\n&Force", 2)
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
