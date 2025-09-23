local api = require("vocal.api")
local ui = require("vocal.ui")

local M = {}

--- Displays an error message to the user and logs internal details.
--- @param user_message string The message to show in the UI.
--- @param internal_details string|nil Specific details for debug logging (defaults to user_message).
function M.report_error(user_message, internal_details)
  internal_details = internal_details or user_message
  api.debug_log("Error: " .. internal_details)
  vim.schedule(function() -- Ensure UI calls are on main thread
    ui.hide_status()
    ui.show_error_status(user_message)
  end)
end

return M