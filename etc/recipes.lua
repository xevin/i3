local replacements = {fuel = {}}

local fmt, match = i3.need("fmt", "match")
local reg_items, reg_aliases = i3.need("reg_items", "reg_aliases")
local maxn, copy, insert, remove = i3.need("maxn", "copy", "insert", "remove")

local true_str, is_table, show_item, table_merge = i3.need("true_str", "is_table", "show_item", "table_merge")
local is_group, extract_groups, item_has_groups, groups_to_items =
	i3.need("is_group", "extract_groups", "item_has_groups", "groups_to_items")

local function table_replace(t, val, new)
	for k, v in pairs(t) do
		if v == val then
			t[k] = new
		end
	end
end

local function table_eq(T1, T2)
	local avoid_loops = {}

	local function recurse(t1, t2)
		if type(t1) ~= type(t2) then return end

		if not is_table(t1) then
			return t1 == t2
		end

		if avoid_loops[t1] then
			return avoid_loops[t1] == t2
		end

		avoid_loops[t1] = t2
		local t2k, t2kv = {}, {}

		for k in pairs(t2) do
			if is_table(k) then
				insert(t2kv, k)
			end

			t2k[k] = true
		end

		for k1, v1 in pairs(t1) do
			local v2 = t2[k1]
			if type(k1) == "table" then
				local ok
				for i = 1, #t2kv do
					local tk = t2kv[i]
					if table_eq(k1, tk) and recurse(v1, t2[tk]) then
						remove(t2kv, i)
						t2k[tk] = nil
						ok = true
						break
					end
				end

				if not ok then return end
			else
				if v2 == nil then return end
				t2k[k1] = nil
				if not recurse(v1, v2) then return end
			end
		end

		if next(t2k) then return end
		return true
	end

	return recurse(T1, T2)
end

local function get_burntime(item)
	return core.get_craft_result{method = "fuel", items = {item}}.time
end

local function cache_fuel(item)
	local burntime = get_burntime(item)
	if burntime > 0 then
		i3.fuel_cache[item] = {
			type = "fuel",
			items = {item},
			burntime = burntime,
			replacements = replacements.fuel[item],
		}
	end
end

local function get_item_usages(item, recipe, added)
	local groups = extract_groups(item)

	if groups then
		for name, def in pairs(reg_items) do
			if not added[name] and show_item(def) and item_has_groups(def.groups, groups) then
				local usage = copy(recipe)
				table_replace(usage.items, item, name)

				i3.usages_cache[name] = i3.usages_cache[name] or {}
				insert(i3.usages_cache[name], 1, usage)

				added[name] = true
			end
		end
	elseif show_item(reg_items[item]) then
		i3.usages_cache[item] = i3.usages_cache[item] or {}
		insert(i3.usages_cache[item], 1, recipe)
	end
end

local function get_usages(recipe)
	local added = {}

	for _, item in pairs(recipe.items) do
		item = reg_aliases[item] or item

		if not added[item] then
			get_item_usages(item, recipe, added)
			added[item] = true
		end
	end
end

local function cache_usages(item)
	local recipes = i3.recipes_cache[item] or {}

	for i = 1, #recipes do
		get_usages(recipes[i])
	end

	if i3.fuel_cache[item] then
		i3.usages_cache[item] = table_merge(i3.usages_cache[item] or {}, {i3.fuel_cache[item]})
	end
end

local function drop_table(name, drop)
	local count_sure = 0
	local drop_items = drop.items or {}
	local max_items = drop.max_items

	for i = 1, #drop_items do
		local di = drop_items[i]
		local valid_rarity = di.rarity and di.rarity > 1

		if di.rarity or not max_items or
				(max_items and not di.rarity and count_sure < max_items) then
			for j = 1, #di.items do
				local dstack = ItemStack(di.items[j])
				local dname  = dstack:get_name()
				local dcount = dstack:get_count()
				local empty  = dstack:is_empty()

				if not empty and (dname ~= name or (dname == name and dcount > 1)) then
					local rarity = valid_rarity and di.rarity

					i3.register_craft {
						type   = rarity and "digging_chance" or "digging",
						items  = {name},
						output = fmt("%s %u", dname, dcount),
						rarity = rarity,
						tools  = di.tools,
					}
				end
			end
		end

		if not di.rarity then
			count_sure = count_sure + 1
		end
	end
end

local function cache_drops(name, drop)
	if true_str(drop) then
		local dstack = ItemStack(drop)
		local dname  = dstack:get_name()
		local empty  = dstack:is_empty()

		if not empty and dname ~= name then
			i3.register_craft {
				type = "digging",
				items = {name},
				output = drop,
			}
		end
	elseif is_table(drop) then
		drop_table(name, drop)
	end
end

local function cache_recipes(item)
	local recipes = core.get_all_craft_recipes(item)

	if replacements[item] then
		local _recipes = {}

		for k, v in ipairs(recipes or {}) do
			_recipes[#recipes + 1 - k] = v
		end

		local shift = 0
		local size_rpl = maxn(replacements[item])
		local size_rcp = #_recipes

		if size_rpl > size_rcp then
			shift = size_rcp - size_rpl
		end

		for k, v in pairs(replacements[item]) do
			k = k + shift

			if _recipes[k] then
				_recipes[k].replacements = v
			end
		end

		recipes = _recipes
	end

	if recipes then
		i3.recipes_cache[item] = table_merge(recipes, i3.recipes_cache[item] or {})
	end
end

--[[	As `core.get_craft_recipe` and `core.get_all_craft_recipes` do not
	return the fuel, replacements and toolrepair recipes, we have to
	override `core.register_craft` and do some reverse engineering.
	See engine's issues #4901, #5745 and #8920.	]]

local old_register_craft = core.register_craft
local rcp_num = {}

core.register_craft = function(def)
	old_register_craft(def)

	if def.type == "toolrepair" then
		i3.toolrepair = def.additional_wear * -100
	end

	local output = def.output or (true_str(def.recipe) and def.recipe) or nil
	if not output then return end
	output = {match(output, "%S+")}

	local groups

	if is_group(output[1]) then
		groups = extract_groups(output[1])
		output = groups_to_items(groups, true)
	end

	for i = 1, #output do
		local item = output[i]
		rcp_num[item] = (rcp_num[item] or 0) + 1

		if def.replacements then
			if def.type == "fuel" then
				replacements.fuel[item] = def.replacements
			else
				replacements[item] = replacements[item] or {}
				replacements[item][rcp_num[item]] = def.replacements
			end
		end
	end
end

local old_clear_craft = core.clear_craft

core.clear_craft = function(def)
	old_clear_craft(def)

	if true_str(def) then
		return -- TODO
	elseif is_table(def) then
		return -- TODO
	end
end

local function resolve_aliases(hash)
	for oldname, newname in pairs(reg_aliases) do
		cache_recipes(oldname)
		local recipes = i3.recipes_cache[oldname]

		if recipes then
			if not i3.recipes_cache[newname] then
				i3.recipes_cache[newname] = {}
			end

			local similar

			for i = 1, #i3.recipes_cache[oldname] do
				local rcp_old = i3.recipes_cache[oldname][i]

				for j = 1, #i3.recipes_cache[newname] do
					local rcp_new = copy(i3.recipes_cache[newname][j])
					rcp_new.output = oldname

					if table_eq(rcp_old, rcp_new) then
						similar = true
						break
					end
				end

				if not similar then
					insert(i3.recipes_cache[newname], rcp_old)
				end
			end
		end

		if newname ~= "" and i3.recipes_cache[oldname] and not hash[newname] then
			i3.init_items[#i3.init_items + 1] = newname
		end
	end
end

return cache_drops, cache_fuel, cache_recipes, cache_usages, resolve_aliases