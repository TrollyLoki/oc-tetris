local term = require("term")
local event = require("event")
local unicode = require("unicode")
local keyboard = require("keyboard")
local computer = require("computer")
local filesystem = require("filesystem")

-- Configuration --

local DEFAULT_CONFIG = [[
keybinds = {
  left = {"left", "numpad4"},
  right = {"right", "numpad6"},
  rotateCounterclockwise = {"z", "lcontrol", "rcontrol", "numpad3", "numpad7"},
  rotateClockwise = {"x", "up", "numpad1", "numpad5", "numpad9"},
  hold = {"c", "lshift", "rshift", "numpad0"},
  softDrop = {"down", "numpad2"},
  sonicDrop = {"pageDown"}, -- instant soft drop
  hardDrop = {"space", "numpad8"},
  quit = {"q"}
}
scoring = {
  level = 1,
  clearedLinesScore = {
    100, -- single
    300, -- double
    500, -- triple
    800  -- tetris
  }
}
gameplay = {
  fieldWidth = 10,
  fieldHeight = 20,
  fieldOverflowHeight = 20,
  gravity = 1, -- tiles per second
  lockDelay = 0.5, -- seconds
  softDropFactor = 10,
  previewLength = 6
}
theme = {
  background = 0x000000,
  border = 0xFFFFFF,
  text = 0xFFFFFF,
  gameOverBackground = 0xCC0000,
  tileCharCode = 0x2B1B, -- filled large square
  shadow = 0x111111,
  shadowBorder = 0x444444,
  pieceBorderMultiplier = 0.425,
  disabledPiece = 0xA0A0A0,
  pieces = {
    I = 0x00F0F0,
    J = 0x0000F0,
    L = 0xF0A000,
    O = 0xF0F000,
    S = 0x00F000,
    T = 0xA000F0,
    Z = 0xF00000,
  }
}
lang = {
  gameOver = "GAME OVER",
  previewLabel = "NEXT",
  holdLabel = "HOLD",
  scorePrefix = "Score: "
}
]]

local function loadConfig()
  if not filesystem.exists("/etc/tetris.cfg") then
    -- Generate config file
    -- (modified from provided edit.lua)
    local fs = require("filesystem")
    local root = fs.get("/")
    if root and not root.isReadOnly() then
      fs.makeDirectory("/etc")
      local f = io.open("/etc/tetris.cfg", "w")
      if f then
        f:write(DEFAULT_CONFIG)
        f:close()
      end
    end
  end

  local config = {}
  local code = loadfile("/etc/tetris.cfg", nil, config)
  if code then
    pcall(code)
  end

  --FIXME: Entries may be missing if config file was edited

  if config.gameplay.previewLength > 7 then
    -- There may only be 7 upcoming pieces available (one full bag)
    -- So limit preview length to avoid issues
    config.gameplay.previewLength = 7
  end
  --TODO: More validation

  -- Precalculate additional constants
  config.gameplay.highestRow = 1 - config.gameplay.fieldOverflowHeight
  config.theme.tileChar = unicode.char(config.theme.tileCharCode)

  return config
end

local config = loadConfig()

-- Constants --

local UPPER_HALF_BLOCK = unicode.char(0x2580)
local LOWER_HALF_BLOCK = unicode.char(0x2584)

-- Generic Utilities --

local function copy(table)
  local c = {}
  for k, v in pairs(table) do
    if type(v) == "table" then
      c[k] = copy(v)
    else
      c[k] = v
    end
  end
  setmetatable(c, getmetatable(table))
  return c
end

-- Color Functions --

local function colorMultiply(color, multiplier)
  local red = (color >> 16) & 0xFF
  local green = (color >> 8) & 0xFF
  local blue = (color) & 0xFF

  red = math.floor(red * multiplier)
  green = math.floor(green * multiplier)
  blue = math.floor(blue * multiplier)

  return (red << 16) | (green << 8) | (blue)
end

-- Pieces
-- https://harddrop.com/wiki/SRS#How_Guideline_SRS_Really_Works
-- Y-coordinates are flipped since POSITIVE Y is down in OpenComputers

-- Clockwise is the positive rotation direction
-- Rotation states are represented as follows:
-- 1 is 0: spawn
-- 2 is R: one clockwise (right) rotation from spawn
-- 3 is 2: two successive rotations from spawn
-- 4 is L: one counterclockwise (left) rotation from spawn

local Piece = {}
Piece.__index = Piece

function Piece.new(color, tiles, offsets)
  -- pre-calculate width and height
  local minX, minY = tiles[1][1], tiles[1][2]
  local maxX, maxY = tiles[1][1], tiles[1][2]
  for i, tile in ipairs(tiles) do
    local x, y = tile[1], tile[2]
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if y < minY then minY = y end
    if y > maxY then maxY = y end
  end

  return setmetatable({
    color=color,
    tiles=tiles,
    rotation=1,
    offsets=offsets,
    minX=minX,
    maxX=maxX,
    minY=minY,
    maxY=maxY,
    width=maxX - minX + 1,
    height=maxY - minY + 1
  }, Piece)
end

local OFFSETS_JLSTZ = {
  {{ 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}},
  {{ 0,  0}, { 1,  0}, { 1,  1}, { 0, -2}, { 1, -2}},
  {{ 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}, { 0,  0}},
  {{ 0,  0}, {-1,  0}, {-1,  1}, { 0, -2}, {-1, -2}}
}

local OFFSETS_I = {
  {{ 0,  0}, {-1,  0}, { 2,  0}, {-1,  0}, { 2,  0}},
  {{-1,  0}, { 0,  0}, { 0,  0}, { 0, -1}, { 0,  2}},
  {{-1, -1}, { 1, -1}, {-2, -1}, { 1,  0}, {-2,  0}},
  {{ 0, -1}, { 0, -1}, { 0, -1}, { 0,  1}, { 0, -2}}
}

local OFFSETS_O = {
  {{ 0,  0}},
  {{ 0,  1}},
  {{-1,  1}},
  {{-1,  0}}
}

local PIECES = {
  Piece.new(config.theme.pieces.I, {{ 0,  0}, {-1,  0}, { 1,  0}, { 2,  0}}, OFFSETS_I    ), -- I
  Piece.new(config.theme.pieces.J, {{ 0,  0}, {-1, -1}, {-1,  0}, { 1,  0}}, OFFSETS_JLSTZ), -- J
  Piece.new(config.theme.pieces.L, {{ 0,  0}, {-1,  0}, { 1,  0}, { 1, -1}}, OFFSETS_JLSTZ), -- L
  Piece.new(config.theme.pieces.O, {{ 0,  0}, { 0, -1}, { 1, -1}, { 1,  0}}, OFFSETS_O    ), -- O
  Piece.new(config.theme.pieces.S, {{ 0,  0}, {-1,  0}, { 0, -1}, { 1, -1}}, OFFSETS_JLSTZ), -- S
  Piece.new(config.theme.pieces.T, {{ 0,  0}, {-1,  0}, { 0, -1}, { 1,  0}}, OFFSETS_JLSTZ), -- T
  Piece.new(config.theme.pieces.Z, {{ 0,  0}, {-1, -1}, { 0, -1}, { 1,  0}}, OFFSETS_JLSTZ)  -- Z
}

function Piece:kickTranslations(from, to)
  local fromOffsets = self.offsets[from]
  local toOffsets = self.offsets[to]

  local translations = {}
  for i, fromOffset in ipairs(fromOffsets) do
    local toOffset = toOffsets[i]
    translations[i] = {
      fromOffset[1] - toOffset[1],
      fromOffset[2] - toOffset[2]
    }
  end

  return translations
end

-- direction MUST be either 1 or -1
-- Also does not edit cached min/max/width/height fields
function Piece:rotate(direction)
  for i, tile in ipairs(self.tiles) do
    local x, y = tile[1], tile[2]

    x, y = -y * direction, x * direction

    self.tiles[i] = {x, y}
  end

  local newRotation = self.rotation + direction
  if newRotation > 4 then newRotation = 1 end
  if newRotation < 1 then newRotation = 4 end

  local kickTranslations = self:kickTranslations(self.rotation, newRotation)
  self.rotation = newRotation
  return kickTranslations
end

-- Setup --

local gpu = term.gpu()

local width, height = gpu.getViewport()
local depth = gpu.getDepth()

local originalBackground = {gpu.getBackground()}
local originalForeground = {gpu.getForeground()}
local originalPalette = nil
if depth == 4 then
  gpu.fill(1, 1, width, height, " ") -- clear any existing colors before altering palette
  local _, fg, bg, fgi, bgi = gpu.get(1, 1)
  originalPalette = {originalBackgroundIndex = bgi}
  for i = 0, 15 do
    originalPalette[i] = gpu.getPaletteColor(i)
  end

  gpu.setPaletteColor(0, config.theme.background)
  gpu.setBackground(0, true)
  gpu.fill(1, 1, width, height, " ")

  gpu.setPaletteColor(1, config.theme.pieces.I)
  gpu.setPaletteColor(2, config.theme.pieces.J)
  gpu.setPaletteColor(3, config.theme.pieces.L)
  gpu.setPaletteColor(4, config.theme.pieces.O)
  gpu.setPaletteColor(5, config.theme.pieces.S)
  gpu.setPaletteColor(6, config.theme.pieces.T)
  gpu.setPaletteColor(7, config.theme.pieces.Z)

  gpu.setPaletteColor(8, config.theme.disabledPiece)

  gpu.setPaletteColor(11, config.theme.shadow)
  gpu.setPaletteColor(12, config.theme.shadowBorder)

  gpu.setPaletteColor(13, config.theme.border)
  gpu.setPaletteColor(14, config.theme.gameOverBackground)
  gpu.setPaletteColor(15, config.theme.text)

else
  gpu.setBackground(config.theme.background)
  gpu.fill(1, 1, width, height, " ")
end

local fieldWidth = 2 * config.gameplay.fieldWidth
local fieldHeight = config.gameplay.fieldHeight
local fieldX = math.floor(width / 2 - fieldWidth / 2 + 1)
local fieldY = math.floor(height / 2 - fieldHeight / 2 + 1)

gpu.setBackground(config.theme.border)
gpu.fill(fieldX - 1, fieldY, 1, fieldHeight, " ") -- Left border
gpu.fill(fieldX + fieldWidth, fieldY, 1, fieldHeight, " ") -- Right border
gpu.setBackground(config.theme.background)
gpu.setForeground(config.theme.border)
gpu.fill(fieldX - 1, fieldY + fieldHeight, fieldWidth + 2, 1, UPPER_HALF_BLOCK) -- Ground

local previewX = fieldX + fieldWidth + 3
local previewY = fieldY + 2

local holdX = fieldX - 4
local holdY = previewY

gpu.setBackground(config.theme.background)
gpu.setForeground(config.theme.text)
gpu.set(previewX, fieldY, config.lang.previewLabel)
gpu.set(holdX - #config.lang.holdLabel + 1, fieldY, config.lang.holdLabel)

local function fieldCoords(x, y)
  return fieldX + (x - 1) * 2, fieldY + (y - 1)
end

local function showGameOver()
  local textX = fieldX + (fieldWidth - #config.lang.gameOver) / 2
  local centerY = fieldY + (fieldHeight - 1) / 2

  gpu.setForeground(config.theme.text)
  gpu.setBackground(config.theme.gameOverBackground)

  gpu.fill(fieldX, centerY - 1, fieldWidth, 3, " ")
  gpu.set(textX, centerY, config.lang.gameOver)
end

local function clearTile(x, y)
  gpu.setBackground(config.theme.background)
  gpu.fill(x, y, 2, 1, " ")
end

local function drawTile(x, y, fillColor, borderColor)
  borderColor = borderColor or (depth ~= 8 and config.theme.background or colorMultiply(fillColor, config.theme.pieceBorderMultiplier))

  gpu.setBackground(borderColor)
  gpu.setForeground(fillColor)
  gpu.set(x, y, config.theme.tileChar)
end

local function clearPiece(piece, x, y)
  for _, tile in ipairs(piece.tiles) do
    local tileX = x + tile[1] * 2
    local tileY = y + tile[2]

    clearTile(tileX, tileY)
  end
end

local function drawPiece(piece, x, y, fillColor, borderColor)
  fillColor = fillColor or piece.color

  for _, tile in ipairs(piece.tiles) do
    local tileX = x + tile[1] * 2
    local tileY = y + tile[2]

    drawTile(tileX, tileY, fillColor, borderColor)
  end
end

local running = true
local score = 0

local function updateScore()
  gpu.setBackground(config.theme.background)
  gpu.setForeground(config.theme.text)
  gpu.set(1, 1, config.lang.scorePrefix .. score)
end

local function increaseScore(amount)
  score = score + amount
  updateScore()
end

updateScore()

local field = {}
for i = config.gameplay.highestRow, config.gameplay.fieldHeight do
  field[i] = {}
end

local droppingPiece, droppingX, droppingY
local droppingPieceOriginal, heldPiece
local heldPieceUsed = false
local lockTime
local gravityDebt = 0

local function resetGravity()
  gravityDebt = 0
end

local function resetLockDelay()
  lockTime = computer.uptime() + config.gameplay.lockDelay
end

local function isColliding(piece, x, y)
  for _, tile in ipairs(piece.tiles) do
    local tileX = x + tile[1]
    if tileX < 1 or tileX > config.gameplay.fieldWidth then
      return true
    end

    local tileY = y + tile[2]
    -- tileY <= 0 is allowed (field top buffer)
    if tileY > config.gameplay.fieldHeight then
      return true
    end

    if field[tileY][tileX] ~= nil then
      return true
    end
  end
  return false
end

local function droppingPieceIsOnGround()
  return isColliding(droppingPiece, droppingX, droppingY + 1)
end

local function calcDropY()
  local newY = droppingY

  while not isColliding(droppingPiece, droppingX, newY + 1) do
    newY = newY + 1
  end

  return newY
end

local function clearDroppingPiece()
  clearPiece(droppingPiece, fieldCoords(droppingX, calcDropY()))
  clearPiece(droppingPiece, fieldCoords(droppingX, droppingY))
end

local function drawDroppingPiece()
  local x, y = fieldCoords(droppingX, calcDropY())
  drawPiece(droppingPiece, x, y, config.theme.shadow, config.theme.shadowBorder)
  drawPiece(droppingPiece, fieldCoords(droppingX, droppingY))
end

local bag = {}
local nextBag = {}

local function newBag()
  bag = nextBag
  nextBag = {}

  -- fill
  for i, piece in ipairs(PIECES) do
    nextBag[i] = piece
  end

  -- shuffle
  for i = #nextBag, 2, -1 do
    local j = math.random(i)
    nextBag[i], nextBag[j] = nextBag[j], nextBag[i]
  end
end

newBag()
newBag()

local maxPieceWidth = 0
local maxPieceHeight = 0
for i, piece in ipairs(PIECES) do
  if piece.width > maxPieceWidth then
    maxPieceWidth = piece.width
  end
  if piece.height > maxPieceHeight then
    maxPieceHeight = piece.height
  end
end
maxPieceWidth = maxPieceWidth * 2

local maxPreviewHeight = (maxPieceHeight + 1) * config.gameplay.previewLength - 1

local function getUpcomingPiece(index)
  if index > #bag then
    return nextBag[#nextBag - ((index - #bag) - 1)]
  else
    return bag[#bag - (index - 1)]
  end
end

local function drawPreviewPiece(piece, offsetY)
  drawPiece(piece, previewX - piece.minX * 2, previewY + offsetY - piece.minY)
end

local function clearPreview()
  gpu.setBackground(config.theme.background)
  gpu.fill(previewX, previewY, maxPieceWidth, maxPreviewHeight, " ")
end

local function drawPreview()
  local offsetY = 0
  for i = 1, config.gameplay.previewLength do
    local piece = getUpcomingPiece(i)
    drawPreviewPiece(piece, offsetY)

    offsetY = offsetY + piece.height + 1
  end
end

local function updatePreview(removedPiece)
  local removedHeight = removedPiece.height + 1

  -- calculate combined height of the remaining pieces
  local remainingHeight = config.gameplay.previewLength - 2 -- initialize to the height of the gaps (in tiles)
  for i = 1, config.gameplay.previewLength - 1 do
    remainingHeight = remainingHeight + getUpcomingPiece(i).height
  end

  -- shift existing preview up
  gpu.copy(previewX, previewY + removedHeight, maxPieceWidth, remainingHeight, 0, -removedHeight)

  -- remove duplicated bottom
  gpu.setBackground(config.theme.background)
  gpu.fill(previewX, previewY + remainingHeight, maxPieceWidth, removedHeight, " ")

  -- draw new piece
  drawPreviewPiece(getUpcomingPiece(config.gameplay.previewLength), remainingHeight + 1)
end

local function drawHeldPiece()
  local color = heldPieceUsed and config.theme.disabledPiece or nil
  drawPiece(heldPiece, holdX - (heldPiece.maxX + 1) * 2 + 1, holdY - heldPiece.minY, color)
end

local function spawn(piece)
  droppingPiece = piece
  droppingPieceOriginal = piece
  droppingX = math.ceil(config.gameplay.fieldWidth / 2)
  droppingY = 0

  if isColliding(droppingPiece, droppingX, droppingY) then
    running = false
    showGameOver()
    return
  end

  resetGravity()
  resetLockDelay()
  drawDroppingPiece()
end

local function newPiece()
  if #bag == 0 then newBag() end

  local nextPiece = bag[#bag]
  bag[#bag] = nil

  updatePreview(nextPiece)

  spawn(nextPiece)

  if heldPieceUsed then
      heldPieceUsed = false
      -- update color of drawn held piece
      drawHeldPiece()
  end
end

local function hold()
  if heldPieceUsed then return end

  clearDroppingPiece()
  -- clear old held piece
  gpu.fill(holdX - maxPieceWidth + 1, holdY, maxPieceWidth, maxPieceHeight, " ")

  local previousHeldPiece = heldPiece
  heldPiece = droppingPieceOriginal

  if previousHeldPiece == nil then
    newPiece()
  else
    spawn(previousHeldPiece)
    heldPieceUsed = true
  end

  drawHeldPiece()
end

local function checkComplete(row)
  local rowTable = field[row]
  for i = 1, config.gameplay.fieldWidth do
    if rowTable[i] == nil then
      return false
    end
  end
  return true
end

local function redrawRow(row)
  local x, y = fieldCoords(1, row)

  -- clear out any old tiles
  gpu.setBackground(config.theme.background)
  gpu.fill(x, y, fieldWidth, 1, " ")

  -- draw tiles from field color data
  local rowTable = field[row]
  for i = 1, config.gameplay.fieldWidth do
    local color = rowTable[i]
    if color then
      drawTile(x + (i - 1) * 2, y, color)
    end
  end
end

local function solidify()
  local highestAffectedRow = config.gameplay.fieldHeight
  local lowestAffectedRow = 1

  for i, tile in ipairs(droppingPiece.tiles) do
    local tileX = droppingX + tile[1]
    local tileY = droppingY + tile[2]

    -- track range of rows that might be cleared by this solidification
    if tileY < highestAffectedRow then highestAffectedRow = tileY end
    if tileY > lowestAffectedRow then lowestAffectedRow = tileY end

    -- copy tile data into the field
    field[tileY][tileX] = droppingPiece.color
  end

  -- clear completed rows while moving down incomplete rows that are between them
  local clearedRows = 0
  for row = lowestAffectedRow, highestAffectedRow, -1 do
    if checkComplete(row) then
      -- the row will be removed when the row(s) above it overwrite it
      clearedRows = clearedRows + 1
    elseif clearedRows ~= 0 then
      -- the row needs to be kept, but rows below it were cleared,
      -- so it must fall down a number of rows equal to the number that were cleared below it
      field[row + clearedRows] = field[row]
      local sourceX, sourceY = fieldCoords(1, row)
      gpu.copy(sourceX, sourceY, fieldWidth, 1, 0, clearedRows)
    end
  end

  -- if rows were cleared, then we need to update the field and score
  if clearedRows ~= 0 then

    -- the rows above highestRow cannot be completed, but still need to be moved down
    for row = highestAffectedRow - 1, config.gameplay.highestRow, -1 do
      field[row + clearedRows] = field[row]
    end
    local sourceX, sourceY = fieldCoords(1, config.gameplay.highestRow)
    gpu.copy(sourceX, sourceY, fieldWidth, (highestAffectedRow - config.gameplay.highestRow), 0, clearedRows)

    -- the top `clearedRows` rows were not overwritten, so must be explicitly emptied
    for row = config.gameplay.highestRow, config.gameplay.highestRow + clearedRows - 1 do
      field[row] = {}
    end

    -- the rows at the very top of the viewport need to be redrawn since they were not previously visible
    -- the highest row that does NOT need to be redrawn is the one that is `clearedRows` rows down from the highest FULLY VISIBLE row
    local highestVisibleRow = 1 - (fieldY - 1)
    for row = math.floor(highestVisibleRow), math.ceil(highestVisibleRow) + clearedRows - 1 do
      redrawRow(row)
    end

    -- increase score
    increaseScore(config.scoring.clearedLinesScore[clearedRows] * config.scoring.level)

  end

  newPiece()
end

drawPreview()
newPiece()

local function move(right, down)
  local newX = droppingX + right
  local newY = droppingY + down

  if isColliding(droppingPiece, newX, newY) then
    return false
  end

  clearDroppingPiece()
  droppingX = newX
  droppingY = newY
  drawDroppingPiece()

  resetLockDelay()
  return true
end

-- direction MUST be either 1 or -1
local function rotate(direction)
  local rotated = copy(droppingPiece)
  local kickTranslations = rotated:rotate(direction)

  for i, translation in ipairs(kickTranslations) do
    local translationX, translationY = translation[1], translation[2]
    if not isColliding(rotated, droppingX + translationX, droppingY + translationY) then

      clearDroppingPiece()
      droppingPiece = rotated
      droppingX = droppingX + translationX
      droppingY = droppingY + translationY
      drawDroppingPiece()

      resetLockDelay()
      return true

    end
  end
  return false
end

local function drop()
  clearDroppingPiece()
  droppingY = calcDropY()
  drawDroppingPiece()

  resetLockDelay()
end

-- Generate Keymap --

local keyMap = {}
local function mapKey(key, action)
  keyMap[keyboard.keys[key]] = action
end

for i, key in ipairs(config.keybinds.left) do
  mapKey(key, function () move(-1, 0) end)
end

for i, key in ipairs(config.keybinds.right) do
  mapKey(key, function () move(1, 0) end)
end

for i, key in ipairs(config.keybinds.rotateCounterclockwise) do
  mapKey(key, function () rotate(-1) end)
end

for i, key in ipairs(config.keybinds.rotateClockwise) do
  mapKey(key, function () rotate(1) end)
end

for i, key in ipairs(config.keybinds.hold) do
  mapKey(key, hold)
end

for i, key in ipairs(config.keybinds.sonicDrop) do
  mapKey(key, drop)
end

for i, key in ipairs(config.keybinds.hardDrop) do
  mapKey(key, function () drop() solidify() end)
end

local quitCodes = {}
for i, key in ipairs(config.keybinds.quit) do
  quitCodes[keyboard.keys[key]] = true
end

local softDropCodes = {}
for i, key in ipairs(config.keybinds.softDrop) do
  softDropCodes[keyboard.keys[key]] = true
end

local function isAnySoftDropKeyDown()
  for code in pairs(softDropCodes) do
    if keyboard.isKeyDown(code) then
      return true
    end
  end
  return false
end

-- Game Loop --

local function gameLoop()
  local previousTime = computer.uptime()

  while true do
    local time = computer.uptime()
    local deltaTime = time - previousTime
    previousTime = time

    -- User Input --
    local id, _, _, code = event.pull(0, "key_down")
    if id then
      local action = keyMap[code]
      if action then
        if running then action() end
      elseif quitCodes[code] then
        return -- stop game loop
      end
    end

    if running then
      -- Lock Delay --
      if lockTime ~= nil and time >= lockTime then
        if droppingPieceIsOnGround() then
          solidify()
        else
          lockTime = nil
        end
      end

      -- Gravity --
      local gravity = config.gameplay.gravity
      if isAnySoftDropKeyDown() then
        gravity = gravity * config.gameplay.softDropFactor
      end

      gravityDebt = gravityDebt + gravity * deltaTime

      local wholeTiles
      wholeTiles, gravityDebt = math.modf(gravityDebt)
      for _ = 1, wholeTiles do
        move(0, 1)
      end
    end
  end
end
gameLoop()

-- Cleanup --

if originalPalette ~= nil then
  gpu.setBackground(0, true)
  gpu.fill(1, 1, width, height, " ") -- clear any existing colors before altering palette
  gpu.setPaletteColor(originalPalette.originalBackgroundIndex, originalBackground[1])
  gpu.setBackground(originalPalette.originalBackgroundIndex, true)
  gpu.fill(1, 1, width, height, " ")

  for i = 0, 15 do
    gpu.setPaletteColor(i, originalPalette[i])
  end
end
gpu.setBackground(table.unpack(originalBackground))
gpu.setForeground(table.unpack(originalForeground))

term.clear()