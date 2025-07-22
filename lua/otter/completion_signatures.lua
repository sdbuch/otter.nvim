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
  local popup_width = math.min(50, math.max(30, string.len(title) + 10))
  local popup_height = math.min(8, #contents + 1)
  
  -- Try to get completion menu position from nvim-cmp directly
  local completion_pos = nil
  local completion_width = nil
  
  local ok, cmp = pcall(require, 'cmp')
  if ok then
    local visible_ok, is_visible = pcall(cmp.visible)
    if visible_ok and is_visible then
      -- Try to get completion window from cmp's internal view
      local view_ok, view = pcall(function() return cmp.core.view end)
      if view_ok and view and view.completion and view.completion.win then
        local completion_win = view.completion.win.win
        if completion_win and vim.api.nvim_win_is_valid(completion_win) then
          local config = vim.api.nvim_win_get_config(completion_win)
          completion_pos = { config.row or 0, config.col or 0 }
          completion_width = config.width or 30
          debug_print("Found cmp completion window at:", completion_pos[1], completion_pos[2], "width:", completion_width)
        end
      end
    end
  end
  
  -- Fallback: scan for floating windows if cmp method failed
  if not completion_pos then
    debug_print("Scanning for completion windows...")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local config = vim.api.nvim_win_get_config(win)
        -- Check if this is a floating window positioned relative to cursor
        if config.relative == 'cursor' and config.row ~= nil and config.col ~= nil then
          local win_buf = vim.api.nvim_win_get_buf(win)
          local lines = vim.api.nvim_buf_get_lines(win_buf, 0, 5, false)
          
          -- More specific heuristic: check if it contains completion-like content
          local looks_like_completion = false
          for _, line in ipairs(lines) do
            if line and (string.match(line, "Function") or string.match(line, "Variable") or 
                        string.match(line, "Class") or string.match(line, "Method") or
                        string.match(line, "print") or string.match(line, "numpy")) then
              looks_like_completion = true
              break
            end
          end
          
          if looks_like_completion then
            completion_pos = { config.row, config.col }
            completion_width = config.width or 30
            debug_print("Found completion-like window at:", completion_pos[1], completion_pos[2], "width:", completion_width)
            break
          end
        end
      end
    end
  end
  
  -- Calculate position
  local win_opts = {
    relative = 'cursor',
    width = popup_width,
    height = popup_height,
    style = 'minimal',
    border = 'rounded',
    title = is_signature and ' Signature ' or ' Preview ',
    title_pos = 'center',
    zindex = 1001, -- Higher than completion menu
    anchor = 'NW'
  }
  
  if completion_pos and completion_width then
    -- Position to the right of the completion menu
    win_opts.row = completion_pos[1]
    win_opts.col = completion_pos[2] + completion_width + 2 -- Small gap
    debug_print("Positioning popup at:", win_opts.row, win_opts.col, "relative to completion menu")
  else
    -- Simple fallback: position to the right of cursor
    win_opts.row = 0
    win_opts.col = 1
    debug_print("Using simple fallback positioning")
  end
  
  debug_print("Creating popup with opts:", vim.inspect(win_opts))
  
  local popup_win = vim.api.nvim_open_win(buf, false, win_opts)
  vim.api.nvim_win_set_option(popup_win, 'wrap', true)
  vim.api.nvim_win_set_option(popup_win, 'linebreak', true)
  
  -- Store popup info
  current_popup.win = popup_win
  current_popup.buf = buf
  current_popup.last_item = completion_item
  
  debug_print("Signature popup created")
  
  -- Only close when completion item changes - no other auto-close events
  -- The popup will be closed when a new item is selected or menu closes
  debug_print("Popup will persist until completion item changes")
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

-- Helper to check if a completion item is function-like
local function is_function_like(item)
  return item.kind == vim.lsp.protocol.CompletionItemKind.Function or 
         item.kind == vim.lsp.protocol.CompletionItemKind.Method or
         item.kind == vim.lsp.protocol.CompletionItemKind.Constructor
end

-- Setup nvim-cmp integration
local function setup_nvim_cmp(main_buf)
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    debug_print("nvim-cmp not found")
    return false
  end

  debug_print("Found nvim-cmp, setting up integration...")

  -- Track the last selected item to avoid flickering
  local last_selected_item = nil

  -- Helper to get the currently selected completion item
  local function get_current_item()
    local visible_ok, is_visible = pcall(cmp.visible)
    if not visible_ok or not is_visible then
      return nil
    end

    -- Try multiple methods to get the selected entry
    local entry_ok, entry = pcall(cmp.get_selected_entry)
    if entry_ok and entry then
      debug_print("got selected entry via get_selected_entry")
      return entry.completion_item
    end

    local active_ok, active_entry = pcall(cmp.get_active_entry)
    if active_ok and active_entry then
      debug_print("got selected entry via get_active_entry")
      return active_entry.completion_item
    end

    -- Fallback: get first entry
    local entries_ok, entries = pcall(cmp.get_entries)
    if entries_ok and entries and #entries > 0 then
      debug_print("using first entry as fallback")
      return entries[1].completion_item
    end

    return nil
  end

  -- Handle completion item changes
  local function handle_item_change()
    local visible_ok, is_visible = pcall(cmp.visible)
    if not visible_ok or not is_visible then
      debug_print("CMP menu not visible, closing popup")
      close_popup()
      last_selected_item = nil
      return
    end

    local current_item = get_current_item()
    if not current_item then
      debug_print("No current item found")
      return
    end

    -- Check if the item actually changed
    if last_selected_item and 
       last_selected_item.label == current_item.label and
       last_selected_item.kind == current_item.kind then
      debug_print("Same item still selected, no change needed")
      return
    end

    debug_print("Item changed from", last_selected_item and last_selected_item.label or "none", "to", current_item.label)
    last_selected_item = current_item

    -- Only show popup for function-like items
    if is_function_like(current_item) then
      create_signature_popup(current_item, main_buf)
    else
      debug_print("Item is not function-like, closing popup")
      close_popup()
    end
  end

  -- Set up cmp event handlers
  cmp.event:on('menu_opened', function()
    debug_print("CMP menu opened")
    -- Small delay to let cmp settle
    vim.defer_fn(handle_item_change, 50)
  end)

  cmp.event:on('menu_closed', function()
    debug_print("CMP menu closed")
    close_popup()
    last_selected_item = nil
  end)

  cmp.event:on('complete_done', function()
    debug_print("CMP completion done")
    close_popup()
    last_selected_item = nil
  end)

  -- Handle cursor movement in completion menu
  vim.api.nvim_create_autocmd('CursorMovedI', {
    buffer = main_buf,
    callback = function()
      local visible_ok, is_visible = pcall(cmp.visible)
      if visible_ok and is_visible then
        handle_item_change()
      end
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
      if ok then
        local visible_ok, is_visible = pcall(cmp.visible)
        if visible_ok and is_visible then
        debug_print("CMP menu visible, testing all methods...")
        
        local entry_ok, entry = pcall(cmp.get_selected_entry)
        local entries_ok, entries = pcall(cmp.get_entries)
        local active_ok, active_entry = pcall(cmp.get_active_entry)
        
        debug_print("=== DETAILED STATE DUMP ===")
        debug_print("get_selected_entry():", (entry_ok and entry) and vim.inspect(entry.completion_item) or "nil")
        debug_print("get_active_entry():", (active_ok and active_entry) and vim.inspect(active_entry.completion_item) or "nil")
        debug_print("get_entries() count:", (entries_ok and entries) and #entries or "nil")
        
        if entries_ok and entries and #entries > 0 then
          for i, e in ipairs(entries) do
            if i <= 3 then -- Only show first 3 for brevity
              debug_print("Entry", i, ":", e.completion_item and e.completion_item.label or "no item")
            end
          end
        end
        
        -- Force create popup for testing
        local target_entry = (entry_ok and entry) or (active_ok and active_entry) or (entries_ok and entries and entries[1])
        if target_entry and target_entry.completion_item then
          debug_print("FORCE CREATING POPUP for:", target_entry.completion_item.label)
          create_signature_popup(target_entry.completion_item, main_buf)
        else
          debug_print("NO SUITABLE ENTRY FOUND")
        end
        else
          debug_print("CMP menu not visible")
        end
      else
        debug_print("CMP not available")
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
    local visible_ok, is_visible = pcall(cmp.visible)
    if visible_ok and is_visible then
      local entry_ok, entry = pcall(cmp.get_selected_entry)
      debug_print("Selected entry:", (entry_ok and entry) and entry.completion_item and entry.completion_item.label or "none")
      if entry_ok and entry and entry.completion_item then
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