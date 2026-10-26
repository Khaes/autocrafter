-- remote.lua: orders to the worker turtles over rednet (wired network)
--
-- send() sends an order and returns its number; the worker's reply is kept by
-- listen(), which runs alongside the UI and the crafts (the scheduler's sleep would
-- drop messages received while it waits); take() hands it back.
-- Order: { kind = "craft", job, cells = { grid slots }, count }
-- Reply: { job, ok, err }

local remote = { PROTOCOL = "autocrafter" }

local replies = {} -- order number -> reply
local counter = 0

-- Opens every modem; false if there is none
function remote.open()
  peripheral.find("modem", rednet.open)
  return rednet.isOpen()
end

function remote.isOpen() return rednet.isOpen() end

-- Numbers stay unique across reboots: a late reply from before a reboot cannot be
-- mistaken for the reply to a new order
function remote.send(computerId, msg)
  counter = counter + 1
  msg.job = ("%d-%d"):format(os.epoch("utc"), counter)
  rednet.send(computerId, msg, remote.PROTOCOL)
  return msg.job
end

-- Reply to order `job` from `computerId`, or nil if it has not arrived
function remote.take(job, computerId)
  local r = replies[job]
  if r and r.from == computerId then
    replies[job] = nil
    return r
  end
end

function remote.listen()
  while true do
    local from, msg = rednet.receive(remote.PROTOCOL)
    if type(msg) == "table" and msg.job then
      msg.from = from
      replies[msg.job] = msg
    end
  end
end

return remote
