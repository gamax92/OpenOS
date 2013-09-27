--[[ Top level program run by the kernel.

  We actually do quite a bit of work here, since we want to provide at least
  some very rudimentary way to print to screens - flying blind really would
  be a bit too harsh. And to get that in a robust fashion we also want to
  keep track of connected components. For which we want to keep track of
  signals related to that.

  Thus we have these basic program parts:
  - Events: provide a global event system into which signals are injected as
      they come in in a global event loop, or a convenience `coroutine.sleep`
      function.
  - Components: keeps track of components via an ID unique for this computer,
      which will still be valid if a component changes its address.
  - Terminal: basic implementation of a write function that keeps track of
      the first connected GPU and Screen and an internal cursor position. It
      will provide a global `write` function and provides wrapping + scrolling.
  - Command line: simple command line that allows entering a single line
      command that will be executed when pressing enter.
]]

-------------------------------------------------------------------------------

--[[ Distribute signals as events. ]]
local listeners = {}
local weakListeners = {}

local function listenersFor(name, weak)
  checkArg(1, name, "string")
  if weak then
    weakListeners[name] = weakListeners[name] or setmetatable({}, {__mode = "k"})
    return weakListeners[name]
  else
    listeners[name] = listeners[name] or {}
    return listeners[name]
  end
end

--[[ Event API table. ]]
event = {}
local timers = {}

--[[ Register a new event listener for the specified event. ]]
function event.listen(name, callback, weak)
  checkArg(2, callback, "function")
  listenersFor(name, weak)[callback] = true
end

--[[ Remove an event listener. ]]
function event.ignore(name, callback)
  listenersFor(name, false)[callback] = nil
  listenersFor(name, true)[callback] = nil
end

--[[ Dispatch an event with the specified parameter. ]]
function event.fire(name, ...)
  if name then
    for callback, _ in pairs(listenersFor(name, false)) do
      local result, message = xpcall(callback, event.error, name, ...)
      if not result and message then
        error(message, 0)
      end
    end
    for callback, _ in pairs(listenersFor(name, true)) do
      local result, message = xpcall(callback, event.error, name, ...)
      if not result and message then
        error(message, 0)
      end
    end
  end
  local elapsed = {}
  for id, info in pairs(timers) do
    if info.after < os.clock() then
      table.insert(elapsed, info)
      timers[id] = nil
    end
  end
  for _, info in ipairs(elapsed) do
    local result, message = xpcall(info.callback, event.error)
    if not result and message then
      error(message, 0)
    end
  end
end

--[[ Calls the specified function after the specified time. ]]
function event.timed(timeout, callback)
  local id = #timers
  timers[id] = {after = os.clock() + timeout, callback = callback}
  return id
end

function event.cancel(timerId)
  checkArg(1, timerId, "number")
  timers[timerId] = nil
end

--[[ Error handler for ALL event callbacks. If this returns a value,
     the computer will crash. Otherwise it'll keep going. ]]
function event.error(message)
  return message
end

--[[ Suspends a thread for the specified amount of time. ]]
function coroutine.sleep(seconds)
  checkArg(1, seconds, "number")
  local target = os.clock() + seconds
  repeat
    local closest = target
    for _, info in pairs(timers) do
      if info.after < closest then
        closest = info.after
      end
    end
    event.fire(os.signal(nil, closest - os.clock()))
  until os.clock() >= target
end

-------------------------------------------------------------------------------

--[[ Keep track of connected components across address changes. ]]
local components = {}
component = {}

function component.address(id)
  local component = components[id]
  if component then
    return component.address
  end
end

function component.type(id)
  local component = components[id]
  if component then
    return component.name
  end
end

function component.id(address)
  for id, component in pairs(components) do
    if component.address == address then
      return id
    end
  end
end

function component.ids()
  local id = nil
  return function()
    id = next(components, id)
    return id
  end
end

event.listen("component_added", function(_, address)
  local id = #components + 1
  components[id] = {address = address, name = driver.componentType(address)}
  event.fire("component_installed", id)
end)

event.listen("component_removed", function(_, address)
  local id = component.id(address)
  components[id] = nil
  event.fire("component_uninstalled", id)
end)

event.listen("component_changed", function(_, newAddress, oldAddress)
  local id = component.id(oldAddress)
  components[id].address = newAddress
end)

-------------------------------------------------------------------------------

--[[ Setup terminal API. ]]
local idGpu, idScreen = 0, 0
local screenWidth, screenHeight = 0, 0
local boundGpu = nil
local cursorX, cursorY = 1, 1

event.listen("component_installed", function(_, id)
  local type = component.type(id)
  if type == "gpu" and idGpu < 1 then
    term.gpuId(id)
  elseif type == "screen" and idScreen < 1 then
    term.screenId(id)
  end
end)

event.listen("component_uninstalled", function(_, id)
  if idGpu == id then
    term.gpuId(0)
    for id in component.ids() do
      if component.type(id) == "gpu" then
        term.gpuId(id)
        return
      end
    end
  elseif idScreen == id then
    term.screenId(0)
    for id in component.ids() do
      if component.type(id) == "screen" then
        term.screenId(id)
        return
      end
    end
  end
end)

event.listen("screen_resized", function(_, address, w, h)
  local id = component.id(address)
  if id == idScreen then
    screenWidth = w
    screenHeight = h
  end
end)

local function bindIfPossible()
  if idGpu > 0 and idScreen > 0 then
    if not boundGpu then
      local function gpu() return component.address(idGpu) end
      local function screen() return component.address(idScreen) end
      boundGpu = driver.gpu.bind(gpu, screen)
      screenWidth, screenHeight = boundGpu.getResolution()
      event.fire("term_available")
    end
  elseif boundGpu then
    boundGpu = nil
    screenWidth, screenHeight = 0, 0
    event.fire("term_unavailable")
  end
end

term = {}

function term.gpu()
  return boundGpu
end

function term.screenSize()
  return screenWidth, screenHeight
end

function term.gpuId(id)
  if id then
    checkArg(1, id, "number")
    idGpu = id
    bindIfPossible()
  end
  return idGpu
end

function term.screenId(id)
  if id then
    checkArg(1, id, "number")
    idScreen = id
    bindIfPossible()
  end
  return idScreen
end

function term.getCursor()
  return cursorX, cursorY
end

function term.setCursor(col, row)
  checkArg(1, col, "number")
  checkArg(2, row, "number")
  cursorX = math.max(col, 1)
  cursorY = math.max(row, 1)
end

function term.write(value, wrap)
  value = tostring(value)
  local w, h = screenWidth, screenHeight
  if value:len() == 0 or not boundGpu or w < 1 or h < 1 then
    return
  end
  local function checkCursor()
    if cursorX > w then
      cursorX = 1
      cursorY = cursorY + 1
    end
    if cursorY > h then
      boundGpu.copy(1, 1, w, h, 0, -1)
      boundGpu.fill(1, h, w, 1, " ")
      cursorY = h
    end
  end
  for line, nl in value:gmatch("([^\r\n]*)([\r\n]?)") do
    while wrap and line:len() > w - cursorX + 1 do
      local partial = line:sub(1, w - cursorX + 1)
      line = line:sub(partial:len() + 1)
      boundGpu.set(cursorX, cursorY, partial)
      cursorX = cursorX + partial:len()
      checkCursor()
    end
    if line:len() > 0 then
      boundGpu.set(cursorX, cursorY, line)
      cursorX = cursorX + line:len()
    end
    if nl:len() == 1 then
      cursorX = 1
      cursorY = cursorY + 1
      checkCursor()
    end
  end
end

function term.clear()
  if not boundGpu then return end
  boundGpu.fill(1, 1, screenWidth, screenHeight, " ")
  cursorX, cursorY = 1, 1
end

-- Set custom write function to replace the dummy.
write = function(...)
  local args = {...}
  for _, value in ipairs(args) do
    term.write(value, true)
  end
end

-------------------------------------------------------------------------------

--[[ Primitive command line. ]]
local command = ""
local isRunning = false
local function commandLineKey(_, char, code)
  if isRunning then return end -- ignore events while running a command
  local keys = driver.keyboard.keys
  local gpu = term.gpu()
  local x, y = term.getCursor()
  if code == keys.back then
    if command:len() == 0 then return end
    command = command:sub(1, -2)
    term.setCursor(command:len() + 3, y) -- from leading "> "
    gpu.set(x - 1, y, "  ") -- overwrite cursor blink
  elseif code == keys.enter then
    if command:len() == 0 then return end
    print(" ") -- overwrite cursor blink
    local code, result = load("return " .. command, "=stdin")
    if not code then
      code, result = load(command, "=stdin") -- maybe it's a statement
    end
    if code then
      isRunning = true
      local result = {pcall(code)}
      isRunning = false
      if not result[1] or result[2] ~= nil then
        -- TODO handle multiple results?
        print(result[2])
      end
    else
      print(result)
    end
    command = ""
    write("> ")
  elseif not keys.isControl(char) then
    -- Non-control character, add to command.
    char = string.char(char)
    command = command .. char
    term.write(char)
  end
end
local function commandLineClipboard(_, value)
  if isRunning then return end -- ignore events while running a command
  value = value:match("([^\r\n]+)")
  if value and value:len() > 0 then
    command = command .. value
    term.write(value)
  end
end

-- Reset when the term is reset and ignore input while we have no terminal.
event.listen("term_available", function()
  term.clear()
  command = ""
  write("> ")
  event.listen("key_down", commandLineKey)
  event.listen("clipboard", commandLineClipboard)
end)
event.listen("term_unavailable", function()
  event.ignore("key_down", commandLineKey)
  event.ignore("clipboard", commandLineClipboard)
end)

-- Serves as main event loop while keeping the cursor blinking. As soon as
-- we run a command from the command line this will stop until the process
-- returned, since indirectly it was called via our sleep.
local blinkState = false
while true do
  coroutine.sleep(0.5)
  local gpu = term.gpu()
  if gpu then
    local x, y = term.getCursor()
    if blinkState then
      term.gpu().set(x, y, string.char(0x2588)) -- Solid block.
    else
      term.gpu().set(x, y, " ")
    end
  end
  blinkState = not blinkState
end
