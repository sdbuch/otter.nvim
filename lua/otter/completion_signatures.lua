-- Completion item signature help popups for otter.nvim
-- Shows function signatures when hovering over completion items

local M = {}

local keeper = require("otter.keeper")

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
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, contents)
      vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
      vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

      local win_opts = {
        relative = 'cursor',
        width = math.min(50, math.max(20, string.len(function_name) + 10)),
        height = #contents,
        row = 0,
        col = 25,
        style = 'minimal',
        border = 'rounded',
        title = ' Preview ',
        title_pos = 'center'
      }

      local win = vim.api.nvim_open_win(buf, false, win_opts)
      vim.api.nvim_win_set_option(win, 'wrap', true)
      
      current_popup.win = win
      current_popup.buf = buf
      current_popup.last_item = completion_item
      
      debug_print("Created fallback popup for:", function_name)
      
      -- Auto-close
      vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI', 'BufLeave', 'InsertLeave'}, {
        buffer = main_buf,
        once = true,
        callback = function()
          debug_print("Auto-closing fallback popup")
          close_popup()
        end
      })
      
      return
    end

    debug_print("Got", #result.signatures, "signatures")

    -- Close any existing popup
    close_popup()

    -- Create signature popup
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

    -- Create floating window positioned next to completion menu
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, contents)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

    -- Position popup to the right of completion menu
    local win_opts = {
      relative = 'cursor',
      width = math.min(60, math.max(20, string.len(signature.label) + 4)),
      height = math.min(10, #contents),
      row = 0,
      col = 25, -- Offset to avoid overlap with completion menu
      style = 'minimal',
      border = 'rounded',
      title = ' Signature ',
      title_pos = 'center'
    }

    debug_print("Creating floating window...")
    local win = vim.api.nvim_open_win(buf, false, win_opts)
    vim.api.nvim_win_set_option(win, 'wrap', true)
    vim.api.nvim_win_set_option(win, 'linebreak', true)

    -- Store popup info
    current_popup.win = win
    current_popup.buf = buf
    current_popup.last_item = completion_item

    debug_print("Signature popup created successfully!")

    -- Auto-close on various events
    vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI', 'BufLeave', 'InsertLeave'}, {
      buffer = main_buf,
      once = true,
      callback = function()
        debug_print("Auto-closing popup due to event")
        close_popup()
      end
    })
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

  -- Track menu state to reduce event spam
  local menu_open = false

  -- Hook into cmp selection events
  cmp.event:on('menu_opened', function()
    if not menu_open then
      debug_print("CMP menu opened")
      menu_open = true
      -- Close any existing popup when menu opens
      close_popup()
      
      -- AUTOMATIC STATE LOGGING when menu opens
      vim.defer_fn(function()
        if cmp.visible() then
          debug_print("=== AUTO STATE DUMP (menu just opened) ===")
          
          local entry = cmp.get_selected_entry()
          local entries = cmp.get_entries()
          local active_entry = cmp.get_active_entry()
          
          debug_print("AUTO: get_selected_entry():", entry and entry.completion_item and entry.completion_item.label or "nil")
          debug_print("AUTO: get_active_entry():", active_entry and active_entry.completion_item and active_entry.completion_item.label or "nil")
          debug_print("AUTO: get_entries() count:", entries and #entries or "nil")
          
          if entries and #entries > 0 then
            debug_print("AUTO: First few entries:")
            for i, e in ipairs(entries) do
              if i <= 3 then
                debug_print("  ", i, ":", e.completion_item and e.completion_item.label or "no item", 
                           "(kind:", e.completion_item and e.completion_item.kind or "unknown", ")")
              end
            end
          end
        end
      end, 100) -- Small delay to ensure menu is fully populated
    end
  end)

  cmp.event:on('menu_closed', function()
    if menu_open then
      debug_print("CMP menu closed")
      menu_open = false
      -- Close popup when menu closes
      close_popup()
    end
  end)

  cmp.event:on('complete_done', function()
    debug_print("CMP completion done")
    menu_open = false
    -- Close popup when completion is done
    close_popup()
  end)

  -- Try to hook into confirmation/selection events
  cmp.event:on('confirm_done', function()
    debug_print("CMP confirm done")
    close_popup()
  end)

  -- Use a different approach: listen for completion menu changes
  local group = vim.api.nvim_create_augroup("OtterCompletionSignatures" .. main_buf, { clear = true })
  
  -- Use a more targeted approach with less frequent polling
  local last_check_time = 0
  local CHECK_INTERVAL_MS = 100
  
  vim.api.nvim_create_autocmd('CursorMovedI', {
    buffer = main_buf,
    group = group,
    callback = function()
      -- Throttle checks for performance
      local now = vim.fn.reltimestr(vim.fn.reltime())
      local current_time = tonumber(now) * 1000
      if current_time - last_check_time < CHECK_INTERVAL_MS then
        return
      end
      last_check_time = current_time

      debug_print("CursorMovedI fired (throttled)")
      
      -- Only proceed if completion menu is visible
      if not cmp.visible() then
        if menu_open then
          debug_print("CMP menu closed, updating state")
          menu_open = false
          close_popup()
        end
        return
      end

      if not menu_open then
        debug_print("CMP menu opened, updating state")
        menu_open = true
      end
      
      debug_print("CMP menu is visible, checking selected entry...")
      
      -- Get selected entry with multiple attempts and better debugging
      vim.defer_fn(function()
        if not cmp.visible() then
          debug_print("CMP menu closed during delay")
          return
        end
        
        -- Try different ways to get the selected entry
        local entry = cmp.get_selected_entry()
        local entries = cmp.get_entries()
        local active_entry = cmp.get_active_entry()
        
        debug_print("Entry methods results:")
        debug_print("  get_selected_entry():", entry and "found" or "nil")
        debug_print("  get_entries() count:", entries and #entries or "nil")
        debug_print("  get_active_entry():", active_entry and "found" or "nil")
        
        -- Try the active entry if selected entry is nil
        local target_entry = entry or active_entry
        
        if target_entry and target_entry.completion_item then
          debug_print("Found completion item:", target_entry.completion_item.label)
          debug_print("Item kind:", target_entry.completion_item.kind)
          debug_print("Item detail:", target_entry.completion_item.detail or "none")
          
          -- Only show if different from last item to avoid flickering
          if not current_popup.last_item or 
             current_popup.last_item.label ~= target_entry.completion_item.label then
            debug_print("Creating signature popup for:", target_entry.completion_item.label)
            create_signature_popup(target_entry.completion_item, main_buf)
          else
            debug_print("Same item as last time, skipping")
          end
        else
          -- Try to get the first entry if nothing is explicitly selected
          if entries and #entries > 0 then
            local first_entry = entries[1]
            if first_entry and first_entry.completion_item then
              debug_print("Using first entry as fallback:", first_entry.completion_item.label)
              if not current_popup.last_item or 
                 current_popup.last_item.label ~= first_entry.completion_item.label then
                create_signature_popup(first_entry.completion_item, main_buf)
              end
            else
              debug_print("First entry has no completion_item")
            end
          else
            debug_print("No entries found")
          end
        end
      end, 50)
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

return M 