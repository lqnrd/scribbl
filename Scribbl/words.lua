--[[
Scribbl words
--]]

local words = {"demon hunter", "death knight", "druid", "hunter", "mage", "monk", "paladin", "priest", "rogue", "shaman", "warlock", "warrior"}
do
  --prepare words
  for i = 1, #words do
    words[i] = words[i]:upper():gsub("\"", "")
  end
end

Scribbl_words = words