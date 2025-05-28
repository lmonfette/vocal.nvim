local fmt = require("vocal.utils").fmt
local recording = require("vocal.recording")
local ui = require("vocal.ui")
local api = require("vocal.api")
local buffer = require("vocal.buffer")
local Job = require("plenary.job")
local async = require("plenary.async")

local M = {}
M.config = require("vocal.config") -- Initial config, will be extended by setup

--- Path to the Python transcription script.
--- @type string
local transcribe_path = assert(
  vim.api.nvim_get_runtime_file("python/transcribe.py", false)[1],
  "transcribe.py not found in runtime path"
)

--- Resolved API key for transcription (cached after first resolution).
--- @type string|nil
local resolved_api_key = nil

--- Stores the receiver end of the channel for the current recording.
--- @type (fun(): table)|nil
local current_recording_channel_rx = nil

-- Utility Functions (Consolidation & Readability)

--- Normalizes transcribed text by trimming whitespace and standardizing newlines.
--- @param text string|nil The text to normalize.
--- @return string The normalized text, or an empty string if input is nil or not a string.
local function normalize_transcribed_text(text)
  if type(text) ~= "string" then return "" end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r\n", "\n"))
end

--- Displays an error message to the user and logs internal details.
--- @param user_message string The message to show in the UI.
--- @param internal_details string|nil Specific details for debug logging (defaults to user_message).
local function report_error(user_message, internal_details)
  internal_details = internal_details or user_message
  api.debug_log("Error: " .. internal_details)
  vim.schedule(function() -- Ensure UI calls are on main thread
    ui.hide_status()
    ui.show_error_status(user_message)
  end)
end

--- Deletes a recording file with platform-specific process cleanup.
--- Uses defer_fn to avoid blocking and allow processes to terminate.
--- @param filename string|nil The path to the recording file to delete.
--- @return boolean True if deletion process was initiated, false if file not found or filename is nil.
local function delete_recording_file(filename)
  if not filename or vim.fn.filereadable(filename) ~= 1 then return false end
  vim.defer_fn(function()
    -- Attempt to kill lingering processes associated with the file
    if vim.fn.has("unix") == 1 or vim.fn.has("mac") == 1 then
      os.execute(fmt("pkill -f %s > /dev/null 2>&1 || true", vim.fn.shellescape(filename)))
    elseif vim.fn.has("win32") == 1 then
      os.execute(
        fmt(
          'taskkill /F /FI "WINDOWTITLE eq *%s*" > nul 2>&1 || exit /b 0',
          vim.fn.fnamemodify(filename, ":t")
        )
      )
    end
    -- Give a short delay for process termination before trying to delete
    vim.defer_fn(function()
      local success, err = os.remove(filename)
      api.debug_log(
        success and fmt("Deleted: %s", filename)
          or fmt("Failed to delete: %s (Error: %s)", filename, err or "unknown")
      )
    end, 200) -- Delay before os.remove
  end, 300) -- Initial delay for pkill/taskkill
  return true
end

--- Handles the successful transcription of an audio file.
--- Inserts the text, optionally deletes the recording, and shows a success message.
--- @param filename string The path to the original recording file.
--- @param transcribed_text string The transcribed text from the audio.
local function handle_transcription_success(filename, transcribed_text)
  local normalized_text = normalize_transcribed_text(transcribed_text)
  if normalized_text ~= "" then
    buffer.insert_at_cursor(normalized_text)
  else
    api.debug_log("Transcription returned empty or whitespace-only result.")
  end

  local msg = "Transcription complete"
  if M.config.delete_recordings then
    if delete_recording_file(filename) then
      msg = fmt("%s (recording deleted)", msg)
      -- delete_recording_file logs its own success/failure for deletion
    else
      api.debug_log(
        fmt(
          "Deletion not initiated by handle_transcription_success or file not found for: %s",
          filename
        )
      )
    end
  end
  ui.show_success_status(msg)
end

--- Processes a local recording using the configured local model.
--- Handles model download status updates via stderr parsing from the Python script.
--- @param filename string The path to the recording file.
local function process_local_recording(filename)
  local model_cfg = M.config.local_model
  if not model_cfg or not model_cfg.model or not model_cfg.path then
    report_error("Invalid local model configuration")
    return
  end

  local STATUS_PREFIX = "DOWNLOAD_STATUS:" -- Specific to transcribe.py output
  local MSG_ALREADY_DOWNLOADED = "MODEL_ALREADY_DOWNLOADED"
  local MSG_DOWNLOADING_MODEL = "DOWNLOADING_MODEL:"
  local MSG_DOWNLOADING_PROGRESS = "DOWNLOADING_PROGRESS:"
  local MSG_DOWNLOAD_COMPLETE = "MODEL_DOWNLOAD_COMPLETE"

  local function handle_stderr(_, data_line)
    if type(data_line) ~= "string" then -- plenary.job on_stderr data is a line string usually
      api.debug_log(fmt("Python script stderr (unexpected type): %s", vim.inspect(data_line)))
      return false -- Not processed
    end

    if data_line:match(fmt("^%s", STATUS_PREFIX)) then
      local message = data_line:gsub(fmt("^%s", STATUS_PREFIX), "")
      vim.schedule(function() -- Ensure UI calls are on main thread
        api.debug_log(fmt("Received download status: %s", message))
        if message:match(MSG_ALREADY_DOWNLOADED) then
          api.debug_log(
            fmt(
              "Script confirms model %s already downloaded. Setting Transcribing status.",
              model_cfg.model
            )
          )
          ui.start_transcribing_status()
        elseif message:match(fmt("^%s", MSG_DOWNLOADING_MODEL)) then
          local model_name_from_script = message:gsub(fmt("^%s", MSG_DOWNLOADING_MODEL), "")
          api.debug_log(fmt("Script confirms downloading model: %s", model_name_from_script))
          ui.show_downloading_status(model_name_from_script)
        elseif message:match(fmt("^%s", MSG_DOWNLOADING_PROGRESS)) then
          ui.show_downloading_status(message:gsub(fmt("^%s", MSG_DOWNLOADING_PROGRESS), ""))
        elseif message:match(MSG_DOWNLOAD_COMPLETE) then
          api.debug_log(
            "Model download complete message received. Setting Transcribing status."
          )
          ui.start_transcribing_status() -- Switch UI to transcribing
        else
          api.debug_log(fmt("Unhandled DOWNLOAD_STATUS message: %s", message))
        end
      end)
      return true -- Processed
    else
      -- Log other stderr lines for debugging without treating them as DOWNLOAD_STATUS
      api.debug_log(fmt("Python script stderr: %s", data_line))
      return false -- Not processed as a status update
    end
  end

  local function handle_exit(job, exit_code)
    vim.schedule(function() -- Ensure UI calls are on main thread
      ui.hide_status() -- Always hide status on exit
      if exit_code == 0 then -- Success
        local raw_text = table.concat(job:result() or {}, "\n")
        handle_transcription_success(filename, raw_text)
      else -- Failure
        local stderr_lines = job:stderr_result() or {}
        local filtered_stderr_for_user = {}
        for _, line in ipairs(stderr_lines) do
          if not line:match(fmt("^%s", STATUS_PREFIX)) then
            table.insert(filtered_stderr_for_user, line)
          end
        end
        local user_stderr_output =
          normalize_transcribed_text(table.concat(filtered_stderr_for_user, "\n"))

        local user_error_message = fmt("Local transcription failed (code: %d)", exit_code)
        if user_stderr_output ~= "" then
          user_error_message = fmt("%s:\n%s", user_error_message, user_stderr_output)
        end

        local full_stderr_for_log = table.concat(stderr_lines, "\n")
        local internal_details = fmt(
          "Local transcription job failed. Code: %d. Full Stderr:\n%s",
          exit_code,
          full_stderr_for_log
        )
        report_error(user_error_message, internal_details)
      end
    end)
  end

  api.debug_log("Starting local transcription job...")
  Job:new({
    command = "python",
    args = { transcribe_path, filename, model_cfg.model, model_cfg.path },
    on_stdout = function(_, data) -- Assuming stdout is only the final transcription or empty
      return not data or data:match("^%s*$")
    end,
    on_stderr = handle_stderr, -- plenary.job calls this for each line of stderr
    on_exit = handle_exit,
  }):start()
end

--- Waits for a recording file to stabilize (exist and size stops changing), then processes it.
--- @param filename string The path to the recording file.
local function process_recording(filename)
  vim.loop.sleep(200) -- Initial brief pause after stop signal or job exit

  local attempts = 15 -- Check for ~1.5 seconds total (200ms + 15*100ms)
  local file_ready = false
  local last_size = -1

  for i = 1, attempts do
    local exists = vim.fn.filereadable(filename) == 1
    local current_size = vim.fn.getfsize(filename) or -1
    api.debug_log(
      fmt(
        "process_recording check %d/%d for %s: exists=%s, size=%d, last_size=%d",
        i,
        attempts,
        filename,
        tostring(exists),
        current_size,
        last_size
      )
    )
    if exists and current_size > 0 and current_size == last_size then
      file_ready = true
      api.debug_log(
        fmt("File %s ready after %dms check (loop iteration %d).", filename, 200 + i * 100, i)
      )
      break
    end
    last_size = current_size
    if i < attempts then
      vim.loop.sleep(100) -- Wait before next check
    end
  end

  if not file_ready then
    local final_exists = vim.fn.filereadable(filename) == 1
    local final_size = vim.fn.getfsize(filename) or -1
    local log_details = fmt(
      "File %s not found or unstable after %d attempts. Exists: %s, Size: %s",
      filename,
      attempts,
      tostring(final_exists),
      tostring(final_size)
    )
    report_error("Recording file processing error (timeout/unstable)", log_details)
    if M.config.delete_recordings and final_exists then delete_recording_file(filename) end
    return
  end

  -- File is ready, decide transcription path
  if M.config.local_model and M.config.local_model.model and M.config.local_model.path then
    process_local_recording(filename)
  else
    resolved_api_key = resolved_api_key or api.resolve_api_key(M.config.api_key)
    if not resolved_api_key then
      report_error("OpenAI API key not found")
      if M.config.delete_recordings then -- Also delete if API key is the issue post-recording
        delete_recording_file(filename)
      end
      return
    end

    -- API transcription success/error callbacks
    local function on_api_success(api_text_response)
      vim.schedule(function() -- Ensure UI calls are on main thread
        ui.hide_status()
        handle_transcription_success(filename, api_text_response)
      end)
    end
    local function on_api_error(err_msg)
      report_error(fmt("API Transcription failed: %s", err_msg))
      if M.config.delete_recordings then -- Delete if API transcription fails
        delete_recording_file(filename)
      end
    end

    api.transcribe(filename, resolved_api_key, on_api_success, on_api_error)
  end
end

--- Checks if the configured local model file exists.
--- @return boolean|nil true if model file exists, false if configured but file not found,
---                     nil if local model is not configured enough for a check.
local function check_local_model_exists()
  local model_cfg = M.config.local_model
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

--- Sets the UI status to "Downloading" or "Transcribing" based on local model availability
--- when a recording is stopped and transcription is pending.
local function set_pending_transcription_ui_status()
  local use_local_model = M.config.local_model
    and M.config.local_model.model
    and M.config.local_model.path
  local local_model_file_exists -- Will be true or false if use_local_model is true

  if use_local_model then
    local_model_file_exists = check_local_model_exists()
    -- If check_local_model_exists returned nil here, it would imply 'use_local_model'
    -- was true but config was still somehow insufficient for the check, which
    -- 'use_local_model' definition tries to prevent.
    -- For safety, treat nil return from check as 'not found' if use_local_model was true.
    if local_model_file_exists == nil then local_model_file_exists = false end
  end

  vim.schedule(function() -- Ensure UI calls are on main thread
    if use_local_model then
      if local_model_file_exists == false then -- Explicitly false: configured but physical file not found
        local model_name = M.config.local_model.model -- 'model' field known to exist due to 'use_local_model'
        ui.show_downloading_status(model_name)
        api.debug_log(
          fmt("Set immediate UI to Downloading (model file not found): %s", model_name)
        )
      else -- Model exists (true)
        ui.start_transcribing_status()
        api.debug_log("Set immediate UI to Transcribing (Local model present)")
      end
    else -- API path
      ui.start_transcribing_status()
      api.debug_log("Set immediate UI to Transcribing (API path)")
    end
  end)
end

--- Handles completion of recording after the recording job exits or its channel signals.
--- @param recording_result table The result table from the recording channel.
--- Expected keys: filename, code, potentially_successful_exit, file_exists, file_size.
local function handle_recording_completion(recording_result)
  local filename = recording_result.filename
  local exit_code = recording_result.code
  local was_successful_exit = recording_result.potentially_successful_exit
  local file_exists = recording_result.file_exists
  local file_size = recording_result.file_size

  api.debug_log(
    fmt(
      "handle_recording_completion called for: %s with exit_code: %s, successful_exit: %s, file_exists: %s, file_size: %s",
      filename,
      tostring(exit_code),
      tostring(was_successful_exit),
      tostring(file_exists),
      tostring(file_size)
    )
  )

  if not filename then
    report_error(
      "Recording error: No filename after process exit.",
      "handle_recording_completion: No filename provided by job exit/channel."
    )
    return
  end

  if was_successful_exit and file_exists and file_size > 0 then
    api.debug_log(
      fmt(
        "File %s appears usable based on channel data. Proceeding to process_recording.",
        filename
      )
    )
    -- process_recording starts with vim.loop.sleep, better to schedule this call
    -- to ensure M.transcribe's async block doesn't hang the main thread.
    vim.schedule(function() process_recording(filename) end)
  else
    local err_msg_user = fmt(
      "Recording %s unusable or empty (exit: %s, success_flag: %s, exists: %s, size: %s). Not transcribing.",
      filename,
      tostring(exit_code),
      tostring(was_successful_exit),
      tostring(file_exists),
      tostring(file_size)
    )
    report_error(err_msg_user) -- Log details are same as user message here
    if M.config.delete_recordings and file_exists then delete_recording_file(filename) end
  end
end

--- Validates the current M.config settings.
--- Notifies the user of issues and may revert to defaults for problematic fields.
--- @return boolean isValid True if configuration is valid, false otherwise.
local function validate_config()
  local all_valid = true
  local errors = {}
  local defaultConfig = require("vocal.config") -- To access original defaults

  -- Validate delete_recordings
  if type(M.config.delete_recordings) ~= "boolean" then
    table.insert(
      errors,
      fmt(
        "delete_recordings must be a boolean (true/false). Using default: %s",
        tostring(defaultConfig.delete_recordings)
      )
    )
    M.config.delete_recordings = defaultConfig.delete_recordings
    all_valid = false
  end

  -- Validate recording_dir
  if type(M.config.recording_dir) ~= "string" or M.config.recording_dir == "" then
    table.insert(
      errors,
      fmt(
        "recording_dir must be a non-empty string. Using default: %s",
        tostring(defaultConfig.recording_dir)
      )
    )
    M.config.recording_dir = defaultConfig.recording_dir
    all_valid = false
  end
  -- Ensure recording_dir exists (or can be created)
  if vim.fn.isdirectory(vim.fn.expand(M.config.recording_dir)) == 0 then
    local success, err =
      os.execute(fmt('mkdir -p "%s"', vim.fn.expand(M.config.recording_dir)))
    if not success then -- os.execute returns true on success (exit code 0)
      table.insert(
        errors,
        fmt(
          "recording_dir '%s' could not be created: %s. Please check permissions or path.",
          M.config.recording_dir,
          err or "unknown error"
        )
      )
      all_valid = false -- Critical if dir can't be made
    end
  end

  -- Validate local_model
  if M.config.local_model ~= nil and type(M.config.local_model) ~= "table" then
    table.insert(errors, "local_model must be a table or nil. Disabling local model usage.")
    M.config.local_model = nil -- Revert to not using local model
    all_valid = false
  elseif type(M.config.local_model) == "table" then
    if
      not (type(M.config.local_model.model) == "string" and M.config.local_model.model ~= "")
    then
      table.insert(
        errors,
        "local_model.model must be a non-empty string. Disabling local model usage."
      )
      M.config.local_model = nil
      all_valid = false
    end
    if
      M.config.local_model
      and not (type(M.config.local_model.path) == "string" and M.config.local_model.path ~= "")
    then
      table.insert(
        errors,
        "local_model.path must be a non-empty string. Disabling local model usage."
      )
      M.config.local_model = nil
      all_valid = false
    end
  end

  -- Validate api configuration (if local_model is not primary)
  if M.config.local_model == nil then -- Only validate API settings if API is likely to be used
    if type(M.config.api) ~= "table" then
      table.insert(errors, "api configuration must be a table. Using default API settings.")
      M.config.api = defaultConfig.api
      all_valid = false
    else
      if not (type(M.config.api.timeout) == "number" and M.config.api.timeout > 0) then
        table.insert(
          errors,
          fmt(
            "api.timeout must be a positive number. Using default: %d",
            defaultConfig.api.timeout
          )
        )
        M.config.api.timeout = defaultConfig.api.timeout
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

--- Public setup function for the plugin.
--- Merges user options, sets up API/UI configs, creates command and keymap.
--- @param opts table|nil User configuration options table.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Configure debug mode early
  if M.config.debug ~= nil then api.set_debug_mode(M.config.debug) end

  -- Validate the merged configuration
  validate_config() -- This might modify M.config by reverting invalid fields to defaults

  -- Apply (potentially validated/modified) configurations to submodules
  if M.config.api then -- opts.api was the old way, now use M.config.api
    api.set_options(M.config.api)
  end
  ui.set_config(M.config) -- UI needs the full config

  vim.api.nvim_create_user_command(
    "Vocal",
    M.transcribe, -- Function reference
    { desc = "Start/stop Vocal recording and transcribe" }
  )
  if M.config.keymap then
    vim.keymap.set(
      "n",
      M.config.keymap,
      ":Vocal<CR>",
      { desc = "Start/stop Vocal recording", silent = true }
    )
  end
  api.debug_log("Vocal setup complete.")
end

--- Toggles audio recording or initiates transcription based on the current state.
--- If not recording, starts a new audio recording.
--- If recording, stops the current recording and proceeds to transcribe the audio
--- using either a local model or the configured API.
--- This function is typically invoked by the :Vocal user command.
function M.transcribe()
  if recording.is_recording() then
    -- Stop existing recording
    local filename_expected = recording.stop_recording()

    if not filename_expected then
      report_error(
        "Failed to stop recording (no active recording found).",
        "M.transcribe: stop_recording returned nil (no active recording)."
      )
      current_recording_channel_rx = nil -- Ensure channel is cleared
      return
    end

    api.debug_log(
      fmt(
        "M.transcribe: recording.stop_recording() called for expected file %s. Waiting for job exit signal via channel.",
        filename_expected
      )
    )

    set_pending_transcription_ui_status() -- Set UI immediately based on config

    if not current_recording_channel_rx then
      report_error(
        "Internal error: Recording channel missing after stop.",
        "M.transcribe: No active recording channel (current_recording_channel_rx is nil) after stop. Cannot wait for completion."
      )
      return
    end

    local rx = current_recording_channel_rx
    current_recording_channel_rx = nil -- Consume the channel

    async.run(function()
      api.debug_log(
        "M.transcribe: Coroutine started, awaiting recording completion signal from channel for "
          .. filename_expected
      )
      local success, result_data = pcall(rx) -- rx is the async function that awaits the data from the channel

      if success then
        api.debug_log("M.transcribe: Received data from channel:", result_data)
        handle_recording_completion(result_data)
      else
        -- Error occurred while waiting on the channel or rx() itself threw an error.
        -- 'result_data' here is the error message from pcall.
        local err_msg_detail =
          fmt("Error waiting for recording completion signal: %s", tostring(result_data))
        report_error("Recording completion signal error.", err_msg_detail)

        -- Attempt to delete if file exists and config allows, as a fallback.
        if M.config.delete_recordings and vim.fn.filereadable(filename_expected) == 1 then
          delete_recording_file(filename_expected)
        end
      end
    end)
  else
    -- Start a new recording
    local function on_recording_start(started_filename)
      vim.schedule(function() -- Ensure UI call is on main thread
        ui.show_recording_status()
      end)
      api.debug_log(fmt("Recording started. UI updated for: %s", started_filename))
    end

    local function on_recording_start_error(err_msg_start)
      report_error(fmt("Recording start error: %s", err_msg_start))
      current_recording_channel_rx = nil -- Clear channel if start failed
    end

    current_recording_channel_rx = recording.start_recording(
      M.config.recording_dir,
      on_recording_start,
      on_recording_start_error
    )

    if not current_recording_channel_rx then
      api.debug_log(
        "M.transcribe: recording.start_recording did not return a channel. Recording likely failed to start (error should have been reported by on_recording_start_error)."
      )
    else
      api.debug_log("M.transcribe: New recording started. Channel receiver stored.")
    end
  end
end

--- Gets the filename of the currently active recording, if any.
--- @return string|nil The active recording filename or nil if not recording.
function M.get_recording_filename() return recording.active_filename end

return M
