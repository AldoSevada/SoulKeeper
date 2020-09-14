local _, core = ...

-- Start and end time of last cast 'Drain Soul'
drain_soul = { 
  start_t = -1, 
  end_t = -1 
}

-- data associated with soul shard
killed_target = {
  time = -1,
  name = "",
  race = "",
  class = "",
  location = ""
  -- TODO: Add level if alliance? 
}

-- Mapping of soul shards to bag indices
-- TODO: Save these values between sessions
shard_mapping = { {}, {}, {}, {}, {} }

-- next available slot in bags (soul bag priority)
next_open_slot = {}
shard_added = false

-- shard(s) that are currently locked (selected/swapping)
locked_shards = {}


-- Reset drain soul start/end times
function resetData()
    drain_soul = { start_t = -1, end_t = -1 }
end


--[[ Return true if the spell consumes a shard; false otherwise --]]
function shard_consuming_spell(spell_name)
  for _, shard_spell in pairs(core.SPELL_NAMES) do
    if ( string.find(spell_name,shard_spell) ) then
      return true
    end
  end
  return false
end


--[[ Return the bag number and slot of next shard that will be consumed --]]
function findNextShard()
  local next_shard = { bag = core.SLOT_NULL, index = core.SLOT_NULL }
  for bag_num, _ in ipairs(shard_mapping) do 
    for bag_index, _ in pairs(shard_mapping[bag_num]) do
      if bag_num <= next_shard.bag then
        next_shard.bag = bag_num
        if bag_index <= next_shard.index then
          next_shard.index = bag_index
        end
      end
    end
  end
  next_shard.bag = next_shard.bag
  return next_shard
end


--[[
  Set next_open_slot variable to contain the bag_number and index of the 
  next open bag slot. Only soulbags and regular bags considered, soul bags
  get priority order.
--]]
function update_next_open_bag_slot()
    local open_soul_bag = {}
    local open_normal_bag = {}
    for bag_num = 0, core.MAX_BAG_INDEX, 1 do
      -- get number of free slots in bag and its type
      local num_free_slots, bag_type = GetContainerNumFreeSlots(bag_num);
      if num_free_slots > 0 then
        local free_slots = GetContainerFreeSlots(bag_num)

        -- save bag number and first open index if not yet found for bag type
        if bag_type == core.SOUL_BAG_TYPE and next(open_soul_bag) == nil then
          open_soul_bag['bag_number'] = bag_num
          open_soul_bag['open_index'] = free_slots[1]
        elseif bag_type == core.NORMAL_BAG_TYPE and next(open_normal_bag) == nil then
          open_normal_bag['bag_number'] = bag_num
          open_normal_bag['open_index'] = free_slots[1]
        end
      end
    end

    -- set next_open_slot to corresopnding bag/index
    if next(open_soul_bag) ~= nil then 
      next_open_slot = open_soul_bag
    elseif next(open_normal_bag) ~= nil then
      next_open_slot = open_normal_bag
    else
      next_open_slot = {} 
    end
end


--[[ From the Combat Log save the targets details, time, and location of kill --]]
local combat_log_frame = CreateFrame("Frame")
combat_log_frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
combat_log_frame:SetScript("OnEvent", function(self,event)
  local curr_time = GetTime()
  local _, subevent, _, _, _, _, _, dest_guid, dest_name = CombatLogGetCurrentEventInfo()
  if subevent == core.UNIT_DIED then 
    killed_target.time = curr_time
    killed_target.name = dest_name 
    killed_target.location = core.getPlayerZone()
    if dest_guid ~= nil then -- non npc?
      local class_name, _, race_name = GetPlayerInfoByGUID(dest_guid)
      killed_target.race = race_name
      killed_target.class = class_name
    end
  end
end)


--[[ Time drain soul started channeling --]]
local channel_start_frame = CreateFrame("Frame")
channel_start_frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
channel_start_frame:SetScript("OnEvent", function(self,event, ...)
  local spell_name, _, _, start_time = ChannelInfo()  
  if spell_name == core.DRAIN_SOUL then 
    -- ChannelInfo() multiplies time by 1000 this undos that.
    drain_soul.start_t = start_time/1000
  end
end)


--[[ 
  Time drain soul stopped channeling. 
  Check if the enemy was killed during this time.
--]]
local channel_end_frame = CreateFrame("Frame")
channel_end_frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
channel_end_frame:SetScript("OnEvent", function(self,event, ...)
  local _, _, spell_id = ... 
  local curr_time = GetTime()  
  local spell_name = GetSpellInfo(spell_id)

  if spell_name == core.DRAIN_SOUL then 
    drain_soul.end_t = curr_time

    -- enemy killed during drain soul?
    if ( killed_target.time >= drain_soul.start_t 
         and killed_target.time <= drain_soul.end_t
         and killed_target.time ~= -1 
         and drain_soul.start_t ~= -1
         and drain_soul.end_t ~= -1
       ) then 
      -- check if there is space for newly captured soul shard
      if next(next_open_slot) ~= nil then 
        shard_added = true
      end
    end

    resetData()
  end
end)


--[[
  On BAG_UPDATE (inventory change), check if item was a newly added soul shard. 
  Save mapping of new shard to bag index. Update next open bag slot.
--]]
local item_frame = CreateFrame("Frame")
item_frame:RegisterEvent("BAG_UPDATE")
item_frame:SetScript("OnEvent",
  function(self, event, ...)

    -- Drain soul was successfully cast on killed target after last BAG_UPDATE
    if shard_added then
      shard_added = false
      local bag_number = next_open_slot['bag_number']
      local shard_index = next_open_slot['open_index']
      local item_id = GetContainerItemID(bag_number, shard_index)
      if item_id == core.SOUL_SHARD_ID then
        print(
         "Soul shard added to bag : " .. 
          bag_number .. ", slot " .. shard_index
        )
        -- save deep copy of table
        -- NOTE: Bag numbers index from [0-4] but the shard_mapping table is from [1-5]
        shard_mapping[bag_number+1][shard_index] = core.deep_copy(killed_target)
        --print("Name: " .. shard_mapping[bag_number+1][shard_index].name)
        --print("Location: " .. shard_mapping[bag_number+1][shard_index].location)
      end
    end

    -- update next open slot
    update_next_open_bag_slot()

    --print_shard_info()
  end)


--[[
  When a soul shard is locked (selected from inventory), save its data
  in the locked_shards table with its bag/bag_slot numbers. 
  Remove the shards mapping from the shard_mapping table until unlocked.
  ( see 'ITEM_UNLOCKED' frame )
--]]
local bag_slot_lock_frame = CreateFrame("Frame")
bag_slot_lock_frame:RegisterEvent("ITEM_LOCKED")
bag_slot_lock_frame:SetScript("OnEvent",
  function(self, event, ...)
    local bag_id, slot_id = ...
    local item_id = GetContainerItemID(bag_id, slot_id)
    if item_id == core.SOUL_SHARD_ID then
      -- add shard to table of currently locked shards
      curr_shard = {}
      curr_shard.data = shard_mapping[bag_id+1][slot_id]
      curr_shard.bag_id = bag_id
      curr_shard.slot_id = slot_id
      table.insert(locked_shards, curr_shard)
      shard_mapping[bag_id+1][slot_id] = nil

      -- TODO: REMOVE ME!!!
      print("Removing shard --- " .. curr_shard.data.name .. " --- from map!")
      print("From [" .. bag_id+1 .. ", " .. slot_id .. "]")
    end
  end)


--[[
  When a soul shard is unlocked (put into the inventory from locked state),
  update mapping with the shards data. 
  Checks table of locked_shards adding the shard from a different bag slot
  if there are more than one shards in the list (e.g. a swap is occuring).
--]]
local bag_slot_unlock_frame = CreateFrame("Frame")
bag_slot_unlock_frame:RegisterEvent("ITEM_UNLOCKED")
bag_slot_unlock_frame:SetScript("OnEvent",
  function(self, event, ...)
    local bag_id, slot_id = ...
    local item_id = GetContainerItemID(bag_id, slot_id)
    if item_id == core.SOUL_SHARD_ID then

      -- select correct shard to insert from table of unlocked shards
      for index, curr_shard in pairs(locked_shards) do
        
        -- only 1 element in table; set into slot; remove from table
        if (#locked_shards == 1) then
          shard_mapping[bag_id+1][slot_id] = table.remove(locked_shards,index).data

        -- swapping multiple shards; select the one from a different slot
        elseif ( (curr_shard.bag_id ~= bag_id) or 
             (curr_shard.bag_id == bag_id and curr_shard.slot_id ~= slot_id) 
           ) then
            shard_mapping[bag_id+1][slot_id] = table.remove(locked_shards,index).data
            break
        end
      end

      -- TODO: REMOVE ME!!!
      print("Added shard --- " .. shard_mapping[bag_id+1][slot_id].name .. " --- to map!")
      print("To [" .. bag_id+1 .. ", " .. slot_id .. "]")
    end
  end)


--[[ 
  On game start/reload, iterate over all bag slots and map any unmapped soul shards. 
  Values set to default (<MISSING DATA>).
--]]
local reload_frame = CreateFrame("Frame")
reload_frame:RegisterEvent("PLAYER_ENTERING_WORLD")
reload_frame:SetScript("OnEvent", 
  function(self,event,...)
    for bag_num = 0, core.MAX_BAG_INDEX, 1 do
      num_bag_slots = GetContainerNumSlots(bag_num)
      for slot_num = 1, num_bag_slots, 1 do
        curr_item_id = GetContainerItemID(bag_num, slot_num)
        curr_shard_slot = shard_mapping[bag_num+1][slot_num]
        -- unmapped soul shard; map it.
        if ( (curr_item_id == core.SOUL_SHARD_ID) and (curr_shard_slot == nil) ) then
          shard_mapping[bag_num+1][slot_num] = core.deep_copy(core.DEFAULT_KILLED_TARGET_DATA)
        end
      end
    end 
  end)


--[[ TODO: ]]--
-- Check if shard consuming spell was successfully cast, display 
-- associated information about shard.
local cast_success_frame = CreateFrame("Frame")
cast_success_frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
cast_success_frame:SetScript("OnEvent", 
  function(self,event,...)
    local unit_target, cast_guid, spell_id = ...
    local spell_name = GetSpellInfo(spell_id)

    -- create healthstone/soulstone/etc...
    if ( shard_consuming_spell(spell_name) ) then
      print("Consumed a shard!")
      consumed_shard = findNextShard()
      if consumed_shard.bag == core.SLOT_NULL then -- prevents duplicate executions
        return 
      end
      -- TODO: 
      --  1. Temporary: Whisper to self consumed_shard data
      --  2. Map HS/SS/whatever created to consumed_shard data
      
    --TODO: elseif (consume healthstone/soulstone/whatever) announce consuming HS with soul of w/e
    end
  end)








function print_shard_info() 
  for i=1, 5 do
    for j=1, 16 do
      if shard_mapping[i][j] ~= nil then
        print("Bag " .. i-1 .. " slot " .. j ..
       "\nKilled " .. shard_mapping[i][j].name
        .. "\n Location: " .. shard_mapping[i][j].location .. "\n - - - - - -") 
      end
    end
  end
end





-- TODO: Handle if player destroys a shard
-- TODO: Reset data option





-- TODO: TEMP -- REMOVE ME!!!!
--[[
local target_info_frame = CreateFrame("Frame")
target_info_frame:RegisterEvent("PLAYER_TARGET_CHANGED")
target_info_frame:SetScript("OnEvent",
  function(self, event)
    shard_mapping[2][1] = { name = 'x' }
    shard_mapping[2][2] = { name = 'y' }
    shard_mapping[2][3] = { name = 'z' }
    next_shard = findNextShard()
    print("Next shard bag: " .. next_shard.bag)
    print("Next shard index: " .. next_shard.index)
  end)
-]]
-- END
