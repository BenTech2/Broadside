-- Broadside: grid naval combat for Playdate
-- Hide your fleet, hunt the enemy's. First to sink every ship wins.

import "CoreLibs/graphics"
import "CoreLibs/timer"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

playdate.display.setRefreshRate(30)
math.randomseed(playdate.getSecondsSinceEpoch())

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local N <const> = 10
local SHIPS <const> = {
	{ name = "Carrier",    len = 5 },
	{ name = "Battleship", len = 4 },
	{ name = "Cruiser",    len = 3 },
	{ name = "Submarine",  len = 3 },
	{ name = "Destroyer",  len = 2 },
}
local DIFFS <const> = { "easy", "normal", "hard" }
local DIFF_LABEL <const> = { "Easy", "Normal", "Hard" }

-- Big grid
local GX <const> = 20
local GY <const> = 21
local CS <const> = 21
-- Side panel
local PX <const> = 240
local PW <const> = 156
-- Mini map
local MX <const> = 245
local MY <const> = 172
local MC <const> = 6

local CHECKER <const> = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 }
-- sparse staggered dots: a light "water" texture
local WATER <const> = { 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF }

local font = gfx.getSystemFont()
local boldFont = gfx.getSystemFont(gfx.font.kVariantBold)
local small = gfx.font.new("fonts/Roobert-10-Bold")
local FH <const> = font:getHeight()
local SH <const> = small:getHeight()
-- Measured glyph metrics (pixels below the draw y where capitals start, and
-- cap height). Used to center text optically inside boxes and rows.
local SYS_TOP <const>, SYS_CAP <const> = 1, 14
local SM_TOP <const>, SM_CAP <const> = 2, 10
-- draw-y that vertically centers capitals inside a box
local function centerSys(boxY, boxH) return boxY + (boxH - SYS_CAP) // 2 - SYS_TOP end
local function centerSm(boxY, boxH) return boxY + (boxH - SM_CAP) // 2 - SM_TOP end

local function textImage(text)
	local w = boldFont:getTextWidth(text)
	local img = gfx.image.new(w, boldFont:getHeight())
	gfx.pushContext(img)
	boldFont:drawText(text, 0, 0)
	gfx.popContext()
	return img
end
local titleImg = textImage("BROADSIDE")
local victoryImg = textImage("VICTORY!")
local defeatImg = textImage("DEFEAT")
local titleShadow = (function()
	local w, h = titleImg:getSize()
	local img = gfx.image.new(w, h)
	gfx.pushContext(img)
	titleImg:drawFaded(0, 0, 0.5, gfx.image.kDitherTypeBayer2x2)
	gfx.popContext()
	return img
end)()

---------------------------------------------------------------------------
-- Save data
---------------------------------------------------------------------------
local save = playdate.datastore.read() or {}
save.wins = save.wins or 0
save.losses = save.losses or 0
save.difficulty = save.difficulty or 2
local function writeSave() playdate.datastore.write(save) end

---------------------------------------------------------------------------
-- Sound
---------------------------------------------------------------------------
local sNoise = snd.synth.new(snd.kWaveNoise)
sNoise:setADSR(0, 0.35, 0, 0.15)
local sLow = snd.synth.new(snd.kWaveSquare)
sLow:setADSR(0, 0.3, 0, 0.1)
local sMiss = snd.synth.new(snd.kWaveSine)
sMiss:setADSR(0.01, 0.12, 0, 0.08)
local sBlip = snd.synth.new(snd.kWaveSquare)
sBlip:setADSR(0, 0.03, 0, 0.01)
local sBad = snd.synth.new(snd.kWaveSawtooth)
sBad:setADSR(0, 0.12, 0, 0.05)

-- Dedicated channels for the ship-sunk sound so nothing else can cut it off.
local sSunkBoom = snd.synth.new(snd.kWaveNoise)
sSunkBoom:setADSR(0, 1.0, 0, 0.3)
local sSunkSub = snd.synth.new(snd.kWaveSine)
sSunkSub:setADSR(0, 0.8, 0, 0.2)
local sJingle = snd.synth.new(snd.kWaveSquare)
sJingle:setADSR(0.005, 0.1, 0.5, 0.1)
local sMusic = snd.synth.new(snd.kWaveSquare)
sMusic:setADSR(0.005, 0.1, 0.5, 0.1)

local function after(ms, fn) playdate.timer.performAfterDelay(ms, fn) end

local function playHit() sNoise:playNote(220, 0.7, 0.3); sLow:playNote(55, 0.5, 0.2) end

-- enemyShip=true: you sank theirs (boom + rising victory jingle)
-- enemyShip=false: they sank yours (boom + descending "going down" glide)
local function playSunk(enemyShip)
	sSunkBoom:playNote(90, 1.0, 0.8)
	sSunkSub:playNote(45, 0.8, 0.6)
	if enemyShip then
		local notes = { 523, 659, 784, 1047 }
		for i, f in ipairs(notes) do
			after(320 + (i - 1) * 110, function() sJingle:playNote(f, 0.35, i == #notes and 0.4 or 0.09) end)
		end
	else
		for i = 0, 11 do
			after(300 + i * 55, function() sJingle:playNote(420 - i * 28, 0.3, 0.06) end)
		end
	end
end
local function playMiss()
	sMiss:playNote(880, 0.4, 0.07)
	after(80, function() sMiss:playNote(440, 0.4, 0.15) end)
end
local function playBlip() sBlip:playNote(1200, 0.12, 0.02) end
local function playPlace() sBlip:playNote(600, 0.3, 0.06) end
local function playBad() sBad:playNote(90, 0.4, 0.1) end
local function playFanfare(win)
	local notes = win and { 523, 659, 784, 1047 } or { 392, 370, 349, 262 }
	for i, f in ipairs(notes) do
		after(1400 + (i - 1) * 200, function() sMusic:playNote(f, 0.35, 0.18) end)
	end
end

---------------------------------------------------------------------------
-- Board logic
---------------------------------------------------------------------------
local function newBoard()
	local b = { cells = {}, ships = {} }
	for y = 1, N do
		b.cells[y] = {}
		for x = 1, N do b.cells[y][x] = { ship = nil, shot = false } end
	end
	return b
end

local function canPlace(b, x, y, len, horiz)
	for i = 0, len - 1 do
		local cx = horiz and x + i or x
		local cy = horiz and y or y + i
		if cx < 1 or cx > N or cy < 1 or cy > N then return false end
		if b.cells[cy][cx].ship then return false end
	end
	return true
end

local function placeShip(b, idx, x, y, horiz)
	local def = SHIPS[idx]
	b.ships[idx] = { name = def.name, len = def.len, x = x, y = y, horiz = horiz, hits = 0, sunk = false }
	for i = 0, def.len - 1 do
		local cx = horiz and x + i or x
		local cy = horiz and y or y + i
		b.cells[cy][cx].ship = idx
	end
end

local function randomPlace(b)
	for idx, def in ipairs(SHIPS) do
		while true do
			local horiz = math.random(2) == 1
			local x = math.random(1, horiz and N - def.len + 1 or N)
			local y = math.random(1, horiz and N or N - def.len + 1)
			if canPlace(b, x, y, def.len, horiz) then
				placeShip(b, idx, x, y, horiz)
				break
			end
		end
	end
end

-- returns "miss" | "hit" | "sunk", shipIndex
local function fire(b, x, y)
	local c = b.cells[y][x]
	c.shot = true
	if c.ship then
		local s = b.ships[c.ship]
		s.hits = s.hits + 1
		if s.hits >= s.len then
			s.sunk = true
			return "sunk", c.ship
		end
		return "hit", c.ship
	end
	return "miss"
end

local function allSunk(b)
	for _, s in ipairs(b.ships) do
		if not s.sunk then return false end
	end
	return true
end

---------------------------------------------------------------------------
-- Enemy AI
---------------------------------------------------------------------------
local function unresolvedHits(b)
	local list = {}
	for y = 1, N do
		for x = 1, N do
			local c = b.cells[y][x]
			if c.shot and c.ship and not b.ships[c.ship].sunk then list[#list + 1] = { x, y } end
		end
	end
	return list
end

local function unshotCells(b, parity)
	local list = {}
	for y = 1, N do
		for x = 1, N do
			if not b.cells[y][x].shot and (not parity or (x + y) % 2 == 0) then
				list[#list + 1] = { x, y }
			end
		end
	end
	return list
end

local function pick(list) return list[math.random(#list)] end

-- Probability density: count every way each remaining ship could still fit.
local function densityPick(b)
	local anyHit = #unresolvedHits(b) > 0
	local score = {}
	for y = 1, N do
		score[y] = {}
		for x = 1, N do score[y][x] = 0 end
	end
	for _, s in ipairs(b.ships) do
		if not s.sunk then
			local len = s.len
			for o = 1, 2 do
				local horiz = o == 1
				for y = 1, horiz and N or N - len + 1 do
					for x = 1, horiz and N - len + 1 or N do
						local ok, hc = true, 0
						for i = 0, len - 1 do
							local c = b.cells[horiz and y or y + i][horiz and x + i or x]
							if c.shot then
								if not c.ship or b.ships[c.ship].sunk then ok = false break end
								hc = hc + 1
							end
						end
						if ok and (not anyHit or hc > 0) then
							local w = anyHit and hc * hc * 10 or 1
							for i = 0, len - 1 do
								local cy, cx = horiz and y or y + i, horiz and x + i or x
								if not b.cells[cy][cx].shot then score[cy][cx] = score[cy][cx] + w end
							end
						end
					end
				end
			end
		end
	end
	local best, choices = 0, {}
	for y = 1, N do
		for x = 1, N do
			local v = score[y][x]
			if v > best then
				best, choices = v, { { x, y } }
			elseif v == best and v > 0 then
				choices[#choices + 1] = { x, y }
			end
		end
	end
	if best == 0 then return nil end
	return pick(choices)
end

local function easyPick(b)
	local hits = unresolvedHits(b)
	if #hits > 0 and math.random() < 0.6 then
		local opts = {}
		for _, h in ipairs(hits) do
			for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				local nx, ny = h[1] + d[1], h[2] + d[2]
				if nx >= 1 and nx <= N and ny >= 1 and ny <= N and not b.cells[ny][nx].shot then
					opts[#opts + 1] = { nx, ny }
				end
			end
		end
		if #opts > 0 then return pick(opts) end
	end
	return pick(unshotCells(b))
end

local function cpuChoose(b)
	local d = save.difficulty
	if d == 1 then return easyPick(b) end
	if d == 2 then
		if #unresolvedHits(b) > 0 then return densityPick(b) or pick(unshotCells(b)) end
		local l = unshotCells(b, true)
		if #l == 0 then l = unshotCells(b) end
		return pick(l)
	end
	return densityPick(b) or pick(unshotCells(b))
end

---------------------------------------------------------------------------
-- Game state
---------------------------------------------------------------------------
local state = "title" -- title, place, aim, presult, cpu, over
local player, enemy
local view = "own"
local cur = { x = 1, y = 1 }
local placeIdx, placeHoriz = 1, true
local msg = ""
local now = 0
local stateT = 0
local effects = {}
local shakeUntil = 0
local cpuTarget, cpuStart, cpuFired, cpuFiredT = nil, nil, false, 0
local lastWasSunk = false
local stats = { pShots = 0, pHits = 0, cShots = 0, cHits = 0 }
local winner = false
local crankAcc = 0
local heldUntil = {}

local function setState(s)
	state = s
	stateT = now
	crankAcc = 0
end

local function coord(x, y) return string.char(64 + x) .. tostring(y) end

local function addEffect(board, x, y, kind)
	effects[#effects + 1] = { board = board, x = x, y = y, kind = kind, t = now }
end

local function clampPlace()
	local len = SHIPS[placeIdx].len
	local mx = placeHoriz and N - len + 1 or N
	local my = placeHoriz and N or N - len + 1
	cur.x = math.max(1, math.min(mx, cur.x))
	cur.y = math.max(1, math.min(my, cur.y))
end

local function newGame()
	player, enemy = newBoard(), newBoard()
	randomPlace(enemy)
	placeIdx, placeHoriz = 1, true
	cur.x, cur.y = 1, 1
	effects = {}
	stats = { pShots = 0, pHits = 0, cShots = 0, cHits = 0 }
	view = "own"
	msg = "D-pad: move\nB / crank: rotate\nA: place ship"
	setState("place")
end

local function startBattle()
	view = "target"
	cur.x, cur.y = 5, 5
	msg = "Fleet deployed!\nPick a target,\nA to fire."
	setState("aim")
end

local function randomFleet()
	player = newBoard()
	randomPlace(player)
	placeIdx = #SHIPS + 1
	playPlace()
	startBattle()
end

local function endGame(win)
	winner = win
	if win then save.wins = save.wins + 1 else save.losses = save.losses + 1 end
	writeSave()
	view = win and "target" or "own"
	playFanfare(win)
	setState("over")
end

local function playerFire()
	local c = enemy.cells[cur.y][cur.x]
	local at = coord(cur.x, cur.y)
	if c.shot then
		playBad()
		msg = at .. " was already targeted."
		return
	end
	local res, idx = fire(enemy, cur.x, cur.y)
	stats.pShots = stats.pShots + 1
	lastWasSunk = res == "sunk"
	if res == "miss" then
		msg = at .. "  Miss."
		playMiss()
		addEffect("target", cur.x, cur.y, "splash")
	else
		stats.pHits = stats.pHits + 1
		shakeUntil = now + (lastWasSunk and 450 or 250)
		if lastWasSunk then
			msg = at .. "  Hit!\nEnemy " .. SHIPS[idx].name .. "\nsunk!"
			playSunk(true)
			addEffect("target", cur.x, cur.y, "sunk")
		else
			msg = at .. "  Hit!"
			playHit()
			addEffect("target", cur.x, cur.y, "boom")
		end
	end
	setState("presult")
end

local function beginCpu()
	cpuTarget = cpuChoose(player)
	cpuStart = { math.random(N), math.random(N) }
	cpuFired = false
	view = "own"
	msg = "Enemy is\ntaking aim..."
	setState("cpu")
end

local function cpuFire()
	local x, y = cpuTarget[1], cpuTarget[2]
	local res, idx = fire(player, x, y)
	local at = coord(x, y)
	stats.cShots = stats.cShots + 1
	lastWasSunk = res == "sunk"
	if res == "miss" then
		msg = "Enemy fires " .. at .. ".\nMissed us!"
		playMiss()
		addEffect("own", x, y, "splash")
	else
		stats.cHits = stats.cHits + 1
		shakeUntil = now + (lastWasSunk and 450 or 250)
		if lastWasSunk then
			msg = "Enemy fires " .. at .. ".\nOur " .. SHIPS[idx].name .. "\nsank!"
			playSunk(false)
			addEffect("own", x, y, "sunk")
		else
			msg = "Enemy fires " .. at .. ".\nWe're hit!"
			playHit()
			addEffect("own", x, y, "boom")
		end
	end
	cpuFired = true
	cpuFiredT = now
end

---------------------------------------------------------------------------
-- System menu
---------------------------------------------------------------------------
local menu = playdate.getSystemMenu()
menu:addMenuItem("random fleet", function()
	if state == "place" then randomFleet() end
end)
menu:addMenuItem("new game", function() newGame() end)
local diffItem = menu:addOptionsMenuItem("AI", DIFFS, DIFFS[save.difficulty], function(v)
	for i, d in ipairs(DIFFS) do
		if d == v then save.difficulty = i end
	end
	writeSave()
end)

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local DIRS <const> = {
	{ playdate.kButtonLeft, -1, 0 },
	{ playdate.kButtonRight, 1, 0 },
	{ playdate.kButtonUp, 0, -1 },
	{ playdate.kButtonDown, 0, 1 },
}

local function repeatPressed(btn)
	if playdate.buttonJustPressed(btn) then
		heldUntil[btn] = now + 280
		return true
	end
	if playdate.buttonIsPressed(btn) and heldUntil[btn] and now >= heldUntil[btn] then
		heldUntil[btn] = now + 70
		return true
	end
	return false
end

local function readDir()
	local dx, dy = 0, 0
	for _, d in ipairs(DIRS) do
		if repeatPressed(d[1]) then dx, dy = dx + d[2], dy + d[3] end
	end
	return dx, dy
end

local function handleInput()
	local crank = playdate.getCrankChange()

	if state == "title" then
		local dx = readDir()
		if dx ~= 0 then
			save.difficulty = (save.difficulty - 1 + dx) % #DIFFS + 1
			diffItem:setValue(DIFFS[save.difficulty])
			writeSave()
			playBlip()
		end
		if playdate.buttonJustPressed(playdate.kButtonA) then
			playPlace()
			newGame()
		end

	elseif state == "place" then
		local dx, dy = readDir()
		if dx ~= 0 or dy ~= 0 then
			cur.x, cur.y = cur.x + dx, cur.y + dy
			clampPlace()
			playBlip()
		end
		crankAcc = crankAcc + crank
		local rotate = playdate.buttonJustPressed(playdate.kButtonB)
		if math.abs(crankAcc) >= 90 then
			crankAcc = 0
			rotate = true
		end
		if rotate then
			placeHoriz = not placeHoriz
			clampPlace()
			playBlip()
		end
		if playdate.buttonJustPressed(playdate.kButtonA) then
			local len = SHIPS[placeIdx].len
			if canPlace(player, cur.x, cur.y, len, placeHoriz) then
				placeShip(player, placeIdx, cur.x, cur.y, placeHoriz)
				playPlace()
				placeIdx = placeIdx + 1
				if placeIdx > #SHIPS then
					startBattle()
				else
					clampPlace()
				end
			else
				playBad()
			end
		end

	elseif state == "aim" then
		view = playdate.buttonIsPressed(playdate.kButtonB) and "own" or "target"
		local dx, dy = readDir()
		if dx ~= 0 or dy ~= 0 then
			cur.x = (cur.x - 1 + dx) % N + 1
			cur.y = (cur.y - 1 + dy) % N + 1
			playBlip()
		end
		crankAcc = crankAcc + crank
		while math.abs(crankAcc) >= 20 do
			local step = crankAcc > 0 and 1 or -1
			crankAcc = crankAcc - step * 20
			local i = ((cur.y - 1) * N + (cur.x - 1) + step) % (N * N)
			cur.x, cur.y = i % N + 1, i // N + 1
			playBlip()
		end
		if view == "target" and playdate.buttonJustPressed(playdate.kButtonA) then
			playerFire()
		end

	elseif state == "over" then
		if now - stateT > 900 and playdate.buttonJustPressed(playdate.kButtonA) then
			playPlace()
			setState("title")
		end
	end
end

---------------------------------------------------------------------------
-- Update logic
---------------------------------------------------------------------------
local function updateLogic()
	if state == "presult" then
		if now - stateT > (lastWasSunk and 1300 or 900) then
			if allSunk(enemy) then endGame(true) else beginCpu() end
		end
	elseif state == "cpu" then
		if not cpuFired and now - stateT > 850 then
			cpuFire()
		elseif cpuFired and now - cpuFiredT > (lastWasSunk and 1500 or 1100) then
			if allSunk(player) then
				endGame(false)
			else
				view = "target"
				setState("aim")
			end
		end
	end

	if now < shakeUntil then
		playdate.display.setOffset(math.random(-3, 3), math.random(-3, 3))
	else
		playdate.display.setOffset(0, 0)
	end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function cellCenter(ox, oy, cs, x, y)
	return ox + (x - 1) * cs + cs // 2, oy + (y - 1) * cs + cs // 2
end

local function drawGridFrame(ox, oy, cs, labels)
	local size = N * cs
	if labels then
		-- light water texture, dotted inner grid, heavy frame
		gfx.setPattern(WATER)
		gfx.fillRect(ox, oy, size, size)
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(1)
		gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
		for i = 1, N - 1 do
			gfx.drawLine(ox + i * cs, oy, ox + i * cs, oy + size)
			gfx.drawLine(ox, oy + i * cs, ox + size, oy + i * cs)
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(2)
		gfx.drawRect(ox - 1, oy - 1, size + 2, size + 2)
		gfx.setLineWidth(1)
		for i = 1, N do
			local hl = state == "aim" and view == "target"
			-- label pills are 14px tall with 2px around the 10px capitals
			local lx = ox + (i - 1) * cs + cs // 2 + 1
			local pillY = oy - 17
			local ly = oy + (i - 1) * cs + (cs - 14) // 2 + 1
			-- highlight the cursor's row/column labels
			if hl and i == cur.x then
				gfx.fillRoundRect(lx - 7, pillY, 14, 14, 3)
				gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			end
			small:drawTextAligned(string.char(64 + i), lx, pillY + 2 - SM_TOP, kTextAlignment.center)
			gfx.setImageDrawMode(gfx.kDrawModeCopy)
			local num = tostring(i)
			local nx = ox - 5
			if hl and i == cur.y then
				local nw = small:getTextWidth(num)
				gfx.fillRoundRect(nx - nw - 3, ly, nw + 5, 14, 3)
				gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			end
			small:drawTextAligned(num, nx, ly + 2 - SM_TOP, kTextAlignment.right)
			gfx.setImageDrawMode(gfx.kDrawModeCopy)
		end
	else
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(1)
		gfx.drawRect(ox, oy, size + 1, size + 1)
	end
end

local function shipRect(s, ox, oy, cs)
	local x = ox + (s.x - 1) * cs
	local y = oy + (s.y - 1) * cs
	local w = s.horiz and s.len * cs or cs
	local h = s.horiz and cs or s.len * cs
	local ins = math.max(1, cs // 6)
	return x + ins, y + ins, w - 2 * ins + 1, h - 2 * ins + 1
end

local function drawShipShape(s, ox, oy, cs, mode)
	local x, y, w, h = shipRect(s, ox, oy, cs)
	local r = math.min(w, h) // 2
	gfx.setColor(gfx.kColorBlack)
	if mode == "solid" then
		gfx.fillRoundRect(x, y, w, h, r)
	elseif mode == "ghost" then
		gfx.setPattern(CHECKER)
		gfx.fillRoundRect(x, y, w, h, r)
		gfx.setColor(gfx.kColorBlack)
		gfx.drawRoundRect(x, y, w, h, r)
	elseif mode == "outline" then
		gfx.setLineWidth(cs >= 12 and 2 or 1)
		gfx.drawRoundRect(x, y, w, h, r)
		gfx.setLineWidth(1)
	elseif mode == "invalid" then
		gfx.setLineWidth(2)
		gfx.drawRoundRect(x, y, w, h, r)
		gfx.drawLine(x, y, x + w, y + h)
		gfx.drawLine(x + w, y, x, y + h)
		gfx.setLineWidth(1)
	end
end

local function drawBoard(b, ox, oy, cs, kind, big)
	drawGridFrame(ox, oy, cs, big)

	-- ships
	for _, s in ipairs(b.ships) do
		if kind == "own" then
			drawShipShape(s, ox, oy, cs, "solid")
		elseif s.sunk then
			drawShipShape(s, ox, oy, cs, "outline")
		elseif state == "over" then
			drawShipShape(s, ox, oy, cs, "ghost")
		end
	end

	-- markers
	for y = 1, N do
		for x = 1, N do
			local c = b.cells[y][x]
			local cx, cy = cellCenter(ox, oy, cs, x, y)
			if not big then
				-- minimap: black blocks for hits, single dots for misses
				gfx.setColor(c.ship and kind == "own" and c.shot and gfx.kColorWhite or gfx.kColorBlack)
				if c.shot and c.ship then
					if kind == "own" then
						gfx.fillRect(cx - 1, cy - 1, 3, 3)
					else
						gfx.fillRect(cx - 2, cy - 2, 5, 5)
					end
				elseif c.shot then
					gfx.fillRect(cx, cy, 1, 1)
				end
		else
			-- Everything below is laid out from the cell's top-left corner so it
			-- is exactly symmetric about the cell's true center (10.5 px in),
			-- the same center the ship hulls use.
			local x0, y0 = ox + (x - 1) * cs, oy + (y - 1) * cs
			if kind == "own" and c.ship then
				gfx.setColor(gfx.kColorWhite)
				if c.shot then
					-- damage: white X across the hull, 3px strokes built from
					-- 1px diagonals so the thickness is symmetric
					local a, b = 6, cs - 6
					for d = -1, 1 do
						gfx.drawLine(x0 + a + d, y0 + a, x0 + b + d, y0 + b)
						gfx.drawLine(x0 + b + d, y0 + a, x0 + a + d, y0 + b)
					end
				else
					-- porthole
					gfx.fillEllipseInRect(x0 + 9, y0 + 9, 4, 4)
				end
			elseif c.shot and c.ship then
				-- hit peg: black with a glint
				gfx.setColor(gfx.kColorBlack)
				gfx.fillEllipseInRect(x0 + 4, y0 + 4, 14, 14)
				gfx.setColor(gfx.kColorWhite)
				gfx.fillEllipseInRect(x0 + 7, y0 + 7, 4, 4)
			elseif c.shot then
				-- miss peg: small white ring with a center dot
				gfx.setColor(gfx.kColorWhite)
				gfx.fillEllipseInRect(x0 + 6, y0 + 6, 10, 10)
				gfx.setColor(gfx.kColorBlack)
				gfx.drawEllipseInRect(x0 + 6, y0 + 6, 10, 10)
				gfx.fillRect(x0 + 10, y0 + 10, 2, 2)
			end
		end
		end
	end
end

local function drawEffects()
	for i = #effects, 1, -1 do
		local e = effects[i]
		local dur = e.kind == "sunk" and 1000 or 650
		local p = (now - e.t) / dur
		if p >= 1 then
			table.remove(effects, i)
		elseif e.board == view then
			local cx, cy = cellCenter(GX, GY, CS, e.x, e.y)
			if e.kind == "splash" then
				gfx.setColor(gfx.kColorBlack)
				gfx.drawCircleAtPoint(cx, cy, 2 + p * 13)
				if p > 0.25 then gfx.drawCircleAtPoint(cx, cy, (p - 0.25) * 14) end
				local lift = math.sin(p * math.pi) * 12
				for k = -1, 1, 2 do
					gfx.fillRect(cx + k * p * 9 - 1, cy - lift - 1, 3, 3)
					gfx.fillRect(cx + k * p * 5 - 1, cy - lift * 1.4 - 1, 2, 2)
				end
			else
				local big = e.kind == "sunk"
				local r = (big and 4 or 3) + p * (big and 22 or 12)
				gfx.setColor(gfx.kColorXOR)
				gfx.fillCircleAtPoint(cx, cy, r)
				if p > 0.3 then gfx.fillCircleAtPoint(cx, cy, r * (p - 0.3) / 0.7 * 0.9) end
				local parts = big and 10 or 6
				for k = 1, parts do
					local a = k * 2 * math.pi / parts + e.x
					local d = (big and 6 or 4) + p * (big and 32 or 18)
					gfx.fillRect(cx + math.cos(a) * d - 1, cy + math.sin(a) * d - 1, 3, 3)
				end
			end
		end
	end
end

local function drawCursor()
	if state == "place" and placeIdx <= #SHIPS then
		local s = { x = cur.x, y = cur.y, len = SHIPS[placeIdx].len, horiz = placeHoriz }
		local ok = canPlace(player, cur.x, cur.y, s.len, placeHoriz)
		drawShipShape(s, GX, GY, CS, ok and "ghost" or "invalid")
	elseif state == "aim" and view == "target" then
		local x, y = GX + (cur.x - 1) * CS, GY + (cur.y - 1) * CS
		if (now // 300) % 2 == 0 then
			gfx.setColor(gfx.kColorXOR)
			gfx.fillRect(x + 2, y + 2, CS - 3, CS - 3)
		end
		-- corner brackets
		local x0, y0, x1, y1, L = x - 2, y - 2, x + CS + 2, y + CS + 2, 6
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(3)
		gfx.drawLine(x0, y0, x0 + L, y0); gfx.drawLine(x0, y0, x0, y0 + L)
		gfx.drawLine(x1, y0, x1 - L, y0); gfx.drawLine(x1, y0, x1, y0 + L)
		gfx.drawLine(x0, y1, x0 + L, y1); gfx.drawLine(x0, y1, x0, y1 - L)
		gfx.drawLine(x1, y1, x1 - L, y1); gfx.drawLine(x1, y1, x1, y1 - L)
		gfx.setLineWidth(1)
	elseif state == "cpu" and not cpuFired then
		local p = math.min(1, (now - stateT) / 600)
		p = 1 - (1 - p) * (1 - p)
		local tx = cpuStart[1] + (cpuTarget[1] - cpuStart[1]) * p
		local ty = cpuStart[2] + (cpuTarget[2] - cpuStart[2]) * p
		local cx = GX + (tx - 1) * CS + CS / 2
		local cy = GY + (ty - 1) * CS + CS / 2
		gfx.setColor(gfx.kColorXOR)
		gfx.drawLine(GX, cy, GX + N * CS, cy)
		gfx.drawLine(cx, GY, cx, GY + N * CS)
		if p < 1 or (now // 120) % 2 == 0 then
			gfx.setColor(gfx.kColorBlack)
			gfx.setLineWidth(2)
			gfx.drawCircleAtPoint(cx, cy, CS // 2 + 1)
			gfx.setLineWidth(1)
		end
	end
end

-- Segmented hull: one box per section, filled(i) decides each one.
-- Right-aligned so the names line up on the left.
local SEG <const> = 9
local function drawMiniShip(right, y, len, filled, struck)
	local x = right - len * SEG + 2
	for i = 0, len - 1 do
		if filled(i) then
			gfx.fillRect(x + i * SEG, y, SEG - 1, SEG - 1)
		else
			gfx.drawRect(x + i * SEG, y, SEG - 1, SEG - 1)
		end
	end
	if struck then
		gfx.fillRect(x - 3, y + 3, right - x + 6, 2)
	end
end

local function dottedRule(y)
	gfx.setColor(gfx.kColorBlack)
	for x = PX + 3, PX + PW - 3, 3 do gfx.fillRect(x, y, 1, 1) end
end

-- Panel layout. Content runs from TL to TR (inclusive pixels).
local TL <const> = PX + 6
local TR <const> = PX + PW - 3
local HEAD_Y <const>, HEAD_H <const> = 2, 22
local MSG_Y <const> = 28           -- caps of first line start at 29
local RULE1 <const> = 88
local LIST_Y <const>, ROW_H <const> = 91, 15
local RULE2 <const> = LIST_Y + 5 * ROW_H + 2

local function drawPanel()
	-- header bar
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRoundRect(PX, HEAD_Y, PW, HEAD_H, 4)
	local header
	if state == "place" then header = "DEPLOY FLEET"
	elseif state == "over" then header = winner and "VICTORY" or "DEFEAT"
	elseif state == "cpu" then header = "ENEMY TURN"
	elseif view == "own" then header = "YOUR FLEET"
	else header = "FIRE!" end
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	boldFont:drawText(header, TL, centerSys(HEAD_Y, HEAD_H))
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	if state == "aim" and view == "target" then
		-- coordinate badge: white pill inset 3px inside the header bar
		local c = coord(cur.x, cur.y)
		local bh = HEAD_H - 6
		local bw = small:getTextWidth(c) + 10
		local bx = PX + PW - 3 - bw
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRoundRect(bx, HEAD_Y + 3, bw, bh, 3)
		small:drawTextAligned(c, bx + bw // 2 + 1, centerSm(HEAD_Y + 3, bh), kTextAlignment.center)
	end

	-- message (up to three lines)
	gfx.drawTextInRect(msg, TL, MSG_Y, TR - TL + 1, FH * 3)
	dottedRule(RULE1)

	-- fleet status: name on the left, hull segments on the right
	for i, def in ipairs(SHIPS) do
		local y = LIST_Y + (i - 1) * ROW_H
		local ty = centerSm(y, ROW_H)          -- text draw y
		local sy = ty + SM_TOP + (SM_CAP - (SEG - 1)) // 2 -- hull boxes, centered on the caps
		local placing = state == "place" and i == placeIdx
		local sunk = false
		if state ~= "place" then
			sunk = (view == "own" and player or enemy).ships[i].sunk
		end
		gfx.setColor(gfx.kColorBlack)
		if placing then
			gfx.fillRoundRect(PX + 2, y, PW - 4, ROW_H - 1, 3)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			gfx.setColor(gfx.kColorWhite)
		end
		small:drawText(def.name, TL, ty)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		if sunk then
			gfx.fillRect(TL - 2, sy + 3, small:getTextWidth(def.name) + 4, 2)
		end
		local right = placing and TR - 3 or TR
		if state == "place" then
			local placed = i < placeIdx
			drawMiniShip(right, sy, def.len, function() return placed end, false)
		elseif view == "own" then
			local s = player.ships[i]
			drawMiniShip(right, sy, def.len, function(k)
				local cx = s.horiz and s.x + k or s.x
				local cy = s.horiz and s.y or s.y + k
				return player.cells[cy][cx].shot
			end, s.sunk)
		else
			local s = enemy.ships[i]
			drawMiniShip(right, sy, def.len, function() return s.sunk end, s.sunk)
		end
		gfx.setColor(gfx.kColorBlack)
	end
	dottedRule(RULE2)

	-- bottom block spans MY .. BOT, bottom-aligned with the big board's frame
	local BOT = GY + N * CS + 1
	if state == "place" then
		local s = SHIPS[math.min(placeIdx, #SHIPS)]
		small:drawText("NOW PLACING", TL, MY - SM_TOP)
		boldFont:drawText(s.name .. " (" .. s.len .. ")", TL, MY + SM_CAP + 4 - SYS_TOP)
		-- hint button, same style and spot as the battle-time "B" button
		local bh = 16
		local by = BOT - bh + 1
		gfx.drawRoundRect(PX + 2, by, PW - 4, bh, 4)
		small:drawTextAligned("Menu: random fleet", PX + PW // 2 + 1, centerSm(by, bh), kTextAlignment.center)
		return
	end

	-- minimap of whichever board isn't on the big grid
	if view == "own" then
		drawBoard(enemy, MX, MY, MC, "target", false)
	else
		drawBoard(player, MX, MY, MC, "own", false)
	end
	local sx = MX + N * MC + 8
	local acc = stats.pShots > 0 and math.floor(stats.pHits * 100 / stats.pShots + 0.5) or 0
	local rows = { { "SHOTS", stats.pShots }, { "HITS", stats.pHits }, { "ACC", acc .. "%" } }
	for i, r in ipairs(rows) do
		local y = MY - SM_TOP + (i - 1) * (SM_CAP + 4)
		small:drawText(r[1], sx, y)
		small:drawTextAligned(tostring(r[2]), TR + 1, y, kTextAlignment.right)
	end
	if state == "aim" then
		-- hint button, bottom-aligned with the minimap
		local bh = 16
		local by = BOT - bh + 1
		gfx.setColor(gfx.kColorBlack)
		gfx.drawRoundRect(sx - 2, by, TR - sx + 3, bh, 4)
		small:drawTextAligned(view == "target" and "B: our fleet" or "release B", (sx - 2 + TR) // 2 + 1, centerSm(by, bh), kTextAlignment.center)
	end
end

local function drawOverlay()
	local x, y, w, h = 66, 34, 268, 172
	-- dithered drop shadow
	gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
	gfx.fillRoundRect(x + 5, y + 5, w, h, 8)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRoundRect(x, y, w, h, 8)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(3)
	gfx.drawRoundRect(x, y, w, h, 8)
	gfx.setLineWidth(1)
	gfx.drawRoundRect(x + 4, y + 4, w - 8, h - 8, 5)

	local img = winner and victoryImg or defeatImg
	local iw, ih = img:getSize()
	img:drawScaled(200 - iw, y + 16, 2)

	-- two-column stat table
	local acc = stats.pShots > 0 and math.floor(stats.pHits * 100 / stats.pShots + 0.5) or 0
	local ty = y + 56 - SM_TOP
	local c1, c2, c3 = x + 20, x + 160, x + 228
	small:drawTextAligned("YOU", c2, ty, kTextAlignment.center)
	small:drawTextAligned("ENEMY", c3, ty, kTextAlignment.center)
	local rows = {
		{ "Shots fired", stats.pShots, stats.cShots },
		{ "Hits", stats.pHits, stats.cHits },
		{ "Ships sunk", 0, 0 },
	}
	local function sunkCount(b) local n = 0 for _, s in ipairs(b.ships) do if s.sunk then n = n + 1 end end return n end
	rows[3][2], rows[3][3] = sunkCount(enemy), sunkCount(player)
	for i, r in ipairs(rows) do
		local ry = ty + i * 15
		small:drawText(r[1], c1, ry)
		small:drawTextAligned(tostring(r[2]), c2, ry, kTextAlignment.center)
		small:drawTextAligned(tostring(r[3]), c3, ry, kTextAlignment.center)
	end
	local ry = ty + 3 * 15 + 19
	gfx.drawLine(c1, ry - 3 + SM_TOP, x + w - 20, ry - 3 + SM_TOP)
	small:drawText("Accuracy " .. acc .. "%", c1, ry)
	small:drawTextAligned("Record " .. save.wins .. "-" .. save.losses, x + w - 20, ry, kTextAlignment.right)

	small:drawTextAligned("A: continue      hold B: see board", 200, y + h - 14 - SM_CAP - SM_TOP, kTextAlignment.center)
end

local function drawTitleShip(cx, y)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillPolygon(cx - 95, y - 14, cx + 108, y - 14, cx + 88, y + 2, cx - 84, y + 2)
	gfx.fillRect(cx - 28, y - 30, 50, 17)
	gfx.fillRect(cx - 14, y - 44, 22, 15)
	gfx.fillRect(cx + 26, y - 38, 12, 25)
	gfx.setLineWidth(2)
	gfx.drawLine(cx - 4, y - 44, cx - 4, y - 64)
	gfx.drawLine(cx - 14, y - 58, cx + 6, y - 58)
	gfx.fillRect(cx + 48, y - 22, 22, 9)
	gfx.drawLine(cx + 68, y - 19, cx + 92, y - 24)
	gfx.fillRect(cx - 74, y - 22, 22, 9)
	gfx.drawLine(cx - 74, y - 19, cx - 96, y - 24)
	gfx.setLineWidth(1)
	gfx.setColor(gfx.kColorWhite)
	for i = 0, 5 do gfx.fillCircleAtPoint(cx - 50 + i * 22, y - 7, 2) end
end

local function drawTitle()
	local t = now / 1000
	local tw, th = titleImg:getSize()
	-- dithered drop shadow behind the logo
	titleShadow:drawScaled(200 - tw * 3 // 2 + 4, 10, 3)
	titleImg:drawScaled(200 - tw * 3 // 2, 6, 3)
	small:drawTextAligned("N A V A L   C O M B A T", 200, 64, kTextAlignment.center)

	local bob = math.sin(t * 2) * 2
	drawTitleShip(200, 150 + bob)

	-- smoke puffs
	gfx.setColor(gfx.kColorBlack)
	for i = 0, 2 do
		local p = (t * 0.6 + i / 4) % 0.75
		gfx.drawCircleAtPoint(232 - p * 40, 108 + bob - p * 30, 3 + p * 7)
	end

	-- waves
	gfx.setColor(gfx.kColorBlack)
	for row = 0, 2 do
		local base = 162 + row * 9
		local speed = 40 + row * 25
		for x = 0, 400, 8 do
			local y1 = base + math.sin((x + t * speed) / 16 + row) * 2.5
			local y2 = base + math.sin((x + 8 + t * speed) / 16 + row) * 2.5
			gfx.drawLine(x, y1, x + 8, y2)
		end
	end

	if (now // 500) % 2 == 0 then
		boldFont:drawTextAligned("Press A to start", 200, 189, kTextAlignment.center)
	end
	gfx.drawTextAligned("< AI: " .. DIFF_LABEL[save.difficulty] .. " >", 120, 213, kTextAlignment.center)
	gfx.drawTextAligned("Record " .. save.wins .. " - " .. save.losses, 300, 213, kTextAlignment.center)
end

local function draw()
	gfx.clear(gfx.kColorWhite)
	if state == "title" then
		drawTitle()
		return
	end
	if state == "over" then
		view = playdate.buttonIsPressed(playdate.kButtonB) and (winner and "own" or "target") or (winner and "target" or "own")
	end
	local b = view == "own" and player or enemy
	drawBoard(b, GX, GY, CS, view, true)
	drawEffects()
	drawCursor()
	drawPanel()
	if state == "over" and now - stateT > 900 and not playdate.buttonIsPressed(playdate.kButtonB) then
		drawOverlay()
	end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
function playdate.update()
	playdate.timer.updateTimers()
	now = playdate.getCurrentTimeMilliseconds()
	handleInput()
	updateLogic()
	draw()
end
