-- Completion item signature help popups for otter.nvim
-- Shows function signatures when hovering over completion items

local M = {}

local keeper = require("otter.keeper")

-- TEMPORARY: Disable to stop errors while debugging
local FEATURE_ENABLED = false

-- Track current signature popup
local current_popup = {
  win = nil,
  buf = nil,
  last_item = nil,
}

-- Throttling for performance (separate from signature help throttling)
local last_completion_request_time = 0
local COMPLETION_REQUEST_THROTTLE_MS = 300

-- Debug flag
local DEBUG = true

local function debug_print(...)
  if DEBUG then
    vim.print("[COMPLETION-SIG]", ...)
  end
end

-- Close any existing signature popup
local function close_popup()
  if current_popup.win and vim.api.nvim_win_is_valid(current_popup.win) then
    vim.api.nvim_win_close(current_popup.win, true)
    debug_print("Closed popup")
  end
  current_popup.win = nil
  current_popup.buf = nil
  current_popup.last_item = nil
end

-- Helper function to create positioned popup with smart placement
local function create_positioned_popup(contents, title, main_buf, completion_item, is_signature)
  -- Close any existing popup first
  close_popup()
  
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, contents)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- Calculate popup dimensions
  local popup_width = math.min(60, math.max(30, string.len(title) + 10))
  local popup_height = math.min(10, #contents)
  
  -- Find the completion menu window to position relative to it
  local completion_win = nil
  local completion_pos = nil
  local completion_width = nil
  
  -- Look for floating windows that might be the completion menu
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local config = vim.api.nvim_win_get_config(win)
      -- Check if this is a floating window positioned relative to cursor
      if config.relative == 'cursor' and config.focusable ~= false then
        -- Try to get the buffer content to see if it looks like completion
        local win_buf = vim.api.nvim_win_get_buf(win)
        local lines = vim.api.nvim_buf_get_lines(win_buf, 0, 3, false)
        
        -- Heuristic: if the window contains text that looks like completion items
        -- (has multiple lines, or contains common completion patterns)
        if #lines > 1 or (lines[1] and (string.find(lines[1], "Function") or string.find(lines[1], "Variable") or string.find(lines[1], "Class") or string.find(lines[1], "Method"))) then
          completion_win = win
          completion_pos = { config.row or 0, config.col or 0 }
          completion_width = config.width or 30
          debug_print("Found completion window at:", completion_pos[1], completion_pos[2], "width:", completion_width)
          break
        end
      end
    end
  end
  
  -- Default positioning (fallback if we can't find completion menu)
  local win_opts = {
    relative = 'cursor',
    width = popup_width,
    height = popup_height,
    row = 1,
    col = 42, -- Fallback position
    style = 'minimal',
    border = 'rounded',
    title = is_signature and ' Signature ' or ' Preview ',
    title_pos = 'center',
    zindex = 1000,
    anchor = 'NW'
  }
  
  -- If we found the completion menu, position relative to it
  if completion_win and completion_pos and completion_width then
    -- Position our popup to the right of the completion menu
    win_opts.relative = 'cursor'
    win_opts.row = completion_pos[1] -- Same row as completion menu
    win_opts.col = completion_pos[2] + completion_width + 1 -- Right after completion menu with 1 char gap
    debug_print("Positioning popup relative to completion menu at:", win_opts.row, win_opts.col)
  else
    -- Fallback: try to get completion menu info from nvim-cmp if available
    local ok, cmp = pcall(require, 'cmp')
    if ok and cmp.visible() then
      -- Try to get completion menu dimensions from cmp
      local cmp_config = cmp.get_config()
      if cmp_config and cmp_config.window and cmp_config.window.completion then
        local completion_opts = cmp_config.window.completion
        if completion_opts.col_offset then
          win_opts.col = (completion_opts.col_offset or 0) + (completion_opts.max_width or 40) + 1
          debug_print("Using nvim-cmp config for positioning at col:", win_opts.col)
        end
      end
    end
    
    debug_print("Using fallback positioning at:", win_opts.row, win_opts.col)
  end
  
  debug_print("Creating popup with adaptive positioning")
  
  local popup_win = vim.api.nvim_open_win(buf, false, win_opts)
  vim.api.nvim_win_set_option(popup_win, 'wrap', true)
  vim.api.nvim_win_set_option(popup_win, 'linebreak', true)
  
  -- Store popup info
  current_popup.win = popup_win
  current_popup.buf = buf
  current_popup.last_item = completion_item
  
  debug_print("Signature popup created with adaptive positioning")
  
  -- More persistent auto-close behavior - only close on major events
  -- Don't close on CursorMovedI (which fires when navigating completion menu)
  local close_events = {'BufLeave', 'InsertLeave', 'CompleteDone'}
  vim.api.nvim_create_autocmd(close_events, {
    buffer = main_buf,
    once = true,
    callback = function()
      debug_print("Auto-closing popup due to major event")
      close_popup()
    end
  })
  
  -- Longer timeout for better user experience
  vim.defer_fn(function()
    if current_popup.win and vim.api.nvim_win_is_valid(current_popup.win) then
      debug_print("Auto-closing popup due to timeout")
      close_popup()
    end
  end, 10000) -- 10 seconds timeout
end

-- Create signature popup for completion item
local function create_signature_popup(completion_item, main_buf)
  debug_print("=== CREATE SIGNATURE POPUP ===")
  debug_print("Item:", completion_item.label, "Kind:", completion_item.kind)
  
  -- Only show for function/method completion items
  local item_kind = completion_item.kind
  if not (item_kind == vim.lsp.protocol.CompletionItemKind.Function or 
          item_kind == vim.lsp.protocol.CompletionItemKind.Method or
          item_kind == vim.lsp.protocol.CompletionItemKind.Constructor) then
    debug_print("Skipping - not a function/method/constructor, kind:", item_kind)
    return
  end

  debug_print("Item is function-like, proceeding...")

  -- Close any existing popup first to prevent overlaps
  close_popup()

  -- Check if we're in an otter context
  local lang = keeper.get_current_language_context(main_buf)
  if not lang then
    debug_print("No otter language context found")
    return
  end

  debug_print("Language context:", lang)

  -- Get otter buffer for this language  
  local otter_nr = keeper.rafts[main_buf] and keeper.rafts[main_buf].buffers[lang]
  if not otter_nr then
    debug_print("No otter buffer found for language:", lang)
    return
  end

  debug_print("Otter buffer:", otter_nr)

  -- Separate throttle for completion signatures to avoid conflicts
  local now = vim.fn.reltimestr(vim.fn.reltime())
  local current_time = tonumber(now) * 1000
  if current_time - last_completion_request_time < COMPLETION_REQUEST_THROTTLE_MS then
    debug_print("Throttling completion signature request, too soon")
    return
  end
  last_completion_request_time = current_time

  -- Use completion item position if available, otherwise use cursor position
  local params
  if completion_item.data and completion_item.data.position then
    debug_print("Using completion item position:", vim.inspect(completion_item.data.position))
    params = {
      textDocument = { 
        uri = completion_item.data.uri or completion_item.textDocument.uri 
      },
      position = completion_item.data.position
    }
  else
    debug_print("Using cursor position for signature help")
    params = vim.lsp.util.make_position_params(0)
    -- Use the otter buffer URI instead of main buffer
    params.textDocument.uri = keeper.rafts[main_buf].buffers[lang] and 
                              vim.uri_from_bufnr(keeper.rafts[main_buf].buffers[lang]) or 
                              params.textDocument.uri
  end
  
  -- Add completion item context
  params.context = {
    triggerKind = 1, -- Manual/Invoked
    isRetrigger = false,
    completionItem = {
      label = completion_item.label,
      kind = completion_item.kind,
      detail = completion_item.detail,
      data = completion_item.data
    }
  }

  debug_print("Making signature help request with params:")
  debug_print("  URI:", params.textDocument.uri)
  debug_print("  Position:", vim.inspect(params.position))

  -- Make signature help request to otter buffer directly
  vim.lsp.buf_request(otter_nr, 'textDocument/signatureHelp', params, function(err, result, ctx)
    debug_print("=== SIGNATURE HELP RESPONSE ===")
    debug_print("Error:", err and vim.inspect(err) or "none")
    debug_print("Result:", result and "received" or "none")
    
    if err then
      debug_print("Request failed with error:", vim.inspect(err))
      return
    end
    
    if not result or not result.signatures or #result.signatures == 0 then
      debug_print("No signatures in response")
      
      -- FALLBACK: Create a simple preview popup since signature help failed
      debug_print("Creating simple preview popup for function:", completion_item.label)
      
      local function_name = completion_item.label
      local contents = {
        "**" .. function_name .. "**()",
        "",
        "Function signature help not available",
        "Try typing `" .. function_name .. "(` for full signature help"
      }
      
      -- Create the popup with smarter positioning
      create_positioned_popup(contents, function_name, main_buf, completion_item)
      return
    end

    debug_print("Got", #result.signatures, "signatures")

    -- Create signature popup with real signature data
    local signature = result.signatures[1]
    local contents = { signature.label }
    
    debug_print("Signature label:", signature.label)
    
    -- Add documentation if available
    if signature.documentation then
      table.insert(contents, "")
      if type(signature.documentation) == "string" then
        table.insert(contents, signature.documentation)
      elseif signature.documentation.value then
        table.insert(contents, signature.documentation.value)
      end
    end

    -- Create the popup with smarter positioning
    create_positioned_popup(contents, completion_item.label, main_buf, completion_item, true)
  end)
end

-- Hook into nvim-cmp if available
local function setup_nvim_cmp(main_buf)
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    debug_print("nvim-cmp not found")
    return false
  end

  debug_print("Found nvim-cmp, setting up integration...")

  -- Track menu state and selected item to reduce unnecessary popup changes
  local menu_open = false
  local last_selected_item = nil

  -- Hook into cmp selection events
  cmp.event:on('menu_opened', function()
    if not menu_open then
      debug_print("CMP menu opened")
      menu_open = true
      last_selected_item = nil
      -- Don't close popup immediately - let the user navigate first
      
      -- Auto-detect selection after menu stabilizes
      vim.defer_fn(function()
        if cmp.visible() then
          debug_print("=== AUTO STATE DUMP (menu stabilized) ===")
          
          local entry = cmp.get_selected_entry() or cmp.get_active_entry()
          local entries = cmp.get_entries()
          
          debug_print("Selected entry:", entry and entry.completion_item and entry.completion_item.label or "nil")
          debug_print("Total entries:", entries and #entries or "nil")
          
          -- Try to show signature for the first/selected item
          local target_entry = entry or (entries and entries[1])
          if target_entry and target_entry.completion_item then
            debug_print("Auto-showing signature for:", target_entry.completion_item.label)
            create_signature_popup(target_entry.completion_item, main_buf)
            last_selected_item = target_entry.completion_item.label
          end
        end
      end, 150) -- Longer delay to let menu fully populate
    end
  end)

  cmp.event:on('menu_closed', function()
    if menu_open then
      debug_print("CMP menu closed")
      menu_open = false
      last_selected_item = nil
      -- Close popup when menu closes
      close_popup()
    end
  end)

  cmp.event:on('complete_done', function()
    debug_print("CMP completion done")
    menu_open = false
    last_selected_item = nil
    -- Close popup when completion is done
    close_popup()
  end)

  cmp.event:on('confirm_done', function()
    debug_print("CMP confirm done")
    close_popup()
  end)

  -- Less aggressive cursor movement detection - only update on actual selection changes
  local group = vim.api.nvim_create_augroup("OtterCompletionSignatures" .. main_buf, { clear = true })
  
  -- Reduced frequency checking with debouncing
  local last_check_time = 0
  local CHECK_INTERVAL_MS = 200 -- Slower checking
  
  vim.api.nvim_create_autocmd('CursorMovedI', {
    buffer = main_buf,
    group = group,
    callback = function()
      -- Throttle checks for performance and reduce flicker
      local now = vim.fn.reltimestr(vim.fn.reltime())
      local current_time = tonumber(now) * 1000
      if current_time - last_check_time < CHECK_INTERVAL_MS then
        return
      end
      last_check_time = current_time

      -- Only proceed if completion menu is visible
      if not cmp.visible() then
        if menu_open then
          debug_print("CMP menu closed during cursor movement")
          menu_open = false
          last_selected_item = nil
          close_popup()
        end
        return
      end

      -- Check if selection actually changed
      vim.defer_fn(function()
        if not cmp.visible() then return end
        
        local entry = cmp.get_selected_entry() or cmp.get_active_entry()
        local entries = cmp.get_entries()
        local target_entry = entry or (entries and entries[1])
        
        if target_entry and target_entry.completion_item then
          local current_item = target_entry.completion_item.label
          
          -- Only update if the selection actually changed
          if current_item ~= last_selected_item then
            debug_print("Selection changed from", last_selected_item or "nil", "to", current_item)
            create_signature_popup(target_entry.completion_item, main_buf)
            last_selected_item = current_item
          end
        end
      end, 50) -- Shorter delay for responsiveness
    end
  })

  debug_print("nvim-cmp integration setup complete")
  return true
end

-- Hook into blink.cmp if available
local function setup_blink_cmp(main_buf)
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok then
    debug_print("blink.cmp not found")
    return false
  end

  debug_print("Found blink.cmp (built-in documentation)")
  -- TODO: Implement blink.cmp integration when its event system is available
  -- For now, blink.cmp has its own documentation system that should work
  
  return true
end

-- Setup completion signature popups for a buffer
function M.setup(main_buf)
  main_buf = main_buf or vim.api.nvim_get_current_buf()
  
  -- TEMPORARY: Check if feature is enabled
  if not FEATURE_ENABLED then
    vim.print("Completion signatures: DISABLED (debugging)")
    return
  end
  
  debug_print("=== SETTING UP COMPLETION SIGNATURES ===")
  debug_print("Main buffer:", main_buf)
  
  -- Try to setup with available completion systems
  local cmp_setup = setup_nvim_cmp(main_buf)
  local blink_setup = setup_blink_cmp(main_buf)
  
  if cmp_setup then
    vim.print("Completion signatures: nvim-cmp integration enabled")
    
    -- Add insert mode key mapping for testing (Ctrl+K)
    vim.keymap.set('i', '<C-k>', function()
      debug_print("=== INSERT MODE TEST TRIGGERED ===")
      
      local ok, cmp = pcall(require, 'cmp')
      if ok and cmp.visible() then
        debug_print("CMP menu visible, testing all methods...")
        
        local entry = cmp.get_selected_entry()
        local entries = cmp.get_entries()  
        local active_entry = cmp.get_active_entry()
        
        debug_print("=== DETAILED STATE DUMP ===")
        debug_print("get_selected_entry():", entry and vim.inspect(entry.completion_item) or "nil")
        debug_print("get_active_entry():", active_entry and vim.inspect(active_entry.completion_item) or "nil")
        debug_print("get_entries() count:", entries and #entries or "nil")
        
        if entries and #entries > 0 then
          for i, e in ipairs(entries) do
            if i <= 3 then -- Only show first 3 for brevity
              debug_print("Entry", i, ":", e.completion_item and e.completion_item.label or "no item")
            end
          end
        end
        
        -- Force create popup for testing
        local target_entry = entry or active_entry or (entries and entries[1])
        if target_entry and target_entry.completion_item then
          debug_print("FORCE CREATING POPUP for:", target_entry.completion_item.label)
          create_signature_popup(target_entry.completion_item, main_buf)
        else
          debug_print("NO SUITABLE ENTRY FOUND")
        end
      else
        debug_print("CMP menu not visible or cmp not available")
      end
      
      return '' -- Return empty string to not insert anything
    end, { 
      buffer = main_buf,
      expr = true, -- Important: makes it an expression mapping
      desc = "Test completion signature popup (Ctrl+K in insert mode)" 
    })
    
    vim.print("Completion signatures: Press Ctrl+K in insert mode to test while menu is open")
    
  elseif blink_setup then
    vim.print("Completion signatures: blink.cmp detected (built-in docs)")
  else
    vim.print("Completion signatures: no supported completion system found")
  end

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd('BufDelete', {
    buffer = main_buf,
    once = true,
    callback = function()
      debug_print("Buffer deleted, cleaning up")
      close_popup()
    end
  })
end

-- Manual function to show signature for current completion item (for testing)
function M.show_signature_for_current_item()
  local main_buf = vim.api.nvim_get_current_buf()
  
  debug_print("=== MANUAL SIGNATURE REQUEST ===")
  
  -- Try nvim-cmp first
  local ok, cmp = pcall(require, 'cmp')
  if ok then
    debug_print("Checking nvim-cmp...")
    if cmp.visible() then
      local entry = cmp.get_selected_entry()
      debug_print("Selected entry:", entry and entry.completion_item and entry.completion_item.label or "none")
      if entry and entry.completion_item then
        create_signature_popup(entry.completion_item, main_buf)
        return
      end
    else
      debug_print("CMP menu not visible")
    end
  end
  
  vim.notify("No completion item selected or supported completion system", vim.log.levels.WARN)
end

-- Enable/disable debug logging
function M.set_debug(enabled)
  DEBUG = enabled
  debug_print("Debug logging", enabled and "enabled" or "disabled")
end

-- Enable/disable the feature (for debugging)
function M.set_enabled(enabled)
  FEATURE_ENABLED = enabled
  vim.print("Completion signatures:", enabled and "ENABLED" or "DISABLED")
  
  -- If enabling, automatically run setup for current buffer
  if enabled then
    local current_buf = vim.api.nvim_get_current_buf()
    vim.print("Re-running setup for buffer:", current_buf)
    M.setup(current_buf)
  end
end

-- Reload the module (clears cached version)
function M.reload()
  package.loaded['otter.completion_signatures'] = nil
  vim.print("Completion signatures module reloaded")
  return require('otter.completion_signatures')
end

return M 