vim.api.nvim_create_user_command("OtterActivate", require("otter").activate, {})
vim.api.nvim_create_user_command("OtterDeactivate", require("otter").deactivate, {})

-- Test completion signature popups
vim.api.nvim_create_user_command("OtterShowCompletionSignature", function()
  local completion_signatures = require("otter.completion_signatures")
  completion_signatures.show_signature_for_current_item()
end, { desc = "Show signature for current completion item" })

-- Debug completion signatures
vim.api.nvim_create_user_command("OtterDebugCompletionSignatures", function(opts)
  local completion_signatures = require("otter.completion_signatures")
  local enable = opts.args == "on" or opts.args == "true" or opts.args == "1"
  local disable = opts.args == "off" or opts.args == "false" or opts.args == "0"
  
  if enable then
    completion_signatures.set_debug(true)
    vim.notify("Completion signatures debug: ENABLED", vim.log.levels.INFO)
  elseif disable then
    completion_signatures.set_debug(false)
    vim.notify("Completion signatures debug: DISABLED", vim.log.levels.INFO)
  else
    vim.notify("Usage: :OtterDebugCompletionSignatures [on|off]", vim.log.levels.WARN)
  end
end, { 
  nargs = "?", 
  complete = function() return {"on", "off"} end,
  desc = "Enable/disable debug logging for completion signatures" 
})

vim.api.nvim_create_user_command("OtterExport", function(opts)
  require("otter").export(opts.bang == true)
end, { bang = true })
vim.api.nvim_create_user_command("OtterExportAs", function(opts)
  local force = opts.bang == true
  local lang = opts.fargs[1]
  local fname = opts.fargs[2]
  if not lang or not fname then
    vim.notify("Usage: OtterExportAs <lang> <fname>", vim.log.levels.ERROR)
    return
  end
  require("otter").export_otter_as(lang, fname, force)
end, {
  bang = true,
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local main_nr = vim.api.nvim_get_current_buf()
    local langs = require("otter.keeper").rafts[main_nr].languages
    return vim.fn.filter(langs, function(lang)
      return vim.startswith(lang, arg_lead)
    end)
  end,
})
