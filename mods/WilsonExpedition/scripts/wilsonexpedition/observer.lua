--============================================================================
-- [喵喵喵] WilsonExpedition / 观测层（纯客户端只读观测）
--
-- 本文件只读取"客户端可见"的副本数据(组件副本 replica、玩家 classified 实体、
-- TheWorld.state、TheSim 查询)，不发起任何服务端改动、不调用 RPC。
-- 脚本全局变量是 DST 原生全局(TheNet / TheShard / TheWorld / TheSim / TUNING)，
-- 不使用 modmain 的 GLOBAL 包装。
--
-- 对外接口：
--   Observer.Observe(player, memory) -> snapshot
--       player: 观测目标(通常是 ThePlayer)；可为 nil(此时 ready=false)。
--       memory: 调用方持有的可持久化表(纯可序列化数据)，本文件只读写该表，
--               每次观测做有界更新(去重 + 上限裁剪)。
--
-- snapshot 命名域(不可用的值一律为 nil，就绪状态用布尔字段显式表达)：
--   ready           boolean  本次观测是否拿到最小可用上下文
--   ready_reason    string|nil  ready=false 的原因
--   settled         boolean  副本/classified 是否初始化完毕(未就绪时不要相信计数)
--   replicas        table     各副本可用性布尔表
--   userid          string|nil
--   session         string|nil   原生会话/世界标识(TheNet:GetSessionIdentifier)
--   shard           string|nil   稳定分片标识("surface"/"cave"/"shard_<id>")
--   shard_kind      string|nil   "surface"|"cave"
--   shard_native    string|number|nil  原生分片号(TheShard:GetShardId)
--   prefab          string|nil
--   ghost           boolean|nil
--   x, y, z         number|nil   世界坐标
--   cycles          number|nil   零基天数(TheWorld.state.cycles)
--   day             number|nil   = cycles + 1(一基，便于阅读)
--   time            number|nil   0..1 当日小数进度(TheWorld.state.time)
--   time_in_phase   number|nil   0..1 当前相位内进度(TheWorld.state.timeinphase)
--   season          string|nil   "autumn"|"winter"|"spring"|"summer"
--   season_progress number|nil   0..1 季节内进度
--   phase           string|nil   "day"|"dusk"|"night"
--   moonphase       string|nil
--   nightmare_phase string|nil
--   health/hunger/sanity  number|nil  已钳制到 0..1 的百分比
--   temperature     number|nil   玩家体温(classified.currenttemperature)
--   moisture        number|nil   0..1 潮湿度比例
--   moisture_raw    number|nil   原生湿度绝对值
--   light           table      { available, in_light, level, threshold, dark }
--   platform        table|nil  { entity, guid, prefab }  当前所站平台(如船)
--   inventory       table      { records, count_map, by_prefab, total,
--                                backpack, settled, count(fn) }
--   equipment       table      装备槽 -> 记录(槽键沿用原生 ES 键)
--   active_item     record|nil 当前手持/激活物品
--   open_containers table      打开中的容器数组(含背包，is_backpack 标记)
--   nearby          table      附近实体数组
--   threats         table      附近实体中的威胁子集
--   landmarks       table      本次观测新看到的分类地标(含实体引用)
--   shore_points    table|nil  本次探测到的海岸点数组 { x, z }
--   memory_added    number|nil  本次写入记忆的新条目数
--   shard_memory    table|nil  该分片的持久记忆(只读视图，调用方不要改)
--
-- 记录(record)结构：
--   { item = entity, entity = entity, guid = GUID, prefab = string,
--     count = number, slot = number|string|nil, container = entity|nil,
--     kind = "inventory"|"backpack"|"equipment"|"active"|"container" }
--   container 为 nil 表示来源是主背包栏(primary inventory)。
--
-- 记忆(memory)结构(纯数据，只有坐标，不含实体句柄)：
--   memory.v            模式版本号
--   memory.tick         单调递增计数(用于 LRU)
--   memory.shards[key]  { kind, native_id, last_cycle, last_time, touched,
--                         seq, cats = { 类别 = { {prefab,x,z,cycle,seq}, ... } } }
--============================================================================

local Observer = {}

Observer.SCHEMA_VERSION = 1

-- [喵喵喵]: 地形探测与动作接近预算；可见实体范围由当前屏幕投影确定。 (2026-11-12)
Observer.NEARBY_RADIUS = 20
Observer.SHORE_PROBE_RADIUS = 12
Observer.SHORE_PROBE_COUNT = 8
Observer.LIGHT_THRESHOLD = 0.1

-- [喵喵喵] 记忆预算：每分片每类别条目上限、分片数上限、去重网格边长(世界单位)。
-- [喵喵喵]: 受控简化 — 每类保留最近512个已见网格；边界：最多4分片；升级：容量饱和且发生遗漏 → 分区存储。 (2026-11-12)
Observer.MEMORY_ENTRIES_PER_CATEGORY = 512
Observer.MEMORY_MAX_SHARDS = 4
Observer.MEMORY_GRID = 4

-- [喵喵喵] 地标类别：资源/通道/站点/海岸/船/首领/月岛/远古。
Observer.CATEGORIES = {
    "resource",
    "passage",
    "station",
    "shore",
    "boat",
    "boss",
    "lunar",
    "ancient",
}

-- [喵喵喵] 通道类 prefab 前缀(森林->洞穴、洞穴->森林、虫洞、天坑)。
local PASSAGE_PREFIXES = {
    "cave_entrance",
    "cave_exit",
    "wormhole",
    "sinkhole",
}

-- [喵喵喵] 常用站点 prefab 白名单(其余靠标签判定，未列出的不会被误分类)。
local STATION_PREFABS = {
    cookpot = true,
    sciencemachine = true,
    alchemymachine = true,
    tent = true,
    siestahut = true,
    birdcage = true,
    dryingrack = true,
    meatrack = true,
    icebox = true,
    chest = true,
    treasurechest = true,
    firepit = true,
    campfire = true,
    coldfirepit = true,
    coldfire = true,
    lightning_rod = true,
    researchlab = true,
    researchlab2 = true,
    researchlab3 = true,
    researchlab4 = true,
}

-- [喵喵喵] 额外威胁 prefab(标签没覆盖时的兜底)。
local THREAT_PREFABS = {
    hound = true,
    firehound = true,
    icehound = true,
    spider_warrior = true,
    spider_hider = true,
    spider_spitter = true,
    spider_healer = true,
    tentacle = true,
    krampus = true,
    beardedklaus = true,
    clockwork_knight = true,
    clockwork_rook = true,
    clockwork_bishop = true,
    -- [喵喵喵]: tallbird 原版仅有 animal/tallbird 标签，但会主动索敌玩家，不能依赖 hostile 标签。 (2026-11-12)
    tallbird = true,
    -- [喵喵喵]: 杀人蜂与近身放蜂的蜂巢均无 hostile 标签，必须在进入索敌区前识别。 (2026-11-12)
    killerbee = true,
    wasphive = true,
    -- [喵喵喵]: 守卫和它保护的猪火炬均无 hostile；火炬会在守卫未靠近玩家时触发索敌。 (2026-11-12)
    pigguard = true,
    pigtorch = true,
    shadow_knight = true,
    shadow_bishop = true,
    shadow_rook = true,
}

--------------------------------------------------------------------------
-- [喵喵喵] 基础小工具
--------------------------------------------------------------------------

local function try(fn, ...)
    -- [喵喵喵] 保留前三个返回值：GetWorldPosition 返回 x,y,z，少一个 y 会让 get_pos 判空。
    local ok, a, b, c = pcall(fn, ...)
    if ok then
        return a, b, c
    end
    return nil
end

local function as_number(v)
    return type(v) == "number" and v or nil
end

local function clamp01(v)
    if type(v) ~= "number" then
        return nil
    end
    if v ~= v then
        return nil
    end
    if v < 0 then
        return 0
    elseif v > 1 then
        return 1
    end
    return v
end

local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

local function get_pos(inst)
    if inst == nil or inst.Transform == nil then
        return nil
    end
    local x, y, z = try(function()
        return inst.Transform:GetWorldPosition()
    end)
    if type(x) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return x, as_number(y) or 0, z
end

local function has_any_tag(inst, tags)
    if inst == nil or inst.HasTag == nil then
        return false
    end
    for i = 1, #tags do
        if inst:HasTag(tags[i]) then
            return true
        end
    end
    return false
end

local function prefab_has_prefix(prefab, prefixes)
    if type(prefab) ~= "string" then
        return false
    end
    for i = 1, #prefixes do
        if prefab:sub(1, #prefixes[i]) == prefixes[i] then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------
-- [喵喵喵] 世界状态(TheWorld.state == components.worldstate.data)
--------------------------------------------------------------------------

local function get_state()
    if TheWorld == nil then
        return nil
    end
    return TheWorld.state or nil
end

local function get_session()
    if TheNet == nil then
        return nil
    end
    if TheNet.GetSessionIdentifier ~= nil then
        local id = try(function()
            return TheNet:GetSessionIdentifier()
        end)
        if type(id) == "string" and id ~= "" then
            return id
        end
    end
    if TheNet.GetServerSessionId ~= nil then
        local id = try(function()
            return TheNet:GetServerSessionId()
        end)
        if (type(id) == "string" and id ~= "") or type(id) == "number" then
            return tostring(id)
        end
    end
    return nil
end

local function get_shard_native()
    if TheShard == nil or TheShard.GetShardId == nil then
        return nil
    end
    local id = try(function()
        return TheShard:GetShardId()
    end)
    if id == nil or id == "" then
        return nil
    end
    return id
end

-- [喵喵喵] 稳定分片标识：优先用世界标签(surface/cave)，退化为原生分片号。
local function get_shard_kind()
    if TheWorld == nil or TheWorld.HasTag == nil then
        return nil
    end
    if TheWorld:HasTag("cave") then
        return "cave"
    end
    if TheWorld:HasTag("forest") then
        return "surface"
    end
    return nil
end

local function get_shard_key(kind, native)
    if kind ~= nil then
        return kind
    end
    if native ~= nil then
        return "shard_" .. tostring(native)
    end
    return nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 玩家基础数据
--------------------------------------------------------------------------

local function get_classified(player)
    if player == nil then
        return nil
    end
    return player.player_classified or nil
end

local function get_userid(player)
    if player ~= nil and type(player.userid) == "string" and player.userid ~= "" then
        return player.userid
    end
    if TheNet ~= nil and TheNet.GetUserID ~= nil then
        local id = try(function()
            return TheNet:GetUserID()
        end)
        if type(id) == "string" and id ~= "" then
            return id
        end
    end
    return nil
end

-- [喵喵喵] 幽灵态：优先玩家标签(会同步到客户端)，退化到 classified.isghostmode。
local function get_ghost(player, classified)
    if player == nil then
        return nil
    end
    local tagged = try(function()
        return player:HasTag("playerghost")
    end)
    if tagged == true then
        return true
    end
    if classified ~= nil and classified.isghostmode ~= nil then
        local mode = try(function()
            return classified.isghostmode:value()
        end)
        if mode ~= nil then
            return mode and true or false
        end
    end
    if tagged == false then
        return false
    end
    return nil
end

local function get_percent(inst, component_name)
    if inst == nil or inst.replica == nil then
        return nil
    end
    local replica = inst.replica[component_name]
    if replica == nil or replica.GetPercent == nil then
        return nil
    end
    return clamp01(try(function()
        return replica:GetPercent()
    end))
end

local function get_temperature(player, classified)
    if classified ~= nil then
        local temp = as_number(classified.currenttemperature)
        if temp ~= nil then
            return temp
        end
    end
    if player ~= nil and player.components ~= nil
        and player.components.temperature ~= nil
        and player.components.temperature.GetCurrent ~= nil then
        return as_number(try(function()
            return player.components.temperature:GetCurrent()
        end))
    end
    return nil
end

local function get_moisture(classified)
    if classified == nil then
        return nil, nil
    end
    local raw = nil
    if classified.moisture ~= nil then
        raw = as_number(try(function()
            return classified.moisture:value()
        end))
    end
    local max = nil
    if classified.maxmoisture ~= nil then
        max = as_number(try(function()
            return classified.maxmoisture:value()
        end))
    end
    if raw == nil then
        return nil, nil
    end
    if max ~= nil and max > 0 then
        return clamp01(raw / max), raw
    end
    return nil, raw
end

-- [喵喵喵] 光照可用性：以 TheSim:GetLightAtPoint(x,y,z) 为主，
-- 取不到时退化到玩家的 IsInLight()(两者都是客户端可见信息)。
local function get_light(player, x, y, z)
    local light = {
        available = false,
        in_light = nil,
        level = nil,
        threshold = Observer.LIGHT_THRESHOLD,
        dark = nil,
        ambient = nil,
    }

    -- [喵喵喵]: 环境光不含手持火把；按原版 shadeeffects.lua 将 0..255 RGB 归一化，供收灯判断使用。 (2026-11-12)
    local r, g, b = try(function() return TheSim:GetAmbientColour() end)
    if as_number(r) ~= nil and as_number(g) ~= nil and as_number(b) ~= nil then
        light.ambient = clamp01((r + g + b) / (3 * 255))
    end

    if x == nil or z == nil then
        return light
    end

    local level = as_number(try(function()
        return TheSim:GetLightAtPoint(x, y or 0, z)
    end))
    if level ~= nil then
        light.level = level
        light.available = true
        light.in_light = level >= Observer.LIGHT_THRESHOLD
        light.dark = level < Observer.LIGHT_THRESHOLD
        return light
    end

    if player ~= nil and player.IsInLight ~= nil then
        local in_light = try(function()
            return player:IsInLight()
        end)
        if in_light ~= nil then
            light.available = true
            light.in_light = in_light and true or false
            light.dark = not light.in_light
        end
    end
    return light
end

local function get_platform(player)
    if player == nil or player.GetCurrentPlatform == nil then
        return nil
    end
    local platform = try(function()
        return player:GetCurrentPlatform()
    end)
    if not is_valid(platform) then
        return nil
    end
    return {
        entity = platform,
        guid = platform.GUID,
        prefab = platform.prefab,
    }
end

--------------------------------------------------------------------------
-- [喵喵喵] 背包 / 装备 / 打开中的容器
--------------------------------------------------------------------------

-- [喵喵喵] 堆叠数量：客户端用 stackable 副本的 StackSize()，取不到按 1 计。
local function stack_count(item)
    if item == nil or item.replica == nil then
        return nil
    end
    local stackable = item.replica.stackable
    if stackable ~= nil and stackable.StackSize ~= nil then
        local n = as_number(try(function()
            return stackable:StackSize()
        end))
        if n ~= nil then
            return n
        end
    end
    return 1
end

local function make_record(item, slot, container, kind)
    if not is_valid(item) then
        return nil
    end
    return {
        item = item,
        entity = item,
        guid = item.GUID,
        prefab = item.prefab,
        count = stack_count(item),
        slot = slot,
        container = container,
        kind = kind,
    }
end

local function iter_items(items, fn)
    if type(items) ~= "table" then
        return
    end
    for slot, item in pairs(items) do
        if item ~= nil and type(item) ~= "boolean" then
            fn(item, slot)
        end
    end
end

-- [喵喵喵] 背包：GetOverflowContainer() 返回的是 container 副本(而非实体)。
local function get_backpack(player)
    local inventory = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil or inventory.GetOverflowContainer == nil then
        return nil, nil
    end
    local container = try(function()
        return inventory:GetOverflowContainer()
    end)
    if container == nil then
        return nil, nil
    end
    local inst = container.inst
    if not is_valid(inst) then
        return nil, nil
    end
    return inst, container
end

local function build_inventory(player, settled)
    local inventory = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    local result = {
        records = {},
        count_map = {},
        by_prefab = {},
        total = 0,
        backpack = nil,
        settled = settled,
    }

    -- [喵喵喵] 快速查询，避免上层每次自己遍历 records。
    result.count = function(prefab)
        if type(prefab) == "string" and result.count_map[prefab] ~= nil then
            return result.count_map[prefab]
        end
        return 0
    end

    if inventory == nil then
        return result, nil
    end

    local seen = {}

    -- [喵喵喵] 同一物品实体只记录一次，避免主栏/装备/手持重复计数。
    local function push(item, slot, container, kind)
        if item == nil or seen[item] then
            return
        end
        local record = make_record(item, slot, container, kind)
        if record == nil then
            return
        end
        seen[item] = true
        result.records[#result.records + 1] = record
        local prefab = record.prefab
        if type(prefab) == "string" then
            local count = record.count or 1
            result.count_map[prefab] = (result.count_map[prefab] or 0) + count
            result.total = result.total + count
            local list = result.by_prefab[prefab]
            if list == nil then
                list = {}
                result.by_prefab[prefab] = list
            end
            list[#list + 1] = record
        end
    end

    -- 1) 主背包栏容器(槽位来自原生 itemslots 索引)
    if inventory.GetItems ~= nil then
        local items = try(function()
            return inventory:GetItems()
        end)
        iter_items(items, function(item, slot)
            push(item, slot, nil, "inventory")
        end)
    end

    -- 2) 装备槽(背包也在这里，但背包本体只记一次)
    if inventory.GetEquips ~= nil then
        local equips = try(function()
            return inventory:GetEquips()
        end)
        iter_items(equips, function(item, slot)
            push(item, slot, nil, "equipment")
        end)
    end

    -- 3) 背包内物品：背包只统计一次，来源容器写背包实体
    local backpack_entity, backpack_container = get_backpack(player)
    if backpack_container ~= nil and backpack_container.GetItems ~= nil then
        result.backpack = backpack_entity
        local items = try(function()
            return backpack_container:GetItems()
        end)
        iter_items(items, function(item, slot)
            push(item, slot, backpack_entity, "backpack")
        end)
    end

    -- 4) 手持/激活物品：主栏 GetItems() 会把它排除，这里补回且不会重复
    local active = nil
    if inventory.GetActiveItem ~= nil then
        local candidate = try(function()
            return inventory:GetActiveItem()
        end)
        if is_valid(candidate) then
            active = candidate
            push(active, nil, nil, "active")
        end
    end

    return result, active
end

local function build_equipment(player)
    local equipment = {}
    local inventory = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil or inventory.GetEquips == nil then
        return equipment
    end
    local equips = try(function()
        return inventory:GetEquips()
    end)
    iter_items(equips, function(item, slot)
        local record = make_record(item, slot, nil, "equipment")
        if record ~= nil then
            equipment[slot] = record
        end
    end)
    return equipment
end

-- [喵喵喵] 打开中的容器：世界箱子只列内容，不计入"随身携带"统计。
local function build_open_containers(player, backpack_entity)
    local list = {}
    local inventory = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil or inventory.GetOpenContainers == nil then
        return list
    end
    local containers = try(function()
        return inventory:GetOpenContainers()
    end)
    if type(containers) ~= "table" then
        return list
    end
    for container_entity, flag in pairs(containers) do
        if flag and is_valid(container_entity) then
            local entry = {
                entity = container_entity,
                guid = container_entity.GUID,
                prefab = container_entity.prefab,
                is_backpack = (container_entity == backpack_entity) and true or false,
                items = {},
                count = 0,
            }
            local container_replica = container_entity.replica ~= nil
                and container_entity.replica.container or nil
            if container_replica ~= nil and container_replica.GetItems ~= nil then
                local items = try(function()
                    return container_replica:GetItems()
                end)
                iter_items(items, function(item, slot)
                    local record = make_record(item, slot, container_entity, "container")
                    if record ~= nil then
                        entry.items[#entry.items + 1] = record
                        entry.count = entry.count + (record.count or 1)
                    end
                end)
            end
            list[#list + 1] = entry
        end
    end
    return list
end

--------------------------------------------------------------------------
-- [喵喵喵] 附近实体 / 威胁 / 地标分类
--------------------------------------------------------------------------

local EXCLUDE_TAGS = { "INLIMBO", "FX", "DECOR", "NOCLICK" }

local RESOURCE_TAGS = { "tree", "bush", "rock", "mineable", "pickable", "plant", "harvestable" }
-- [喵喵喵]: 普通猪变疯只加 werepig，未添加 hostile；月猪虽复用 pigman 显示名，原版保留 hostile。 (2026-11-13)
local THREAT_TAGS = { "hostile", "epic", "shadowthrall", "werepig" }

-- [喵喵喵] 分类只依赖客户端可见的 prefab 名与标签，不猜测服务端组件。
local function classify(inst, categories)
    local prefab = inst.prefab

    if prefab_has_prefix(prefab, PASSAGE_PREFIXES) then
        categories.passage = true
    end
    if STATION_PREFABS[prefab] == true then
        categories.station = true
    end
    if has_any_tag(inst, RESOURCE_TAGS) then
        categories.resource = true
    end
    if inst:HasTag("boat") then
        categories.boat = true
    end
    if inst:HasTag("epic") then
        categories.boss = true
    end
    if inst:HasTag("lunar") or inst:HasTag("moonbase") then
        categories.lunar = true
    end
    if inst:HasTag("ancient") or inst:HasTag("ruins") then
        categories.ancient = true
    end

    local any = false
    for _ in pairs(categories) do
        any = true
        break
    end
    return any
end

local function is_threat(inst)
    if inst == nil then
        return false
    end
    if THREAT_PREFABS[inst.prefab] == true then
        return true
    end
    return has_any_tag(inst, THREAT_TAGS)
end

local function screen_view(x, z)
    if TheSim == nil or TheSim.GetScreenSize == nil or TheSim.ProjectScreenPos == nil then return nil end
    local w, h = TheSim:GetScreenSize()
    if as_number(w) == nil or as_number(h) == nil or w <= 0 or h <= 0 then return nil end
    local radius = 0
    for _, point in ipairs({ { 0, 0 }, { w, 0 }, { 0, h }, { w, h } }) do
        local px, _, pz = TheSim:ProjectScreenPos(point[1], point[2])
        if as_number(px) == nil or as_number(pz) == nil then return nil end
        local dx, dz = px - x, pz - z
        radius = math.max(radius, math.sqrt(dx * dx + dz * dz))
    end
    -- [喵喵喵]: 投影覆盖地面，再纳入一个相机距离容纳边缘高大实体；实际观测仍受引擎视锥和原版视力约束。 (2026-11-12)
    local distance = TheCamera ~= nil and TheCamera.GetDistance ~= nil and TheCamera:GetDistance() or 0
    return { width = w, height = h, radius = radius + (as_number(distance) or 0) }
end

local function point_visible(player, view, x, y, z)
    if view == nil or type(CanEntitySeePoint) ~= "function" or TheSim.GetScreenPos == nil then return false end
    local sx, sy = TheSim:GetScreenPos(x, y, z)
    return as_number(sx) ~= nil and as_number(sy) ~= nil
        and sx >= 0 and sx <= view.width and sy >= 0 and sy <= view.height
        and CanEntitySeePoint(player, x, y, z) == true
end

-- [喵喵喵]: 地形知识只能来自画面内且原版视力允许看见的地面，不能读取整张已加载地图。 (2026-11-13)
function Observer.TerrainAtPoint(player, snapshot, x, z)
    local map = TheWorld ~= nil and TheWorld.Map or nil
    if map == nil or map.GetTileAtPoint == nil or TheSim == nil
        or not point_visible(player, snapshot.view, x, 0, z) then
        return nil
    end
    if map.IsPassableAtPoint == nil or not map:IsPassableAtPoint(x, 0, z)
        or (map.IsOceanAtPoint ~= nil and map:IsOceanAtPoint(x, 0, z)) then
        return nil
    end
    return as_number(map:GetTileAtPoint(x, 0, z))
end

local function collect_terrain(player, snapshot)
    local points = {}
    local view = snapshot.view
    if view == nil then return points end
    for row = 0, 4 do
        for col = 0, 4 do
            local x, _, z = TheSim:ProjectScreenPos(view.width * col / 4, view.height * row / 4)
            if as_number(x) ~= nil and as_number(z) ~= nil then
                local tile = Observer.TerrainAtPoint(player, snapshot, x, z)
                if tile ~= nil then points[#points + 1] = { x = x, z = z, tile = tile } end
            end
        end
    end
    return points
end

local function collect_nearby(player, x, y, z, view)
    local nearby, threats, landmarks = {}, {}, {}
    if view == nil or type(CanEntitySeeTarget) ~= "function" then return nearby, threats, landmarks end
    local ents = TheSim:FindEntities(x, y, z, view.radius, nil, EXCLUDE_TAGS) or {}
    for i = 1, #ents do
        local ent = ents[i]
        if ent ~= player and is_valid(ent) and ent.entity ~= nil and ent.entity.FrustumCheck ~= nil
            and ent.entity:FrustumCheck() and ent.entity.IsVisible ~= nil and ent.entity:IsVisible()
            and CanEntitySeeTarget(player, ent) then
            local ex, ey, ez = get_pos(ent)
            if ex ~= nil and ez ~= nil then
                local dx, dz = ex - x, ez - z
                local record = {
                    entity = ent, guid = ent.GUID, prefab = ent.prefab,
                    x = ex, y = ey, z = ez, distance = math.sqrt(dx * dx + dz * dz),
                    threat = is_threat(ent), pickable = ent:HasTag("pickable"),
                }
                nearby[#nearby + 1] = record
                if record.threat then threats[#threats + 1] = record end
                local categories = {}
                if classify(ent, categories) then
                    for category in pairs(categories) do
                        landmarks[category] = landmarks[category] or {}
                        landmarks[category][#landmarks[category] + 1] = record
                    end
                end
            end
        end
    end
    table.sort(nearby, function(a, b) return a.distance < b.distance end)
    table.sort(threats, function(a, b) return a.distance < b.distance end)
    return nearby, threats, landmarks
end

-- [喵喵喵] 海岸：绕玩家八方向探测，命中海洋点即记为海岸点(纯坐标)。
local function collect_shore(player, view, x, z)
    local points = nil
    if TheWorld == nil or TheWorld.Map == nil or TheWorld.Map.IsOceanAtPoint == nil then
        return points
    end
    local map = TheWorld.Map
    for i = 0, Observer.SHORE_PROBE_COUNT - 1 do
        local angle = (i / Observer.SHORE_PROBE_COUNT) * math.pi * 2
        local px = x + math.cos(angle) * Observer.SHORE_PROBE_RADIUS
        local pz = z + math.sin(angle) * Observer.SHORE_PROBE_RADIUS
        local ocean = try(function()
            return map:IsOceanAtPoint(px, 0, pz)
        end)
        if ocean and point_visible(player, view, px, 0, pz) then
            points = points or {}
            points[#points + 1] = { x = px, z = pz }
        end
    end
    return points
end

--------------------------------------------------------------------------
-- [喵喵喵] 有界持久记忆(只有坐标，无实体句柄)
--------------------------------------------------------------------------

local function get_shard_memory(memory, shard_key, shard_kind, shard_native)
    if type(memory) ~= "table" or shard_key == nil then
        return nil
    end

    memory.v = Observer.SCHEMA_VERSION
    memory.tick = as_number(memory.tick) or 0
    if type(memory.shards) ~= "table" then
        memory.shards = {}
    end

    local shard = memory.shards[shard_key]
    if shard == nil then
        -- [喵喵喵] 分片数有上限，超限时淘汰最久未更新的分片。
        local total, oldest_key, oldest_touched = 0, nil, nil
        for k, v in pairs(memory.shards) do
            total = total + 1
            local touched = as_number(v.touched) or 0
            if oldest_touched == nil or touched < oldest_touched then
                oldest_key, oldest_touched = k, touched
            end
        end
        if total >= Observer.MEMORY_MAX_SHARDS and oldest_key ~= nil then
            memory.shards[oldest_key] = nil
        end

        shard = {
            kind = shard_kind,
            native_id = shard_native,
            cats = {},
            seq = 0,
            touched = 0,
        }
        memory.shards[shard_key] = shard
    end

    shard.kind = shard.kind or shard_kind
    shard.native_id = shard.native_id or shard_native
    if type(shard.cats) ~= "table" then
        shard.cats = {}
    end
    shard.seq = as_number(shard.seq) or 0

    return shard
end

local function memory_cell(value)
    return math.floor(value / Observer.MEMORY_GRID)
end

-- [喵喵喵] 写一条地标记忆：同网格去重 + 类别上限裁剪(淘汰最旧)。
local function remember(shard, category, prefab, x, z, cycle, pickable)
    if shard == nil or type(prefab) ~= "string" or x == nil or z == nil then
        return nil, false
    end
    local list = shard.cats[category]
    if list == nil then
        list = {}
        shard.cats[category] = list
    end

    local gx, gz = memory_cell(x), memory_cell(z)
    shard.seq = shard.seq + 1
    local seq = shard.seq

    for i = 1, #list do
        local entry = list[i]
        if entry ~= nil and entry.prefab == prefab
            and memory_cell(entry.x or 0) == gx and memory_cell(entry.z or 0) == gz then
            local changed = entry.pickable ~= pickable
            entry.prefab = prefab
            entry.x = x
            entry.z = z
            entry.cycle = cycle or entry.cycle
            entry.seq = seq
            entry.pickable = pickable
            return entry, changed
        end
    end

    if #list >= Observer.MEMORY_ENTRIES_PER_CATEGORY then
        local oldest_index, oldest_seq = nil, nil
        for i = 1, #list do
            local entry_seq = as_number(list[i].seq) or 0
            if oldest_seq == nil or entry_seq < oldest_seq then
                oldest_index, oldest_seq = i, entry_seq
            end
        end
        if oldest_index ~= nil then
            table.remove(list, oldest_index)
        end
    end

    local entry = {
        prefab = prefab,
        x = x,
        z = z,
        cycle = cycle,
        seq = seq,
        pickable = pickable,
    }
    list[#list + 1] = entry
    return entry, true
end

local function update_memory(memory, shard, snapshot, landmarks, shore_points)
    if type(memory) ~= "table" or shard == nil then
        return nil
    end

    memory.tick = (as_number(memory.tick) or 0) + 1
    shard.touched = memory.tick
    shard.last_cycle = snapshot.cycles
    shard.last_time = snapshot.time

    local added = 0

    if type(landmarks) == "table" then
        for category, list in pairs(landmarks) do
            for i = 1, #list do
                local record = list[i]
                local _, is_new = remember(shard, category, record.prefab, record.x, record.z,
                    snapshot.cycles, record.pickable)
                if is_new then
                    added = added + 1
                end
            end
        end
    end

    if type(shore_points) == "table" then
        for i = 1, #shore_points do
            local point = shore_points[i]
            local _, is_new = remember(shard, "shore", "shore", point.x, point.z, snapshot.cycles)
            if is_new then
                added = added + 1
            end
        end
    end

    return added
end

--------------------------------------------------------------------------
-- [喵喵喵] 主观测入口
--------------------------------------------------------------------------

-- [喵喵喵] 副本是否已初始化：classified 的初始脏状态回调建立 _old*percent 之后
-- 才认为数值可信，避免刚复活/刚进世界时把旧值或空值当成结论。
local function is_settled(player, portions)
    local classified = get_classified(player)
    if classified == nil then
        return false
    end
    if classified._oldhealthpercent == nil then
        return false
    end
    return portions.health ~= nil and portions.hunger ~= nil
end

function Observer.Observe(player, memory)
    local snapshot = {
        ready = false,
        ready_reason = nil,
        settled = false,
        replicas = {
            inventory = false,
            health = false,
            hunger = false,
            sanity = false,
            container = false,
            classified = false,
        },
    }

    if player == nil then
        snapshot.ready_reason = "no_player"
        return snapshot
    end
    if not is_valid(player) then
        snapshot.ready_reason = "player_invalid"
        return snapshot
    end

    local x, y, z = get_pos(player)
    if x == nil then
        snapshot.ready_reason = "no_position"
        return snapshot
    end

    -- [喵喵喵] 身份与世界上下文(取不到就留 nil，不填假值)。
    snapshot.userid = get_userid(player)
    snapshot.session = get_session()
    snapshot.prefab = player.prefab
    snapshot.x, snapshot.y, snapshot.z = x, y, z

    local shard_kind = get_shard_kind()
    local shard_native = get_shard_native()
    snapshot.shard_kind = shard_kind
    snapshot.shard_native = shard_native
    snapshot.shard = get_shard_key(shard_kind, shard_native)

    -- [喵喵喵] 副本可用性：缺哪个就把依赖字段留成 nil。
    local replicas = snapshot.replicas
    local inventory_replica = player.replica ~= nil and player.replica.inventory or nil
    replicas.inventory = inventory_replica ~= nil
    replicas.health = player.replica ~= nil and player.replica.health ~= nil
    replicas.hunger = player.replica ~= nil and player.replica.hunger ~= nil
    replicas.sanity = player.replica ~= nil and player.replica.sanity ~= nil
    replicas.container = player.replica ~= nil and player.replica.container ~= nil

    local classified = get_classified(player)
    replicas.classified = classified ~= nil

    -- [喵喵喵] 生命/饥饿/理智：0..1，取不到就是 nil。
    local health = get_percent(player, "health")
    local hunger = get_percent(player, "hunger")
    local sanity = get_percent(player, "sanity")
    snapshot.health = health
    snapshot.hunger = hunger
    snapshot.sanity = sanity
    snapshot.settled = is_settled(player, { health = health, hunger = hunger })

    snapshot.ghost = get_ghost(player, classified)
    snapshot.temperature = get_temperature(player, classified)
    snapshot.moisture, snapshot.moisture_raw = get_moisture(classified)
    snapshot.light = get_light(player, x, y, z)
    snapshot.platform = get_platform(player)

    -- [喵喵喵] 世界状态：TheWorld.state 是 worldstate 组件的 data 副本。
    local state = get_state()
    if state ~= nil then
        snapshot.cycles = as_number(state.cycles)
        snapshot.time = as_number(state.time)
        snapshot.time_in_phase = as_number(state.timeinphase)
        snapshot.season = type(state.season) == "string" and state.season or nil
        snapshot.season_progress = clamp01(state.seasonprogress)
        snapshot.precipitation_rate = as_number(state.precipitationrate)
        snapshot.phase = type(state.phase) == "string" and state.phase or nil
        snapshot.moonphase = type(state.moonphase) == "string" and state.moonphase or nil
        snapshot.nightmare_phase = type(state.nightmarephase) == "string" and state.nightmarephase or nil
        if snapshot.cycles ~= nil then
            snapshot.day = snapshot.cycles + 1
        end
    end
    local network = TheWorld ~= nil and TheWorld.net or nil
    local clock = network ~= nil and network.components ~= nil and network.components.clock or nil
    if clock ~= nil then
        snapshot.time_until_night = as_number(try(function() return clock:GetTimeUntilPhase("night") end))
        snapshot.time_until_day = as_number(try(function() return clock:GetTimeUntilPhase("day") end))
    end

    -- [喵喵喵] 背包/装备/手持/打开的容器。
    local inventory, active = build_inventory(player, snapshot.settled)
    snapshot.inventory = inventory
    snapshot.active_item = active
    snapshot.equipment = build_equipment(player)
    snapshot.open_containers = build_open_containers(player, inventory.backpack)

    -- [喵喵喵] 附近实体、威胁、地标分类。
    snapshot.view = screen_view(x, z)
    snapshot.terrain = collect_terrain(player, snapshot)
    local nearby, threats, landmarks = collect_nearby(player, x, y, z, snapshot.view)
    snapshot.nearby = nearby
    snapshot.threats = threats
    snapshot.landmarks = landmarks

    local shore_points = collect_shore(player, snapshot.view, x, z)
    snapshot.shore_points = shore_points

    -- [喵喵喵] 有界记忆写入(每分片每类别上限 + 分片上限)。
    local shard_memory = get_shard_memory(memory, snapshot.shard, shard_kind, shard_native)
    if shard_memory ~= nil then
        snapshot.memory_added = update_memory(memory, shard_memory, snapshot, landmarks, shore_points)
        snapshot.shard_memory = shard_memory
    end

    -- [喵喵喵] 就绪判定：必须有玩家实体、坐标、prefab、世界状态；
    -- ghost 允许为 nil(未知)，但绝不能把未知当 False 用。
    local missing = nil
    if snapshot.prefab == nil then
        missing = "no_prefab"
    elseif state == nil then
        missing = "no_world_state"
    elseif snapshot.cycles == nil then
        missing = "no_cycles"
    elseif snapshot.view == nil or type(CanEntitySeeTarget) ~= "function" then
        missing = "view_unavailable"
    end

    if missing == nil then
        snapshot.ready = true
    else
        snapshot.ready_reason = missing
    end

    return snapshot
end

--------------------------------------------------------------------------
-- [喵喵喵] 供调试/策略复用的小工具
--------------------------------------------------------------------------

-- [喵喵喵] 清空记忆(保留模式版本，方便重开一局时复位)。
function Observer.ClearMemory(memory)
    if type(memory) ~= "table" then
        return false
    end
    memory.v = Observer.SCHEMA_VERSION
    memory.tick = 0
    memory.shards = {}
    return true
end

-- [喵喵喵] 读取某分片记忆(只读；没有则返回 nil)。
function Observer.GetShardMemory(memory, shard_key)
    if type(memory) ~= "table" or type(memory.shards) ~= "table" then
        return nil
    end
    return memory.shards[shard_key]
end

-- [喵喵喵] 记忆里某类别的地标数量(用于日志与容量自检)。
function Observer.CountMemorized(memory, shard_key, category)
    local shard = Observer.GetShardMemory(memory, shard_key)
    if shard == nil or type(shard.cats) ~= "table" then
        return 0
    end
    if category ~= nil then
        local list = shard.cats[category]
        return type(list) == "table" and #list or 0
    end
    local total = 0
    for _, list in pairs(shard.cats) do
        if type(list) == "table" then
            total = total + #list
        end
    end
    return total
end

-- [喵喵喵] 单行摘要，方便上层打日志，不做任何副作用。
function Observer.Describe(snapshot)
    if type(snapshot) ~= "table" then
        return "snapshot=nil"
    end
    return string.format(
        "ready=%s day=%s %s/%s pos=(%.1f,%.1f) hp=%s light=%s inv=%d threats=%d",
        tostring(snapshot.ready),
        tostring(snapshot.day),
        tostring(snapshot.season),
        tostring(snapshot.phase),
        as_number(snapshot.x) or 0,
        as_number(snapshot.z) or 0,
        snapshot.health ~= nil and string.format("%.2f", snapshot.health) or "nil",
        snapshot.light ~= nil and tostring(snapshot.light.in_light) or "nil",
        type(snapshot.inventory) == "table" and #snapshot.inventory.records or 0,
        type(snapshot.threats) == "table" and #snapshot.threats or 0
    )
end

return Observer
