local fmt = require("vocal.utils").fmt
local recording = require("vocal.recording")
local ui = require("vocal.ui")
local api = require("vocal.api")
local async = require("plenary.async")
local transcription = require("vocal.transcription")
local validation = require("vocal.validation")
local error_handling = require("vocal.error_handling")
local file_utils = require("vocal.file_utils")

local M = {}
M.config = require("vocal.config") -- Initial config, will be extended by setup

--- Resolved API key for transcription (cached after first resolution).
--- @type string|nil
local resolved_api_key = nil

--- Stores the receiver end of the channel for the current recording.
--- @type (fun(): table)|nil
local current_recording_channel_rx = nil

--- Stores the start time of the current recording for duration calculation.
--- @type number|nil
local recording_start_time = nil

--- Public setup function for the plugin.
--- Merges user options, sets up API/UI configs, creates command and keymap.
--- @param opts table|nil User configuration options table.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Configure debug mode early
  if M.config.debug ~= nil then api.set_debug_mode(M.config.debug) end

  -- Validate the merged configuration
  validation.validate_config(M.config) -- This might modify M.config by reverting invalid fields to defaults

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
      error_handling.report_error(
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

    transcription.set_pending_transcription_ui_status(M.config) -- Set UI immediately based on config

    if not current_recording_channel_rx then
      error_handling.report_error(
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
        resolved_api_key = resolved_api_key or api.resolve_api_key(M.config.api_key)
        recording_start_time = transcription.handle_recording_completion(
          result_data,
          M.config,
          resolved_api_key,
          recording_start_time
        )
      else
        -- Error occurred while waiting on the channel or rx() itself threw an error.
        -- 'result_data' here is the error message from pcall.
        local err_msg_detail =
          fmt("Error waiting for recording completion signal: %s", tostring(result_data))
        error_handling.report_error("Recording completion signal error.", err_msg_detail)

        -- Reset timing on error
        recording_start_time = nil

        -- Attempt to delete if file exists and config allows, as a fallback.
        if M.config.delete_recordings and vim.fn.filereadable(filename_expected) == 1 then
          file_utils.delete_recording_file(filename_expected)
        end
      end
    end)
  else
    -- Start a new recording
    local function on_recording_start(started_filename)
      -- Record start time for duration calculation
      recording_start_time = vim.loop.hrtime() / 1000000 -- Convert to milliseconds
      vim.schedule(function() -- Ensure UI call is on main thread
        ui.show_recording_status()
      end)
      api.debug_log(
        fmt(
          "Recording started at %dms. UI updated for: %s",
          recording_start_time,
          started_filename
        )
      )
    end

    local function on_recording_start_error(err_msg_start)
      error_handling.report_error(fmt("Recording start error: %s", err_msg_start))
      current_recording_channel_rx = nil -- Clear channel if start failed
      recording_start_time = nil -- Reset timing on error
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
