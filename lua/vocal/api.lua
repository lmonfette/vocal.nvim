local Job = require("plenary.job")
local fmt = require("vocal.utils").fmt

--- @diagnostic disable-next-line: unused-local
local M_NAME = "vocal" -- For potential use in more specific error messages or logging

-- Forward declaration for helper functions
local trim_whitespaces
local _write_to_log_file

-- Module-level variables for caching and state
local uploader_script_path = nil --- @type string|nil Path to the Python uploader script, initialized on first use.
local discovered_python_interpreter_path = nil --- @type string|nil Cached path to the Python interpreter.
local log_directory_verified_this_session = false --- @type boolean Tracks if log directory has been verified in the current session.

--- Module for Vocal, handling OpenAI API interaction for audio transcription.
--- Provides functions to configure, transcribe audio, and test API connectivity.
--- @class Vocal
local M = {
  --- Enable debug logging. This is typically set via a setup function or configuration.
  --- @type boolean
  debug_mode = false,

  --- Path to the log file. Defaults to `~/.cache/vocal.log`.
  --- @type string
  log_file = fmt("%s/.cache/vocal.log", os.getenv("HOME")),

  --- API request options for the transcription.
  --- These options are passed to the OpenAI API.
  --- @type table
  options = {
    model = "whisper-1", --- @type string The model to use for transcription (e.g., "whisper-1").
    language = nil, --- @type string|nil The language of the input audio (ISO 639-1 format, e.g., "en"). `nil` for auto-detect.
    response_format = "json", --- @type string The format of the transcript output (e.g., "json", "text", "srt", "vtt", "verbose_json").
    temperature = 0, --- @type number The sampling temperature, between 0 and 1. Higher values (e.g., 0.8) make output more random. Lower values (e.g., 0.2) make it more focused and deterministic.
    timeout = 300, --- @type number Timeout in seconds for the API request execution via the Python script.
  },
}

--- Trims leading and trailing whitespace from a string.
--- @param s string | nil The input string.
--- @return string | nil The trimmed string. Returns `nil` if input is `nil`.
--- Returns an empty string if the input string consists only of whitespace.
function trim_whitespaces(s)
  if type(s) ~= "string" then return s end
  return s:match("^%s*(.-)%s*$")
end

--- Writes a message to the configured log file.
--- Ensures the log directory exists and handles file I/O errors gracefully.
--- @param message_to_log string The exact string to write to the file.
function _write_to_log_file(message_to_log)
  if not log_directory_verified_this_session then
    local cache_dir = vim.fn.fnamemodify(M.log_file, ":h")
    if vim.fn.isdirectory(cache_dir) == 0 then
      local ok, err = pcall(vim.fn.mkdir, cache_dir, "p")
      if ok then
        log_directory_verified_this_session = true
      else
        print(
          fmt(
            "Vocal Plugin Error: Failed to create log directory %s: %s",
            cache_dir,
            tostring(err)
          )
        )
        -- Do not set flag to true, allow retry on next log call.
        -- Exit here to avoid trying to open a file in a non-existent/unwritable dir for this attempt.
        return
      end
    else
      log_directory_verified_this_session = true -- Directory already exists
    end
  end

  local file, err_open = io.open(M.log_file, "a")
  if file then
    local write_ok, err_write = pcall(function() file:write(message_to_log) end)
    if not write_ok then
      print(
        fmt(
          "Vocal Plugin Error: Failed to write to log file %s: %s",
          M.log_file,
          tostring(err_write)
        )
      )
    end

    local close_ok, err_close = pcall(function() file:close() end)
    if not close_ok then
      print(
        fmt(
          "Vocal Plugin Error: Failed to close log file %s: %s",
          M.log_file,
          tostring(err_close)
        )
      )
    end
  else
    log_directory_verified_this_session = false -- Reset flag to re-verify dir on next attempt
    print(
      fmt(
        "Vocal Plugin Error: Could not open log file %s for appending: %s",
        M.log_file,
        tostring(err_open)
      )
    )
  end
end

--- Validates the format of an OpenAI API key.
--- @param api_key string|nil The API key to validate.
--- @return boolean is_valid True if the key format is valid, false otherwise.
--- @return string|nil error_msg An error message if the key is invalid, otherwise nil.
local function validate_api_key(api_key)
  if not api_key or api_key == "" then return false, "API key is empty or not provided." end
  if type(api_key) ~= "string" then -- Ensure it's a string before specific checks
    return false, "API key must be a string."
  end
  if not api_key:match("^sk%-") then return false, "API key must start with 'sk-'." end
  -- A common length for OpenAI API keys is 51 characters (sk + 48).
  -- Allowing some flexibility, but very short keys are definitely invalid.
  if #api_key < 40 then
    return false,
      "API key is too short (expected format like sk-xxxxxxxx...). Ensure the full key is provided."
  end
  return true, nil
end

--- Logs debug messages to the configured log file if debug_mode is enabled.
--- Arguments are converted to strings and concatenated. Tables are inspected.
--- @param ... any The messages or values to log.
function M.debug_log(...)
  if not M.debug_mode then return end
  local args_to_log = vim.tbl_map(
    function(arg) return type(arg) == "table" and vim.inspect(arg) or tostring(arg) end,
    { ... }
  )
  local log_message_content = table.concat(args_to_log, " ")
  local formatted_message = fmt("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), log_message_content)
  _write_to_log_file(formatted_message)
end

--- Sets the debug mode for the plugin.
--- When enabled, detailed logs are written to the log file.
--- @param enabled boolean True to enable debug mode, false to disable.
function M.set_debug_mode(enabled)
  M.debug_mode = enabled
  if enabled then
    -- Ensure log directory is checked/created when debug mode is explicitly enabled
    log_directory_verified_this_session = false -- Reset to force check by _write_to_log_file
    _write_to_log_file(
      fmt("\n\n======== DEBUG MODE ENABLED AT %s ========\n", os.date("%Y-%m-%d %H:%M:%S"))
    )
    vim.notify(
      fmt("Vocal plugin debug mode enabled - Logging to %s", M.log_file),
      vim.log.levels.INFO,
      { title = "Vocal" }
    )
  else
    -- No notification when disabling, to be less verbose.
    _write_to_log_file(
      fmt("======== DEBUG MODE DISABLED AT %s ========\n\n", os.date("%Y-%m-%d %H:%M:%S"))
    )
  end
end

--- Resolves the API key from plugin configuration or environment variables.
--- The key is sourced in the following order:
--- 1. Direct string value of `config_key` (trimmed).
--- 2. Output of a command if `config_key` is a table `{"command", "arg1", ...}` (trimmed).
--- 3. Value of the `OPENAI_API_KEY` environment variable if `config_key` is `nil` (trimmed).
--- @param config_key string|table|nil The configuration key.
---   Can be a string (the API key itself),
---   a table (a command and arguments to execute to get the key, e.g., `{"gpg", "--decrypt", "key.gpg"}`),
---   or `nil` (to check the `OPENAI_API_KEY` environment variable).
--- @return string|nil api_key The resolved and trimmed API key, or `nil` if not found, invalid, or if a command fails.
function M.resolve_api_key(config_key)
  local key_value = nil
  if config_key == nil then
    local env_key = os.getenv("OPENAI_API_KEY")
    local trimmed_env_key = trim_whitespaces(env_key)
    if trimmed_env_key and trimmed_env_key ~= "" then key_value = trimmed_env_key end
  elseif type(config_key) == "string" then
    local trimmed_config_key = trim_whitespaces(config_key)
    if trimmed_config_key ~= "" then key_value = trimmed_config_key end
  elseif type(config_key) == "table" then
    if type(config_key[1]) ~= "string" or config_key[1] == "" then
      M.debug_log(
        "Error in API key configuration: if 'config_key' is a table, its first element must be a non-empty command string. Got: %s",
        vim.inspect(config_key[1])
      )
    else
      local cmd_table_for_systemlist = config_key -- Use directly, systemlist expects a list-like table.
      local ok, result = pcall(vim.fn.systemlist, cmd_table_for_systemlist)
      if ok then
        if vim.v.shell_error == 0 then
          if #result > 0 and type(result[1]) == "string" then
            local trimmed_cmd_output = trim_whitespaces(result[1])
            if trimmed_cmd_output ~= "" then
              key_value = trimmed_cmd_output
            else
              M.debug_log(
                "API key command '%s' executed successfully but produced empty (after trim) output.",
                cmd_table_for_systemlist[1]
              )
            end
          elseif #result == 0 then
            M.debug_log(
              "API key command '%s' executed successfully but produced no output.",
              cmd_table_for_systemlist[1]
            )
          else
            M.debug_log(
              "API key command '%s' output was not a string or was empty: %s",
              cmd_table_for_systemlist[1],
              vim.inspect(result)
            )
          end
        else
          M.debug_log(
            "API key command '%s' failed with shell error code %d. Output (if any): %s",
            cmd_table_for_systemlist[1],
            vim.v.shell_error,
            vim.inspect(result)
          )
        end
      else
        M.debug_log(
          "Failed to execute API key command '%s' due to Lua error: %s",
          cmd_table_for_systemlist[1],
          tostring(result)
        )
      end
    end
  else
    M.debug_log(
      "Invalid type for 'config_key' in resolve_api_key: %s. Expected string, table, or nil.",
      type(config_key)
    )
  end

  return key_value
end

--- Transcribes the given audio file using the OpenAI API via a Python helper script.
--- It handles finding the Python interpreter, validating inputs, and processing the script's output.
--- @param filename string Path to the audio file.
--- @param api_key string The OpenAI API key.
--- @param on_success fun(transcription: string) Callback function for successful transcription.
--- @param on_error fun(error_message: string) Callback function for errors.
function M.transcribe(filename, api_key, on_success, on_error)
  if not uploader_script_path then
    local rt_files = vim.api.nvim_get_runtime_file("python/openai_uploader.py", false)
    if #rt_files > 0 then
      uploader_script_path = rt_files[1]
      M.debug_log("Found uploader script at: %s", uploader_script_path)
    else
      M.debug_log("Error: openai_uploader.py script not found in runtime path.")
      return on_error("OpenAI uploader script (openai_uploader.py) not found in runtime path.")
    end
  end

  if not discovered_python_interpreter_path then
    if vim.fn.executable("python3") == 1 then
      discovered_python_interpreter_path = "python3"
    elseif vim.fn.executable("python") == 1 then
      discovered_python_interpreter_path = "python"
    else
      M.debug_log("Error: Python interpreter (python3 or python) not found in PATH.")
      return on_error("Python interpreter (python3 or python) not found in PATH.")
    end
    M.debug_log(
      "Using Python interpreter for transcription jobs: %s",
      discovered_python_interpreter_path
    )
  end

  if not filename or vim.fn.filereadable(filename) ~= 1 then
    M.debug_log("Error: Audio file not found or not readable: %s", filename or "nil")
    return on_error(fmt("Audio file not found or not readable: %s", filename or "nil"))
  end

  local key_valid, key_error_msg = validate_api_key(api_key)
  if not key_valid then
    M.debug_log("Error: Invalid API key: %s", key_error_msg)
    return on_error(fmt("Invalid API key: %s", key_error_msg))
  end

  local current_request_options = M.options
  M.debug_log("======== NEW TRANSCRIPTION REQUEST (Python uploader) ========")
  M.debug_log(
    "Attempting API request via Python script with key: %s...%s",
    api_key:sub(1, 5),
    api_key:sub(-4)
  )
  M.debug_log("File: %s Options: %s", filename, vim.inspect(current_request_options))

  local python_args = {
    uploader_script_path,
    api_key,
    filename,
    current_request_options.model,
    current_request_options.response_format,
    tostring(current_request_options.temperature),
    tostring(current_request_options.timeout),
  }

  if current_request_options.language then
    table.insert(python_args, current_request_options.language)
  end

  do -- Block for logging python_args with masked key
    local logged_args_display = vim.deepcopy(python_args)
    if #logged_args_display >= 2 and type(logged_args_display[2]) == "string" then
      logged_args_display[2] = fmt(
        "%s...%s (masked)",
        logged_args_display[2]:sub(1, 5),
        logged_args_display[2]:sub(-4)
      )
    else
      logged_args_display[2] = "<API_KEY_MASKED>" -- Fallback mask if key is not string or too short
    end
    M.debug_log(
      "Executing Python uploader. Command (approx): %s %s",
      discovered_python_interpreter_path,
      table.concat(logged_args_display, " ")
    )
  end

  local job_instance = Job:new({
    command = discovered_python_interpreter_path,
    args = python_args,
    on_exit = vim.schedule_wrap(function(j, exit_code)
      local stdout_lines = j:result() or {}
      local stderr_lines = j:stderr_result() or {}
      local response_body = table.concat(stdout_lines, "\n")
      local stderr_output = table.concat(stderr_lines, "\n")

      M.debug_log(fmt("Python uploader job exited. Code: %s", exit_code))
      M.debug_log(
        fmt("Python uploader stdout (first 500 chars):\n%s", response_body:sub(1, 500))
      )
      if stderr_output ~= "" and stderr_output ~= "\n" then
        M.debug_log(fmt("Python uploader stderr:\n%s", stderr_output))
      end

      if not response_body or response_body == "" then
        local err_msg_detail = "Empty response from Python uploader script."
        if exit_code ~= 0 then
          err_msg_detail = fmt("%s Script exited with code %s.", err_msg_detail, exit_code)
        end
        if stderr_output ~= "" and stderr_output ~= "\n" then
          err_msg_detail = fmt(
            "%s Stderr: %s",
            err_msg_detail,
            stderr_output:gsub("^\n*", ""):gsub("\n*$", "")
          )
        end
        M.debug_log("Error: %s", err_msg_detail)
        return on_error(err_msg_detail)
      end

      local ok_decode, decoded_json = pcall(vim.json.decode, response_body)

      if ok_decode and type(decoded_json) == "table" then
        if
          decoded_json.error
          and type(decoded_json.error) == "table"
          and decoded_json.error.message
        then
          M.debug_log(
            "Error: Python script reported an API error: %s (Type: %s)",
            decoded_json.error.message,
            decoded_json.error.type or "unknown"
          )
          return on_error(fmt("API Error via Python: %s", decoded_json.error.message))
        elseif decoded_json.error then -- Non-standard error format from script
          M.debug_log(
            "Error: Python script reported a non-API error: %s",
            vim.inspect(decoded_json.error)
          )
          return on_error(fmt("Script Error via Python: %s", vim.inspect(decoded_json.error)))
        elseif decoded_json.text then
          M.debug_log(
            "Transcription successful (JSON response)! Length: %d characters",
            #decoded_json.text
          )
          on_success(decoded_json.text)
        else
          M.debug_log(
            "Error: 'text' or 'error' field not found in JSON table from Python. Full response: %s",
            vim.inspect(decoded_json)
          )
          on_error(
            "Unexpected JSON structure in Python script response (missing text/error fields)."
          )
        end
      elseif
        current_request_options.response_format == "text"
        and type(response_body) == "string"
        and response_body ~= ""
      then
        M.debug_log("Transcription successful (plain text response)!")
        on_success(response_body)
      else
        local decode_fail_reason = "Could not process response from Python script."
        if not ok_decode then
          decode_fail_reason =
            fmt("Failed to decode JSON response: %s.", tostring(decoded_json)) -- decoded_json is error message here
        elseif type(decoded_json) ~= "table" then
          decode_fail_reason = fmt(
            "Decoded JSON is not a table (type: %s), and response_format is '%s'.",
            type(decoded_json),
            current_request_options.response_format
          )
        end
        M.debug_log(
          "Error: %s Raw Body (first 500 chars): %s",
          decode_fail_reason,
          response_body:sub(1, 500)
        )
        on_error(fmt("%s Check logs for raw response.", decode_fail_reason))
      end
    end),
  })

  local job_started_ok, start_err = pcall(function() job_instance:start() end)
  if not job_started_ok then
    local err_msg =
      fmt("Failed to start the transcription process (Python script): %s", tostring(start_err))
    M.debug_log("Error: %s", err_msg)
    return on_error(err_msg)
  end
end

--- Tests connectivity to the OpenAI API by attempting to list available models.
--- Temporarily enables debug logging for the duration of the test.
--- @param api_key string The OpenAI API key to test.
--- @param callback fun(message: string, level: "info"|"error") Callback function to report the result.
---        `level` indicates if the message is informational (success) or an error.
function M.test_api_connectivity(api_key, callback)
  local was_debug_enabled = M.debug_mode
  M.set_debug_mode(true) -- Temporarily enable debug for this test
  M.debug_log("======== API CONNECTIVITY TEST ========")

  local key_valid, key_error_msg = validate_api_key(api_key)
  if not key_valid then
    M.debug_log("Error: Invalid API key for connectivity test: %s", key_error_msg)
    M.set_debug_mode(was_debug_enabled) -- Restore debug mode
    return callback(fmt("Invalid API key for test: %s", key_error_msg), "error")
  end

  M.debug_log("Testing API connectivity with key: %s...%s", api_key:sub(1, 5), api_key:sub(-4))

  local command_str = fmt(
    "curl -s -X GET -H 'Authorization: Bearer %s' https://api.openai.com/v1/models",
    api_key
  )
  M.debug_log(
    "Executing test command: %s (API key is part of the command here, be cautious if logs are public)",
    command_str:gsub(api_key, api_key:sub(1, 5) .. "...MASKED..." .. api_key:sub(-4))
  )

  local job_id = vim.fn.jobstart(command_str, {
    on_stdout = function(j_id, data_lines, event)
      if data_lines and #data_lines > 0 and data_lines[1] ~= "" then
        local combined_data = table.concat(data_lines, "\n")
        M.debug_log(
          "API Test Response (stdout, first 500 chars): %s",
          combined_data:sub(1, 500)
        )

        local decode_ok, decoded_response = pcall(vim.json.decode, combined_data)
        if decode_ok and type(decoded_response) == "table" then
          if decoded_response.data and type(decoded_response.data) == "table" then
            callback(
              "API connection successful! Found " .. #decoded_response.data .. " models.",
              "info"
            )
            M.debug_log("Success: Found %d models.", #decoded_response.data)
          elseif decoded_response.error and type(decoded_response.error) == "table" then
            local err_msg_detail = decoded_response.error.message
              or vim.inspect(decoded_response.error)
            callback(fmt("API error: %s", err_msg_detail), "error")
            M.debug_log("Error (decoded.error): %s", err_msg_detail)
          else
            callback(
              "Unexpected API response structure (missing 'data' or 'error' field).",
              "error"
            )
            M.debug_log(
              "Error: Unexpected API response structure. Full response: %s",
              vim.inspect(decoded_response)
            )
          end
        else
          local fail_reason = "Failed to decode API response or unexpected format."
          if not decode_ok then
            fail_reason = fmt("Failed to decode API response: %s.", tostring(decoded_response)) -- decoded_response is error here
          elseif type(decoded_response) ~= "table" then
            fail_reason =
              fmt("Decoded API response is not a table (type: %s).", type(decoded_response))
          end
          callback(fail_reason, "error")
          M.debug_log(
            "Error: %s Raw data snippet: %s",
            fail_reason,
            combined_data:sub(1, 200) .. (#combined_data > 200 and "..." or "")
          )
        end
      elseif data_lines and (#data_lines == 0 or data_lines[1] == "") then
        M.debug_log("API Test: Received empty stdout.")
        callback("API Test: Received empty response from server.", "error")
      end
    end,
    on_stderr = function(j_id, data_lines, event)
      if data_lines and #data_lines > 0 and data_lines[1] ~= "" then
        local error_msg = table.concat(data_lines, "\n")
        M.debug_log("API Test Error (stderr): %s", error_msg)
        callback(fmt("API connection failed (stderr): %s", error_msg), "error")
      end
    end,
    on_exit = function(j_id, exit_code, event)
      M.debug_log("API test curl command exited with code: %d", exit_code)
      -- Note: Callback might have already been called by on_stdout or on_stderr.
      -- This on_exit is mainly for logging and cleanup.
      M.debug_log("======== API TEST COMPLETE (Exit Code: %s) ========", exit_code)
      M.set_debug_mode(was_debug_enabled) -- Restore original debug mode
    end,
    stdout_buffered = true,
    stderr_buffered = true,
  })

  if job_id == 0 or job_id == -1 then
    local err_msg = fmt(
      "Failed to start API connectivity test command (job_id: %s). Ensure 'curl' is installed and in your PATH.",
      tostring(job_id)
    )
    M.debug_log("Error: %s", err_msg)
    M.set_debug_mode(was_debug_enabled) -- Restore debug mode as on_exit will not be called
    return callback(err_msg, "error")
  end
end

--- Sets or merges API request options.
--- @param opts table|nil A table of options to merge into the current `M.options`.
---   If `nil`, current options are maintained.
function M.set_options(opts)
  if opts == nil then return end
  if type(opts) ~= "table" then
    M.debug_log("Warning: M.set_options called with non-table opts: %s", type(opts))
    vim.notify(
      "Vocal: Invalid options provided to set_options (must be a table).",
      vim.log.levels.WARN,
      { title = "Vocal Configuration" }
    )
    return
  end
  M.options = vim.tbl_deep_extend("force", M.options, opts)
  M.debug_log("Vocal options updated: %s", vim.inspect(M.options))
end

--- Enables debug mode.
--- Legacy function for backward compatibility. Use `M.set_debug_mode(true)` instead.
function M.enable_debug() M.set_debug_mode(true) end

--- Disables debug mode.
--- Legacy function for backward compatibility. Use `M.set_debug_mode(false)` instead.
function M.disable_debug() M.set_debug_mode(false) end

return M
