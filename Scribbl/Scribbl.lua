--[[
Scribbl
--]]

local COMprefix = "SCRiBBL"
local CHANNEL_LIST = {{"PARTY", "P"}, {"RAID", "R"}, {"GUILD", "G"}, {"OFFICER", "O"}, {"BATTLEGROUND", "B"}};
local BLUE_PRINT_COLOR = "|cffaaaaff"
local MAX_GUESSING_TIME = 120
local MAX_HINTS = 3

local words = Scribbl_words

local iTP = LibStub:GetLibrary("iTransferProtocol-1.0")
if not iTP then return end
local iTPCallback = iTP:RegisterPrefix(COMprefix)

--split string containing quoted and non quoted arguments
--input pattern: (\S+|".+")?(\s+(\S+|".+"))*
--example input: [[arg1 "arg2part1 arg2part2" arg3]]
--example output: {"arg1", "arg2part1 arg2part2", "arg3"}
local function mysplit2(inputstr)
  local i, i1, i2, l, ret, retI = 1, 0, 0, inputstr:len(), {}, 1
  --remove leading spaces
  i1, i2 = inputstr:find("^%s+")
  if i1 then
    i = i2 + 1
  end
  
  while i <= l do
    --find end of current arg
    if (inputstr:sub(i, i)) == "\"" then
      --quoted arg, find end quote
      i1, i2 = inputstr:find("\"%s+", i + 1)
      if i1 then
        --spaces after end quote, more args to follow
        ret[retI] = inputstr:sub(i + 1, i1 - 1)
        retI = retI + 1
        i = i2 + 1
      else
        i1, i2 = inputstr:find("\"$", i + 1)
        if i1 then
          --end of msg
          ret[retI] = inputstr:sub(i + 1, i1 - 1)
          return ret
        else
          -- no end quote found, or end quote followed by no-space-charater found, disregard last arg
          return ret
        end
      end
    else
      --not quoted arg, find next space (if any)
      i1, i2 = inputstr:find("%s+", i + 1)
      if i1 then
        --spaces after arg, more args to follow
        ret[retI] = inputstr:sub(i, i1 - 1)
        retI = retI + 1
        i = i2 + 1
      else
        --end of msg
        ret[retI] = inputstr:sub(i)
        return ret
      end
    end
  end
  
  return ret
end

local DefaultO, O = {
  ["framePoint"] = "CENTER";
  ["frameRelativeTo"] = "UIParent";
  ["frameRelativePoint"] = "CENTER";
  ["frameOffsetX"] = 173;
  ["frameOffsetY"] = 141;
  ["COMchannel"] = "GUILD";
};

local myRealm = GetRealmName("player"):gsub("%s","")
local myCharnameRealm = UnitName("player").."-"..myRealm
local myClass = select(2, UnitClass("player"))
local _G = _G

--forward declarations
local currentGame, startNewGame, startGame, nextRound, resetGame, joinGame, getCurrentHost, addPlayer, addPlayerFrame, removePlayerFrame, updatePlayerFrames, removePlayer, getPlayer, addPlayerScore, setPlayerScore
local resetPlayersDone, checkAllPlayersDone
local headerFrame, mainDrawFrame, jointextbox, startGameButton, leaveGameButton, clearCanvasButton, chooseOptions, chooseButtons, COMchannelDropdown
local ArtPad = {};

local function isValidGameId(id)
  if id:len() < 12 then
    return
  end
  if id:sub(1,1) ~= "S" then
    return
  end
  local c2, c = id:sub(2,2)
  for i = 1, #CHANNEL_LIST do
    if CHANNEL_LIST[i][2] == c2 then
      c = CHANNEL_LIST[i][1]
      break
    end
  end
  if not c then
    return
  end
  return id:sub(3):match("^[0-9A-F]+$")
end

---------------------
--COM
---------------------

--link new game in chat
local function MyOnHyperlinkShow(_, link, text)
  if link:sub(1, 8) ~= "Scribbl:" then
    return
  end
  local info = ChatTypeInfo["SYSTEM"]
  if link:sub(9, 11) == "NEW" then
    local id = link:sub(12)
    if id ~= "" then
      joinGame(id)
    end
  end
end
hooksecurefunc("ChatFrame_OnHyperlinkShow", MyOnHyperlinkShow)
local old_SetHyperlink = ItemRefTooltip.SetHyperlink -- http://forums.wowace.com/showthread.php?t=20217
function ItemRefTooltip:SetHyperlink(link, ...)
  if link:sub(1, 8) == "Scribbl:" then
    return
  end
  return old_SetHyperlink(self, link, ...)
end

local function setCOMChannel(channel, silent)
  O.COMchannel = channel
  COMchannelDropdown:updateSelection()
  if not silent then
    print(BLUE_PRINT_COLOR.."Scribbl |rCOM channel changed to:", channel)
  end
end

local function sendNewGame()
  if currentGame.id then
    iTP:SendAddonMessage(COMprefix, "NEW"..currentGame.id, O.COMchannel)
  end
end
local function sendJoinGame(id)
  if not isValidGameId(id) then
    return
  end
  local c2, c = id:sub(2,2)
  for i = 1, #CHANNEL_LIST do
    if CHANNEL_LIST[i][2] == c2 then
      c = CHANNEL_LIST[i][1]
      break
    end
  end
  if not c then
    return
  end
  setCOMChannel(c, true)
  currentGame.id = id --prepare for LST
  iTP:SendAddonMessage(COMprefix, "INV"..id.." "..myClass, O.COMchannel)
end
local function sendPlayerList()
  local msg = "LST"..currentGame.id
  for i = 1, #(currentGame.ps) do
    msg = msg.." "..currentGame.ps[i].pid.." "..currentGame.ps[i].pclass
  end
  iTP:SendAddonMessage(COMprefix, msg, O.COMchannel)
end
local function sendNextRoundPlayerList()
  local msg = "RND"..currentGame.id
  for i = 1, #(currentGame.ps) do
    msg = msg.." "..currentGame.ps[i].pid.." "..currentGame.ps[i].pclass
  end
  iTP:SendAddonMessage(COMprefix, msg, O.COMchannel)
end
local function sendLeaveGame()
  if currentGame.id then
    iTP:SendAddonMessage(COMprefix, "EXT"..currentGame.id, O.COMchannel)
  end
end
local function sendVersion(target)
  iTP:SendAddonMessage(COMprefix, "VRR"..(GetAddOnMetadata("Scribbl", "Version") or "?"), "WHISPER", target)
end
local function sendChooseOption(word, wordX)
  iTP:SendAddonMessage(COMprefix, "WRD"..currentGame.id.." \""..word.."\" \""..wordX.."\"", O.COMchannel)
end
local function sendWordHint(wordX)
  iTP:SendAddonMessage(COMprefix, "HNT"..currentGame.id.." \""..wordX.."\"", O.COMchannel)
end
local function sendGuess(word)
  if currentGame.id and currentGame.word and currentGame.guessing and (getCurrentHost() ~= myCharnameRealm) then
    iTP:SendAddonMessage(COMprefix, "GSSScribbl_playerFrames getSetWordFunc "..myCharnameRealm.." \""..word.."\"", O.COMchannel)
  end
end
local function sendPlayerScores()
  local msg = "SCR"..currentGame.id
  for i = 1, #(currentGame.ps) do
    msg = msg.." "..currentGame.ps[i].pid.." "..currentGame.ps[i].score
  end
  iTP:SendAddonMessage(COMprefix, msg, O.COMchannel)
end
local function sendClearCanvas()
  if currentGame.id then
    iTP:SendAddonMessage(COMprefix, "CLS"..currentGame.id, O.COMchannel)
  end
end
local function sendLines(mainLinesPending)
  if currentGame.id then
    local l = mainLinesPending[1]
    if l then
      local c = 0
      local msg = format("LNE%s %.2f %.2f %.2f %.2f %d %d", currentGame.id, l.r, l.g, l.b, l.a, l.lbx, l.lby)
      for i = 1, #mainLinesPending do
        l = mainLinesPending[i]
        msg = msg..format(" %d %d", l.lax, l.lay)
        c = c + 1
      end
      iTP:SendAddonMessage(COMprefix, msg, O.COMchannel)
    end
  end
end

local protectedTables = {["_G"]=1};
function iTPCallback:CHAT_MSG_ADDON(prefix, msg, channel, from, sendermsgid)
  if not prefix == COMprefix then
    return
  end
  
  local cmd = msg:sub(1,3)
  
  if (cmd == "NEW") and (from ~= myCharnameRealm) then
    local id = msg:sub(4)
    if (id ~= "") and isValidGameId(id) then
      print(format(BLUE_PRINT_COLOR.."%s started a new Scribbl game: \124cffaaffaa\124HScribbl:NEW%s\124h[Join]\124h", from, id))
    end
  elseif (cmd == "INV") and (from ~= myCharnameRealm) then
    if getCurrentHost() == myCharnameRealm then
      local id, className = msg:sub(4):match("^(%S+)%s(%S+)$")
      if id and className and (id == currentGame.id) then
        addPlayer(from, className)
        addPlayerFrame(from, className)
        sendPlayerList()
      end
    end
  elseif (cmd == "LST") and (from ~= myCharnameRealm) then
    local args = mysplit2(msg:sub(4))
    if currentGame.id and (args[1] == currentGame.id) then --id == nil: i am not part of a game right now
      jointextbox:SetText(currentGame.id)
      leaveGameButton:Show()
      --remove players no longer in game
      for i = #(currentGame.ps), 1, -1 do
        --is player still in game?
        local b = false
        for j = 2, #args-1, 2 do
          if args[j] == currentGame.ps[i].pid then
            b = true
            break
          end
        end
        if not b then
          --player left
          removePlayerFrame(currentGame.ps[i].pid)
          removePlayer(currentGame.ps[i].pid)
        end
      end
      --add new players, and mark all players
      for i = 2, #args-1, 2 do
        if args[i] and args[i+1] then
          if addPlayer(args[i], args[i+1], i/2) then
            addPlayerFrame(args[i], args[i+1])
          end
        end
      end
      --sort by mark
      table.sort(currentGame.ps, function(a,b)return a.order<b.order;end)
    end
  elseif cmd == "RND" then
    --same as LST
    local args = mysplit2(msg:sub(4))
    if currentGame.id and (args[1] == currentGame.id) then --id == nil: i am not part of a game right now
      jointextbox:SetText(currentGame.id)
      --remove players no longer in game
      for i = #(currentGame.ps), 1, -1 do
        --is player still in game?
        local b = false
        for j = 2, #args-1, 2 do
          if args[j] == currentGame.ps[i].pid then
            b = true
            break
          end
        end
        if not b then
          --player left
          removePlayerFrame(currentGame.ps[i].pid)
          removePlayer(currentGame.ps[i].pid)
        end
      end
      --add new players, mark all players
      for i = 2, #args-1, 2 do
        if args[i] and args[i+1] then
          if addPlayer(args[i], args[i+1], i/2) then --mark all players
            addPlayerFrame(args[i], args[i+1])
          end
        end
      end
      --sort by mark
      table.sort(currentGame.ps, function(a,b)return a.order<b.order;end)
      
      --if host, play game
      if getCurrentHost() == myCharnameRealm then
        leaveGameButton:Hide()
        for i = 1, 3 do
          local j = random(#words)
          chooseOptions[i] = words[j]
          table.remove(words, j)
          chooseButtons[i].text:SetText(chooseOptions[i])
          chooseButtons[i]:Show()
        end
        for i = 1, 3 do
          table.insert(words, chooseOptions[i])
        end
      else
        leaveGameButton:Show()
      end
      currentGame.word = nil
      currentGame.wordX = nil
      mainDrawFrame.text:Hide()
      ArtPad:ClearCanvas()
      currentGame.guessing = nil
      resetPlayersDone(true)
      updatePlayerFrames()
    end
  elseif (cmd == "EXT") and (from ~= myCharnameRealm) then
    if getCurrentHost() == myCharnameRealm then
      local id = msg:sub(4)
      if id == currentGame.id then
        for i = 1, #(currentGame.ps) do
          if currentGame.ps[i].pid == from then
            removePlayerFrame(from)
            removePlayer(from)
            break
          end
        end
        sendPlayerList()
      end
    elseif getCurrentHost() == from then --host left
      if getCurrentHost(2) == myCharnameRealm then
        --take over as new host
        for i = 1, #(currentGame.ps) do
          if currentGame.ps[i].pid == from then
            removePlayerFrame(from)
            removePlayer(from)
            break
          end
        end
        sendPlayerList()
        --TODO:start new round
      end
    end
  elseif (cmd == "VER") and (from ~= myCharnameRealm) then
    sendVersion(from)
  elseif cmd == "WRD" then
    local args = mysplit2(msg:sub(4))
    if (#args == 3) and (args[1] == currentGame.id) then
      headerFrame:resetTimer()
      currentGame.word = args[2]
      currentGame.wordX = args[3]
      currentGame.hints = 0
      mainDrawFrame.text:Show()
      currentGame.guessing = true
      resetPlayersDone()
      updatePlayerFrames()
      if getCurrentHost() == myCharnameRealm then
        mainDrawFrame.text:SetText(currentGame.word)
        clearCanvasButton:Show()
      else
        mainDrawFrame.text:SetText(currentGame.wordX)
        clearCanvasButton:Hide()
      end
    end
  elseif cmd == "HNT" then
    local args = mysplit2(msg:sub(4))
    if (#args == 2) and (args[1] == currentGame.id) then
      currentGame.wordX = args[2]
      mainDrawFrame.text:Show()
      if currentGame.guessing and (from ~= myCharnameRealm) then
        mainDrawFrame.text:SetText(currentGame.wordX.." ("..headerFrame.guessingTime..")")
      end
    end
  elseif cmd == "GSS" then
    local args = mysplit2(msg:sub(4))
    --protect against exposing "_G" table to user input
    if not protectedTables[args[1]] then
      --get correct frame's show func
      local t = _G[args[1]]
      if t then
        --get correct event func
        local ft = t[args[2]]
        if ft then
          local f = ft(args[3])
          if f then
            --trigger event, pass state
            f(args[4])
            if currentGame.word then
              if currentGame.word:lower() == args[4]:lower() then
                --print(format("%s got it!", from))
                local p = getPlayer(from)
                if p then
                  p.done = true
                end
                if from == myCharnameRealm then
                  mainDrawFrame.text:SetText(currentGame.word)
                  currentGame.guessing = nil
                elseif getCurrentHost() == myCharnameRealm then
                  p = addPlayerScore(from, MAX_GUESSING_TIME-headerFrame.guessingTime)
                  if p then
                    if checkAllPlayersDone() then
                      headerFrame:finishTimer()
                    end
                  end
                end
                updatePlayerFrames()
              else
                --print(format("%s: %s", from, args[4]))
                --TODO:chat window
              end
            end
          end
        end
      end
    end
  elseif cmd == "SCR" then
    local args = mysplit2(msg:sub(4))
    if currentGame.id and (args[1] == currentGame.id) then --id == nil: i am not part of a game right now
      clearCanvasButton:Hide()
      mainDrawFrame.text:SetText((currentGame.word or "?").." ("..MAX_GUESSING_TIME..")")
      currentGame.word = nil
      currentGame.wordX = nil
      currentGame.guessing = nil
      for i = 2, #args-1, 2 do
        if args[i] and args[i+1] then
          setPlayerScore(args[i], tonumber(args[i+1]) or 0)
        end
      end
      resetPlayersDone()
      updatePlayerFrames()
      if getCurrentHost() == myCharnameRealm then
        C_Timer.After(3, nextRound)
      end
    end
  elseif cmd == "CLS" then
    if from ~= myCharnameRealm then
      if currentGame.id and (msg:sub(4) == currentGame.id) then --id == nil: i am not part of a game right now
        ArtPad:ClearCanvas()
      end
    end
  elseif cmd == "LNE" then
    if from ~= myCharnameRealm then
      local args = mysplit2(msg:sub(4))
      if currentGame.id and (args[1] == currentGame.id) then --id == nil: i am not part of a game right now
        if #args >= 9 then
          local brush = {
            r = tonumber(args[2]) or 1;
            g = tonumber(args[3]) or 1;
            b = tonumber(args[4]) or 1;
            a = tonumber(args[5]) or 1;
          }
          local x2, y2, x1, y1 = tonumber(args[6]) or 0, tonumber(args[7]) or 0
          local c = 0
          for i = 8, #args, 2 do --TODO: check #args!
            x1 = tonumber(args[i]) or 0
            y1 = tonumber(args[i+1]) or 0
            c = c + 1
            ArtPad:DrawLine(x1, y1, x2, y2, brush)
            x2 = x1
            y2 = y1
          end
        end
      end
    end
  end
end

---------------------
--GUI
---------------------

headerFrame = CreateFrame("Frame", "ScribblFrame", UIParent)
local minButtonFrame = CreateFrame("Frame", nil, headerFrame)
local closeButtonFrame = CreateFrame("Frame", nil, headerFrame)
mainDrawFrame = CreateFrame("Frame", nil, headerFrame)
local chatFrame = CreateFrame("Frame", nil, mainDrawFrame)
local guesstextbox = CreateFrame("EditBox", nil, chatFrame, "InputBoxTemplate")
jointextbox = CreateFrame("EditBox", nil, mainDrawFrame, "InputBoxTemplate")
COMchannelDropdown = CreateFrame("Button", "$parentChannelDropDown", mainDrawFrame, "UIDropDownMenuTemplate")
local joinButton = CreateFrame("Frame", nil, mainDrawFrame)
local newGameButton = CreateFrame("Frame", nil, mainDrawFrame)
startGameButton = CreateFrame("Frame", nil, mainDrawFrame)
leaveGameButton = CreateFrame("Frame", nil, mainDrawFrame)
clearCanvasButton = CreateFrame("Frame", nil, mainDrawFrame)

local function addDefaultTextures(self, addHighlightTex, addClassTex)
  self.bgtexture = self:CreateTexture(nil, "BACKGROUND")
  self.bgtexture:SetAllPoints(self)
  self.bgtexture:SetColorTexture(0, 0, 0, 1)
  
  if addHighlightTex then
    self.highlighttexture = self:CreateTexture(nil, "HIGHLIGHT")
    self.highlighttexture:SetAllPoints(self)
    self.highlighttexture:SetColorTexture(1, 1, 1, 0.3)
  end
  
  if addClassTex then
    self.classtexture = self:CreateTexture(nil, "ARTWORK")
    self.classtexture:SetAllPoints(self)
  end
end

local function addDefaultText(f, text, textName, myRefPoint, parentFrame, parentRefPoint, offsetX, offsetY)
  textName = textName or "text"
  myRefPoint = myRefPoint or "CENTER"
  parentFrame = parentFrame or f
  parentRefPoint = parentRefPoint or "CENTER"
  offsetX = offsetX or 0
  offsetY = offsetY or 0
  f[textName] = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f[textName]:SetPoint(myRefPoint, parentFrame, parentRefPoint, offsetX, offsetY)
  f[textName]:SetText(text)
  f[textName]:SetTextColor(1, 1, 1, 1)
end

local playerFrames = {};
Scribbl_playerFrames = {
  getSetWordFunc = function(playerId)
    for i = 1, #playerFrames do
      if playerFrames[i].playerId == playerId then
        return playerFrames[i].setWord
      end
    end
  end
};
local unusedPlayerFrames = {};
local function alignPlayerFrames()
  table.sort(playerFrames, function(a, b)
    if a.score~=b.score then
      return a.score>b.score --sort by score (desc)...
    end
    return a.playerId<b.playerId --...then by name (asc)
  end);
  for i, v in ipairs(playerFrames) do
    v:SetPoint("TOPRIGHT", mainDrawFrame, "TOPLEFT", 0, -40*(i-1))
  end
end
addPlayerFrame = function(playerId, className)
  local f
  if #unusedPlayerFrames > 0 then
    f = table.remove(unusedPlayerFrames)
  else
    f = CreateFrame("Frame", nil, mainDrawFrame)
    addDefaultTextures(f, true, true)
    f:EnableMouse(true)
    addDefaultText(f, "pid", "textPlayerId", "TOP", f, "TOP", 0, -5)
    addDefaultText(f, "score", "textScore", "BOTTOM", f, "BOTTOM", 0, 5)
    addDefaultText(f, "my guess", "word", "RIGHT", f, "LEFT", -5, 0)
    f.removeWord = function()
      f.word:Hide()
    end
    f.setWord = function(word)
      if currentGame.word and (currentGame.word:lower() ~= word:lower()) then
        f.word:Show()
        f.word:SetText(word)
        C_Timer.After(3, f.removeWord)
      end
    end
  end
  table.insert(playerFrames, f)
  
  f:SetSize(40, 40)
  f.playerId = playerId
  f.className = className
  f.score = 0
  f.textPlayerId:SetText(string.utf8sub(playerId, 1, 4))
  f.textScore:SetText(f.score)
  f.word:Hide()
  local classColor = RAID_CLASS_COLORS[className or "PRIEST"]
  f.classtexture:SetColorTexture(classColor.r, classColor.g, classColor.b, 0.5)
  f:Show()
  
  alignPlayerFrames()
end
local function removePlayerFrameIndex(i)
  local f = table.remove(playerFrames, i)
  f:Hide()
  table.insert(unusedPlayerFrames, f)
end
removePlayerFrame = function(playerId)
  for i = 1, #playerFrames do
    if playerFrames[i].playerId == playerId then
      removePlayerFrameIndex(i)
      break
    end
  end
  
  alignPlayerFrames()
end
local function removeAllPlayerFrames()
  for i = #playerFrames, 1, -1 do
    removePlayerFrameIndex(i)
  end
  
  alignPlayerFrames()
end
updatePlayerFrames = function()
  for _, v in pairs(playerFrames) do
    local p = getPlayer(v.playerId)
    if p then
      v.textPlayerId:SetText(string.utf8sub(v.playerId, 1, 4))
      v.score = p.score
      v.done = p.done
      v.textScore:SetText(v.score)
      v:SetAlpha(v.done and 1 or 0.5)
      if getCurrentHost() == v.playerId then
        v:SetWidth(60)
      else
        v:SetWidth(40)
      end
    end
  end
  alignPlayerFrames()
end

local function chooseOption(optionIndex)
  for i = 1, 3 do
    chooseButtons[i]:Hide()
  end
  currentGame.word = chooseOptions[optionIndex]
  currentGame.wordX = string.rep("_", string.utf8len(currentGame.word))
  mainDrawFrame.text:SetText(currentGame.word)
  sendChooseOption(currentGame.word, currentGame.wordX)
end

local function toggleHeaderFrame(b)
  if b then
    headerFrame:Show()
  else
    headerFrame:Hide()
  end
end
local function toggleDrawFrame(b)
  if b then
    mainDrawFrame:Show()
  else
    mainDrawFrame:Hide()
  end
end

function headerFrame:PLAYER_ENTERING_WORLD()
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  
  ---------------------
  --init options
  ---------------------
  if not ScribblOptions then
    ScribblOptions = DefaultO
  end
  O = ScribblOptions
  ---------------------
  --upgrade options
  ---------------------
  O.framePoint = O.framePoint or DefaultO.framePoint
  O.frameRelativeTo = O.frameRelativeTo or DefaultO.frameRelativeTo
  O.frameRelativePoint = O.frameRelativePoint or DefaultO.frameRelativePoint
  O.frameOffsetX = O.frameOffsetX or DefaultO.frameOffsetX
  O.frameOffsetY = O.frameOffsetY or DefaultO.frameOffsetY
  O.COMchannel = O.COMchannel or DefaultO.COMchannel
  
  ---------------------
  --header text
  ---------------------
  self:SetPoint(O.framePoint, O.frameRelativeTo, O.frameRelativePoint, O.frameOffsetX, O.frameOffsetY)
  self:SetFrameStrata("LOW")
  self:SetSize(100, 20)
  
  self:SetScript("OnDragStart", function(self)self:StartMoving()end);
  self:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    O.framePoint = point or "CENTER"
    O.frameRelativeTo = relativeTo or "UIParent"
    O.frameRelativePoint = relativePoint or "CENTER"
    O.frameOffsetX = xOfs
    O.frameOffsetY = yOfs
  end);
  self:SetMovable(true)
  self:RegisterForDrag("LeftButton")
  self:EnableMouse(true)
  
  addDefaultTextures(self, true)
  addDefaultText(self, "SCRIBBL")
  self.text:SetTextColor(.67, .67, 1, 1)
  
  ---------------------
  --minimize button
  ---------------------
  minButtonFrame:SetSize(20, 20)
  minButtonFrame:SetPoint("LEFT", self, "RIGHT")
  addDefaultTextures(minButtonFrame, true)
  minButtonFrame:EnableMouse(true)
  addDefaultText(minButtonFrame, "^")
  minButtonFrame.toggleAction = false
  minButtonFrame:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        if self.toggleAction then
          toggleDrawFrame(true)
          self.text:SetText("^")
        else
          toggleDrawFrame(false)
          self.text:SetText("v")
        end
        self.toggleAction = not self.toggleAction
      end
    end
  end)
  
  ---------------------
  --close button
  ---------------------
  closeButtonFrame:SetSize(20, 20)
  closeButtonFrame:SetPoint("LEFT", minButtonFrame, "RIGHT")
  addDefaultTextures(closeButtonFrame, true)
  closeButtonFrame.highlighttexture:SetColorTexture(1, .5, .5, 0.7)
  closeButtonFrame:EnableMouse(true)
  addDefaultText(closeButtonFrame, "X")
  closeButtonFrame:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        toggleHeaderFrame(false)
      end
    end
  end)
  
  ---------------------
  --invite fields
  ---------------------
  jointextbox:SetPoint("BOTTOMLEFT", mainDrawFrame, "TOPLEFT")
  jointextbox:SetAutoFocus(false)
  jointextbox:SetSize(100, 20)
  jointextbox:SetTextInsets(0,0,3,3)
  jointextbox:SetText("")
  jointextbox:SetCursorPosition(0)
  jointextbox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end);
  jointextbox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end);
  
  COMchannelDropdown:SetPoint("BOTTOMLEFT", jointextbox, "TOPLEFT", -20, 5)
  COMchannelDropdown.OnClick = function(self)
    if O.COMchannel ~= CHANNEL_LIST[self:GetID()][1] then
      setCOMChannel(CHANNEL_LIST[self:GetID()][1])
    end
  end
  COMchannelDropdown.initialize = function(self, level)
    local info
    for _, v in ipairs(CHANNEL_LIST) do
      info = UIDropDownMenu_CreateInfo()
      info.text = v[1]
      info.value = v[1]
      info.func = self.OnClick
      UIDropDownMenu_AddButton(info, level)
    end
  end
  COMchannelDropdown.updateSelection = function(self)
    local dropDownIndex = 3 --GUILD
    for i, v in ipairs(CHANNEL_LIST) do
      if v[1] == O.COMchannel then
        dropDownIndex = i
        break
      end
    end
    UIDropDownMenu_SetSelectedID(self, dropDownIndex)
  end
  UIDropDownMenu_Initialize(COMchannelDropdown, COMchannelDropdown.initialize)
  UIDropDownMenu_SetWidth(COMchannelDropdown, 100, 0)
  UIDropDownMenu_SetButtonWidth(COMchannelDropdown, 124)
  COMchannelDropdown:updateSelection()
  UIDropDownMenu_JustifyText(COMchannelDropdown, "LEFT")
  
  joinButton:SetSize(20, 20)
  joinButton:SetPoint("LEFT", jointextbox, "RIGHT")
  addDefaultTextures(joinButton, true)
  joinButton:EnableMouse(true)
  addDefaultText(joinButton, ">")
  joinButton:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        joinGame(jointextbox:GetText())
      end
    end
  end)
  
  newGameButton:SetSize(30, 20)
  newGameButton:SetPoint("LEFT", joinButton, "RIGHT", 10, 0)
  addDefaultTextures(newGameButton, true)
  newGameButton:EnableMouse(true)
  addDefaultText(newGameButton, "new")
  newGameButton:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        startNewGame()
      end
    end
  end)
  
  startGameButton:SetSize(30, 20)
  startGameButton:SetPoint("LEFT", newGameButton, "RIGHT", 10, 0)
  addDefaultTextures(startGameButton, true)
  startGameButton.highlighttexture:SetColorTexture(.5, 1, .5, 0.7)
  startGameButton:EnableMouse(true)
  addDefaultText(startGameButton, "start")
  startGameButton:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        startGame()
      end
    end
  end)
  startGameButton:Hide()
  
  leaveGameButton:SetSize(40, 20)
  leaveGameButton:SetPoint("RIGHT", self, "LEFT", -10, 0)
  addDefaultTextures(leaveGameButton, true)
  leaveGameButton.highlighttexture:SetColorTexture(1, .5, .5, 0.7)
  leaveGameButton:EnableMouse(true)
  addDefaultText(leaveGameButton, "leave")
  leaveGameButton:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        leaveGame()
      end
    end
  end)
  leaveGameButton:Hide()
  
  ---------------------
  --main draw frame
  ---------------------
  mainDrawFrame:SetSize(400, 300)
  mainDrawFrame:SetPoint("TOPRIGHT", self, "BOTTOMLEFT")
  addDefaultTextures(mainDrawFrame)
  mainDrawFrame:EnableMouse(true)
  addDefaultText(mainDrawFrame, "Option X", nil, "TOP", mainDrawFrame, "TOP", 0, -5)
  mainDrawFrame.text:SetFont("Fonts\\FRIZQT__.TTF", 20)
  mainDrawFrame.text:Hide()
  
  chooseOptions = {};
  chooseButtons = {};
  for i = 1, 3 do
    chooseOptions[i] = "Option "..i
    chooseButtons[i] = CreateFrame("Frame", nil, mainDrawFrame)
    chooseButtons[i]:SetSize(125, 20)
    chooseButtons[i]:SetPoint("TOPLEFT", mainDrawFrame, "TOPLEFT", 5+130*(i-1), -5)
    addDefaultTextures(chooseButtons[i], true)
    chooseButtons[i]:EnableMouse(true)
    addDefaultText(chooseButtons[i], chooseOptions[i])
    chooseButtons[i].optionIndex = i
    chooseButtons[i]:SetScript("OnMouseUp", function(self, button)
      if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
        if button=="LeftButton" then
          chooseOption(self.optionIndex)
        end
      end
    end)
    chooseButtons[i]:Hide()
  end
  
  self.interval = 1
  function self:resetTimer()
    self.guessingTime = 0
    self.tslu = 0
  end
  self:resetTimer()
  function self:finishTimer()
    self.guessingTime = MAX_GUESSING_TIME
    self.tslu = 0
  end
  function self:OnUpdate(elapsed)
    self.tslu = self.tslu + elapsed
    if self.tslu >= self.interval then
      if currentGame.word and currentGame.wordX then
        self.guessingTime = self.guessingTime + 1
        if currentGame.guessing and (getCurrentHost() ~= myCharnameRealm) then
          mainDrawFrame.text:SetText(currentGame.wordX.." ("..self.guessingTime..")")
        else
          mainDrawFrame.text:SetText(currentGame.word.." ("..self.guessingTime..")")
        end
        if self.guessingTime >= MAX_GUESSING_TIME then
          mainDrawFrame.text:SetText(currentGame.word.." ("..self.guessingTime..")")
          currentGame.guessing = nil
          if getCurrentHost() == myCharnameRealm then
            currentGame.wordX = nil
            sendPlayerScores()
          end
        elseif getCurrentHost() == myCharnameRealm then
          if floor(self.guessingTime * (MAX_HINTS+1) / MAX_GUESSING_TIME) > currentGame.hints then
            --construct next hint
            currentGame.hints = currentGame.hints + 1
            local wps = {};
            for i = 1, string.utf8len(currentGame.wordX) do
              if string.utf8sub(currentGame.wordX, i, i) == "_" then
                table.insert(wps, i)
              end
            end
            --"how many revealed chars do we want?" - "how many do we already have?"
            local c = floor(currentGame.hints / (MAX_HINTS+1) * string.utf8len(currentGame.wordX)) - (string.utf8len(currentGame.wordX) - #wps)
            for i = 1, c do
              local j = random(#wps)
              currentGame.wordX = string.utf8sub(currentGame.wordX, 1, wps[j]-1)..string.utf8sub(currentGame.word, wps[j], wps[j])..string.utf8sub(currentGame.wordX, wps[j]+1)
              table.remove(wps, j)
            end
            sendWordHint(currentGame.wordX)
          end
        end
      end
      
      self.tslu = 0
    end
  end
  self:SetScript("OnUpdate", function(self, elapsed)
    self:OnUpdate(elapsed)
  end);
  
  clearCanvasButton:SetSize(30, 20)
  clearCanvasButton:SetPoint("TOPRIGHT", mainDrawFrame, "TOPRIGHT", 0, 0)
  addDefaultTextures(clearCanvasButton, true)
  clearCanvasButton:EnableMouse(true)
  addDefaultText(clearCanvasButton, "clear")
  clearCanvasButton:SetScript("OnMouseUp", function(self, button)
    if GetMouseFocus() == self then --OnMouseUp fires when the button is released while the cursor is not above the frame
      if button=="LeftButton" then
        ArtPad:ClearCanvas()
        sendClearCanvas()
      end
    end
  end)
  clearCanvasButton:Hide()
  
  ---------------------
  --chat frame
  ---------------------
  chatFrame:SetSize(140, 300)
  chatFrame:SetPoint("TOPLEFT", self, "BOTTOMLEFT")
  addDefaultTextures(chatFrame)
  chatFrame.bgtexture:SetColorTexture(.1, .1, .2, 1)
  chatFrame:EnableMouse(true)
  
  guesstextbox:SetPoint("BOTTOMLEFT", chatFrame, "BOTTOMLEFT", 6, 0)
  guesstextbox:SetAutoFocus(false)
  guesstextbox:SetSize(100, 20)
  guesstextbox:SetTextInsets(0,0,3,3)
  guesstextbox:SetText("guess what...")
  guesstextbox:SetCursorPosition(0)
  guesstextbox:SetScript("OnEnterPressed", function(self)
    sendGuess(self:GetText())
    self:SetText("")
  end);
  guesstextbox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end);
  
  ---------------------
  --player frames
  ---------------------
  addPlayerFrame(myCharnameRealm, myClass)
end
headerFrame:SetScript("OnEvent", function(self, event, ...)
  self[event](self, ...)
end);
headerFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

---------------------
--model
---------------------
local gameIdChars = {"0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"};
currentGame = {
  id = nil;
  ps = {};
  hints = 0;
};

addPlayer = function(playerId, playerClass, order)
  for i = 1, #(currentGame.ps) do
    if currentGame.ps[i].pid == playerId then
      if order then
        currentGame.ps[i].order = order
      end
      return --not new
    end
  end
  table.insert(currentGame.ps, {
    pid = playerId;
    pclass = playerClass;
    lastguess = "";
    correctguess = 0;
    score = 0;
  })
  return true --new player
end
removePlayer = function(playerId)
  for i = 1, #(currentGame.ps) do
    if currentGame.ps[i].pid == playerId then
      table.remove(currentGame.ps, i)
      break
    end
  end
end
getPlayer = function(playerId)
  for i = 1, #(currentGame.ps) do
    if currentGame.ps[i].pid == playerId then
      return currentGame.ps[i]
    end
  end
end

getCurrentHost = function(position)
  position = position or 1
  if #(currentGame.ps) >= position then
    return currentGame.ps[position].pid
  end
end

addPlayerScore = function(playerId, score)
  for i = 1, #(currentGame.ps) do
    if currentGame.ps[i].pid == playerId then
      currentGame.ps[i].score = currentGame.ps[i].score + max(score, 0)
      return currentGame.ps[i]
    end
  end
end
setPlayerScore = function(playerId, score)
  for i = 1, #(currentGame.ps) do
    if currentGame.ps[i].pid == playerId then
      currentGame.ps[i].score = score
      break
    end
  end
end

resetPlayersDone = function(isHostDone)
  for i = 1, #(currentGame.ps) do
    if isHostDone and (i == 1) then
      currentGame.ps[i].done = true
    else
      currentGame.ps[i].done = nil
    end
  end
end
checkAllPlayersDone = function()
  for i = 1, #(currentGame.ps) do
    if not (currentGame.ps[i].done or (currentGame.ps[i].pid == myCharnameRealm)) then
      return
    end
  end
  return true
end

resetGame = function()
  removeAllPlayerFrames()
  currentGame.id = nil
  sendLeaveGame()
  currentGame.ps = {};
  jointextbox:SetText("")
  startGameButton:Hide()
  leaveGameButton:Hide()
  
  currentGame.word = nil
  currentGame.wordX = nil
  currentGame.guessing = nil
  mainDrawFrame.text:Hide()
  ArtPad:ClearCanvas()
  
  for i = 1, 3 do
    chooseButtons[i]:Hide()
  end
  
  clearCanvasButton:Hide()
end

joinGame = function(id)
  resetGame()
  toggleHeaderFrame(true)
  toggleDrawFrame(true)
  sendJoinGame(id)
end

startNewGame = function()
  resetGame()
  
  --create new game id
  local id = "S"
  local channelFound = false
  --add COM channel to game id
  for i = 1, #CHANNEL_LIST do
    if CHANNEL_LIST[i][1] == O.COMchannel then
      id = id..CHANNEL_LIST[i][2]
      channelFound = true
      break
    end
  end
  if not channelFound then
    print("unknown COM channel")
    return
  end
  --add random chars to game id
  for i = 1, 10 do
    id = id..gameIdChars[random(#gameIdChars)]
  end
  jointextbox:SetText(id)
  
  currentGame.id = id
  
  addPlayer(myCharnameRealm, myClass)
  addPlayerFrame(myCharnameRealm, myClass)
  
  startGameButton:Show()
  
  print(BLUE_PRINT_COLOR.."Scribbl |rstarted new game!")
  
  sendNewGame()
end

nextRound = function()
  --rotate
  local p = table.remove(currentGame.ps, 1)
  table.insert(currentGame.ps, p)
  
  --send
  sendNextRoundPlayerList()
end

startGame = function()
  --shuffle
  local ps = {};
  for i = 1, #(currentGame.ps) do
    table.insert(ps, i)
  end
  for i = 1, #(currentGame.ps) do
    local j = random(#ps)
    currentGame.ps[i].order = ps[j]
    table.remove(ps, j)
  end
  table.sort(currentGame.ps, function(a,b)return a.order<b.order;end)
  
  startGameButton:Hide()
  
  nextRound()
end

leaveGame = function()
  resetGame()
end

---------------------
--Draw
---------------------
--uses parts of ArtPad (https://wow.curseforge.com/projects/artpad)
--by:
--  Dust, Turalyon-EU
--  Snaxxramas, Defias Brotherhood-EU
--  mnu87 on curseforge
---------------------

ArtPad.mainFrame = mainDrawFrame
ArtPad.state = "SLEEP";

mainDrawFrame:SetScript("OnMouseDown", function(self, button)
  ArtPad:OnMouseDown(button)
end);
mainDrawFrame:SetScript("OnMouseUp", function(self, button)
  ArtPad:OnMouseUp(button)
end);
mainDrawFrame:SetScript("OnEnter", function(self, motion)
  ArtPad:OnEnter(motion)
end);
mainDrawFrame:SetScript("OnLeave", function(self, motion)
  ArtPad:OnLeave(motion)
end);

function ArtPad.OnMouseDown(frame, button)
  local self = ArtPad; -- Static Method
  if (getCurrentHost() == myCharnameRealm) and currentGame.wordX then
    if self.state == "SLEEP" then
      if button == "LeftButton" then
        self.state = "PAINT";
      else
        self.state = "CLEAR";
      end;
    end;
  end
end;

function ArtPad.OnMouseUp(frame, button)
  local self = ArtPad; -- Static Method
  self.state = "SLEEP";
  --send pending lines, move between buffers
  if getCurrentHost() == myCharnameRealm then
    sendLines(self.mainLinesPending)
    for i = #(self.mainLinesPending), 1, -1 do
      table.insert(self.mainLines, table.remove(self.mainLinesPending, i))
    end
  end
end;

function ArtPad.OnEnter(frame, motion)
  local self = ArtPad; -- Static Method
  self.mainFrame:SetScript("OnUpdate", self.OnUpdate);
end;

function ArtPad.OnLeave(frame, motion)
  local self = ArtPad; -- Static Method
  self.mainFrame:SetScript("OnUpdate", nil);
  self.state = "SLEEP";
  self.lastX = nil;
  self.lastY = nil;
end;

ArtPad.mouseX = -1;
ArtPad.mouseY = -1;

ArtPad.tslu = 0
ArtPad.interval = .03

function ArtPad.OnUpdate(frame, elapsed)
  local self = ArtPad; -- Static Method
  
  self.tslu = self.tslu + elapsed
  if self.tslu < self.interval then
    return
  end
  self.tslu = 0
  
  local mx, my = GetCursorPosition();
  if mx == self.mouseX and my == self.mouseY then
    return;
  else
    self.mouseX = mx;
    self.mouseY = my;
  end;
  local x, y;		-- Local coordinates
  local scale = self.mainFrame:GetEffectiveScale();
  
  mx = mx/scale;
  my = my/scale;
  x = math.floor(mx - self.mainFrame:GetLeft());
  y = math.floor(my - self.mainFrame:GetBottom());
  
  if self.state ~= "SLEEP" then
    self:HandleMove(x, y, self.lastX, self.lastY);
  end;
  
  self.lastX = x;
  self.lastY = y;
end;

function ArtPad:HandleMove(x,y,oldX,oldY)
  if self.state == "PAINT" then
    self:DrawLine(x, y, oldX, oldY, self.brushColor, true);
  elseif self.state == "CLEAR" then
    self:ClearLine(x,y,oldX,oldY);
    --TODO:buffer clear lines, send them
  end;
end;

ArtPad.brushColor = { r = 1.0; g = 1.0; b = 1.0; a = 0.75; };

ArtPad.mainLines = {};
ArtPad.mainLinesPending = {};
ArtPad.junkLines = {};

function ArtPad:DrawLine(x, y, oldX, oldY, brush, addToPending)
  if oldX and oldY then
    self:CreateLine(x,y, oldX, oldY, brush, addToPending);
  end;
end;

function ArtPad:ClearLine(x, y, oldX, oldY)
  for i = #self.mainLines, 1, -1 do
    if self.mainLines[i]  then
      local px = self.mainLines[i]["lax"];
      local py = self.mainLines[i]["lay"];
      local qx = self.mainLines[i]["lbx"];
      local qy = self.mainLines[i]["lby"];
      if self:LineLineIntersect(x,y,oldX,oldY,px,py,qx,qy) then
        self:JunkLine(i);
      end;
    end;
  end;
end;

function ArtPad:LineLineIntersect(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
  --http://www.softsurfer.com/Archive/algorithm_0104/algorithm_0104B.htm#intersect2D_SegSeg()
  local ux, uy = ax1-ax0, ay1-ay0;
  local vx, vy = bx1-bx0, by1-by0;
  local wx, wy = ax0-bx0, ay0-by0;
  local D = ux*vy - uy*vx;
  
  if (D == 0) then
    -- Parallel
    return false;
  else
    local sI = (vx*wy-vy*wx) / D;
    if (sI < 0 or sI > 1) then -- no intersect with S1
      return false;
    end;
    
    local tI = (ux*wy-uy*wx) / D;
    if (tI < 0 or tI > 1) then -- no intersect with S2
      return false;
    end;
    
    return true;
  end;
end;

-- A square brush
function ArtPad:ClearCanvas()
  for i = #self.mainLines, 1, -1 do
    self:JunkLine(i);
  end;
end;

function ArtPad:SetColor(r, g, b, a)
  self.brushColor.r = r;
  self.brushColor.g = g;
  self.brushColor.b = b;
  self.brushColor.a = a;
  self.brushColorSample:SetColorTexture(r,g,b,a);
end;

function ArtPad:SetTexColor(tex, brush)
  tex:SetVertexColor(brush.r,
    brush.g,
    brush.b,
    brush.a);
end;

function ArtPad:CreateLine(x, y, a, b, brush, addToPending)
  local ix = math.floor(x);
  local iy = math.floor(y);
  local ia = math.floor(a);
  local ib = math.floor(b);
  
  local cx, cy = (ix + ia)/2, (iy + ib)/2;
  local dx, dy = ix-ia, iy-ib;
  local dmax = math.max(math.abs(dx),math.abs(dy));
  local dr = math.sqrt(dx*dx + dy*dy);
  local scale = 1/dmax*32;
  local sinA, cosA = dy/dr*scale, dx/dr*scale;
  if dr == 0 then
    return nil;
  end
  
  local pix;
  if #(self.junkLines) > 0 then
    pix = table.remove(self.junkLines); -- Recycling ftw!
  else
    pix = self.mainFrame:CreateTexture(nil, "OVERLAY");
    pix:SetTexture("Interface\\AddOns\\Scribbl\\line.tga");
  end;
  self:SetTexColor(pix, brush);
  pix:ClearAllPoints();
  
  pix:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", cx, cy);
  pix:SetWidth(dmax); pix:SetHeight(dmax);
  pix:SetTexCoord(self.GetCoordsForTransform(
  cosA, sinA, -(cosA+sinA)/2+0.5,
    -sinA, cosA, -(-sinA+cosA)/2+0.5));
  pix:Show();
  pix["lax"] = ix;
  pix["lay"] = iy;
  pix["lbx"] = ia;
  pix["lby"] = ib;
  pix["r"] = brush.r
  pix["g"] = brush.g
  pix["b"] = brush.b
  pix["a"] = brush.a
  if addToPending then
    table.insert(self.mainLinesPending, pix);
  else
    table.insert(self.mainLines, pix);
  end
  
  return pix, #self.mainLines;
end;

function ArtPad:JunkLine(id)
  if self.mainLines[id] then
    local pix = table.remove(self.mainLines, id);
    if pix then
      table.insert(self.junkLines, pix);
      pix:Hide();
    end;
  end;
end;

function ArtPad.GetCoordsForTransform(A, B, C, D, E, F)
  -- http://www.wowwiki.com/SetTexCoord_Transformations
  local det = A*E - B*D;
  local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy;
  
  ULx, ULy = ( B*F - C*E ) / det, ( -(A*F) + C*D ) / det;
  LLx, LLy = ( -B + B*F - C*E ) / det, ( A - A*F + C*D ) / det;
  URx, URy = ( E + B*F - C*E ) / det, ( -D - A*F + C*D ) / det;
  LRx, LRy = ( E - B + B*F - C*E ) / det, ( -D + A -(A*F) + C*D ) / det;
  
  return ULx, ULy, LLx, LLy, URx, URy, LRx, LRy;
end;

---------------------

SLASH_SCRIBBL1 = "/scribbl"
SlashCmdList["SCRIBBL"] = function(msg, editbox)
  local args = mysplit2(msg or "")
  local arg1 = string.lower(args[1] or "")
  if arg1 == "resetposition" then
    O.framePoint = DefaultO.framePoint
    O.frameRelativeTo = DefaultO.frameRelativeTo
    O.frameRelativePoint = DefaultO.frameRelativePoint
    O.frameOffsetX = DefaultO.frameOffsetX
    O.frameOffsetY = DefaultO.frameOffsetY
    
    headerFrame:ClearAllPoints()
    headerFrame:SetPoint(O.framePoint, O.frameRelativeTo, O.frameRelativePoint, O.frameOffsetX, O.frameOffsetY)
    
    print(BLUE_PRINT_COLOR.."Scribbl |rposition reset")
  elseif arg1 == "show" then
    toggleHeaderFrame(true)
  elseif arg1 == "hide" then
    toggleHeaderFrame(false)
  elseif arg1 == "max" then
    toggleDrawFrame(true)
  elseif arg1 == "min" then
    toggleDrawFrame(false)
  else
    print(BLUE_PRINT_COLOR.."Scribbl |r"..(GetAddOnMetadata("Scribbl", "Version") or "").." "..BLUE_PRINT_COLOR.."(use |r/scribbl <option> "..BLUE_PRINT_COLOR.."for these options)")
    print("  show/hide "..BLUE_PRINT_COLOR.."toggle all frames")
    print("  min/max "..BLUE_PRINT_COLOR.."minimize/restore frames")
    print("  resetposition "..BLUE_PRINT_COLOR.."reset position to default")
  end
end
