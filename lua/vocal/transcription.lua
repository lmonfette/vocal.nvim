local fmt = require("vocal.utils").fmt
local Job = require("plenary.job")
local api = require("vocal.api")
local ui = require("vocal.ui")
local buffer = require("vocal.buffer")
local file_utils = require("vocal.file_utils")
local error_handling = require("vocal.error_handling")
local validation = require("vocal.validation")

local M = {}

--- Path to the Python transcription script.
--- @type string
local transcribe_path = assert(
  vim.api.nvim_get_runtime_file("python/transcribe.py", false)[1],
  "transcribe.py not found in runtime path"
)

--- Handles the successful transcription of an audio file.
--- Inserts the text, optionally deletes the recording, and shows a success message.
--- @param filename string The path to the original recording file.
--- @param transcribed_text string The transcribed text from the audio.
--- @param config table The plugin configuration
function M.handle_transcription_success(filename, transcribed_text, config)
  local normalized_text = file_utils.normalize_transcribed_text(transcribed_text)
  if normalized_text ~= "" then
    buffer.insert_at_cursor(normalized_text)
  else
    api.debug_log("Transcription returned empty or whitespace-only result.")
  end

  local msg = "Transcription complete"
  if config.delete_recordings then
    if file_utils.delete_recording_file(filename) then
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
--- @param config table The plugin configuration
function M.process_local_recording(filename, config)
  local model_cfg = config.local_model
  if not model_cfg or not model_cfg.model or not model_cfg.path then
    error_handling.report_error("Invalid local model configuration")
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
        M.handle_transcription_success(filename, raw_text, config)
      else -- Failure
        local stderr_lines = job:stderr_result() or {}
        local filtered_stderr_for_user = {}
        for _, line in ipairs(stderr_lines) do
          if not line:match(fmt("^%s", STATUS_PREFIX)) then
            table.insert(filtered_stderr_for_user, line)
          end
        end
        local user_stderr_output =
          file_utils.normalize_transcribed_text(table.concat(filtered_stderr_for_user, "\n"))

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
        error_handling.report_error(user_error_message, internal_details)
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
--- Uses adaptive timing based on file size and recording characteristics.
--- @param filename string The path to the recording file.
--- @param recording_duration_ms number|nil Estimated recording duration in milliseconds for adaptive timing.
--- @param config table The plugin configuration
--- @param resolved_api_key string|nil The resolved API key for transcription
function M.process_recording(filename, recording_duration_ms, config, resolved_api_key)
  -- Adaptive initial pause: shorter for short recordings, but minimum 50ms
  local initial_pause = recording_duration_ms
      and math.max(50, math.min(200, recording_duration_ms / 10))
    or 100

  vim.loop.sleep(initial_pause)

  -- Adaptive attempts and intervals based on recording duration
  local base_attempts = 10
  local base_interval = 50 -- Reduced from 100ms for better responsiveness

  if recording_duration_ms then
    if recording_duration_ms < 1000 then -- Very short recordings (< 1 second)
      base_attempts = 6 -- Check for ~300ms total
      base_interval = 50
    elseif recording_duration_ms < 3000 then -- Short recordings (< 3 seconds)
      base_attempts = 8 -- Check for ~400ms total
      base_interval = 50
    else -- Longer recordings
      base_attempts = 15 -- Check for ~750ms total
      base_interval = 50
    end
  end

  local attempts = base_attempts
  local interval = base_interval
  local file_ready = false
  local last_size = -1
  local stable_count = 0
  local required_stable_checks = recording_duration_ms
      and (recording_duration_ms < 1000 and 1 or 2)
    or 2

  api.debug_log(
    fmt(
      "process_recording starting for %s: duration_ms=%s, initial_pause=%dms, attempts=%d, interval=%dms, required_stable=%d",
      filename,
      tostring(recording_duration_ms or "unknown"),
      initial_pause,
      attempts,
      interval,
      required_stable_checks
    )
  )

  for i = 1, attempts do
    local exists = vim.fn.filereadable(filename) == 1
    local current_size = vim.fn.getfsize(filename) or -1

    api.debug_log(
      fmt(
        "process_recording check %d/%d for %s: exists=%s, size=%d, last_size=%d, stable_count=%d",
        i,
        attempts,
        filename,
        tostring(exists),
        current_size,
        last_size,
        stable_count
      )
    )

    if exists and current_size > 0 then
      if current_size == last_size then
        stable_count = stable_count + 1
        if stable_count >= required_stable_checks then
          file_ready = true
          api.debug_log(
            fmt(
              "File %s ready after %dms (iteration %d, stable for %d checks).",
              filename,
              initial_pause + i * interval,
              i,
              stable_count
            )
          )
          break
        end
      else
        stable_count = 0 -- Reset stability counter if size changed
      end
    end

    last_size = current_size
    if i < attempts then vim.loop.sleep(interval) end
  end

  if not file_ready then
    local final_exists = vim.fn.filereadable(filename) == 1
    local final_size = vim.fn.getfsize(filename) or -1

    -- For very small files that exist, be more lenient
    if final_exists and final_size > 0 then
      api.debug_log(
        fmt(
          "File %s exists with size %d but didn't stabilize. Proceeding with transcription anyway for short recording.",
          filename,
          final_size
        )
      )
      file_ready = true
    elseif final_exists and recording_duration_ms and recording_duration_ms < 2000 then
      -- Very short recordings might take longer to show their true size
      api.debug_log(
        fmt(
          "Very short recording (%dms) - giving additional time for file to show content",
          recording_duration_ms
        )
      )
      vim.loop.sleep(200) -- Additional wait for very short recordings
      local delayed_size = vim.fn.getfsize(filename) or -1
      api.debug_log(fmt("After additional delay: size=%d", delayed_size))

      if delayed_size > 0 then
        file_ready = true
        api.debug_log("File now shows content after additional delay")
      else
        -- Check if the file has a valid WAV header even if size is reported as 0
        local file_handle = io.open(filename, "rb")
        if file_handle then
          local header = file_handle:read(4)
          file_handle:close()
          if header == "RIFF" then
            api.debug_log("File has valid WAV header despite size=0, proceeding")
            file_ready = true
          else
            api.debug_log("File exists but has no valid WAV header")
          end
        end
      end
    end

    if not file_ready then
      local log_details = fmt(
        "File %s not found or empty after %d attempts. Exists: %s, Size: %s, Duration: %sms",
        filename,
        attempts,
        tostring(final_exists),
        tostring(final_size),
        tostring(recording_duration_ms or "unknown")
      )
      error_handling.report_error(
        "Recording file processing error (timeout/empty)",
        log_details
      )
      if config.delete_recordings and final_exists then
        file_utils.delete_recording_file(filename)
      end
      return
    end
  end

  -- File is ready, decide transcription path
  if config.local_model and config.local_model.model and config.local_model.path then
    M.process_local_recording(filename, config)
  else
    if not resolved_api_key then
      error_handling.report_error("OpenAI API key not found")
      if config.delete_recordings then -- Also delete if API key is the issue post-recording
        file_utils.delete_recording_file(filename)
      end
      return
    end

    -- API transcription success/error callbacks
    local function on_api_success(api_text_response)
      vim.schedule(function() -- Ensure UI calls are on main thread
        ui.hide_status()
        M.handle_transcription_success(filename, api_text_response, config)
      end)
    end
    local function on_api_error(err_msg)
      error_handling.report_error(fmt("API Transcription failed: %s", err_msg))
      if config.delete_recordings then -- Delete if API transcription fails
        file_utils.delete_recording_file(filename)
      end
    end

    api.transcribe(filename, resolved_api_key, on_api_success, on_api_error)
  end
end

--- Sets the UI status to "Downloading" or "Transcribing" based on local model availability
--- when a recording is stopped and transcription is pending.
--- @param config table The plugin configuration
function M.set_pending_transcription_ui_status(config)
  local use_local_model = config.local_model
    and config.local_model.model
    and config.local_model.path
  local local_model_file_exists -- Will be true or false if use_local_model is true

  if use_local_model then
    local_model_file_exists = validation.check_local_model_exists(config)
    -- If check_local_model_exists returned nil here, it would imply 'use_local_model'
    -- was true but config was still somehow insufficient for the check, which
    -- 'use_local_model' definition tries to prevent.
    -- For safety, treat nil return from check as 'not found' if use_local_model was true.
    if local_model_file_exists == nil then local_model_file_exists = false end
  end

  vim.schedule(function() -- Ensure UI calls are on main thread
    if use_local_model then
      if local_model_file_exists == false then -- Explicitly false: configured but physical file not found
        local model_name = config.local_model.model -- 'model' field known to exist due to 'use_local_model'
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
--- @param config table The plugin configuration
--- @param resolved_api_key string|nil The resolved API key for transcription
--- @param recording_start_time number|nil The start time of the recording
--- @return number|nil The updated recording_start_time (should be nil after processing)
function M.handle_recording_completion(
  recording_result,
  config,
  resolved_api_key,
  recording_start_time
)
  local filename = recording_result.filename
  local exit_code = recording_result.code
  local was_successful_exit = recording_result.potentially_successful_exit
  local file_exists = recording_result.file_exists
  local file_size = recording_result.file_size

  -- Calculate recording duration for adaptive processing
  local recording_duration_ms = nil
  if recording_start_time then
    recording_duration_ms = (vim.loop.hrtime() / 1000000) - recording_start_time
    api.debug_log(fmt("Recording duration calculated: %dms", recording_duration_ms))
  end

  api.debug_log(
    fmt(
      "handle_recording_completion called for: %s with exit_code: %s, successful_exit: %s, file_exists: %s, file_size: %s, duration_ms: %s",
      filename,
      tostring(exit_code),
      tostring(was_successful_exit),
      tostring(file_exists),
      tostring(file_size),
      tostring(recording_duration_ms or "unknown")
    )
  )

  if not filename then
    error_handling.report_error(
      "Recording error: No filename after process exit.",
      "handle_recording_completion: No filename provided by job exit/channel."
    )
    return nil -- Reset timing
  end

  -- More robust condition checking with explicit type validation and better logic for short recordings
  local success_exit = (was_successful_exit == true)
  local exists = (file_exists == true)
  local has_positive_size = (type(file_size) == "number" and file_size > 0)

  api.debug_log(
    fmt(
      "Condition check details: success_exit=%s, exists=%s, has_positive_size=%s (raw_size=%s)",
      tostring(success_exit),
      tostring(exists),
      tostring(has_positive_size),
      tostring(file_size)
    )
  )

  -- For very short recordings with exit code 15 (SIGTERM), be more lenient
  -- Sometimes sox creates a valid file but it appears as 0 bytes immediately after exit
  local should_proceed = false

  if success_exit and exists then
    if has_positive_size then
      -- Normal case: file exists and has content
      should_proceed = true
      api.debug_log("File has positive size, proceeding normally")
    elseif recording_duration_ms and recording_duration_ms < 2000 and exit_code == 15 then
      -- Special case: very short recording with SIGTERM, file might have content that hasn't been reported yet
      should_proceed = true
      api.debug_log(
        fmt(
          "Very short recording (%dms) with SIGTERM, proceeding despite size=%d",
          recording_duration_ms,
          file_size
        )
      )
    else
      api.debug_log(
        fmt(
          "File exists but size check failed: duration=%s, exit_code=%s, size=%s",
          tostring(recording_duration_ms),
          tostring(exit_code),
          tostring(file_size)
        )
      )
    end
  end

  if should_proceed then
    api.debug_log(
      fmt(
        "File %s appears usable based on channel data. Proceeding to process_recording with duration %sms.",
        filename,
        tostring(recording_duration_ms or "unknown")
      )
    )
    -- Reset recording timing
    recording_start_time = nil
    -- process_recording starts with vim.loop.sleep, better to schedule this call
    -- to ensure transcribe's async block doesn't hang the main thread.
    vim.schedule(
      function() M.process_recording(filename, recording_duration_ms, config, resolved_api_key) end
    )
  else
    local err_msg_user = fmt(
      "Recording %s unusable or empty (exit: %s, success_flag: %s, exists: %s, size: %s, duration: %sms). Not transcribing.",
      filename,
      tostring(exit_code),
      tostring(was_successful_exit),
      tostring(file_exists),
      tostring(file_size),
      tostring(recording_duration_ms or "unknown")
    )
    api.debug_log("Condition failure details: " .. err_msg_user)
    error_handling.report_error(err_msg_user) -- Log details are same as user message here
    recording_start_time = nil -- Reset timing
    if config.delete_recordings and exists then file_utils.delete_recording_file(filename) end
  end

  return recording_start_time
end

return M

