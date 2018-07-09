--[[

                         iTransferProtocol-1.0

   2017 by lqnrd (CC BY-SA 4.0)

1. Usage

1.1 Functions

  local iTPCallback = iTP:RegisterPrefix(prefix)
  
    Registers a new addon prefix like you would with Blizzard's
    RegisterAddonMessagePrefix(prefix). Result table will be used to get
    events.
  
  local isRegistered = iTP:IsPrefixRegistered(prefix)
  
    Returns whether the given prefix is already registered.
  
  local msgid = iTP:SendAddonMessage(prefix, msg, channel [, target])
  
    Works just like Blizzard's SendAddonMessage. Return value can be
    used to keep track of specific messages.
  
  iTP:ClearPendingMessages(prefix)
  
    Clear output queue for that prefix, aborting current transfers and
    deleting all outgoing messages.
  
  iTP:RepeatLastMessage(prefix)
  
    Sends the last message that was put into the output queue of that
    prefix again.
    If message B is put into the queue while message A is still being
    sent, calling RepeatLastMessage will push a copy of message B into
    the queue.
  
  iTP:toggledebug(level, silent)
  
    Sets the debug message level. level=0 means no debug messages will
    be shown, level=1 for some messages, level=2 to show all debug
    messages.
    If silent is not "true" a message will be shown echoing the current
    debug level.

1.2 Events

  Note: With the exception of "IDLE" all events are only sent to the
  matching prefix. Prefix A does not get a "CHAT_MSG_ADDON" when a
  message of prefix B has been received.

  iTPCallback:CHAT_MSG_ADDON(prefix, msg, channel, from, sendermsgid)
  
    Works just like Blizzard's CHAT_MSG_ADDON.
    Additional arg sendermsgid is the msgid returned from the sender's
    call to SendAddonMessage.
  
  iTPCallback:OnSendAddonMessageBegin(msgid, partcount)
  
    Fired after calling SendAddonMessage. Message with id "msgid" was
    put into the output queue, split into "partcount" parts.
  
  iTPCallback:OnSendAddonMessageProgress(msgid, partcount, partnumber)
  
    Fired when part "partnumber" of total parts "partcount" of message
    with id "msgid" is sent.
  
  iTPCallback:OnSendAddonMessageEnd(msgid, partcount)
  
    Fired when the last ("partcount") part of message with id "msgid"
    was sent.
  
  iTPCallback:IDLE()
  
    Fired after sending a message when the output queue is empty again.
  
2. Limitations

2.1 Prefix

  Prefix length is limited to 8 characters. While there won't be an
  error message, with prefixes longer than 8 characters only the first 8
  will be used. Prefixes shorter than 8 characters will be padded with
  trailing spaces.
  Prefixes "abc" and "abc " are equal. Prefixes "abcdefgh" and
  "abcdefghi" are equal.
  
  There is no limit to the number of different prefixes being registered
  at any time.

2.2 Message length

  Outgoing messages are limited to 15073050 characters, which is a
  little more than 14.3 MByte.

3. Technical details

  The lib itself uses the prefix "iTP1".
  
  Outgoing messages are split into parts of 230 characters.
  One part consists of the following fields:
    +--------+----+----+----+-...-+
    | PREFIX |M_ID|PCNT|PNUM|PMSG |
    +--------+----+----+----+-...-+
  where
    PREFIX is the calling addon's registered prefix (filled with
      trailing spaces to be 8 characters long).
    M_ID is the current message id. Each message that is put into the
      output queue is assigned a consecutive id between 0x0000 and
      0xffff.
    PCNT is the number of parts this message was split into.
    PNUM is the current part's number.
    PMSG is the currently transmitted part of the message.
  
  If the output queue is not empty, every 0.5 seconds one part is sent.
  
  The output uses a FIFO queue.
--]]

--------------------
--XXX BfA compat
--------------------
local isBfA = select(4, GetBuildInfo()) >= 80000
local RegisterAddonMessagePrefix = isBfA and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local SendAddonMessage = isBfA and C_ChatInfo.SendAddonMessage or SendAddonMessage
--------------------

local iTP = LibStub:NewLibrary("iTransferProtocol-1.0", 1)

if not iTP then return end -- No upgrade needed
local iTPPrefix = "iTP1"
local COMok = RegisterAddonMessagePrefix(iTPPrefix)
if not COMok then error("iTP: RegisterAddonMessagePrefix failed.") end

iTP.prefixes = {};
local prefixesList = {};
local nextPrefix = 1
local lastSentTimestamp = 0
local isdebug = 0
local myRealm = GetRealmName("player"):gsub("%s","")
local function logdebug(...)
  if isdebug > 0 then
    print(...)
  end
end
local function logdebugverbose(...)
  if isdebug > 1 then
    print(...)
  end
end

local iTPFrame = CreateFrame("Frame", nil, UIParent)
iTPFrame.tslu = 0
iTPFrame.interval = 0.5

local function trim1(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end
local function getPaddedPrefix(prefix)
  return ("%s        "):format(prefix):sub(1, 8) --only get the first 8 chars, padded with spaces
end

function iTP:toggledebug(b, silent)
  if type(b) == "Boolean" then
    isdebug = b and 1 or 0
  else
    isdebug = b
  end
  if not silent then
    print("|cffffff00iTP debug:", isdebug)
  end
end

function iTP:RegisterPrefix(prefix)
  prefix = getPaddedPrefix(prefix)
  if self.prefixes[prefix] then
    error(format("Prefix %s is already registered.", trim1(prefix)))
  end
  
  self.prefixes[prefix] = {
    ["prefix"] = prefix;
    ["nextmsgid"] = 1; --"0001"
    ["messagesOut"] = {};
    ["messagesIn"] = {};
    ["lastMessageOut"] = nil;
  };
  table.insert(prefixesList, self.prefixes[prefix])
  
  return self.prefixes[prefix]
end

function iTP:IsPrefixRegistered(prefix)
  prefix = getPaddedPrefix(prefix)
  if self.prefixes[prefix] then
    return true
  end
  return false
end

function iTP:SendAddonMessage(prefix, message, channel, whispertarget)
  prefix = getPaddedPrefix(prefix)
  local prefixTable = self.prefixes[prefix]
  if not prefixTable then
    error(format("Prefix %s is not registered.", trim1(prefix)))
  end
  
  if message:len() > 15073050 then --"ffff" parts with len 230 (15,073,050 bytes)
    error("Message too long.")
  end
  
  local parts = {};
  if message:len() == 0 then
    table.insert(parts, "")
  else
    for i = 1, message:len(), 230 do
      table.insert(parts, message:sub(i, i + 229))
    end
  end
  
  local messageOut = {
    ["msgid"] = prefixTable.nextmsgid;
    ["channel"] = channel;
    ["whispertarget"] = whispertarget;
    ["partcount"] = #parts;
    ["parts"] = parts;
    ["nextpartnumber"] = 1;
  };
  table.insert(prefixTable.messagesOut, messageOut)
  prefixTable.lastMessageOut = {
    ["message"] = message;
    ["channel"] = channel;
    ["whispertarget"] = whispertarget;
  };
  
  if prefixTable.OnSendAddonMessageBegin and type(prefixTable.OnSendAddonMessageBegin) == "function" then
    local ok, err = pcall(prefixTable.OnSendAddonMessageBegin, prefixTable, prefixTable.nextmsgid, #parts)
  end
  
  prefixTable.nextmsgid = prefixTable.nextmsgid + 1
  if prefixTable.nextmsgid > 65535 then --"ffff"
    prefixTable.nextmsgid = 1
  end
  
  if lastSentTimestamp < (GetTime() - iTPFrame.interval) then
    iTPFrame:OnUpdate(iTPFrame.interval)
  end
  
  return messageOut.msgid
end

function iTP:ClearPendingMessages(prefix)
  prefix = getPaddedPrefix(prefix)
  local prefixTable = self.prefixes[prefix]
  if not prefixTable then
    error(format("Prefix %s is not registered.", trim1(prefix)))
  end
  
  prefixTable.messagesOut = {}
  prefixTable.messagesIn = {}
  prefixTable.lastMessageOut = nil
end

function iTP:RepeatLastMessage(prefix)
  prefix = getPaddedPrefix(prefix)
  local prefixTable = self.prefixes[prefix]
  if not prefixTable then
    error(format("Prefix %s is not registered.", trim1(prefix)))
  end
  
  if prefixTable.lastMessageOut then
    return iTP:SendAddonMessage(prefix, prefixTable.lastMessageOut.message, prefixTable.lastMessageOut.channel, prefixTable.lastMessageOut.whispertarget)
  end
  
  return false
end

local function SendNextMessage()
  if #(prefixesList) == 0 then return end
  logdebugverbose("|cffffcc00  #(prefixesList) > 0")
  
  local prefixIndex = 0
  
  for i = nextPrefix, #(prefixesList) do
    if #(prefixesList[i].messagesOut) > 0 then
      prefixIndex = i
      break
    end
  end
  if prefixIndex == 0 then
    for i = 1, nextPrefix - 1 do
      if #(prefixesList[i].messagesOut) > 0 then
        prefixIndex = i
        break
      end
    end
  end
  
  if prefixIndex == 0 then return end
  logdebugverbose("|cffffcc00  prefixIndex =", prefixIndex)
  
  local message = prefixesList[prefixIndex].messagesOut[1]
  
  local msg = format("%s%04x%04x%04x%s", prefixesList[prefixIndex].prefix, message.msgid, message.partcount, message.nextpartnumber, message.parts[message.nextpartnumber])

  local sendOk, sendErr = pcall(SendAddonMessage, iTPPrefix, msg, message.channel, message.whispertarget)
  logdebug("|cffffff00SendAddonMessage(", iTPPrefix, msg, message.channel, message.whispertarget, ")", sendOk, sendErr)
  
  if prefixesList[prefixIndex].OnSendAddonMessageProgress and type(prefixesList[prefixIndex].OnSendAddonMessageProgress) == "function" then
    local ok, err = pcall(prefixesList[prefixIndex].OnSendAddonMessageProgress, prefixesList[prefixIndex], message.msgid, message.partcount, message.nextpartnumber)
  end

  message.parts[message.nextpartnumber] = nil
  
  message.nextpartnumber = message.nextpartnumber + 1
  if message.nextpartnumber > message.partcount then
    if prefixesList[prefixIndex].OnSendAddonMessageEnd and type(prefixesList[prefixIndex].OnSendAddonMessageEnd) == "function" then
      local ok, err = pcall(prefixesList[prefixIndex].OnSendAddonMessageEnd, prefixesList[prefixIndex], message.msgid, message.partcount)
    end
    
    table.remove(prefixesList[prefixIndex].messagesOut, 1)
  end
  
  nextPrefix = prefixIndex + 1
  if nextPrefix > #(prefixesList) then
    nextPrefix = 1
  end
  
  lastSentTimestamp = GetTime()
  
  --if no more messages to sent, callback IDLE
  --TODO: IDLE only after 0.5sec
  local queueEmpty = true
  for _, v in ipairs(prefixesList) do
    if #(v.messagesOut) > 0 then
      queueEmpty = false
      break
    end
  end
  if queueEmpty then
    for _, v in ipairs(prefixesList) do
      if v.IDLE and type(v.IDLE) == "function" then
        local ok, err = pcall(v.IDLE, v)
      end
    end
  end
end

function iTPFrame:CHAT_MSG_ADDON(prefix, msg, channel, from)
  if prefix ~= iTPPrefix then return end
  
  logdebug("|cffffff00CHAT_MSG_ADDON", prefix, msg, channel, from)
  if not from:find("-") then
    logdebug("CHAT_MSG_ADDON: set realm to", myRealm)
    from = from.."-"..myRealm
  end
  
  local payloadPrefix = msg:sub(1, 8)
  
  local prefixTable = iTP.prefixes[payloadPrefix]
  if not prefixTable then return end
  
  local msgid = tonumber(msg:sub(9, 12), 16)
  local partcount = tonumber(msg:sub(13, 16), 16)
  local partnumber = tonumber(msg:sub(17, 20), 16)
  local payload = msg:sub(21)
  
  if not msgid or not partcount or not partnumber then
    logdebug("msg part missing")
    return
  end
  
  if not prefixTable.messagesIn[from] then
    prefixTable.messagesIn[from] = {};
  end
  local playeridTable = prefixTable.messagesIn[from]
  
  if not playeridTable[msgid] then
    playeridTable[msgid] = {
      ["channel"] = channel;
      ["partcount"] = partcount;
      ["parts"] = {};
      ["nextpartnumber"] = 1;
    };
  end
  local messageTable = playeridTable[msgid]
  
  if partnumber ~= messageTable.nextpartnumber then
    logdebug(format("|cffffff00Got part %d, expected %d.", partnumber, messageTable.nextpartnumber))
    playeridTable[msgid] = nil
    return
  end
  
  messageTable.parts[partnumber] = payload
  messageTable.nextpartnumber = messageTable.nextpartnumber + 1
  
  if messageTable.nextpartnumber > messageTable.partcount then
    local msgconcat = table.concat(messageTable.parts, "")
    if prefixTable.CHAT_MSG_ADDON and type(prefixTable.CHAT_MSG_ADDON) == "function" then
      local ok, err = pcall(prefixTable.CHAT_MSG_ADDON, prefixTable, trim1(payloadPrefix), msgconcat, channel, from, msgid)
    end
    
    playeridTable[msgid] = nil
  end
end
iTPFrame:RegisterEvent("CHAT_MSG_ADDON")

iTPFrame:SetScript("OnEvent", function(self, event, ...)
  iTPFrame[event](self, ...)
end);

function iTPFrame:OnUpdate(elapsed)
  self.tslu = self.tslu + elapsed
  if self.tslu >= self.interval then
    logdebugverbose("|cffffcc00iTPFrame:Timer()")
    SendNextMessage()
    self.tslu = 0
  end
end
iTPFrame:SetScript("OnUpdate", function(self, elapsed)
  self:OnUpdate(elapsed)
end);