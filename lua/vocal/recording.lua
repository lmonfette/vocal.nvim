local Job = require("plenary.job")
local api = require("vocal.api")
local fmt = require("vocal.utils").fmt
local async = require("plenary.async")

local M = {}

local active_job = nil
local active_channel_tx = nil

M.active_filename = nil

function M.is_recording() return active_job and not active_job.is_shutdown end

local function format_recording_command(filename, has_sox)
  if not has_sox then return nil end
  return fmt("exec sox -q -c 1 -r 44100 -d %s", vim.fn.shellescape(filename))
end

function M.start_recording(recording_dir, on_start, on_error)
  local has_sox = vim.fn.executable("sox") == 1
  if not has_sox then
    if on_error then on_error("Sox is not installed. Please install it to record audio.") end
    return nil
  end

  if vim.fn.isdirectory(recording_dir) == 0 then vim.fn.mkdir(recording_dir, "p") end
  local filename = fmt("%s/recording_%d.wav", recording_dir, os.time())
  M.active_filename = filename

  local cmd = format_recording_command(filename, has_sox)
  if not cmd then
    M.active_filename = nil
    if on_error then on_error("Failed to create recording command") end
    return nil
  end
  api.debug_log("Formatted sox command for Job:new:", cmd)

  local tx, rx = async.control.channel.oneshot()
  active_channel_tx = tx

  active_job = Job:new({
    command = "bash",
    args = { "-c", cmd },
    on_start = function(job)
      if on_start then on_start(filename) end
      api.debug_log("Started recording:", filename, "Command:", cmd, "PID:", job.pid)
    end,
    on_stderr = function(_, data)
      if data and #data > 0 and data[1] ~= "" then
        local msg = type(data) == "table" and table.concat(data, "\n") or data
        if
          not msg:match("ALSA")
          and not msg:match("warning")
          and not msg:match("rate")
          and not msg:match("format")
          and not msg:match("can't encode 0%-bit Unknown or not applicable")
        then
          api.debug_log("Recording stderr:", msg)
        else
          api.debug_log("Ignored non-critical recording stderr:", msg)
        end
      end
    end,
    on_exit = function(exited_job, code)
      local stopped_filename = filename
      local current_tx = active_channel_tx

      if active_job and exited_job.pid == active_job.pid then
        active_job = nil
        M.active_filename = nil
        active_channel_tx = nil
      end

      -- Updated to include exit code 15 as potentially successful
      local potentially_successful_exit = (
        code == 0
        or code == 15
        or code == 130
        or code == 143
      )

      api.debug_log(
        "Recording process exited:",
        stopped_filename,
        "Exit code:",
        code,
        "Potentially successful exit:",
        potentially_successful_exit
      )

      -- For short recordings, give the file system a brief moment to flush data
      -- before checking file properties
      vim.defer_fn(function()
        local exists = vim.fn.filereadable(stopped_filename) == 1
        local size = vim.fn.getfsize(stopped_filename) or 0

        api.debug_log(
          "File check after brief delay:",
          stopped_filename,
          "File exists:",
          exists,
          "Size:",
          size
        )

        if current_tx then
          api.debug_log(
            fmt(
              "Sox job exited with code %d. Sending result on channel for %s (size after delay: %d)",
              code,
              stopped_filename,
              size
            )
          )
          vim.schedule(
            function()
              current_tx({
                filename = stopped_filename,
                code = code,
                potentially_successful_exit = potentially_successful_exit,
                file_exists = exists,
                file_size = size,
              })
            end
          )
        else
          api.debug_log(
            "Sox job exited but no active channel sender (tx) was found for PID "
              .. exited_job.pid
              .. ". This might happen if stop_recording was called multiple times or the job ended unexpectedly before full setup."
          )
        end
      end, 100) -- 100ms delay to allow file system to flush
    end,
  })

  if active_job then
    active_job:start()
    return rx
  else
    M.active_filename = nil
    active_channel_tx = nil
    if on_error then on_error("Failed to initialize recording job.") end
    return nil
  end
end

function M.stop_recording()
  local filename_to_return = M.active_filename
  local job_to_stop = active_job
  api.debug_log(
    "M.stop_recording called. Active job PID:",
    (job_to_stop and job_to_stop.pid or "N/A"),
    "Job is_shutdown:",
    (job_to_stop and job_to_stop.is_shutdown or "N/A"),
    "Active filename:",
    (filename_to_return or "N/A")
  )

  if job_to_stop and not job_to_stop.is_shutdown then
    job_to_stop:shutdown(15)
    api.debug_log(
      "Sent SIGTERM (15) to stop recording process for:",
      filename_to_return,
      "PID:",
      job_to_stop.pid
    )
    return filename_to_return
  else
    api.debug_log("Stop recording called but no active job found or job already shut down.")
    if not job_to_stop or (job_to_stop and job_to_stop.is_shutdown) then
      active_job = nil
      M.active_filename = nil
      if active_channel_tx then
        api.debug_log(
          "Clearing orphaned active_channel_tx due to inactive/shutdown job during stop_recording."
        )
        active_channel_tx = nil
      end
    end
    return nil
  end
end

function M.get_recording_filename() return M.active_filename end

return M
