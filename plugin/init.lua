local wezterm = require('wezterm')

local M = {}

-- Module-local state
local registered_bindings = {}
local config_bindings = {}
local plugin_opts = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Normalize a modifier string for display: "CTRL|SHIFT" → "Ctrl+Shift"
local function format_mods_key(mods, key)
  if not mods or mods == '' or mods == 'NONE' then
    return key:upper()
  end
  local parts = {}
  for mod in mods:gmatch('[^|]+') do
    mod = mod:match('^%s*(.-)%s*$') -- trim
    if mod ~= '' and mod ~= 'NONE' then
      table.insert(parts, mod:sub(1, 1):upper() .. mod:sub(2):lower())
    end
  end
  table.insert(parts, key:upper())
  return table.concat(parts, '+')
end

--- Best-effort readable name for an action
local function action_to_string(action)
  if action == nil then
    return '(no action)'
  end
  -- Try wezterm.json_encode first — gives structured output for action objects
  local ok, json = pcall(wezterm.json_encode, action)
  if ok and json then
    -- json is typically like {"SpawnTab":"CurrentPaneDomain"} or
    -- {"CloseCurrentPane":{"confirm":true}} or just "TogglePaneZoomState"
    -- Strip outer quotes for simple string actions
    local s = json:gsub('^"', ''):gsub('"$', '')
    -- For object actions, make them more readable:
    -- {"SpawnTab":"CurrentPaneDomain"} → SpawnTab: CurrentPaneDomain
    s = s:gsub('^{', ''):gsub('}$', '')
    -- Clean up inner JSON noise
    s = s:gsub('"', ''):gsub('{', '('):gsub('}', ')')
    -- Trim
    s = s:match('^%s*(.-)%s*$')
    if s ~= '' then
      return s
    end
  end
  -- Fallback to tostring
  local s = tostring(action)
  if s and not s:match('^table:') and s ~= '' then
    return s
  end
  return '(action)'
end

--- Create a unique key for deduplication (normalized lowercase)
local function make_key_id(mods, key)
  local m = (mods or 'NONE'):upper()
  local k = (key or ''):lower()
  -- sort mods for consistency
  local parts = {}
  for mod in m:gmatch('[^|]+') do
    mod = mod:match('^%s*(.-)%s*$')
    if mod ~= '' and mod ~= 'NONE' then
      table.insert(parts, mod)
    end
  end
  table.sort(parts)
  local norm_mods = #parts > 0 and table.concat(parts, '|') or 'NONE'
  return norm_mods .. '+' .. k
end

-- ---------------------------------------------------------------------------
-- build_choices – assembles the InputSelector choices list
-- ---------------------------------------------------------------------------

local function build_choices()
  local choices = {}
  local action_map = {}     -- id → action
  local seen_keys = {}      -- key_id → true (for deduplication)
  local choice_idx = 0

  -- Helper to add one choice
  local function add_choice(binding, label_prefix, fg_key, fg_desc)
    choice_idx = choice_idx + 1
    local id = tostring(choice_idx)
    local has_key = binding.key and binding.key ~= ''
    local desc = binding.desc or action_to_string(binding.action)
    local label

    if has_key then
      local display_key = format_mods_key(binding.mods, binding.key)
      label = wezterm.format({
        { Attribute = { Intensity = 'Bold' } },
        { Foreground = { AnsiColor = fg_key } },
        { Text = label_prefix .. display_key },
        { Attribute = { Intensity = 'Normal' } },
        { Foreground = { AnsiColor = fg_desc } },
        { Text = '  ' .. desc },
      })
    else
      -- Action-only entry (no keybinding)
      label = wezterm.format({
        { Foreground = { AnsiColor = fg_desc } },
        { Text = desc },
      })
    end

    choices[#choices + 1] = {
      id = id,
      label = label,
    }
    action_map[id] = binding.action
    if has_key then
      local kid = make_key_id(binding.mods, binding.key)
      seen_keys[kid] = true
    end
  end

  -- Layer 1: Registered bindings (top priority)
  for _, b in ipairs(registered_bindings) do
    add_choice(b, '', 'Yellow', 'White')
  end

  -- Layer 2: Config bindings snapshot (auto-discovered, not already registered)
  for _, b in ipairs(config_bindings) do
    local kid = make_key_id(b.mods, b.key)
    if not seen_keys[kid] then
      add_choice(b, '', 'Aqua', 'Silver')
    end
  end

  -- Layer 3: WezTerm defaults (if enabled and available)
  if plugin_opts.include_defaults ~= false and wezterm.gui then
    local ok, defaults = pcall(wezterm.gui.default_keys)
    if ok and defaults then
      for _, b in ipairs(defaults) do
        local kid = make_key_id(b.mods, b.key)
        if not seen_keys[kid] then
          add_choice(b, '', 'Grey', 'Grey')
        end
      end
    end
  end

  -- Layer 3b: Default key tables (copy_mode, search_mode, etc.)
  if plugin_opts.include_key_tables and wezterm.gui then
    local ok, key_tables = pcall(wezterm.gui.default_key_tables)
    if ok and key_tables then
      for table_name, bindings in pairs(key_tables) do
        for _, b in ipairs(bindings) do
          local kid = table_name .. ':' .. make_key_id(b.mods, b.key)
          if not seen_keys[kid] then
            seen_keys[kid] = true
            choice_idx = choice_idx + 1
            local id = tostring(choice_idx)
            local display_key = format_mods_key(b.mods, b.key)
            local desc = action_to_string(b.action)
            choices[#choices + 1] = {
              id = id,
              label = wezterm.format({
                { Foreground = { AnsiColor = 'Grey' } },
                { Text = '[' .. table_name .. '] ' .. display_key },
                { Text = '  ' .. desc },
              }),
            }
            action_map[id] = b.action
          end
        end
      end
    end
  end

  return choices, action_map
end

-- ---------------------------------------------------------------------------
-- open_picker – runs InputSelector and executes chosen action
-- ---------------------------------------------------------------------------

local function open_picker(window, pane)
  local choices, action_map = build_choices()

  window:perform_action(
    wezterm.action.InputSelector({
      title = plugin_opts.title or 'Command Picker',
      choices = choices,
      fuzzy = plugin_opts.fuzzy ~= false,
      fuzzy_description = plugin_opts.fuzzy_description or 'Search commands: ',
      action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
        if id and action_map[id] then
          inner_window:perform_action(action_map[id], inner_pane)
        end
      end),
    }),
    pane
  )
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Register bindings with descriptions for the picker.
--- Accepts a single {key, mods, action, desc} or a list of them.
--- Does NOT add to config.keys.
function M.register(bindings)
  if not bindings then
    return
  end
  -- Detect single binding vs list: a single binding has `action` or `key` field
  if bindings.action or bindings.key then
    bindings = { bindings }
  end
  for _, b in ipairs(bindings) do
    registered_bindings[#registered_bindings + 1] = {
      key = b.key or '',
      mods = b.mods or 'NONE',
      action = b.action,
      desc = b.desc,
    }
  end
end

--- Convenience: registers bindings for the picker and optionally adds them to config.keys.
---
--- Two calling styles:
---   add_keys(config, bindings) — appends to config.keys AND registers for picker
---   add_keys(bindings)         — registers for picker only (bindings already in config.keys)
---
--- Bindings can include an optional `desc` field for human-readable descriptions.
function M.add_keys(config_or_bindings, bindings)
  -- Detect calling style
  local config, key_list
  if bindings then
    -- Two-arg form: add_keys(config, bindings)
    config = config_or_bindings
    key_list = bindings
  else
    -- Single-arg form: add_keys(bindings) — register only
    config = nil
    key_list = config_or_bindings
  end

  if not key_list then
    return
  end
  if key_list.key then
    key_list = { key_list }
  end

  if config then
    config.keys = config.keys or {}
    for _, b in ipairs(key_list) do
      config.keys[#config.keys + 1] = {
        key = b.key,
        mods = b.mods or 'NONE',
        action = b.action,
      }
    end
  end

  M.register(key_list)
end

--- Inject the trigger keybinding into config.keys.
--- Call this AFTER all keybindings are defined.
function M.apply_to_config(config, opts)
  opts = opts or {}
  plugin_opts = {
    key = opts.key or ' ',
    mods = opts.mods or 'LEADER',
    title = opts.title or 'Command Picker',
    include_defaults = opts.include_defaults,  -- nil defaults to true in build_choices
    include_key_tables = opts.include_key_tables or false,
    fuzzy = opts.fuzzy,                        -- nil defaults to true in open_picker
    fuzzy_description = opts.fuzzy_description or 'Search commands: ',
  }

  -- Snapshot config.keys to discover bindings not registered via the plugin
  config.keys = config.keys or {}
  local registered_key_ids = {}
  for _, b in ipairs(registered_bindings) do
    registered_key_ids[make_key_id(b.mods, b.key)] = true
  end

  config_bindings = {}
  for _, b in ipairs(config.keys) do
    local kid = make_key_id(b.mods or 'NONE', b.key)
    if not registered_key_ids[kid] then
      config_bindings[#config_bindings + 1] = {
        key = b.key,
        mods = b.mods or 'NONE',
        action = b.action,
      }
    end
  end

  -- Inject the trigger keybinding
  config.keys[#config.keys + 1] = {
    key = plugin_opts.key,
    mods = plugin_opts.mods,
    action = wezterm.action_callback(function(window, pane)
      open_picker(window, pane)
    end),
  }
end

return M
