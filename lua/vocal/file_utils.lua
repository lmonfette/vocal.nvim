local fmt = require("vocal.utils").fmt
local api = require("vocal.api")

local M = {}

--- Normalizes transcribed text by trimming whitespace and standardizing newlines.
--- @param text string|nil The text to normalize.
--- @return string The normalized text, or an empty string if input is nil or not a string.
function M.normalize_transcribed_text(text)
  if type(text) ~= "string" then return "" end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r\n", "\n"))
end

--- Deletes a recording file with platform-specific process cleanup.
--- Uses defer_fn to avoid blocking and allow processes to terminate.
--- @param filename string|nil The path to the recording file to delete.
--- @return boolean True if deletion process was initiated, false if file not found or filename is nil.
function M.delete_recording_file(filename)
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

return M