local term = require("term")
local event = require("event")
local thread = require("thread")
local unicode = require("unicode")
local keyboard = require("keyboard")
local filesystem = require("filesystem")
local text = require("text") -- NOTE: Only used for debug stuff

-- Configuration --

local DEFAULT_CONFIG = [[
keybinds = {
  left = {"left", "numpad4"},
  right = {"right", "numpad6"},
  rotateCounterclockwise = {"z", "lcontrol", "rcontrol", "numpad3", "numpad7"},
  rotateClockwise = {"x", "up", "numpad1", "numpad5", "numpad9"},
  dropSoft = {"down", "numpad2"},
  dropHard = {"space", "numpad8", "pageDown"},
  hold = {"c", "lshift", "rshift", "numpad0"}
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
  dropSpeed = 1,
  softDropMultiplier = 10,
  previewLength = 6
}
theme = {
  background = 0x000000,
  border = 0xFFFFFF,
  text = 0xFFFFFF,
  gameOverBackground = 0xCC0000,
  tileCharCode = 0x2B1B, -- filled large square
  shadowMultiplier = 0.5,
  pieces = {
--  type = {foreground, background}
    gray = {0xA0A0A0, 0x444444},
    I = {0x00F0F0, 0x006666},
    J = {0x0000F0, 0x000066},
    L = {0xF0A000, 0x664400},
    O = {0xF0F000, 0x666600},
    S = {0x00F000, 0x006600},
    T = {0xA000F0, 0x440066},
    Z = {0xF00000, 0x660000}
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

  local env = {}
  local config = loadfile("/etc/tetris.cfg", nil, env)
  if config then
    pcall(config)
  end

  --FIXME: Entries may be missing if config file was edited

  if env.gameplay.previewLength > 7 then
    -- There may only be 7 upcoming pieces available (one full bag)
    -- So limit preview length to avoid issues
    env.gameplay.previewLength = 7
  end
  --TODO: More validation

  -- Precalculate additional constants
  env.gameplay.highestRow = 1 - env.gameplay.fieldOverflowHeight
  env.gameplay.dropInterval = 1 / (env.gameplay.dropSpeed * env.gameplay.softDropMultiplier)
  env.theme.tileChar = unicode.char(env.theme.tileCharCode)

  return env
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

local function applyTransparency(bottomColor, topColor, opacity)
  local transparency = 1 - opacity

  local bottomRed = (bottomColor >> 16) & 0xFF
  local bottomGreen = (bottomColor >> 8) & 0xFF
  local bottomBlue = (bottomColor) & 0xFF

  local topRed = (topColor >> 16) & 0xFF
  local topGreen = (topColor >> 8) & 0xFF
  local topBlue = (topColor) & 0xFF

  local red = math.floor(transparency * bottomRed + opacity * topRed)
  local green = math.floor(transparency * bottomGreen + opacity * topGreen)
  local blue = math.floor(transparency * bottomBlue + opacity * topBlue)

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

function Piece.new(colors, tiles, offsets)
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
    colors=colors,
    shadowColors={
      colorMultiply(colors[1], config.theme.shadowMultiplier),
      colorMultiply(colors[2], config.theme.shadowMultiplier)
    },
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

local originalBackground = {gpu.getBackground()}
local originalForeground = {gpu.getForeground()}

local width, height = gpu.getViewport()
gpu.setBackground(config.theme.background)
gpu.fill(1, 1, width, height, " ")

local tileScale
if config.gameplay.fieldWidth / config.gameplay.fieldHeight < width // 2 / height
then -- field is taller than viewport
  tileScale = height // config.gameplay.fieldHeight
else -- field is wider than viewport
  tileScale = width // 2 // config.gameplay.fieldWidth
end

local fieldWidth = 2 * tileScale * config.gameplay.fieldWidth
local fieldHeight = tileScale * config.gameplay.fieldHeight
local fieldX = math.floor(width / 2 - fieldWidth / 2 + 1)
local fieldY = math.floor(height / 2 - fieldHeight / 2 + 1)

gpu.setBackground(config.theme.border)
gpu.fill(fieldX - 1, fieldY, 1, fieldHeight, " ") -- Left border
gpu.fill(fieldX + fieldWidth, fieldY, 1, fieldHeight, " ") -- Right border
gpu.setBackground(config.theme.background)
gpu.setForeground(config.theme.border)
gpu.fill(fieldX - 1, fieldY + fieldHeight, fieldWidth + 2, 1, UPPER_HALF_BLOCK) -- Ground

local previewX = fieldX + fieldWidth + 1 + 2 * tileScale
local previewY = fieldY + 1 + tileScale

local holdX = fieldX - 2 - 2 * tileScale
local holdY = previewY

gpu.setBackground(config.theme.background)
gpu.setForeground(config.theme.text)
gpu.set(previewX, fieldY, config.lang.previewLabel)
gpu.set(holdX - #config.lang.holdLabel + 1, fieldY, config.lang.holdLabel)

local function fieldCoords(x, y)
  return fieldX + (x - 1) * 2 * tileScale, fieldY + (y - 1) * tileScale
end

local function showGameOver()
  local centerX = fieldX + (fieldWidth - 1) / 2
  local centerY = fieldY + (fieldHeight - 1) / 2

  gpu.setForeground(config.theme.text)
  gpu.setBackground(config.theme.gameOverBackground)
  gpu.fill(fieldX, centerY - tileScale, fieldWidth, 1 + 2 * tileScale, " ")
  gpu.set(centerX - #config.lang.gameOver / 2, centerY, config.lang.gameOver)
end

local function clearTile(x, y)
  gpu.setBackground(config.theme.background)
  gpu.fill(x, y, 2 * tileScale, tileScale, " ")
end

local function drawTile(x, y, fillColor, borderColor)
  if tileScale == 1 then
    gpu.setBackground(borderColor)
    gpu.setForeground(fillColor)
    gpu.set(x, y, config.theme.tileChar)
  else
    gpu.setBackground(fillColor)
    gpu.setForeground(borderColor)

    gpu.setBackground(borderColor)
    gpu.fill(x, y, 1, tileScale, " ") -- left border
    gpu.fill(x + 2 * tileScale - 1, y, 1, tileScale, " ") -- right border

    gpu.setBackground(fillColor)
    gpu.setForeground(borderColor)
    gpu.fill(x + 1, y, 2 * tileScale - 2, 1, UPPER_HALF_BLOCK) -- top border
    gpu.fill(x + 1, y + tileScale - 1, 2 * tileScale - 2, 1, LOWER_HALF_BLOCK) -- bottom border
    gpu.fill(x + 1, y + 1, 2 * tileScale - 2, tileScale - 2, " ") -- inside
  end
end

local function clearPiece(piece, x, y)
  for _, tile in ipairs(piece.tiles) do    
    local tileX = x + tile[1] * 2 * tileScale
    local tileY = y + tile[2] * tileScale

    clearTile(tileX, tileY)
  end
end

local function drawPiece(piece, x, y, colors)
  colors = colors or piece.colors
  fillColor, borderColor = table.unpack(colors)

  for _, tile in ipairs(piece.tiles) do    
    local tileX = x + tile[1] * 2 * tileScale
    local tileY = y + tile[2] * tileScale

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

local function displayFieldData()
  local width, height = gpu.getViewport()
  gpu.set(width - 2 * config.gameplay.fieldWidth + 1, height - config.gameplay.fieldHeight - config.gameplay.fieldOverflowHeight, text.padRight("Collision Data", 2 * config.gameplay.fieldWidth))
  for r = config.gameplay.highestRow, config.gameplay.fieldHeight do
    for c = 1, config.gameplay.fieldWidth do
      colors = field[r][c] or config.theme.pieces.gray
      gpu.setBackground(colors[2])
      gpu.setForeground(colors[1])
      gpu.set(width - 2 * config.gameplay.fieldWidth + 2 * c - 1, height - config.gameplay.fieldHeight + r, config.theme.tileChar)
    end
  end
end

local droppingPiece, droppingX, droppingY
local droppingPieceOriginal, heldPiece
local heldPieceUsed = false

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
  x, y = fieldCoords(droppingX, calcDropY())
  drawPiece(droppingPiece, x, y, droppingPiece.shadowColors)
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
maxPieceWidth = maxPieceWidth * 2 * tileScale
maxPieceHeight = maxPieceHeight * tileScale

local maxPreviewHeight = ((maxPieceHeight + 1) * config.gameplay.previewLength - 1) * tileScale

local function getUpcomingPiece(index)
  if index > #bag then
    return nextBag[#nextBag - ((index - #bag) - 1)]
  else
    return bag[#bag - (index - 1)]
  end
end

local function drawPreviewPiece(piece, offsetY)
  drawPiece(piece, previewX - piece.minX * 2 * tileScale, previewY + offsetY - piece.minY * tileScale)
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

    offsetY = offsetY + (piece.height + 1) * tileScale
  end
end

local function updatePreview(removedPiece)
  local removedHeight = (removedPiece.height + 1) * tileScale

  -- calculate combined height of the remaining pieces
  local remainingHeight = config.gameplay.previewLength - 2 -- initialize to the height of the gaps (in tiles)
  for i = 1, config.gameplay.previewLength - 1 do
    remainingHeight = remainingHeight + getUpcomingPiece(i).height
  end
  remainingHeight = remainingHeight * tileScale

  -- shift existing preview up
  gpu.copy(previewX, previewY + removedHeight, maxPieceWidth, remainingHeight, 0, -removedHeight)

  -- remove duplicated bottom
  gpu.setBackground(config.theme.background)
  gpu.fill(previewX, previewY + remainingHeight, maxPieceWidth, removedHeight, " ")

  -- draw new piece
  drawPreviewPiece(getUpcomingPiece(config.gameplay.previewLength), remainingHeight + tileScale)
end

local function spawn(piece)
  droppingPiece = piece
  droppingPieceOriginal = piece
  droppingX = math.ceil(config.gameplay.fieldWidth / 2)
  droppingY = 0

  if isColliding(droppingPiece, droppingX, droppingY) then
    running = false
    droppingPiece.colors = config.theme.pieces.gray
    showGameOver()
    --os.exit(0)
  end

  drawDroppingPiece()
end

local function newPiece()
  if #bag == 0 then newBag() end

  local nextPiece = bag[#bag]
  bag[#bag] = nil

  updatePreview(nextPiece)

  heldPieceUsed = false
  spawn(nextPiece)
end

local function hold()
  if heldPieceUsed then return end

  clearDroppingPiece()
  -- clear old held piece
  gpu.fill(holdX - maxPieceWidth + 1, holdY, maxPieceWidth, maxPieceHeight, " ")

  local previousHeldPiece = heldPiece
  heldPiece = droppingPieceOriginal

  -- draw new held piece
  drawPiece(heldPiece, holdX - (heldPiece.maxX + 1) * 2 * tileScale + 1, holdY - heldPiece.minY * tileScale)

  if previousHeldPiece == nil then
    newPiece()
  else
    spawn(previousHeldPiece)
    heldPieceUsed = true
  end
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
  gpu.fill(x, y, fieldWidth, tileScale, " ")

  -- draw tiles from field color data
  local rowTable = field[row]
  for i = 1, config.gameplay.fieldWidth do
    local colors = rowTable[i]
    if colors then
      drawTile(x + (i - 1) * 2 * tileScale, y, table.unpack(colors))
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
    field[tileY][tileX] = droppingPiece.colors
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
      gpu.copy(sourceX, sourceY, fieldWidth, tileScale, 0, clearedRows * tileScale)
    end
  end

  -- if no rows were cleared, there is nothing else to do
  if clearedRows == 0 then return 0 end

  -- the rows above highestRow cannot be completed, but still need to be moved down
  for row = highestAffectedRow - 1, config.gameplay.highestRow, -1 do
    field[row + clearedRows] = field[row]
  end
  local sourceX, sourceY = fieldCoords(1, config.gameplay.highestRow)
  gpu.copy(sourceX, sourceY, fieldWidth, (highestAffectedRow - config.gameplay.highestRow) * tileScale, 0, clearedRows * tileScale)

  -- the top `clearedRows` rows were not overwritten, so must be explicitly emptied
  for row = config.gameplay.highestRow, config.gameplay.highestRow + clearedRows - 1 do
    field[row] = {}
  end

  -- the rows at the very top of the viewport need to be redrawn since they were not previously visible
  -- the highest row that does NOT need to be redrawn is the one that is `clearedRows` rows down from the highest FULLY VISIBLE row
  local highestVisibleRow = 1 - (fieldY - 1) / tileScale
  for row = math.floor(highestVisibleRow), math.ceil(highestVisibleRow) + clearedRows - 1 do
    redrawRow(row)
  end

  -- increase score
  increaseScore(config.scoring.clearedLinesScore[clearedRows] * config.scoring.level)

  return clearedRows
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
      return true

    end
  end
  return false
end

local function drop()
  clearDroppingPiece()
  droppingY = calcDropY()
  drawDroppingPiece()
end

-- Generate Keymap --

local keyMap = {}
local function mapKey(key, action)
  keyMap[keyboard.keys[key]] = action
end

local function moveLeft()
  move(-1, 0)
end
for i, key in ipairs(config.keybinds.left) do
  mapKey(key, moveLeft)
end

local function moveRight()
  move(1, 0)
end
for i, key in ipairs(config.keybinds.right) do
  mapKey(key, moveRight)
end

local function rotateCounterclockwise()
  rotate(-1)
end
for i, key in ipairs(config.keybinds.rotateCounterclockwise) do
  mapKey(key, rotateCounterclockwise)
end

local function rotateClockwise()
  rotate(1)
end
for i, key in ipairs(config.keybinds.rotateClockwise) do
  mapKey(key, rotateClockwise)
end

local function dropHard()
  drop()
  solidify()
  newPiece()
  tick = 1
end
for i, key in ipairs(config.keybinds.dropHard) do
  mapKey(key, dropHard)
end

for i, key in ipairs(config.keybinds.hold) do
  mapKey(key, hold)
end

local softDropCodes = {}
for i, key in ipairs(config.keybinds.dropSoft) do
  softDropCodes[i] = keyboard.keys[key]
end

local function isAnySoftDropKeyDown()
  for i, code in ipairs(softDropCodes) do
    if keyboard.isKeyDown(code) then
      return true
    end
  end
  return false
end

-- Gravity Loop --

local tick = 1

local gravityThread = thread.create(function()
  local status, error = pcall(function()
    while running do
      os.sleep(config.gameplay.dropInterval)
      if tick % config.gameplay.softDropMultiplier == 0 or isAnySoftDropKeyDown() then
        if not move(0, 1) then
          solidify()
          newPiece()
        end
        tick = 1
      else
        tick = tick + 1
      end
    end
  end)
  if not status then
    gpu.setBackground(table.unpack(originalBackground))
    gpu.setForeground(table.unpack(originalForeground))
    io.stderr:write(error)
  end  
end)

-- User Input Loop --

while running do
  local id, _, char, code = event.pullMultiple("key_down", "interrupted")
  if id == "interrupted" then break
  elseif id == "key_down" then
    local action = keyMap[code]
    if action then action() end
  end
end

if not running then
  event.pull("interrupted")
end

-- Cleanup --

gravityThread:kill()

gpu.setBackground(table.unpack(originalBackground))
gpu.setForeground(table.unpack(originalForeground))
term.clear()