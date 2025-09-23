local fmt = require("vocal.utils").fmt
local api = require("vocal.api")

local M = {}

--- Checks if the configured local model file exists.
--- @param config table The configuration object
--- @return boolean|nil true if model file exists, false if configured but file not found,
---                     nil if local model is not configured enough for a check.
function M.check_local_model_exists(config)
  local model_cfg = config.local_model
  if not model_cfg or not model_cfg.model or not model_cfg.path then
    return nil -- Not configured enough to check
  end

  local model_file = fmt("%s/%s.pt", vim.fn.expand(model_cfg.path), model_cfg.model)
  local exists = vim.fn.filereadable(model_file) == 1
  api.debug_log(
    exists and fmt("Local model file found: %s", model_file)
      or fmt("Local model file not found: %s", model_file)
  )
  return exists
end

--- Validates the current configuration settings.
--- Notifies the user of issues and may revert to defaults for problematic fields.
--- @param config table The configuration to validate
--- @return boolean isValid True if configuration is valid, false otherwise.
function M.validate_config(config)
  local all_valid = true
  local errors = {}
  local defaultConfig = require("vocal.config") -- To access original defaults

  -- Validate delete_recordings
  if type(config.delete_recordings) ~= "boolean" then
    table.insert(
      errors,
      fmt(
        "delete_recordings must be a boolean (true/false). Using default: %s",
        tostring(defaultConfig.delete_recordings)
      )
    )
    config.delete_recordings = defaultConfig.delete_recordings
    all_valid = false
  end

  -- Validate recording_dir
  if type(config.recording_dir) ~= "string" or config.recording_dir == "" then
    table.insert(
      errors,
      fmt(
        "recording_dir must be a non-empty string. Using default: %s",
        tostring(defaultConfig.recording_dir)
      )
    )
    config.recording_dir = defaultConfig.recording_dir
    all_valid = false
  end
  -- Ensure recording_dir exists (or can be created)
  if vim.fn.isdirectory(vim.fn.expand(config.recording_dir)) == 0 then
    local success, err =
      os.execute(fmt('mkdir -p "%s"', vim.fn.expand(config.recording_dir)))
    if not success then -- os.execute returns true on success (exit code 0)
      table.insert(
        errors,
        fmt(
          "recording_dir '%s' could not be created: %s. Please check permissions or path.",
          config.recording_dir,
          err or "unknown error"
        )
      )
      all_valid = false -- Critical if dir can't be made
    end
  end

  -- Validate local_model
  if config.local_model ~= nil and type(config.local_model) ~= "table" then
    table.insert(errors, "local_model must be a table or nil. Disabling local model usage.")
    config.local_model = nil -- Revert to not using local model
    all_valid = false
  elseif type(config.local_model) == "table" then
    if
      not (type(config.local_model.model) == "string" and config.local_model.model ~= "")
    then
      table.insert(
        errors,
        "local_model.model must be a non-empty string. Disabling local model usage."
      )
      config.local_model = nil
      all_valid = false
    end
    if
      config.local_model
      and not (type(config.local_model.path) == "string" and config.local_model.path ~= "")
    then
      table.insert(
        errors,
        "local_model.path must be a non-empty string. Disabling local model usage."
      )
      config.local_model = nil
      all_valid = false
    end
  end

  -- Validate api configuration (if local_model is not primary)
  if config.local_model == nil then -- Only validate API settings if API is likely to be used
    if type(config.api) ~= "table" then
      table.insert(errors, "api configuration must be a table. Using default API settings.")
      config.api = defaultConfig.api
      all_valid = false
    else
      if not (type(config.api.timeout) == "number" and config.api.timeout > 0) then
        table.insert(
          errors,
          fmt(
            "api.timeout must be a positive number. Using default: %d",
            defaultConfig.api.timeout
          )
        )
        config.api.timeout = defaultConfig.api.timeout
        all_valid = false
      end
    end
  end

  if #errors > 0 then
    local error_msg_parts =
      { "Vocal.nvim: Invalid configuration detected (see :messages for details):" }
    for _, err_detail in ipairs(errors) do
      table.insert(error_msg_parts, "- " .. err_detail)
    end
    vim.notify(
      table.concat(error_msg_parts, "\n"),
      vim.log.levels.WARN,
      { title = "Vocal.nvim Configuration" }
    )
  end
  return all_valid
end

return M