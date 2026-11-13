-- WilsonExpedition 物资规划
-- [喵喵喵]: 仅返回命令；由唯一执行器执行并通过 Report 回执。
-- Plan(player, snapshot, state, request) -> command|nil, reason
-- Report(state, command, status, reason) -> ok, detail
-- request = { item, count, id?, place? }；库存以真实持有量、结构以可见实体确认。
-- 采集、工具、科技、陷阱、剃毛及烹饪共用有界采购状态；state.supplies 不可持久化。
-- 配方、科技与动作走原生校验；未知保持未知，效果不以消耗或实体消失代替。

local Actions = require('wilsonexpedition/actions')
local Navigation = require('wilsonexpedition/navigation')
local Exploration = require('wilsonexpedition/exploration')

local Supplies = {}

Supplies.SCHEMA_VERSION = 1
Supplies.OWNER = "supplies"

-- [喵喵喵]: 交互距离与接近半径。原生 PICK 的 rangecheck 是“目标物理半径 + 4”、
-- PICKUP 也有额外到达距离，但这里一律先用保守值：只有真的站到 2.5 以内才下发点击，
-- 否则先发一条 Navigation 命令，避免把“走不到”当成“拿不到”。
Supplies.ACTION_RANGE = 2.5
Supplies.APPROACH_RANGE = type(Navigation.GOAL_RANGE) == "number" and Navigation.GOAL_RANGE or 1.2
Supplies.GOAL_PRIORITY = type(Actions.DEFAULT_PRIORITY) == "number" and Actions.DEFAULT_PRIORITY or 0
Supplies.WORLD_LIMIT = type(Actions.WORLD_LIMIT) == "number" and Actions.WORLD_LIMIT or 20000

-- [喵喵喵]: 安全约束：目标点离可见威胁太近就连“去”都不发；黑暗中只做身边的事。
Supplies.THREAT_RADIUS = 7
Supplies.THREAT_PAD = 2.5
Supplies.LIGHT_ITEMS = { torch = true, campfire = true, firepit = true, coldfire = true, coldfirepit = true, lantern = true }

-- [喵喵喵]: 全部是有限预算：请求时长、阶段失败次数、单命令轮询次数、到达地标后的观察期。
Supplies.PLAN_TIMEOUT = 180
Supplies.MAX_ATTEMPTS = 3
Supplies.MAX_FAILURES = 8
Supplies.MAX_POLLS = 1200
Supplies.MAX_COUNT = 999
Supplies.ARRIVED_GRACE = 12
Supplies.LANDMARK_MIN_DIST = 3
Supplies.REASON_MAX = 64
Supplies.BAD_MAX = 32
Supplies.STALE_MAX = 64

-- [喵喵喵]: 工具/制作小片：前驱链深度、建址采样(环形 8 方向 × 3 个半径)、
-- 以及“放置类成品”的可见证据半径(不是背包计数)。
-- [喵喵喵]: 暖石 → 炼金引擎 → 电子元件 → 石砖 → 矿石 → 镐需要 6 层；循环仍由 path 拒绝。
Supplies.MAX_DEPTH = 6
Supplies.MAX_STEPS = 14
Supplies.MAX_PENDING_TIME = 150 -- 单条命令允许 pending 的最长真实秒数(> Actions TIMEOUT_MAX=90)
Supplies.MAX_HOIST_CHAIN = 2    -- 同一目标连续“从溢出背包取出来”的次数上限

Supplies.BUILD_DIRECTIONS = 8
Supplies.BUILD_RADII = { 2.0, 3.0, 4.0 }
Supplies.BUILD_MAX_DIST = 6
Supplies.PLACED_RADIUS = 12

-- [喵喵喵]: 原型机接近距离：原生 components/builder.lua 用 TUNING.RESEARCH_MACHINE_DIST=4
-- 找带 prototyper 标签的实体，客户端科技树就是这么同步过来的；这里留一点余量取 3.5。
Supplies.STATION_RANGE = 3.5
Supplies.STATION_NAV_RANGE = 2.5
Supplies.STATION_MEMORY_MAX = 8
Supplies.STATION_TTL = 900

--------------------------------------------------------------------------
-- [喵喵喵] 小工具：只用原生全局或纯 Lua，取不到就明确返回 nil，绝不猜。
--------------------------------------------------------------------------

local function now()
    return type(GetTime) == "function" and GetTime() or os.clock()
end

local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

-- [喵喵喵]: pcall 包装：失败一律当未知返回 nil；三个返回值都带出来(坐标查询需要 x/z)。
local function try(fn)
    local ok, a, b, c = pcall(fn)
    if ok then
        return a, b, c
    end
    return nil, nil, nil
end

local function get_xz(inst)
    if inst == nil or inst.Transform == nil then
        return nil
    end
    local x, _, z = try(function()
        return inst.Transform:GetWorldPosition()
    end)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil
    end
    return x, z
end

local function dist2(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return dx * dx + dz * dz
end

local function short_reason(reason)
    local text = tostring(reason)
    if #text <= Supplies.REASON_MAX then
        return text
    end
    return string.sub(text, 1, Supplies.REASON_MAX)
end

local function get_map()
    local world = TheWorld
    if world == nil or world.Map == nil then
        return nil
    end
    return world.Map
end

-- [喵喵喵]: 只问“这个点是不是可走陆地”。查询能力缺失一律当未知，绝不当成可走。
local function terrain_land(x, z)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, "terrain_bad_coordinates"
    end
    local map = get_map()
    if map == nil or map.IsPassableAtPoint == nil then
        return nil, "terrain_unsupported"
    end
    local ok = try(function()
        return map:IsPassableAtPoint(x, 0, z, false, true)
    end)
    if ok == nil then
        return nil, "terrain_unknown"
    end
    if ok ~= true then
        return false, "terrain_not_land"
    end
    return true, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 来源表：本小片只含“地面拾取”与“可再生采集”，prefab 名全部来自原生实体实现。
--------------------------------------------------------------------------

-- [喵喵喵]: 地面掉落物：拾取动作 ACTIONS.PICKUP，目标 prefab 与物品同名。
local PICKUP_ITEMS = {
    flint = true,
    rocks = true,
    goldnugget = true,
    nitre = true,
    twigs = true,
    log = true,
    cutgrass = true,
    cutreeds = true,
    berries = true,
    berries_juicy = true,
    carrot = true,
    -- [喵喵喵]: petals：花被采后掉在地上的花瓣（prefabs/flower.lua 的同名掉落物）。
    petals = true,
    seeds = true,
    cactus_meat = true,
    green_cap = true,
    blue_cap = true,
    cave_banana = true,
    lightbulb = true,
    meat = true,
    smallmeat = true,
    silk = true,
    beefalowool = true,
    spidergland = true,
}

-- [喵喵喵]: 采集动作 ACTIONS.PICK，键是产物 prefab，值是原生 pickable 主体 prefab。
local PICK_SOURCES = {
    cutgrass = { "grass" },
    twigs = { "sapling" },
    berries = { "berrybush", "berrybush2" },
    berries_juicy = { "berrybush_juicy" },
    carrot = { "carrot_planted" },
    cutreeds = { "reeds" },
    -- [喵喵喵]: prefabs/flower.lua:172 pickable:SetUp("petals", 10) —— 摘花得花瓣。
    petals = { "flower" },
    cactus_meat = { "cactus", "oasis_cactus" },
    green_cap = { "green_mushroom" },
    blue_cap = { "blue_mushroom" },
    cave_banana = { "cave_banana_tree" },
    lightbulb = { "flower_cave", "flower_cave_double", "flower_cave_triple" },
}

-- [喵喵喵]: 工具作业来源：ACTIONS.CHOP / ACTIONS.MINE，工具必须先在手上(原生
-- GetLeftClickActions 先走 GetEquippedItemActions)，而且目标实体必须带原生
-- componentactions.lua:3112 的 <ACTION>_workable 标签(客户端可见)才发。
-- prefab 名取自 prefabs/evergreens.lua、prefabs/deciduoustrees.lua、prefabs/marsh_tree.lua、
-- prefabs/rocks.lua；rock2 产金，rock1 产硝石，rock_flintless* 只产岩石。
local CHOP_PREFABS = {
    "evergreen", "evergreen_normal", "evergreen_tall", "evergreen_short",
    "evergreen_sparse", "evergreen_sparse_normal", "evergreen_sparse_tall", "evergreen_sparse_short",
    "twiggytree", "twiggy_normal", "twiggy_tall", "twiggy_short", "twiggy_old",
    "deciduoustree", "deciduoustree_normal", "deciduoustree_tall", "deciduoustree_short",
    "marsh_tree",
}
local MINE_GOLD_PREFABS = { "rock2" }
local MINE_BASIC_PREFABS = { "rock1", "rock2" }
local MINE_PLAIN_PREFABS = { "rock_flintless", "rock_flintless_med", "rock_flintless_low" }

-- [喵喵喵]: 每个物品的“作业来源”；tool 是必须先装备在 hands 槽的原生工具 prefab。
local WORK_SOURCES = {
    log = { act = "CHOP", tool = "axe", prefabs = CHOP_PREFABS },
    rocks = { act = "MINE", tool = "pickaxe", prefabs = MINE_BASIC_PREFABS, also = MINE_PLAIN_PREFABS },
    flint = { act = "MINE", tool = "pickaxe", prefabs = MINE_BASIC_PREFABS },
    nitre = { act = "MINE", tool = "pickaxe", prefabs = { "rock1" } },
    goldnugget = { act = "MINE", tool = "pickaxe", prefabs = MINE_GOLD_PREFABS },
}

-- [喵喵喵]: 配方白名单，真实科技等级逐条按 data/databundles/scripts/recipes.lua 核对：
--   TECH.NONE   : researchlab(382), axe(393), pickaxe(395), torch(425), campfire(426),
--                 firepit(427), armorgrass(496), trap(451)
--   SCIENCE_ONE : rope(457), boards(459), cutstone(460), spear(478), armorwood(497),
--                 backpack(515)
-- 即：科学机器自己“无科技可造”，只有后面那六个必须在它旁边第一次试制；
-- 试制成功后由服务端 LearnRecipe 变成随处可做（本文件只读 KnowsRecipe，不自己记）。配方名与注册表一一对应，配料一律运行时
-- 从原生 GetValidRecipe/AllRecipes 读，绝不在这里手写配料数量；
-- 来源：data/databundles/scripts/recipes.lua（researchlab/axe/pickaxe/torch/campfire/
-- firepit/armorgrass/trap = TECH.NONE；rope/boards/cutstone/backpack/spear/armorwood = SCIENCE_ONE）。
local CRAFT_RECIPES = {
    axe = "axe",
    pickaxe = "pickaxe",
    torch = "torch",
    campfire = "campfire",
    firepit = "firepit",
    armorgrass = "armorgrass",
    trap = "trap",
    researchlab = "researchlab",
    rope = "rope",
    boards = "boards",
    cutstone = "cutstone",
    backpack = "backpack",
    spear = "spear",
    armorwood = "armorwood",
    -- [喵喵喵]: 四季基线装备（已逐条按 data/databundles/scripts/recipes.lua 核对原料与科技）：
    --   strawhat(cutgrass 12, TECH.NONE)：头部夏季隔热小帽 + 小雨伞级防水
    --     (prefabs/hats.lua:252-257 waterproofer SMALL + insulator SetSummer + INSULATION_SMALL)；
    --   grass_umbrella(twigs 4 + cutgrass 3 + petals 6, TECH.NONE)：
    --     prefabs/umbrella.lua 的 grass() 给 WATERPROOFNESS_MED + INSULATION_MED（弹簧伞）；
    --   minifan(twigs 3 + petals 1, TECH.NONE)：prefabs/minifan.lua:127-133
    --     带 endothermic heater(MINIFAN_COOLER) + INSULATION_SMALL，装备时降温；
    --   lightning_rod(goldnugget 4 + cutstone 1, SCIENCE_ONE, 放置类)：防雷击失火。
    strawhat = "strawhat",
    grass_umbrella = "grass_umbrella",
    minifan = "minifan",
    lightning_rod = "lightning_rod",
    transistor = "transistor",
    researchlab2 = "researchlab2",
    heatrock = "heatrock",
    coldfire = "coldfire",
    coldfirepit = "coldfirepit",
    lantern = "lantern",
    shovel = "shovel",
    razor = "razor",
    winterhat = "winterhat",
}

-- [喵喵喵]: 原生 prefab 用的是旧机器名（prefabs/scienceprototyper.lua 末尾“Using old
-- prefab names”：researchlab / researchlab2 / researchlab3 / researchlab4），
-- 而主线口语里的 sciencemachine/alchemymachine 不是真实 prefab。调用方用哪个名字都行，
-- 这里统一归一到真实 prefab/配方名。
local ITEM_ALIASES = {
    sciencemachine = "researchlab",
    alchemymachine = "researchlab2",
}

-- [喵喵喵]: 客户端可见的原型机 prefab（带 prototyper 标签且会向客户端同步科技树）。
local PROTOTYPER_PREFABS = {
    researchlab = true,
    researchlab2 = true,
    researchlab3 = true,
    researchlab4 = true,
}

-- [喵喵喵]: 放置类成品不进背包：完成证据只能是“客户端附近真的多了这个 prefab”。
-- researchlab（科学机器）也是放置类，它是 SCIENCE_ONE 配方能试制的前提。
local PLACED_ITEMS = {
    campfire = true,
    firepit = true,
    researchlab = true,
    -- [喵喵喵]: 防雷针也是放置类：完成证据只能是“客户端附近真的看得见 lightning_rod”。
    lightning_rod = true,
    researchlab2 = true,
    coldfire = true,
    coldfirepit = true,
}

-- [喵喵喵]: 生火烹饪：COOK 只能把“背包里的可烹饬(cookable 标签)”放到“火堆(cooker 标签)”上，
-- 产物由服务端 components/cookable.product 决定（客户端读不到），所以一律用
-- 真 prefab 名比对 + confirm 回调验证产物。
-- 证据：components/cookable.lua:7 AddTag("cookable")；prefabs/veggies.lua:559-560/664-665
-- （pristine 标签 + product = name.."_cooked"）；prefabs/campfire.lua:148 与
-- prefabs/firepit.lua:165 AddTag("cooker")；scrapbook_prefabs.lua 里的 berries_cooked /
-- berries_juicy_cooked / carrot_cooked 为真实 prefab。
-- 注意：往锅里添料是 stewer/容器搬运(kind='transfer')，与火堆 COOK 完全不是一回事，
-- 本文件绝不把两者混为一谈（cookpot 仍属于 science2 待做项）。
local COOK_SOURCES = {
    berries_cooked = { from = "berries" },
    berries_juicy_cooked = { from = "berries_juicy" },
    carrot_cooked = { from = "carrot" },
    seeds_cooked = { from = "seeds" },
    cactus_meat_cooked = { from = "cactus_meat" },
    green_cap_cooked = { from = "green_cap" },
    blue_cap_cooked = { from = "blue_cap" },
    cave_banana_cooked = { from = "cave_banana" },
    cookedmeat = { from = "meat" },
    cookedsmallmeat = { from = "smallmeat" },
}

-- [喵喵喵]: 可烹饪的火堆 prefab 白名单（必须同时带 cooker 标签）。
local FIRE_PREFABS = {
    campfire = true,
    firepit = true,
}

-- [喵喵喵]: 本小片明确不做、但上层可能已经会请求的条目：只给确定原因，不装实现。
local PENDING_ITEMS = {
    footballhat = "science2",
    cookpot = "science2",
    meatrack = "science2",
    icebox = "science2",
    charcoal = "work",
    pigskin = "work",
    stinger = "work",
}

-- [喵喵喵]: 一个物品在本小片里的全部获取途径；顺序只影响同距离时的偏好(先拾取后采集)。
local function sources_for(item)
    local list = {}
    if PICKUP_ITEMS[item] == true then
        list[#list + 1] = { prefab = item, act = "PICKUP" }
    end
    local picks = PICK_SOURCES[item]
    if type(picks) == "table" then
        for i = 1, #picks do
            list[#list + 1] = { prefab = picks[i], act = "PICK" }
        end
    end
    return list
end

local function is_supported(item)
    return PICKUP_ITEMS[item] == true
        or PICK_SOURCES[item] ~= nil
        or WORK_SOURCES[item] ~= nil
        or CRAFT_RECIPES[item] ~= nil
        or COOK_SOURCES[item] ~= nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 持有量统计：主背包栏 + 装备槽 + 溢出背包 + 手持物品。
-- 世界容器(箱子等)只有此刻被打开时才有可见副本，本文件一律不计入“随身持有”，
-- 也绝不替上层推断箱子里有什么。
--------------------------------------------------------------------------

local COUNTED_KINDS = {
    inventory = true,
    backpack = true,
    equipment = true,
    active = true,
}

-- [喵喵喵]: 背包满了就没必要再出门拿东西：原生 inventory_replica:IsFull() 客户端可读，
-- 拿不到(副本未就绪)就返回 nil 当未知，绝不因为“不知道”而假装能装。
local function inventory_full(player)
    if player == nil or player.replica == nil or player.replica.inventory == nil then
        return nil
    end
    local full = try(function()
        return player.replica.inventory:IsFull()
    end)
    if full == true then
        return true
    elseif full == false then
        return false
    end
    return nil
end

-- 返回 total, known；known=false 表示背包副本还没建立，数量属于“未知”而不是 0。
local function count_owned(snapshot, prefab)
    local inv = type(snapshot) == "table" and snapshot.inventory or nil
    if type(inv) ~= "table" then
        return 0, false
    end
    local records = inv.records
    if type(records) == "table" then
        local total = 0
        for i = 1, #records do
            local record = records[i]
            if type(record) == "table"
                and record.prefab == prefab
                and COUNTED_KINDS[record.kind] == true then
                total = total + (is_finite_number(record.count) and record.count or 1)
            end
        end
        if inv.settled == false then
            return total, false
        end
        return total, true
    end
    if type(inv.count_map) == "table" then
        local v = inv.count_map[prefab]
        return is_finite_number(v) and v or 0, true
    end
    return 0, false
end

-- [喵喵喵]: 放置类成品（营火/石火堆）不进背包，持有量永远为 0；
-- 它们的存在证据只能是“客户端附近真的看得见这个 prefab”。
local function count_placed(snapshot, prefab)
    local nearby = snapshot.nearby
    if type(nearby) ~= "table" then
        return 0, false
    end
    local total = 0
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table" and record.prefab == prefab and is_valid(record.entity)
            and not record.entity:HasTag("burnt") then
            local d = record.distance
            if is_finite_number(d) and d <= Supplies.PLACED_RADIUS then
                total = total + 1
            end
        end
    end
    return total, true
end

-- [喵喵喵]: 找一个指定种类来源的持有记录（主背包栏 / 手持优先，溢出背包不能直接点）。
local function first_owned_record(snapshot, prefab, kinds)
    local inv = type(snapshot) == "table" and snapshot.inventory or nil
    local records = type(inv) == "table" and inv.records or nil
    if type(records) ~= "table" then
        return nil
    end
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table"
            and record.prefab == prefab
            and record.entity ~= nil
            and (kinds == nil or kinds[record.kind] == true) then
            return record
        end
    end
    return nil
end

-- [喵喵喵]: 装备槽键沿用原生 EQUIPSLOTS（constants.lua:654 HANDS="hands"）。
local function equipped_record(snapshot, slot)
    local equipment = type(snapshot) == "table" and snapshot.equipment or nil
    if type(equipment) ~= "table" then
        return nil
    end
    local record = equipment[slot]
    if type(record) == "table" and type(record.prefab) == "string" then
        return record
    end
    return nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 制作层接口：只用客户端可读的原生副本与配方注册表。
--   builder:KnowsRecipe / CanLearn / IsBuildBuffered / GetTechTrees / HasIngredients
--   builder:CanBuildAtPoint(pt, recipe, rot) -> TheWorld.Map:CanDeployRecipeAtPoint(...)
-- 参考 data/databundles/scripts/components/builder_replica.lua 与
--       widgets/widgetutil.lua(CanPrototypeRecipe / DoRecipeClick)
--------------------------------------------------------------------------

local function get_builder(player)
    local rep = player ~= nil and player.replica or nil
    return rep ~= nil and rep.builder or nil
end

local function get_recipe(name)
    if type(GetValidRecipe) ~= "function" then
        return nil
    end
    local recipe = try(function()
        return GetValidRecipe(name)
    end)
    if type(recipe) ~= "table" then
        return nil
    end
    return recipe
end

local function builder_call(builder, method, ...)
    if builder == nil or builder[method] == nil then
        return nil
    end
    -- [喵喵喵]: unpack 在 LuaJIT(5.1) 里是全局；顺手兼容 table.unpack，两者都没有就当 unknown。
    local unpack_fn = table.unpack or unpack
    if type(unpack_fn) ~= "function" then
        return nil
    end
    local args = { ... }
    local ok, value = pcall(function()
        return builder[method](builder, unpack_fn(args))
    end)
    if not ok then
        return nil
    end
    return value
end

-- [喵喵喵]: 与 widgetutil.lua:16-24 同一算法：配方科技不超过当前可触及科技树。
-- 客户端 GetTechTrees() 返回 classified.techtrees（已含附近原型机的树）。
local function can_prototype(recipetree, buildertree)
    if type(recipetree) ~= "table" or type(buildertree) ~= "table" then
        return false
    end
    for k, v in pairs(recipetree) do
        local v1 = buildertree[tostring(k)]
        if v ~= nil and v1 ~= nil and v > v1 then
            return false
        end
    end
    return true
end

-- [喵喵喵]: 配料需求用原生 RoundBiasedUp 同一算法(mathutil.lua:24 floor(n+0.5))，
-- 再乘 builder:IngredientMod()（客户端可读）。
local function ingredient_need(builder, ingredient)
    local amount = type(ingredient) == "table" and ingredient.amount or nil
    if not is_finite_number(amount) then
        return nil
    end
    local mod = 1
    local value = builder_call(builder, "IngredientMod")
    if is_finite_number(value) and value > 0 then
        mod = value
    end
    return math.max(1, math.floor(amount * mod + 0.5))
end

-- [喵喵喵]: Vector3 是 Class（可调用对象），不能假设 type(Vector3)=="function"，
-- 所以只用 pcall 试调用；拿不到就老实报 unknown，不自己造坐标对象。
local function make_point(x, z)
    if Vector3 == nil then
        return nil
    end
    local ok, pt = pcall(Vector3, x, 0, z)
    if ok and pt ~= nil then
        return pt
    end
    return nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 威胁与光照约束：只用快照里“客户端真的看见”的东西。
--------------------------------------------------------------------------

-- [喵喵喵]: 与 exploration.lua 同一套判断：目标点附近有威胁且不比玩家更远就不去；
-- 附近记录自己带 threat 标记的直接跳过。
local function threat_safe(snapshot, tx, tz)
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return false, "no_player_position"
    end
    local threats = snapshot.threats
    if type(threats) ~= "table" then
        return false, "threats_unreadable"
    end
    local player_d = math.sqrt(dist2(px, pz, tx, tz))
    for i = 1, #threats do
        local record = threats[i]
        if type(record) == "table" and is_finite_number(record.x) and is_finite_number(record.z) then
            local threat_d = math.sqrt(dist2(record.x, record.z, tx, tz))
            if threat_d <= Supplies.THREAT_RADIUS and threat_d < player_d + Supplies.THREAT_PAD then
                return false, string.format("threat_near:%.1f", threat_d)
            end
        end
    end
    return true, nil
end

-- [喵喵喵]: 夜里没有光时只允许“伸手就能拿到”的目标；照明类物品本身例外。
local function is_dark(snapshot)
    local light = snapshot.light
    if type(light) ~= "table" or light.dark == nil then
        return snapshot.phase == "night" or snapshot.shard_kind == "cave"
    end
    return light.dark == true
end

--------------------------------------------------------------------------
-- [喵喵喵] 运行期状态：单活跃命令 + 每请求预算；世界或请求变了就重置。
--------------------------------------------------------------------------

local function world_key_of(snapshot)
    local session = type(snapshot.session) == "string" and snapshot.session or nil
    if session == nil and TheWorld ~= nil then
        session = "guid|" .. tostring(TheWorld.GUID)
    end
    local shard = type(snapshot.shard) == "string" and snapshot.shard or "-"
    return tostring(session) .. "|" .. shard
end

local function request_key_of(request)
    local place = "-"
    if type(request.place) == "table"
        and is_finite_number(request.place.x)
        and is_finite_number(request.place.z) then
        place = string.format("%.1f_%.1f", request.place.x, request.place.z)
    end
    if type(request.id) == "string" or type(request.id) == "number" then
        return string.format("id:%s|%s|%s|%s",
            tostring(request.id), tostring(request.item), tostring(request.count), place)
    end
    return string.format("auto:%s|%s|%s", tostring(request.item), tostring(request.count), place)
end

local function reset_request(rt, key, request)
    rt.req_key = key
    rt.req = {
        item = request.item,
        count = request.count,
        id = request.id,
        place = request.place,
    }
    rt.t0 = now()
    rt.attempts = {}
    rt.ops = {}
    rt.hoist = {}
    rt.fail_total = 0
    rt.cmd = nil
    rt.arrived = {}
    -- [喵喵喵]: 同分片空点和不可达点的冷却跨采购保留；换世界仍整体重置。 (2026-11-12)
    rt.stale = rt.stale or {}
    rt.bad = {}
    rt.gave_up = nil
end

local function ensure_runtime(state, snapshot)
    local rt = state.supplies
    if type(rt) ~= "table" then
        rt = {}
        state.supplies = rt
    end
    rt.v = Supplies.SCHEMA_VERSION
    local world = world_key_of(snapshot)
    if rt.world ~= world then
        -- [喵喵喵]: 换世界/换分片一律整体重置：旧世界的 in-flight 记录不能带过来。
        rt.world = world
        rt.stations, rt.fires = {}, {}
        rt.req_key = nil
        rt.req = nil
        rt.t0 = nil
        rt.attempts = {}
        rt.ops = {}
        rt.hoist = {}
        rt.fail_total = 0
        rt.cmd = nil
        rt.arrived = {}
        rt.stale = {}
        rt.bad = {}
        rt.gave_up = nil
        rt.last = nil
    end
    if type(rt.attempts) ~= "table" then
        rt.attempts = {}
    end
    if type(rt.ops) ~= "table" then
        rt.ops = {}
    end
    if type(rt.hoist) ~= "table" then
        rt.hoist = {}
    end
    if type(rt.stale) ~= "table" then
        rt.stale = {}
    end
    if type(rt.bad) ~= "table" then
        rt.bad = {}
    end
    return rt
end

-- [喵喵喵]: 有界淘汰：诊断表超上限时只保留较新的部分，绝不让运行期表无限长。
local function trim_table(tbl, limit)
    local n = 0
    for _ in pairs(tbl) do
        n = n + 1
    end
    if n <= limit then
        return
    end
    local entries = {}
    for key, t in pairs(tbl) do
        entries[#entries + 1] = { key = key, t = is_finite_number(t) and t or 0 }
    end
    table.sort(entries, function(a, b)
        return a.t < b.t
    end)
    local keep = math.max(1, math.floor(limit / 2))
    local kept = {}
    for i = #entries - keep + 1, #entries do
        local entry = entries[i]
        if entry ~= nil then
            kept[entry.key] = tbl[entry.key]
        end
    end
    for key in pairs(tbl) do
        tbl[key] = nil
    end
    for key, value in pairs(kept) do
        tbl[key] = value
    end
end

--------------------------------------------------------------------------
-- [喵喵喵] 命令构造：id 在轮询期间稳定，真正重试时 attempt 段一定变新。
--------------------------------------------------------------------------

local function attempt_of(rt, stage)
    return (tonumber(rt.attempts[stage]) or 0) + 1
end

-- [喵喵喵]: 同一个阶段“真做成了”也算一次新的实际动作（同一棵树每砍一下、同一处每建一次），
-- 所以 id 除了失败重试的 attempt 段，还要带成功计数 ops 段；轮询期间两者都不变。
local function ops_of(rt, stage)
    if type(rt.ops) ~= "table" then
        rt.ops = {}
    end
    return (tonumber(rt.ops[stage]) or 0) + 1
end

local function command_id(rt, stage)
    return string.format("%s|%s|a%d|o%d",
        tostring(rt.req_key), tostring(stage), attempt_of(rt, stage), ops_of(rt, stage))
end

local function make_actions_command(rt, stage, purpose, intent)
    local id = command_id(rt, stage)
    intent.id = id
    return {
        via = "actions",
        intent = intent,
        id = id,
        purpose = purpose,
        stage = stage,
        owner = Supplies.OWNER,
    }
end

-- [喵喵喵]: 本文件自己算出来的目标点；goal.id 用我们的稳定命令 id，重试换 attempt 段。
-- (Exploration.Next 给的目标不能这么改 id，另走 make_explore_command 原样转发。)
local function make_navigation_command(rt, stage, purpose, x, z, range)
    local id = command_id(rt, stage)
    local goal = {
        x = x,
        z = z,
        range = range or Supplies.APPROACH_RANGE,
        priority = Supplies.GOAL_PRIORITY,
        id = id,
    }
    return {
        via = "navigation",
        goal = goal,
        id = id,
        purpose = purpose,
        stage = stage,
        owner = Supplies.OWNER,
    }
end

--------------------------------------------------------------------------
-- [喵喵喵] 候选目标：只用本次观测里看得见的实体，且必须是安全可走陆地上的。
--------------------------------------------------------------------------

local function bad_target(rt, guid)
    if guid == nil then
        return false
    end
    return rt.bad[guid] ~= nil
end

local function mark_bad(rt, guid)
    if guid == nil then
        return
    end
    rt.bad[guid] = now()
    trim_table(rt.bad, Supplies.BAD_MAX)
end

local function mark_stale(rt, key)
    if key == nil then
        return
    end
    rt.stale[key] = now()
    trim_table(rt.stale, Supplies.STALE_MAX)
end

-- [喵喵喵]: 扫描附近实体，挑出“本物品的合法来源 + 没被拒绝过 + 不在威胁里 + 站在陆地上”，
-- 按距离从近到远返回；完全是纯客户端可见信息。
local function visible_candidates(snapshot, rt, item)
    local result = {}
    local nearby = snapshot.nearby
    if type(nearby) ~= "table" then
        return result
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return result
    end
    local sources = sources_for(item)
    if #sources == 0 then
        return result
    end
    local by_prefab = {}
    for i = 1, #sources do
        by_prefab[sources[i].prefab] = sources[i].act
    end
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and by_prefab[record.prefab] ~= nil
            and record.threat ~= true
            and not bad_target(rt, record.guid)
            and is_valid(record.entity)
            and (by_prefab[record.prefab] ~= "PICK" or record.entity:HasTag("pickable")) then
            -- [喵喵喵]: 观测层通常会带坐标；万一没带，就直接问那个客户端可见的实体自己。
            local rx, rz = record.x, record.z
            if not is_finite_number(rx) or not is_finite_number(rz) then
                rx, rz = get_xz(record.entity)
            end
            if is_finite_number(rx) and is_finite_number(rz)
                and math.abs(rx) <= Supplies.WORLD_LIMIT
                and math.abs(rz) <= Supplies.WORLD_LIMIT then
                local land = terrain_land(rx, rz)
                if land == true then
                    local safe = threat_safe(snapshot, rx, rz)
                    local protected = false
                    for _, armor in pairs(snapshot.equipment or {}) do
                        if armor.prefab == "armorwood" or armor.prefab == "footballhat" then protected = true end
                    end
                    local thorny = record.prefab == "cactus" or record.prefab == "oasis_cactus"
                    if safe == true and (not thorny or (protected and is_finite_number(snapshot.health) and snapshot.health >= 0.55)) then
                        result[#result + 1] = {
                            entity = record.entity,
                            guid = record.guid,
                            prefab = record.prefab,
                            act = by_prefab[record.prefab],
                            x = rx,
                            z = rz,
                            distance = math.sqrt(dist2(px, pz, rx, rz)),
                        }
                    end
                end
                -- [喵喵喵]: 地形未知(地图查询不可用)与不可走一律跳过：未知不当可走，
                -- 也不因为一个可疑目标就把已经找到的候选全丢掉。
            end
        end
    end
    table.sort(result, function(a, b)
        return a.distance < b.distance
    end)
    return result
end

--------------------------------------------------------------------------
-- [喵喵喵] 记得的同世界地标：来自 observer 的记忆视图 snapshot.shard_memory.cats。
-- 只把它当成“去哪儿看看”，绝不等于“那儿一定还有货”，更不等于已经拥有资源。
--------------------------------------------------------------------------

local function landmark_entries(snapshot, item)
    local out = {}
    local mem = snapshot.shard_memory
    local cats = type(mem) == "table" and mem.cats or nil
    if type(cats) ~= "table" then
        return out
    end
    local wanted = {}
    local sources = sources_for(item)
    for i = 1, #sources do
        wanted[sources[i].prefab] = true
    end
    -- [喵喵喵]: 作业来源(树/矿石)也是地标：observer 把它们归在 resource 类里。
    local work = WORK_SOURCES[item]
    if type(work) == "table" then
        if type(work.prefabs) == "table" then
            for i = 1, #work.prefabs do
                wanted[work.prefabs[i]] = true
            end
        end
        if type(work.also) == "table" then
            for i = 1, #work.also do
                wanted[work.also[i]] = true
            end
        end
    end
    local list = cats.resource
    if type(list) ~= "table" then
        return out
    end
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == "table"
            and wanted[entry.prefab] == true
            and is_finite_number(entry.x)
            and is_finite_number(entry.z) then
            out[#out + 1] = entry
        end
    end
    return out
end

-- [喵喵喵]: 地标身份用 4 单位网格，与 observer 的记忆网格一致，重试时才认得出是同一处。
local function landmark_key(entry)
    return string.format("landmark|%s|%d_%d",
        tostring(entry.prefab),
        math.floor(entry.x / 4),
        math.floor(entry.z / 4))
end

-- [喵喵喵]: Exploration 的目标原样转发(它按 goal.id 认回执)，只另给命令一个稳定 id。
local function make_explore_command(rt, stage, purpose, goal)
    return {
        via = "navigation",
        goal = goal,
        id = command_id(rt, stage),
        purpose = purpose,
        stage = stage,
        owner = Supplies.OWNER,
        explore_goal = goal,
    }
end

local function plan_landmark(snapshot, rt, item, dark)
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil, "no_player_position"
    end
    local entries = landmark_entries(snapshot, item)
    if #entries == 0 then
        return nil, "no_landmark"
    end
    if dark then
        return nil, "night"
    end
    local t = now()
    local waiting = false
    -- [喵喵喵]: 已采空植株仍会留在地标记忆；以当前可见的 pickable 状态跳过空跑，同格仍有可采实体时保留来源。 (2026-11-12)
    local pick_sources, available = {}, {}
    for _, source in ipairs(sources_for(item)) do
        if source.act == "PICK" then pick_sources[source.prefab] = true end
    end
    for _, record in ipairs(snapshot.nearby or {}) do
        if pick_sources[record.prefab] and is_valid(record.entity)
            and is_finite_number(record.x) and is_finite_number(record.z) then
            local key = landmark_key(record)
            available[key] = available[key] == true or record.entity:HasTag("pickable")
        end
    end
    for i = 1, #entries do
        local entry = entries[i]
        local key = landmark_key(entry)
        if available[key] == false then mark_stale(rt, key) end
        -- [喵喵喵]: 采空结论来自可见实体并随Observer记忆保存；重新看见长好后才恢复来源。 (2026-11-12)
        if rt.stale[key] == nil and not (pick_sources[entry.prefab] and entry.pickable == false) then
            local d = math.sqrt(dist2(px, pz, entry.x, entry.z))
            local arrived = rt.arrived[key]
            if arrived ~= nil then
                local since = t - arrived
                if since <= Supplies.ARRIVED_GRACE then
                    -- [喵喵喵]: 每个地标独立等待观测，走到另一地标不会覆盖已到达的事实。 (2026-11-12)
                    waiting = true
                else
                    -- [喵喵喵]: 真到了还是没看见资源 → 记“此地无货”，换下一个。
                    mark_stale(rt, key)
                    rt.arrived[key] = nil
                end
            elseif d >= Supplies.LANDMARK_MIN_DIST then
                local land = terrain_land(entry.x, entry.z)
                local safe = threat_safe(snapshot, entry.x, entry.z)
                if land == true and safe == true then
                    local cmd = make_navigation_command(rt, key,
                        "landmark:" .. tostring(entry.prefab),
                        entry.x, entry.z,
                        Supplies.APPROACH_RANGE + 0.8)
                    cmd.landmark_key = key
                    return cmd, nil
                end
            end
        end
    end
    if waiting then
        return nil, "landmark_waiting_observation"
    end
    return nil, "no_landmark"
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策阶梯：看得见的来源 → 记得的地标 → Exploration 前沿。
-- 每一步都只产出命令或明确原因，绝不在这里执行任何动作。
--------------------------------------------------------------------------

-- [喵喵喵]: 看得见的拾取/采集候选(地标/探索不在这里)。返回命令，或 nil+原因；
-- 原因 no_candidate 表示“本层没找到”，调用方可以继续往下试。
local count_owned_live

local function plan_visible_pickup(player, snapshot, rt, item, dark)

    local candidates = visible_candidates(snapshot, rt, item)
    if #candidates > 0 then
        local best = candidates[1]
        local use_stage = string.format("use|%s|%s", tostring(best.act), tostring(best.guid))
        local purpose = string.format("acquire:%s@%s", item, tostring(best.prefab))
        if best.distance <= Supplies.ACTION_RANGE then
            local cmd = make_actions_command(rt, use_stage, purpose, {
                kind = "action",
                action = best.act,
                target = best.entity,
                priority = Supplies.GOAL_PRIORITY,
                -- [喵喵喵]: 远端 PICK 等待产物实际进入随身物品，不以目标消失作为成功。 (2026-11-11)
                confirm = (function()
                    local baseline, known = count_owned(snapshot, item)
                    return function()
                        local current = count_owned_live(player, item)
                        return known and current ~= nil and current > baseline
                    end
                end)(),
            })
            cmd.target_guid = best.guid
            cmd.target_x, cmd.target_z = best.x, best.z
            return cmd, nil
        end
        if dark then
            return nil, "night_light_reserve:" .. purpose
        end
        local cmd = make_navigation_command(rt, "approach|" .. use_stage,
            string.format("approach:%s@%s", item, tostring(best.prefab)),
            best.x, best.z, Supplies.APPROACH_RANGE)
        cmd.target_guid = best.guid
        cmd.target_x, cmd.target_z = best.x, best.z
        return cmd, nil
    end

    return nil, "no_candidate"
end

-- [喵喵喵]: 地标 → Exploration 前沿。只在“手边没有、作业也做不了”时才走这里。
local function plan_fallback(player, snapshot, state, rt, item, dark)
    local lcmd, lwhy = plan_landmark(snapshot, rt, item, dark)
    if lcmd ~= nil then
        return lcmd, nil
    end
    if lwhy == "night" then
        return nil, "night_light_reserve:landmark:" .. item
    end
    if lwhy == "landmark_waiting_observation" then
        return nil, lwhy .. ":" .. item
    end

    if dark then
        return nil, "night_light_reserve:explore:" .. item
    end
    -- [喵喵喵]: 基本口粮和随身照明有余量后才规划地形；饥荒、首份照明及备灯期限保持原有近处救急路径。 (2026-11-13)
    local stocked_light = false
    for _, prefab in ipairs({ "torch", "lantern", "minerhat" }) do
        local record = first_owned_record(snapshot, prefab, COUNTED_KINDS)
        if record ~= nil and is_valid(record.entity) and not record.entity:HasTag("fueldepleted") then
            stocked_light = true
            break
        end
    end
    local resource = stocked_light and snapshot.shard_kind == "surface"
        and is_finite_number(snapshot.hunger) and snapshot.hunger > 0.35
        and is_finite_number(snapshot.health) and snapshot.health > 0.35
        and is_finite_number(snapshot.time_until_night) and snapshot.time_until_night > Supplies.PLAN_TIMEOUT
        and item or nil
    local goal, gwhy = Exploration.Next(player, snapshot, state, resource)
    if type(goal) == "table" then
        return make_explore_command(rt, "explore|" .. item, "explore:" .. item, goal), nil
    end
    return nil, string.format("no_source:%s|%s|%s", item, tostring(lwhy), tostring(gwhy))
end

--------------------------------------------------------------------------
-- [喵喵喵] 建造点选择：只从“客户端看得见”的环形采样里挑，逐个用原生
-- builder:CanBuildAtPoint(点, 配方, 朝向) 复核（内部就是
-- TheWorld.Map:CanDeployRecipeAtPoint，含 min_spacing 占地检测）。
-- 不猜可建、不绕过科技、不自己造放置 RPC。
--------------------------------------------------------------------------

local function build_point_ok(player, snapshot, x, z, recipe)
    if not is_finite_number(x) or not is_finite_number(z) then
        return false, "bad_coordinates"
    end
    if math.abs(x) > Supplies.WORLD_LIMIT or math.abs(z) > Supplies.WORLD_LIMIT then
        return false, "out_of_world"
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return false, "no_player_position"
    end
    if math.sqrt(dist2(px, pz, x, z)) > Supplies.BUILD_MAX_DIST then
        return false, "too_far"
    end
    local land, land_why = terrain_land(x, z)
    if land ~= true then
        return false, land_why or "not_land"
    end
    local safe, safe_why = threat_safe(snapshot, x, z)
    if safe ~= true then
        return false, safe_why or "threat"
    end
    local builder = get_builder(player)
    if builder == nil then
        return false, "builder_replica_unavailable"
    end
    local pt = make_point(x, z)
    if pt == nil then
        return false, "vector3_unavailable"
    end
    local can = builder_call(builder, "CanBuildAtPoint", pt, recipe, 0)
    if can ~= true then
        return false, "cannot_deploy_here"
    end
    return true, nil
end

-- [喵喵喵]: 可选 place 提示优先（调用方指定营地位置）；否则环形找第一个可建点。
local function pick_build_point(player, snapshot, recipe, hint)
    if type(hint) == "table" and is_finite_number(hint.x) and is_finite_number(hint.z) then
        local ok, why = build_point_ok(player, snapshot, hint.x, hint.z, recipe)
        if ok == true then
            return hint.x, hint.z, nil
        end
        return nil, nil, "place_hint:" .. tostring(why)
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil, nil, "no_player_position"
    end
    local step = (2 * math.pi) / Supplies.BUILD_DIRECTIONS
    local last_why = "no_clear_spot"
    for r = 1, #Supplies.BUILD_RADII do
        local radius = Supplies.BUILD_RADII[r]
        for i = 0, Supplies.BUILD_DIRECTIONS - 1 do
            local angle = step * i
            local x = px + math.cos(angle) * radius
            local z = pz + math.sin(angle) * radius
            local ok, why = build_point_ok(player, snapshot, x, z, recipe)
            if ok == true then
                return x, z, nil
            end
            last_why = tostring(why)
        end
    end
    return nil, nil, last_why
end

--------------------------------------------------------------------------
-- [喵喵喵] 作业目标：必须同时满足“客户端可见 + 原生 <ACT>_workable 标签”。
-- componentactions.lua:3112-3115 的 workable 收集器在客户端就是查这个标签，
-- 所以这里用同一个条件预筛，减少被执行层拒绝的无用命令。
--------------------------------------------------------------------------

local function work_targets(snapshot, rt, work)
    local result = {}
    local nearby = snapshot.nearby
    if type(nearby) ~= "table" then
        return result
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return result
    end
    local want = {}
    if type(work.prefabs) == "table" then
        for i = 1, #work.prefabs do
            want[work.prefabs[i]] = true
        end
    end
    if type(work.also) == "table" then
        for i = 1, #work.also do
            want[work.also[i]] = true
        end
    end
    local tag = tostring(work.act) .. "_workable"
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and want[record.prefab] == true
            and record.threat ~= true
            and not bad_target(rt, record.guid) then
            local rx, rz = record.x, record.z
            if not is_finite_number(rx) or not is_finite_number(rz) then
                rx, rz = get_xz(record.entity)
            end
            local workable = nil
            if is_valid(record.entity) and record.entity.HasTag ~= nil then
                workable = try(function()
                    return record.entity:HasTag(tag)
                end)
            end
            if workable == true
                and is_finite_number(rx) and is_finite_number(rz)
                and math.abs(rx) <= Supplies.WORLD_LIMIT
                and math.abs(rz) <= Supplies.WORLD_LIMIT
                and terrain_land(rx, rz) == true
                and threat_safe(snapshot, rx, rz) == true then
                result[#result + 1] = {
                    entity = record.entity,
                    guid = record.guid,
                    prefab = record.prefab,
                    x = rx,
                    z = rz,
                    distance = math.sqrt(dist2(px, pz, rx, rz)),
                }
            end
        end
    end
    table.sort(result, function(a, b)
        return a.distance < b.distance
    end)
    return result
end

local function work_tool_ready(player, snapshot, work)
    if count_owned(snapshot, work.tool) >= 1 then return true end
    local recipe = get_recipe(CRAFT_RECIPES[work.tool])
    local builder = get_builder(player)
    return recipe ~= nil and builder ~= nil
        and (builder_call(builder, "IsBuildBuffered", recipe.name) == true
            or builder_call(builder, "HasIngredients", recipe) == true)
end

-- [喵喵喵]: 现成采掘能力与地面来源一起比较，避免总追远处散落物；首把工具仍须原生配料足够。 (2026-11-13)
local function nearest_visible_source(player, snapshot, rt, item)
    local best = visible_candidates(snapshot, rt, item)[1]
    local work = WORK_SOURCES[item]
    local hands = equipped_record(snapshot, "hands")
    if work ~= nil and work_tool_ready(player, snapshot, work)
        and not ((snapshot.phase == "night" or snapshot.shard_kind == "cave")
            and hands ~= nil and Supplies.LIGHT_ITEMS[hands.prefab]) then
        local target = work_targets(snapshot, rt, work)[1]
        if target ~= nil and (best == nil or (best.distance > Supplies.ACTION_RANGE
            and target.distance < best.distance)) then
            return target, true
        end
    end
    return best, false
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策阶梯(工具/制作小片扩展)：
--   白名单配方 → 看得见的拾取/采集 → 作业(先备好工具) → 地标 → 探索
-- 每一层都只产出命令或明确原因，绝不在这里执行任何动作。
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- [喵喵喵] 原型机(科学机器系)：只认客户端可见的 prototyper prefab + 同世界运行期记忆。
-- “有没有科技”一律问原生 builder:GetTechTrees() / KnowsRecipe（服务端会把附近机器
-- 的科技树同步给客户端），本文件绝不自算科技等级，也绝不发放/解锁配方。
-- 记忆只是“去哪儿看看”：到达后必须重新观测到机器实体才算数。
--------------------------------------------------------------------------

local function station_key(prefab, x, z)
    return string.format("station|%s|%d_%d",
        tostring(prefab),
        math.floor(x / 4),
        math.floor(z / 4))
end

-- [喵喵喵]: 有界运行期记忆(纯坐标 + 时间戳)，超上限按时间淘汰；不进存档。
local function remember_station(rt, prefab, x, z)
    if type(rt.stations) ~= "table" then
        rt.stations = {}
    end
    local key = station_key(prefab, x, z)
    rt.stations[key] = { prefab = prefab, x = x, z = z, t = now() }
    local n = 0
    for _ in pairs(rt.stations) do
        n = n + 1
    end
    if n <= Supplies.STATION_MEMORY_MAX then
        return
    end
    local entries = {}
    for k, v in pairs(rt.stations) do
        entries[#entries + 1] = { key = k, t = (type(v) == "table" and tonumber(v.t)) or 0 }
    end
    table.sort(entries, function(a, b)
        return a.t < b.t
    end)
    local keep = math.max(1, math.floor(Supplies.STATION_MEMORY_MAX / 2))
    for i = 1, #entries - keep do
        rt.stations[entries[i].key] = nil
    end
end

-- [喵喵喵]: 本次观测里看得见的原型机：prefab 命中 + 不在威胁里 + 站在陆地上。
local function visible_stations(snapshot, rt, level)
    local result = {}
    local nearby = snapshot.nearby
    if type(nearby) ~= "table" then
        return result
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return result
    end
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and PROTOTYPER_PREFABS[record.prefab] == true
            and is_valid(record.entity) and not record.entity:HasTag("burnt")
            and record.threat ~= true
            and (level == nil or (level <= 1 and (record.prefab == "researchlab" or record.prefab == "researchlab2"))
                or (level == 2 and record.prefab == "researchlab2")) then
            local rx, rz = record.x, record.z
            if not is_finite_number(rx) or not is_finite_number(rz) then
                rx, rz = get_xz(record.entity)
            end
            if is_finite_number(rx) and is_finite_number(rz)
                and math.abs(rx) <= Supplies.WORLD_LIMIT
                and math.abs(rz) <= Supplies.WORLD_LIMIT then
                remember_station(rt, record.prefab, rx, rz)
                if terrain_land(rx, rz) == true and threat_safe(snapshot, rx, rz) == true then
                    result[#result + 1] = {
                        entity = record.entity,
                        guid = record.guid,
                        prefab = record.prefab,
                        x = rx,
                        z = rz,
                        key = station_key(record.prefab, rx, rz),
                        distance = math.sqrt(dist2(px, pz, rx, rz)),
                    }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        return a.distance < b.distance
    end)
    return result
end

-- [喵喵喵]: 同世界记得的原型机（运行期记忆 + observer 的 station 地标）。
-- 返回的只是“去看看”的坐标；到得了不等于机器还在，更不等于已经站在旁边。
local function remembered_stations(snapshot, rt, level)
    local function matches(prefab)
        return level == nil or (level <= 1 and (prefab == "researchlab" or prefab == "researchlab2"))
            or (level == 2 and prefab == "researchlab2")
    end
    local result = {}
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return result
    end
    local t = now()
    if type(rt.stations) == "table" then
        for key, entry in pairs(rt.stations) do
            if type(entry) == "table"
                and is_finite_number(entry.x)
                and is_finite_number(entry.z)
                and rt.stale[key] == nil and matches(entry.prefab)
                and (t - (tonumber(entry.t) or 0)) <= Supplies.STATION_TTL then
                result[#result + 1] = {
                    prefab = entry.prefab,
                    x = entry.x,
                    z = entry.z,
                    key = key,
                    remembered = true,
                    distance = math.sqrt(dist2(px, pz, entry.x, entry.z)),
                }
            end
        end
    end
    -- [喵喵喵]: observer 只把白名单里的站点记进 station 类；名字对得上才用。
    local mem = snapshot.shard_memory
    local cats = type(mem) == "table" and mem.cats or nil
    local list = type(cats) == "table" and cats.station or nil
    if type(list) == "table" then
        for i = 1, #list do
            local entry = list[i]
            if type(entry) == "table"
                and PROTOTYPER_PREFABS[entry.prefab] == true and matches(entry.prefab)
                and is_finite_number(entry.x)
                and is_finite_number(entry.z) then
                local key = station_key(entry.prefab, entry.x, entry.z)
                if rt.stale[key] == nil then
                    result[#result + 1] = {
                        prefab = entry.prefab,
                        x = entry.x,
                        z = entry.z,
                        key = key,
                        remembered = true,
                        distance = math.sqrt(dist2(px, pz, entry.x, entry.z)),
                    }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        return a.distance < b.distance
    end)
    return result
end

local function nearest_station(snapshot, rt, level)
    local visible = visible_stations(snapshot, rt, level)
    if #visible > 0 then
        return visible[1], "visible"
    end
    local remembered = remembered_stations(snapshot, rt, level)
    if #remembered > 0 then
        return remembered[1], "remembered"
    end
    return nil, "none"
end

local function station_nav(rt, recipe_name, station)
    local stage = string.format("station|%s|%s", tostring(recipe_name), tostring(station.key))
    local cmd = make_navigation_command(rt, stage,
        "station:" .. tostring(recipe_name),
        station.x, station.z, Supplies.STATION_NAV_RANGE)
    cmd.station_key = station.key
    cmd.target_x, cmd.target_z = station.x, station.z
    return cmd
end

--------------------------------------------------------------------------
-- [喵喵喵] 火与烹饪：只用客户端可见的火堆(cooker 标签)和随身持着的可烹饬食材，
-- 效果一律走既有执行层的 kind='use'（原生 Inventory:ControllerUseItemOnSceneFromInvTile
-- 同源链路），绝不在这里自己发 RPC、也不把“往锅里添料”当成 COOK。
--------------------------------------------------------------------------

-- [喵喵喵]: 现场数一遍“客户端真的拥有”的数量（主栏 + 装备槽 + 溢出背包 + 手持），
-- 供 confirm 回调使用；读不到就返回 nil(未知)，绝不当 0 来制造成功。
count_owned_live = function(player, prefab)
    local inventory = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
    if inventory == nil then
        return nil
    end
    local seen = {}
    local total = 0
    local known = false

    local function add(item)
        if item == nil or seen[item] == true or not is_valid(item) then
            return
        end
        seen[item] = true
        if item.prefab ~= prefab then
            return
        end
        local size = 1
        local stackable = item.replica ~= nil and item.replica.stackable or nil
        if stackable ~= nil and stackable.StackSize ~= nil then
            local n = try(function()
                return stackable:StackSize()
            end)
            if is_finite_number(n) then
                size = n
            end
        end
        total = total + size
    end

    if inventory.GetItems ~= nil then
        local items = try(function()
            return inventory:GetItems()
        end)
        if type(items) == "table" then
            known = true
            for _, item in pairs(items) do
                if item ~= nil and type(item) ~= "boolean" then
                    add(item)
                end
            end
        end
    end
    if inventory.GetEquips ~= nil then
        local equips = try(function()
            return inventory:GetEquips()
        end)
        if type(equips) == "table" then
            for _, item in pairs(equips) do
                if item ~= nil and type(item) ~= "boolean" then
                    add(item)
                end
            end
        end
    end
    if inventory.GetOverflowContainer ~= nil then
        local overflow = try(function()
            return inventory:GetOverflowContainer()
        end)
        local container = overflow ~= nil and overflow.GetItems ~= nil and overflow or nil
        if container ~= nil then
            local items = try(function()
                return container:GetItems()
            end)
            if type(items) == "table" then
                for _, item in pairs(items) do
                    if item ~= nil and type(item) ~= "boolean" then
                        add(item)
                    end
                end
            end
        end
    end
    if inventory.GetActiveItem ~= nil then
        add(try(function()
            return inventory:GetActiveItem()
        end))
    end

    if not known then
        return nil
    end
    return total
end

-- [喵喵喵]: 远端客户端专用确认：服务端 cookable.product 客户端读不到，Actions 默认会停在
-- effect_unconfirmed。这里用“客户端实测到的成品数量 ≥ 发出时的基线 + 1”作为硬证据，
-- 不认“食材变少”也不是“随便多了一个东西”。
local function make_cook_confirm(player, product, baseline)
    return function()
        local now_count = count_owned_live(player, product)
        if not is_finite_number(now_count) or not is_finite_number(baseline) then
            return false
        end
        return now_count >= baseline + 1
    end
end

-- [喵喵喵]: 有界运行期记忆：只存坐标，用于“记得那边有火堆，去看看吧”。
local function remember_fire(rt, prefab, x, z)
    if type(rt.fires) ~= "table" then
        rt.fires = {}
    end
    local key = string.format("fire|%s|%d_%d", tostring(prefab), math.floor(x / 4), math.floor(z / 4))
    rt.fires[key] = { prefab = prefab, x = x, z = z, t = now() }
    local n = 0
    for _ in pairs(rt.fires) do
        n = n + 1
    end
    if n <= Supplies.STATION_MEMORY_MAX then
        return
    end
    local entries = {}
    for k, v in pairs(rt.fires) do
        entries[#entries + 1] = { key = k, t = (type(v) == "table" and tonumber(v.t)) or 0 }
    end
    table.sort(entries, function(a, b)
        return a.t < b.t
    end)
    local keep = math.max(1, math.floor(Supplies.STATION_MEMORY_MAX / 2))
    for i = 1, #entries - keep do
        rt.fires[entries[i].key] = nil
    end
end

-- [喵喵喵]: 看得见的火堆：prefab 白名单 + 客户端可见的 cooker 标签 + 没烧完(fueldepleted)。
local function visible_fires(snapshot, rt)
    local result = {}
    local nearby = snapshot.nearby
    if type(nearby) ~= "table" then
        return result
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return result
    end
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and FIRE_PREFABS[record.prefab] == true
            and record.threat ~= true
            and is_valid(record.entity) then
            local fx, fz = record.x, record.z
            if not is_finite_number(fx) or not is_finite_number(fz) then
                fx, fz = get_xz(record.entity)
            end
            local cooker = try(function()
                return record.entity:HasTag("cooker")
            end)
            local depleted = try(function()
                return record.entity:HasTag("fueldepleted")
            end)
            if cooker == true and depleted ~= true
                and is_finite_number(fx) and is_finite_number(fz) then
                remember_fire(rt, record.prefab, fx, fz)
                if terrain_land(fx, fz) == true and threat_safe(snapshot, fx, fz) == true then
                    result[#result + 1] = {
                        entity = record.entity,
                        guid = record.guid,
                        prefab = record.prefab,
                        x = fx,
                        z = fz,
                        distance = math.sqrt(dist2(px, pz, fx, fz)),
                    }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        return a.distance < b.distance
    end)
    return result
end

-- [喵喵喵]: 记得的火堆（运行期记忆 + observer 的 station 类：observer 白名单里确实有
-- campfire/firepit）。到得了不等于还在烧，所以到达后仍需重新观测。
local function remembered_fire(snapshot, rt)
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil
    end
    local best = nil
    local t = now()
    if type(rt.fires) == "table" then
        for key, entry in pairs(rt.fires) do
            if type(entry) == "table"
                and is_finite_number(entry.x)
                and is_finite_number(entry.z)
                and rt.stale[key] == nil
                and (t - (tonumber(entry.t) or 0)) <= Supplies.STATION_TTL then
                local d = math.sqrt(dist2(px, pz, entry.x, entry.z))
                if best == nil or d < best.distance then
                    best = { key = key, x = entry.x, z = entry.z, prefab = entry.prefab, distance = d }
                end
            end
        end
    end
    local mem = snapshot.shard_memory
    local cats = type(mem) == "table" and mem.cats or nil
    local list = type(cats) == "table" and cats.station or nil
    if type(list) == "table" then
        for i = 1, #list do
            local entry = list[i]
            if type(entry) == "table"
                and FIRE_PREFABS[entry.prefab] == true
                and is_finite_number(entry.x)
                and is_finite_number(entry.z) then
                local key = string.format("fire|%s|%d_%d",
                    tostring(entry.prefab), math.floor(entry.x / 4), math.floor(entry.z / 4))
                if rt.stale[key] == nil then
                    local d = math.sqrt(dist2(px, pz, entry.x, entry.z))
                    if best == nil or d < best.distance then
                        best = { key = key, x = entry.x, z = entry.z, prefab = entry.prefab, distance = d }
                    end
                end
            end
        end
    end
    return best
end

--------------------------------------------------------------------------
-- [喵喵喵] 烹饪：拿“随身持着的可烹饬食材”对“看得见的火堆”发一次原生 COOK。
-- 顺序：先保证有食材(没有就回到获取/制作链路) → 再找已有炊火
--      → 站到动作距离内才发。火不够近一律先发 Navigation，不隔空烹饪。
--------------------------------------------------------------------------

local plan_item
local hoist_from_overflow

local function plan_cook(player, snapshot, state, rt, product, depth, path, dark, crafts)
    local rule = COOK_SOURCES[product]
    if type(rule) ~= "table" or type(rule.from) ~= "string" then
        return nil, "cook_rule_missing:" .. tostring(product)
    end
    local input = rule.from

    -- 1) 食材：COOK 走背包 invtile 链路，溢出背包里的那一份不能直接点
    local have, known = count_owned(snapshot, input)
    if not known then
        -- [喵喵喵]: 背包副本还没建立时数量属于“未知”，不能当成 0 去白跑一趟采集。
        return nil, "inventory_unsettled:" .. input
    end
    if have < 1 then
        if depth >= Supplies.MAX_STEPS then
            return nil, "steps_exhausted:" .. input
        end
        local cmd, why = plan_item(player, snapshot, state, rt, input, depth + 1, path, nil, crafts)
        if cmd ~= nil then
            return cmd, nil
        end
        return nil, string.format("need_input:%s|%s", input, tostring(why))
    end
    local record = first_owned_record(snapshot, input, { inventory = true, active = true })
    if record == nil then
        -- [喵喵喵]: 只在溢出背包里时，先用原生搬运取回主背包，而不是把活丢给调用方。
        local hidden = first_owned_record(snapshot, input, { backpack = true })
        if hidden ~= nil then
            return hoist_from_overflow(player, rt, input, hidden, "input")
        end
        return nil, "input_missing:" .. input
    end
    local cookable = try(function()
        return record.entity:HasTag("cookable")
    end)
    if cookable ~= true then
        -- [喵喵喵]: 客户端可见标签都不成立时绝不硬发，避免被 picker 换成别的动作。
        return nil, "input_not_cookable:" .. input
    end

    -- 2) 火：只复用看得见或记得的火源，没有炊火时让调用方选择其他补给。
    local fires = visible_fires(snapshot, rt)
    if #fires == 0 then
        for _, pit in ipairs(snapshot.nearby or {}) do
            if pit.prefab == "firepit" and is_valid(pit.entity) and not pit.entity:HasTag("fire")
                and not pit.entity:HasTag("burnt") and threat_safe(snapshot, pit.x, pit.z) == true then
                if math.sqrt(dist2(snapshot.x, snapshot.z, pit.x, pit.z)) > Supplies.ACTION_RANGE then
                    if dark then return nil, "firepit_requires_light" end
                    return make_navigation_command(rt, "cook:firepit", "cook:firepit", pit.x, pit.z, 1.5)
                end
                local fuel = first_owned_record(snapshot, "log", { inventory = true, active = true })
                if fuel ~= nil then
                    local target = pit.entity
                    return make_actions_command(rt, "cook:fuel|" .. tostring(pit.guid), "cook:refuel", {
                        kind = "use", action = "ADDFUEL", item = fuel.entity, target = target,
                        confirm = function() return is_valid(target) and target:HasTag("fire") end,
                    })
                end
                local overflow = first_owned_record(snapshot, "log", { backpack = true })
                if overflow then return hoist_from_overflow(player, rt, "log", overflow, "fuel") end
                return plan_item(player, snapshot, state, rt, "log", depth + 1, path, nil, crafts)
            end
        end
        local remembered = remembered_fire(snapshot, rt)
        if remembered ~= nil and remembered.distance <= Supplies.STATION_RANGE then
            mark_stale(rt, remembered.key)
            remembered = nil
        end
        if remembered ~= nil then
            if dark then
                return nil, "night_light_reserve:fire:" .. product
            end
            local cmd = make_navigation_command(rt, "fire|" .. tostring(remembered.key),
                "fire:" .. product, remembered.x, remembered.z,
                Supplies.APPROACH_RANGE + 0.8)
            -- [喵喵喵]: 复用“到达后要重新观测”的机制：到了还是没火就当此地无火，换下一处。
            cmd.landmark_key = remembered.key
            return cmd, nil
        end
        if dark then
            return nil, "night_light_reserve:build_fire:" .. product
        end
        -- [喵喵喵]: 炊火由照明或体温需求建立；采购熟食不能单独消耗草木新造营火。 (2026-11-11)
        return nil, "need_fire:" .. product
    end

    local fire = fires[1]
    if fire.distance > Supplies.ACTION_RANGE then
        if dark then
            return nil, "night_light_reserve:fire:" .. product
        end
        local cmd = make_navigation_command(rt, "approach|fire|" .. tostring(fire.guid),
            "approach_fire:" .. product, fire.x, fire.z,
            Supplies.ACTION_RANGE * 0.6)
        cmd.target_guid = fire.guid
        cmd.target_x, cmd.target_z = fire.x, fire.z
        return cmd, nil
    end

    -- 3) 下发原生 COOK（物品对场景火堆），并带上远端客户端可用得上的产物确认
    local baseline = count_owned(snapshot, product)
    local cmd = make_actions_command(rt,
        string.format("cook|%s|%s", tostring(product), tostring(fire.guid)),
        "cook:" .. tostring(product), {
            kind = "use",
            action = "COOK",
            item = record.entity,
            target = fire.entity,
            priority = Supplies.GOAL_PRIORITY,
            confirm = make_cook_confirm(player, product, baseline),
        })
    cmd.target_guid = fire.guid
    cmd.target_x, cmd.target_z = fire.x, fire.z
    cmd.cook_product = product
    cmd.cook_input_guid = record.guid
    return cmd, nil
end

-- [喵喵喵]: 溢出背包 → 主背包的原生搬运（Actions kind='transfer'）。
-- 语义按 data/.../components/inventory_replica.lua:584-608 与 container_replica.lua:621-643：
-- 源是容器实体时用该容器副本的 MoveItemFromAllOfSlot(slot, 目标实体)，
-- 目标写本地玩家实体（服务端把物品塞回发起者背包）。
-- 这条与“装备/烹饪”是不同的动作链路，本文件只是把它当一次获取步骤。
hoist_from_overflow = function(player, rt, prefab, record, tag)
    if type(record) ~= "table" then
        return nil, string.format("%s_in_overflow:%s", tostring(tag), tostring(prefab))
    end
    local source = record.container
    local slot = record.slot
    if not is_valid(source) then
        return nil, "overflow_unavailable:" .. tostring(prefab)
    end
    if not is_finite_number(slot) or slot < 1 or math.floor(slot) ~= slot then
        return nil, "overflow_no_slot:" .. tostring(prefab)
    end
    if type(rt.hoist) ~= "table" then
        rt.hoist = {}
    end
    local chain = tonumber(rt.hoist[prefab]) or 0
    if chain >= Supplies.MAX_HOIST_CHAIN then
        -- [喵喵喵]: 已经试过有限次数还没进主背包，就明确收手，不无限搬。
        return nil, "overflow_hoist_exhausted:" .. tostring(prefab)
    end
    rt.hoist[prefab] = chain + 1
    local cmd = make_actions_command(rt, "hoist|" .. tostring(prefab), "hoist:" .. tostring(prefab), {
        kind = "transfer",
        source = source,
        slot = math.floor(slot),
        destination = player,
        priority = Supplies.GOAL_PRIORITY,
    })
    cmd.transfer_slot = math.floor(slot)
    return cmd, nil
end

-- [喵喵喵]: 工具四态：已装备(tool_ready) / 主背包有货就发 EQUIP / 只在溢出背包就先搬运取回
-- / 完全没有就递归做一把。EQUIP 只走主背包栏与手持：原生
-- ControllerUseItemOnSelfFromInvTile 用的是 invtile 槽位，溢出背包里的那一份不能直接点，
-- 所以先用 Actions kind='transfer' 把它搬回主背包（不把活推给调用方）。
local function ensure_tool(player, snapshot, state, rt, tool, depth, path, crafts)
    local hands = equipped_record(snapshot, "hands")
    if hands ~= nil and hands.prefab == tool then
        return nil, "tool_ready"
    end
    local record = first_owned_record(snapshot, tool, { inventory = true, active = true })
    if record ~= nil then
        local cmd = make_actions_command(rt, "equip|" .. tostring(tool), "equip:" .. tostring(tool), {
            kind = "inventory",
            action = "EQUIP",
            item = record.entity,
            priority = Supplies.GOAL_PRIORITY,
        })
        cmd.equip_guid = record.guid
        return cmd, nil
    end
    local hidden = first_owned_record(snapshot, tool, { backpack = true })
    if hidden ~= nil then
        -- [喵喵喵]: 溢出背包里的工具不靠调用方“自己想办法”，直接用原生的背包搬运链路：
        -- Actions kind='transfer' → inventory_replica/container_replica:MoveItemFromAllOfSlot，
        -- 源 = 溢出背包实体(record.container 就是 GetOverflowContainer().inst)，
        -- 目标 = 本地玩家实体(服务端塞回自己的 inventory)。Actions 对“自己的溢出背包”
        -- 作为源是豁免打开状态的，所以这一条在远端客户端也成立。
        return hoist_from_overflow(player, rt, tool, hidden, "tool")
    end
    local cmd, why = plan_item(player, snapshot, state, rt, tool, depth + 1, path, nil, crafts)
    if cmd ~= nil then
        return cmd, nil
    end
    return nil, why or ("need_tool:" .. tostring(tool))
end

local function physical_radius(entity)
    return entity.Physics ~= nil and entity.Physics:GetRadius() or 0
end

-- [喵喵喵]: 预接近走目标外缘而非碰撞中心；最后一段仍交给原版目标动作计算双方半径。 (2026-11-13)
local function work_approach(player, snapshot, target, radius)
    local map = get_map()
    if FindWalkableOffset == nil or map == nil or map.IsPointNearHole == nil then
        return nil, nil, "work_approach_query_unavailable"
    end
    local position = Vector3(target.x, 0, target.z)
    local angle = math.atan2(target.z - snapshot.z, snapshot.x - target.x)
    local offset = FindWalkableOffset(position, angle, radius, 8, false, false, function(point)
        if terrain_land(point.x, point.z) ~= true or threat_safe(snapshot, point.x, point.z) ~= true
            or map:IsPointNearHole(point) ~= false then return false end
        -- [喵喵喵]: 只用已见碰撞体排除被矿石/邻树占据的落点；整段通路仍由Navigation检查。 (2026-11-13)
        for _, record in ipairs(snapshot.nearby or {}) do
            local entity = record.entity
            if is_valid(entity) and entity:HasTag("blocker") then
                local x, z = get_xz(entity)
                local clearance = physical_radius(entity) + physical_radius(player) + 0.25 + 0.1
                if x ~= nil and dist2(x, z, point.x, point.z) < clearance * clearance then return false end
            end
        end
        return true
    end, false, false, true)
    if offset == nil then return nil, nil, "work_approach_blocked" end
    return target.x + offset.x, target.z + offset.z
end

-- [喵喵喵]: 同一目标由 Actions 维持原版连续工作；等作业完成再由持有量确认材料是否到手。 (2026-11-11)
local function plan_work(player, snapshot, state, rt, item, work, depth, path, dark, crafts)
    local targets = work_targets(snapshot, rt, work)
    if #targets == 0 then return nil, "no_candidate" end
    -- [喵喵喵]: 首把镐不能依赖挖矿取得自身配料；已有两份燧石等原生配料时可先制镐再采矿。 (2026-11-13)
    if item == "flint" and not work_tool_ready(player, snapshot, work) then return nil, "no_candidate" end
    if (snapshot.phase == "night" or snapshot.shard_kind == "cave") and equipped_record(snapshot, "hands") ~= nil
        and Supplies.LIGHT_ITEMS[equipped_record(snapshot, "hands").prefab] then
        return nil, "work_requires_stationary_light"
    end
    local tcmd, twhy = ensure_tool(player, snapshot, state, rt, work.tool, depth, path, crafts)
    if tcmd ~= nil then return tcmd, nil end
    if twhy ~= "tool_ready" then return nil, twhy end
    local best = targets[1]
    local stage = string.format("work|%s|%s", tostring(work.act), tostring(best.guid))
    local purpose = string.format("work:%s@%s", item, tostring(best.prefab))
    local stand_radius = physical_radius(player) + physical_radius(best.entity) + 0.5
    if best.distance <= math.max(Supplies.ACTION_RANGE, stand_radius + 0.25) then
        local cmd = make_actions_command(rt, stage, purpose, {
            kind = "action",
            action = work.act,
            target = best.entity,
            priority = Supplies.GOAL_PRIORITY,
        })
        cmd.target_guid = best.guid
        cmd.target_x, cmd.target_z = best.x, best.z
        return cmd, nil
    end
    if dark then
        return nil, "night_light_reserve:" .. purpose
    end
    local x, z, reason = work_approach(player, snapshot, best, stand_radius)
    if x == nil then return nil, reason end
    local cmd = make_navigation_command(rt, "approach|" .. stage,
        string.format("approach:%s@%s", item, tostring(best.prefab)), x, z, 0.25)
    cmd.target_guid = best.guid
    cmd.target_x, cmd.target_z = best.x, best.z
    return cmd, nil
end

-- [喵喵喵]: 制作：配料一律读原生配方注册表；缺料先递归备料(深度/环检测有界)；
-- 科技只认 KnowsRecipe/已缓冲 或 (CanPrototypeRecipe + CanLearn)，需要外地科技时
-- 明确报 need_station，绝不解锁/绕过；放置类必须先在客户端可建的点上。
local function plan_wool(player, snapshot, state, rt, depth, path, crafts)
    local woolly
    for _, record in ipairs(snapshot.nearby or {}) do
        if record.prefab == "beefalo" and is_valid(record.entity) and not bad_target(rt, record.guid)
            and record.entity:HasTag("has_beard") and not record.entity:HasTag("scarytoprey")
            and record.entity.AnimState ~= nil
            and record.entity.AnimState:IsCurrentAnimation("sleep_loop")
            and threat_safe(snapshot, record.x, record.z) == true then
            woolly = record
            break
        end
    end
    if woolly == nil then return nil, "no_candidate" end
    local razor = first_owned_record(snapshot, "razor", { inventory = true, active = true })
    if razor == nil then
        local overflow = first_owned_record(snapshot, "razor", { backpack = true })
        if overflow then return hoist_from_overflow(player, rt, "razor", overflow, "shaver") end
        return plan_item(player, snapshot, state, rt, "razor", depth + 1, path, nil, crafts)
    end
    local distance = math.sqrt(dist2(snapshot.x, snapshot.z, woolly.x, woolly.z))
    if distance > Supplies.ACTION_RANGE then
        if is_dark(snapshot) then return nil, "wool_requires_visible_light" end
        return make_navigation_command(rt, "wool:approach", "wool:approach", woolly.x, woolly.z, 1.5)
    end
    local entity = woolly.entity
    local cmd = make_actions_command(rt, "shave|" .. tostring(woolly.guid), "shave:beefalo", {
        kind = "use", action = "SHAVE", item = razor.entity, target = entity,
        confirm = function() return is_valid(entity) and not entity:HasTag("has_beard") end,
    })
    cmd.target_guid = woolly.guid
    return cmd
end

local function plan_trapping(player, snapshot, state, rt, item, depth, path, dark, crafts)
    if item == "smallmeat" then
        local rabbit = first_owned_record(snapshot, "rabbit", { inventory = true, active = true })
        if rabbit ~= nil then
            return make_actions_command(rt, "murder|" .. tostring(rabbit.guid), "food:rabbit", {
                kind = "inventory", action = "MURDER", item = rabbit.entity,
            })
        end
        local overflow = first_owned_record(snapshot, "rabbit", { backpack = true })
        if overflow then return hoist_from_overflow(player, rt, "rabbit", overflow, "food") end
    end
    local groundtrap, source
    for _, record in ipairs(snapshot.nearby or {}) do
        if is_valid(record.entity) then
            if record.prefab == "trap" and not record.entity:HasTag("INLIMBO") and not bad_target(rt, record.guid) then
                if groundtrap == nil or (record.entity:HasTag("trapsprung") and not groundtrap.entity:HasTag("trapsprung")) then
                    groundtrap = record
                end
            elseif (item == "smallmeat" and record.prefab == "rabbithole" and record.entity.iscollapsed ~= nil
                and record.entity.iscollapsed:value() == false)
                or (item ~= "smallmeat" and record.prefab == "spider") then
                source = record
            end
        end
    end
    if groundtrap ~= nil then
        local distance = math.sqrt(dist2(snapshot.x, snapshot.z, groundtrap.x, groundtrap.z))
        if groundtrap.entity:HasTag("trapsprung") then
            if threat_safe(snapshot, groundtrap.x, groundtrap.z) ~= true then return nil, "trap_unsafe" end
            if distance > Supplies.ACTION_RANGE then
                if dark then return nil, "trap_requires_light" end
                return make_navigation_command(rt, "trap:approach", "trap:harvest", groundtrap.x, groundtrap.z, 1.5)
            end
            local entity = groundtrap.entity
            local cmd = make_actions_command(rt, "trap:harvest|" .. tostring(groundtrap.guid), "trap:harvest", {
                kind = "action", action = "CHECKTRAP", target = entity,
                confirm = function() return is_valid(entity) and not entity:HasTag("trapsprung") end,
            })
            cmd.target_guid = groundtrap.guid
            return cmd
        end
        if source ~= nil and source.prefab == "spider" and distance < 3 then
            local dx, dz = groundtrap.x - source.x, groundtrap.z - source.z
            local n = math.sqrt(dx * dx + dz * dz)
            if n > 0 then
                local x, z = groundtrap.x + dx * 4 / n, groundtrap.z + dz * 4 / n
                if terrain_land(x, z) == true then
                    return make_navigation_command(rt, "trap:lure", "trap:lure", x, z, 0.5)
                end
            end
        end
        if item == "smallmeat" and source ~= nil
            and dist2(source.x, source.z, groundtrap.x, groundtrap.z) > 2.25
            and threat_safe(snapshot, groundtrap.x, groundtrap.z) == true then
            if distance > Supplies.ACTION_RANGE then
                return make_navigation_command(rt, "trap:recover:approach", "trap:recover", groundtrap.x, groundtrap.z, 1.5)
            end
            return make_actions_command(rt, "trap:recover|" .. tostring(groundtrap.guid), "trap:recover", {
                kind = "action", action = "PICKUP", target = groundtrap.entity,
            })
        end
        return nil, "trap_waiting"
    end
    if source == nil then return nil, "no_candidate" end
    local trap = first_owned_record(snapshot, "trap", { inventory = true, active = true })
    if trap == nil then
        local overflow = first_owned_record(snapshot, "trap", { backpack = true })
        if overflow then return hoist_from_overflow(player, rt, "trap", overflow, "trap") end
        return plan_item(player, snapshot, state, rt, "trap", depth + 1, path, nil, crafts)
    end
    if item == "smallmeat" and math.sqrt(dist2(snapshot.x, snapshot.z, source.x, source.z)) > 0.7 then
        if dark then return nil, "trap_requires_light" end
        return make_navigation_command(rt, "trap:place", "trap:place", source.x, source.z, 0.5)
    end
    if item ~= "smallmeat" then
        local distance = math.sqrt(dist2(snapshot.x, snapshot.z, source.x, source.z))
        if distance < 3 or not is_finite_number(snapshot.health) or snapshot.health < 0.6 then
            return nil, "trap_threat_too_close"
        end
        if distance > 9 then return nil, "no_candidate" end
    end
    return make_actions_command(rt, "trap:drop", "trap:drop", {
        kind = "inventory", action = "DROP", item = trap.entity,
    })
end

local function plan_craft(player, snapshot, state, rt, recipe_name, depth, path, hint, crafts)
    -- [喵喵喵]: 只数“配方套配方”的层数，资源采集不消耗这个预算。
    crafts = (is_finite_number(crafts) and crafts or 0) + 1
    if crafts > Supplies.MAX_DEPTH then
        return nil, string.format("craft_depth_exhausted:%s|d=%d", tostring(recipe_name), crafts)
    end
    local recipe = get_recipe(recipe_name)
    if recipe == nil then
        return nil, "no_recipe:" .. tostring(recipe_name)
    end
    if recipe.manufactured == true then
        return nil, "manufactured_recipe:" .. tostring(recipe_name)
    end
    local builder = get_builder(player)
    if builder == nil then
        return nil, "builder_replica_unavailable"
    end
    if type(recipe.character_ingredients) == "table" and #recipe.character_ingredients > 0 then
        return nil, "character_ingredient_unsupported:" .. tostring(recipe_name)
    end
    if type(recipe.tech_ingredients) == "table" and #recipe.tech_ingredients > 0 then
        return nil, "tech_ingredient_unsupported:" .. tostring(recipe_name)
    end

    -- [喵喵喵]: 放置缓冲已扣材料；不能再次索要同一批材料。 (2026-11-11)
    local buffered = builder_call(builder, "IsBuildBuffered", recipe_name) == true
    local ingredients = not buffered and type(recipe.ingredients) == "table" and recipe.ingredients or {}
    -- [喵喵喵]: 先收集当前可见的缺料，避免配方首项稀缺时忽略沿途其它原料；只提交选中的命令，不预先推进多个探索目标。 (2026-11-12)
    for _, ingredient in ipairs(ingredients) do
        if type(ingredient) == "table" and type(ingredient.type) == "string" then
            local need = ingredient_need(builder, ingredient)
            if need ~= nil and count_owned(snapshot, ingredient.type) < need and depth < Supplies.MAX_STEPS then
                local source, working = nearest_visible_source(player, snapshot, rt, ingredient.type)
                if source ~= nil then
                    local dark = is_dark(snapshot) and Supplies.LIGHT_ITEMS[ingredient.type] ~= true
                    local cmd
                    if working then
                        cmd = plan_work(player, snapshot, state, rt, ingredient.type,
                            WORK_SOURCES[ingredient.type], depth + 1, path, dark, crafts)
                    else
                        cmd = plan_visible_pickup(player, snapshot, rt, ingredient.type, dark)
                    end
                    if cmd ~= nil then return cmd, nil end
                end
            end
        end
    end
    for i = 1, #ingredients do
        local ingredient = ingredients[i]
        if type(ingredient) == "table" and type(ingredient.type) == "string" then
            local need = ingredient_need(builder, ingredient)
            if need ~= nil then
                local have = count_owned(snapshot, ingredient.type)
                if have < need then
                    if depth >= Supplies.MAX_STEPS then
                        return nil, string.format("steps_exhausted:%s|%s", tostring(recipe_name), ingredient.type)
                    end
                    local cmd, why = plan_item(player, snapshot, state, rt, ingredient.type, depth + 1, path, nil, crafts)
                    if cmd ~= nil then return cmd, nil end
                    return nil, string.format("need_ingredient:%s:%d/%d|%s",
                        ingredient.type, have, need, tostring(why))
                end
            end
        end
    end

    -- 2) 科技门槛(与 DoRecipeClick 同一顺序)：KnowsRecipe / 已缓冲 / (可原型 + 可学)
    local knows = builder_call(builder, "KnowsRecipe", recipe) == true
    if not (buffered or knows) then
        local tech = builder_call(builder, "GetTechTrees")
        local canlearn = builder_call(builder, "CanLearn", recipe_name) == true
        if not (can_prototype(recipe.level, tech) and canlearn) then
            -- [喵喵喵]: 科技不够时的三条出路，全部有界且不绕过科技：
            --   已站在机器旁仍然不够 -> 就是这台机器等级不够，如实报 station_no_tech；
            --   附近/记忆里有原型机 -> 先导航过去（到那边 GetTechTrees 才含机器树）；
            --   一张都没有 -> 先按真实配方造一台科学机器并放下来（它自己会出现在附近）；
            --   连科学机器也造不了 -> need_station 明确收尾。
            local science = type(recipe.level) == "table" and recipe.level.SCIENCE or 0
            if science > 2 then return nil, "unsupported_tech:" .. tostring(recipe_name) end
            local station, how = nearest_station(snapshot, rt, science)
            if station ~= nil and how == "visible" and station.distance <= Supplies.STATION_RANGE then
                return nil, "station_no_tech:" .. tostring(recipe_name)
            end
            if station ~= nil and how == "remembered" and station.distance <= Supplies.STATION_RANGE then
                -- [喵喵喵]: 到达记忆位置却看不到机器时使该记忆失效，避免原地导航重置采购预算。 (2026-11-11)
                mark_stale(rt, station.key)
                station = nil
            end
            if station ~= nil then return station_nav(rt, recipe_name, station), nil end
            local prerequisite = science >= 2 and "researchlab2" or "researchlab"
            if recipe_name ~= prerequisite and depth < Supplies.MAX_STEPS then
                return plan_item(player, snapshot, state, rt, prerequisite, depth + 1, path, nil, crafts)
            end
            return nil, "need_station:" .. tostring(recipe_name)
        end
    end

    -- [喵喵喵]: 自算备料与原生 HasIngredients 不一致时(快照稍旧/背包副本差异)，以原生为准：
    -- 宁可不发，也不在“材料其实不够”时发一次注定失败的制作。
    if not buffered and builder_call(builder, "HasIngredients", recipe) == false then
        return nil, "has_ingredients_false:" .. tostring(recipe_name)
    end

    -- 3) 放置类：先有一个客户端可建的点（调用方 place 提示优先，其次环形自动找）
    if recipe.placer ~= nil then
        local use_hint = hint
        -- [喵喵喵]: 请求里的 place 只对这个“被请求物品的配方”生效；前驱里的科学机器
        -- 不能被带去同一个点（那里往往是营火/火堆的位置）。
        if use_hint == nil
            and type(rt.req) == "table"
            and CRAFT_RECIPES[rt.req.item] == recipe_name then
            use_hint = rt.req.place
        end
        local x, z, why = pick_build_point(player, snapshot, recipe, use_hint)
        if x == nil then
            return nil, string.format("no_build_spot:%s|%s", tostring(recipe_name), tostring(why))
        end
        local cmd = make_actions_command(rt, "craft|" .. tostring(recipe_name),
            "craft:" .. tostring(recipe_name), {
                kind = "craft",
                recipe = recipe_name,
                x = x,
                z = z,
                rotation = 0,
                priority = Supplies.GOAL_PRIORITY,
            })
        cmd.craft_x, cmd.craft_z = x, z
        return cmd, nil
    end

    return make_actions_command(rt, "craft|" .. tostring(recipe_name),
        "craft:" .. tostring(recipe_name), {
            kind = "craft",
            recipe = recipe_name,
            priority = Supplies.GOAL_PRIORITY,
        }), nil
end

local function choose_item_step(player, snapshot, state, rt, item, depth, path, hint, crafts)
    local dark = is_dark(snapshot) and Supplies.LIGHT_ITEMS[item] ~= true

    -- 1) 白名单配方（工具/营火等成品）
    local recipe_name = CRAFT_RECIPES[item]
    if recipe_name ~= nil then
        return plan_craft(player, snapshot, state, rt, recipe_name, depth, path, hint, crafts)
    end

    -- 1b) 生火烹饪（成品名如 berries_cooked / berries_juicy_cooked / carrot_cooked）：
    --     先备食材 → 找看得见的火(或记得的火/现造营火) → 站到动作距离内才发原生 COOK。
    --     [喵喵喵]: 必须在“地标/探索”之前：熟食不是捡来的，拿探索去碰它是错的。
    if COOK_SOURCES[item] ~= nil then
        return plan_cook(player, snapshot, state, rt, item, depth, path, dark, crafts)
    end

    -- 2) 看得见的拾取/采集
    -- [喵喵喵]: 已具备工具或其配料时，近处采掘来源可先于远处拾取；失败仍可尝试地面来源。 (2026-11-13)
    local _, working = nearest_visible_source(player, snapshot, rt, item)
    if working then
        local cmd = plan_work(player, snapshot, state, rt, item, WORK_SOURCES[item], depth, path, dark, crafts)
        if cmd ~= nil then return cmd, nil end
    end
    local cmd, why = plan_visible_pickup(player, snapshot, rt, item, dark)
    if cmd ~= nil then
        return cmd, nil
    end
    if why ~= "no_candidate" then
        return nil, why
    end

    if item == "beefalowool" then
        local command, reason = plan_wool(player, snapshot, state, rt, depth, path, crafts)
        if command ~= nil or reason ~= "no_candidate" then return command, reason end
    elseif item == "smallmeat" or item == "silk" or item == "spidergland" then
        local command, reason = plan_trapping(player, snapshot, state, rt, item, depth, path, dark, crafts)
        if command ~= nil or reason ~= "no_candidate" then return command, reason end
    elseif item == "cactus_meat" then
        for _, record in ipairs(snapshot.nearby or {}) do
            if record.prefab == "cactus" or record.prefab == "oasis_cactus" then
                if not is_finite_number(snapshot.health) or snapshot.health < 0.55 then return nil, "cactus_health_low" end
                local body = equipped_record(snapshot, "body")
                if body == nil or body.prefab ~= "armorwood" then
                    local armor = first_owned_record(snapshot, "armorwood", { inventory = true, active = true })
                    if armor then return make_actions_command(rt, "cactus:armor", "cactus:armor", {
                        kind = "inventory", action = "EQUIP", item = armor.entity,
                    }) end
                    local overflow = first_owned_record(snapshot, "armorwood", { backpack = true })
                    if overflow then return hoist_from_overflow(player, rt, "armorwood", overflow, "armor") end
                    return plan_item(player, snapshot, state, rt, "armorwood", depth + 1, path, nil, crafts)
                end
            end
        end
    end

    -- 3) 工具作业（先备工具，再动树/矿石）
    local work = WORK_SOURCES[item]
    if work ~= nil then
        local wcmd, wwhy = plan_work(player, snapshot, state, rt, item, work, depth, path, dark, crafts)
        if wcmd ~= nil then
            return wcmd, nil
        end
        if wwhy ~= "no_candidate" then
            return nil, wwhy
        end
    end

    -- 4) 地标 → 探索
    return plan_fallback(player, snapshot, state, rt, item, dark)
end

plan_item = function(player, snapshot, state, rt, item, depth, path, hint, crafts)
    depth = is_finite_number(depth) and depth or 0
    path = type(path) == "table" and path or {}
    if depth > Supplies.MAX_STEPS then return nil, "steps_exhausted:" .. tostring(item) end
    if not is_supported(item) then return nil, "unsupported_ingredient:" .. tostring(item) end
    if path[item] then return nil, "cycle:" .. tostring(item) end
    -- [喵喵喵]: 仅在递归入口维护当前栈；调用方预先标记子物品会把所有缺料误判成循环。 (2026-11-11)
    path[item] = true
    local command, reason = choose_item_step(player, snapshot, state, rt, item, depth, path, hint, crafts)
    path[item] = nil
    return command, reason
end

--------------------------------------------------------------------------
-- [喵喵喵] 对外接口一：决定下一步。绝不执行、绝不下发。
--------------------------------------------------------------------------

local function partial_stack_room(snapshot, item, candidate)
    local room = 0
    for _, record in ipairs(snapshot.inventory and snapshot.inventory.records or {}) do
        local stack = is_valid(record.entity) and record.entity.replica and record.entity.replica.stackable
        if record.prefab == item and COUNTED_KINDS[record.kind] and stack
            and stack.MaxSize ~= nil and stack.StackSize ~= nil then
            local maximum, current = stack:MaxSize(), stack:StackSize()
            if is_finite_number(maximum) and is_finite_number(current) and maximum > current and current > 0
                and (candidate.act ~= "PICKUP" or (stack.CanStackWith ~= nil and stack:CanStackWith(candidate.entity))) then
                room = math.max(room, maximum - current)
            end
        end
    end
    return room
end

-- [喵喵喵]: 只读展开当前缺口并比较近处机会，不下发命令、不切换探索目标；共享原料合并，库存取下限。 (2026-11-13)
function Supplies.NearbyRequest(player, snapshot, state, requests, primary)
    if snapshot.platform ~= nil or snapshot.ghost == true or is_dark(snapshot) then return nil end
    local builder = get_builder(player)
    local recipe = primary and get_recipe(CRAFT_RECIPES[primary.item] or primary.item)
    if recipe ~= nil and (builder_call(builder, "IsBuildBuffered", recipe.name) == true
        or (builder_call(builder, "HasIngredients", recipe) == true
            and (builder_call(builder, "KnowsRecipe", recipe) == true
                or (builder_call(builder, "CanLearn", recipe.name) == true
                    and can_prototype(recipe.level, builder_call(builder, "GetTechTrees")))))) then
        return nil
    end
    local rt = state.supplies
    if type(rt) ~= "table" or rt.world ~= world_key_of(snapshot) then
        rt = { bad = {}, stale = {}, stations = {} }
    end
    local roots, available, missing, targets = {}, {}, {}, {}
    for _, request in ipairs(requests) do
        local item = ITEM_ALIASES[request.item] or request.item
        roots[item] = math.max(roots[item] or 0, request.count)
    end
    local function owned(item)
        return count_owned(snapshot, item)
    end
    local expand
    local stations = { researchlab = roots.researchlab ~= nil, researchlab2 = roots.researchlab2 ~= nil }
    local tools = {}
    -- [喵喵喵]: 已作为根需求的科技台和工具会单独展开，其他配方只复用该份准备。 (2026-11-12)
    for _, work in pairs(WORK_SOURCES) do
        if roots[work.tool] ~= nil then tools[work.tool] = true end
    end
    expand = function(item, amount, depth, path)
        if depth > Supplies.MAX_DEPTH or path[item] then return end
        if available[item] == nil then
            available[item] = PLACED_ITEMS[item] and count_placed(snapshot, item) or owned(item)
        end
        local taken = math.min(available[item], amount)
        available[item] = available[item] - taken
        local deficit = amount - taken
        if deficit <= 0 then return end
        local recipe = get_recipe(item)
        if recipe ~= nil and CRAFT_RECIPES[item] ~= nil then
            path[item] = true
            local output = is_finite_number(recipe.numtogive) and math.max(1, recipe.numtogive) or 1
            local crafts = math.ceil(deficit / output)
            if builder_call(builder, "IsBuildBuffered", recipe.name) == true then crafts = math.max(0, crafts - 1) end
            for _, ingredient in ipairs(recipe.ingredients or {}) do
                local amount = ingredient_need(builder, ingredient)
                if amount ~= nil then expand(ingredient.type, amount * crafts, depth + 1, path) end
            end
            if crafts > 0 and builder_call(builder, "KnowsRecipe", recipe) ~= true
                and not can_prototype(recipe.level, builder_call(builder, "GetTechTrees")) then
                local science = type(recipe.level) == "table" and recipe.level.SCIENCE or 0
                if science > 0 and science <= 2 then
                    local station = science >= 2 and "researchlab2" or "researchlab"
                    if not stations[station] then
                        stations[station] = true
                        if nearest_station(snapshot, rt, science) == nil then expand(station, 1, depth + 1, path) end
                    end
                end
            end
            path[item] = nil
        elseif COOK_SOURCES[item] ~= nil then
            expand(COOK_SOURCES[item].from, deficit, depth + 1, path)
        else
            missing[item] = (missing[item] or 0) + deficit
            local work = WORK_SOURCES[item]
            if work ~= nil and owned(work.tool) < 1 and not tools[work.tool] then
                tools[work.tool] = true
                path[item] = true
                expand(work.tool, 1, depth + 1, path)
                path[item] = nil
            end
        end
    end
    local items = {}
    for item in pairs(roots) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        if CRAFT_RECIPES[item] ~= nil or COOK_SOURCES[item] ~= nil then
            expand(item, roots[item], 0, {})
        else
            targets[item] = roots[item]
            local work = WORK_SOURCES[item]
            if owned(item) < roots[item] and work ~= nil and owned(work.tool) < 1 and not tools[work.tool] then
                tools[work.tool] = true
                expand(work.tool, 1, 1, { [item] = true })
            end
        end
    end
    for item, deficit in pairs(missing) do targets[item] = math.max(targets[item] or 0, owned(item) + deficit) end
    -- [喵喵喵]: 已有原料的未满堆叠只登记顺手机会，不为补堆叠制作、烹饪或新增远行目标。 (2026-11-13)
    local topup = is_finite_number(snapshot.hunger) and snapshot.hunger > 0.35
        and is_finite_number(snapshot.health) and snapshot.health > 0.35
    if topup then
        for _, record in ipairs(snapshot.inventory and snapshot.inventory.records or {}) do
            if COUNTED_KINDS[record.kind] and record.prefab ~= "seeds" and record.prefab ~= "seeds_cooked"
                and CRAFT_RECIPES[record.prefab] == nil and COOK_SOURCES[record.prefab] == nil
                and is_supported(record.prefab) then targets[record.prefab] = targets[record.prefab] or owned(record.prefab) end
        end
    end
    items = {}
    for item in pairs(targets) do items[#items + 1] = item end
    table.sort(items)
    local best
    for _, item in ipairs(items) do
        local target = math.min(Supplies.MAX_COUNT, targets[item])
        local candidate = nearest_visible_source(player, snapshot, rt, item)
        local body = equipped_record(snapshot, "body")
        if item == "cactus_meat" and (body == nil or body.prefab ~= "armorwood") then candidate = nil end
        if candidate ~= nil then
            local stack_room = partial_stack_room(snapshot, item, candidate)
            if topup and candidate.distance <= Supplies.ACTION_RANGE then
                target = math.min(Supplies.MAX_COUNT, math.max(target, owned(item) + stack_room))
            end
            if owned(item) < target and (best == nil or candidate.distance < best.distance)
                and (inventory_full(player) ~= true or stack_room > 0) then
                best = { item = item, count = target, guid = candidate.guid, distance = candidate.distance }
            end
        end
    end
    return best
end

function Supplies.Plan(player, snapshot, state, request)
    if type(state) ~= "table" then
        return nil, "state_not_table"
    end
    if type(snapshot) ~= "table" then
        return nil, "snapshot_not_table"
    end
    if type(request) ~= "table" then
        return nil, "request_not_table"
    end
    if not is_valid(player) then
        return nil, "player_invalid"
    end
    if ThePlayer ~= nil and player ~= ThePlayer then
        return nil, "not_local_player"
    end

    local item = request.item
    if type(item) ~= "string" or item == "" then
        return nil, "request_needs_item"
    end
    -- [喵喵喵]: 把口语名( sciencemachine/alchemymachine )归一到原生真实 prefab 名。
    item = ITEM_ALIASES[item] or item
    local count = request.count
    if not is_finite_number(count) or count < 1 then
        return nil, "request_needs_positive_count"
    end
    count = math.floor(count)
    if count > Supplies.MAX_COUNT then
        count = Supplies.MAX_COUNT
    end

    local normalized = { item = item, count = count, id = request.id, place = nil }
    if type(request.place) == "table"
        and is_finite_number(request.place.x)
        and is_finite_number(request.place.z)
        and math.abs(request.place.x) <= Supplies.WORLD_LIMIT
        and math.abs(request.place.z) <= Supplies.WORLD_LIMIT then
        normalized.place = { x = request.place.x, z = request.place.z }
    elseif request.place ~= nil then
        return nil, "request_bad_place"
    end
    local rt = ensure_runtime(state, snapshot)
    local key = request_key_of(normalized)
    if rt.req_key ~= key then
        -- [喵喵喵]: 换请求时如果还有未回执的命令，绝不默默地把它的所有权记录抹掉，
        -- 否则调用方手里那条命令会变成孤儿。先让它被 Report/Cancel 掉。
        if rt.cmd ~= nil then
            return nil, "in_flight:" .. tostring(rt.cmd.purpose) .. "|request_pending_switch"
        end
        reset_request(rt, key, normalized)
    end

    -- [喵喵喵]: 单活跃控制器：上一条命令还没回执终结就只能等，绝不并发抢执行器。
    if rt.cmd ~= nil then
        return nil, "in_flight:" .. tostring(rt.cmd.purpose)
    end
    if not is_supported(item) then
        local pending = PENDING_ITEMS[item]
        if pending ~= nil then
            return nil, string.format("slice_pending:%s|kind=%s", item, pending)
        end
        return nil, "unsupported_item:" .. item
    end

    if snapshot.ready ~= true then
        return nil, "snapshot_not_ready:" .. tostring(snapshot.ready_reason)
    end
    if not is_finite_number(snapshot.x) or not is_finite_number(snapshot.z) then
        return nil, "snapshot_no_position"
    end
    -- [喵喵喵]: 放置类成品(营火/石火堆)不进背包，所以“持有量”换成“附近看得见的同 prefab 数”，
    -- 这是结构真的存在的客户端证据，不是背包计数。
    local owned, known
    if PLACED_ITEMS[item] == true then
        owned, known = count_placed(snapshot, item)
    else
        owned, known = count_owned(snapshot, item)
    end
    if not known then
        return nil, "inventory_unsettled:" .. item
    end
    if owned >= count then
        -- [喵喵喵]: 已完成采购清空时间基线；以后补同一种资源是新需求，不能继承旧截止点。 (2026-11-11)
        rt.t0 = nil
        rt.gave_up = nil
        return nil, string.format("satisfied:%s:%d/%d", item, owned, count)
    end

    if rt.gave_up ~= nil then
        return nil, string.format("gave_up:%s|%s", tostring(rt.gave_up.stage), tostring(rt.gave_up.reason))
    end

    -- [喵喵喵]: 物资路线走陆地导航；船上须先完成登岸。
    if snapshot.platform ~= nil then
        return nil, "on_platform"
    end
    if snapshot.ghost == true then
        return nil, "player_ghost"
    end

    -- [喵喵喵]: 每个 tick 把看得见的原型机位置写进有界运行期记忆(纯坐标)，
    -- 以后需要试制时就靠它导航回去；它不等于“机器还在”，到达后仍需重新观测。
    visible_stations(snapshot, rt)

    if not is_finite_number(rt.t0) then
        rt.t0 = now()
    end
    if CRAFT_RECIPES[item] == nil and COOK_SOURCES[item] == nil and inventory_full(player) == true then
        -- [喵喵喵]: 槽位用满仍可合入已有堆叠；只在没有可合并堆叠时拒绝采集。 (2026-11-11)
        local stackroom = false
        for _, record in ipairs(snapshot.inventory and snapshot.inventory.records or {}) do
            local stack = is_valid(record.entity) and record.entity.replica and record.entity.replica.stackable
            if record.prefab == item and COUNTED_KINDS[record.kind] and stack and not stack:IsFull() then
                stackroom = true
                break
            end
        end
        if not stackroom then return nil, "inventory_full:" .. item end
    end
    local elapsed = now() - rt.t0
    if elapsed > Supplies.PLAN_TIMEOUT then
        rt.gave_up = { stage = "plan", reason = "plan_timeout", t = now() }
        return nil, string.format("gave_up:plan|plan_timeout:%s|%.1f", item, elapsed)
    end

    local cmd, why = plan_item(player, snapshot, state, rt, item, 0, {}, normalized.place)
    if cmd == nil then
        return nil, why or "no_action"
    end

    rt.cmd = {
        id = cmd.id,
        via = cmd.via,
        purpose = cmd.purpose,
        stage = cmd.stage,
        target_guid = cmd.target_guid,
        target_x = cmd.target_x,
        target_z = cmd.target_z,
        landmark_key = cmd.landmark_key,
        station_key = cmd.station_key,
        explore_goal = cmd.explore_goal,
        t = now(),
        polls = 0,
    }
    return cmd, "planned:" .. tostring(cmd.purpose)
end

--------------------------------------------------------------------------
-- [喵喵喵] 对外接口二：记录执行层回执。只记账，绝不下发动作。
-- 回执必须与当前 in-flight 命令同一个 id，迟到/别人的回执一律不接受。
--------------------------------------------------------------------------

function Supplies.Report(state, command, status, reason)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    local rt = state.supplies
    if type(rt) ~= "table" then
        return false, "no_runtime"
    end
    if type(command) ~= "table" then
        return false, "command_not_table"
    end
    if command.owner ~= Supplies.OWNER then
        return false, "not_supplies_command"
    end
    local current = rt.cmd
    if type(current) ~= "table" then
        return false, "no_in_flight"
    end
    if current.id ~= command.id then
        return false, "not_current_command"
    end

    local normalized = status
    if status == "succeeded" or status == "arrived" then
        normalized = "succeeded"
    elseif status == "failed" or status == "blocked" or status == "refused" then
        normalized = "failed"
    elseif status ~= "pending" then
        return false, "bad_status:" .. tostring(status)
    end

    -- [喵喵喵]: 来自 Exploration.Next 的目标，结果要回灌给探索层(它自己按 goal.id 认)，
    -- 否则同一前沿永远不会解除阻塞计数。只回灌终态：Exploration 不接受 pending。
    local forwarded = nil
    local function forward_explore(final_status, why_text)
        if current.explore_goal == nil then
            return
        end
        local ok_f, why_f = Exploration.Report(state, current.explore_goal, final_status, why_text)
        forwarded = tostring(ok_f) .. ":" .. tostring(why_f)
    end

    rt.last = {
        id = current.id,
        via = current.via,
        status = normalized,
        reason = short_reason(reason),
        t = now(),
    }

    if normalized == "pending" then
        current.polls = (tonumber(current.polls) or 0) + 1
        local age = now() - (tonumber(current.t) or now())
        -- [喵喵喵]: pending 上限按“真实秒数”算，不按调用方轮询频率：
        -- Actions 自己的 deadline 上限是 90s，Navigation 一条长路线也可能跑很久；
        -- 轮询快不等于动作失败，绝不能因为刷新频率把一条仍然有效的动作判死。
        if age <= Supplies.MAX_PENDING_TIME and current.polls <= Supplies.MAX_POLLS then
            return true, string.format("pending_recorded:polls=%d|age=%.1f", current.polls, age)
        end
        normalized = "failed"
        reason = string.format("stalled:age=%.1f|polls=%d|%s", age, current.polls, tostring(reason))
        current.stalled = true
        rt.last.status = normalized
        rt.last.reason = short_reason(reason)
    end

    if reason ~= "preempted_for_replan" then forward_explore(normalized, reason) end

    rt.cmd = nil
    local stage = tostring(current.stage or "unknown")
    if reason == "preempted_for_replan" then
        -- [喵喵喵]: 生存抢占不是来源失败；推进操作身份，不禁用目标，不重用过期确认回调。 (2026-11-11)
        rt.ops[stage] = (tonumber(rt.ops[stage]) or 0) + 1
        return true, "terminal:cancelled|" .. stage
    end

    if normalized == "succeeded" then
        -- [喵喵喵]: 单纯到达不代表取得物资；只有真实交互进展延长采购预算，避免空地标往返无限续期。 (2026-11-12)
        if current.via == "actions" then rt.t0 = now() end
        rt.attempts[stage] = nil
        if string.sub(stage, 1, 6) == "hoist|" then rt.hoist[string.sub(stage, 7)] = nil end
        if current.landmark_key ~= nil then
            -- [喵喵喵]: 每处地标分别记到达时间，有界保留，等待后续观测确认产物。 (2026-11-12)
            rt.arrived[current.landmark_key] = now()
            trim_table(rt.arrived, Supplies.STALE_MAX)
        elseif current.station_key ~= nil then
            -- [喵喵喵]: 走到原型机旁也只是“到了”，科技够不够仍由下一次 plan_craft 的
            -- GetTechTrees/KnowsRecipe 说话；这里只记时间供诊断。
            rt.station = { key = current.station_key, t = now() }
        end
        -- [喵喵喵]: 一个目标或交互完成后推进身份；同一目标的连续挥动由执行层维持。
        if type(rt.ops) ~= "table" then
            rt.ops = {}
        end
        rt.ops[stage] = (tonumber(rt.ops[stage]) or 0) + 1
        return true, "terminal:succeeded|" .. stage
            .. (forwarded ~= nil and ("|explore=" .. forwarded) or "")
    end

    -- [喵喵喵] 失败：本请求内的重试与作废都是有界的
    --   * 点过的目标/走过的接近点：客户端已明确拒绝或目标消失，直接作废(rt.bad)
    --   * 地标：既然去不成，本请求内不再试同一处(rt.stale)
    --   * 全请求失败总量触顶：给出明确结论，绝不无限重试
    local attempts = (tonumber(rt.attempts[stage]) or 0) + 1
    rt.attempts[stage] = attempts
    rt.fail_total = (tonumber(rt.fail_total) or 0) + 1
    -- [喵喵喵]: 只有“执行层真的给了失败”才把目标作废；stalled 是我们自己的记账预算到点
    -- (见 MAX_PENDING_TIME)，不能拿它当“这个目标不可用”的证据，否则轮询一慢就会误杀。
    if current.stalled ~= true then
        if current.via == "actions" or current.landmark_key == nil then
            mark_bad(rt, current.target_guid)
        end
        if current.landmark_key ~= nil then
            mark_stale(rt, current.landmark_key)
        end
        if current.station_key ~= nil then
            -- [喵喵喵]: 去不成/到了没用的原型机，本请求内不再选同一处，避免来回跑。
            mark_stale(rt, current.station_key)
        end
    end

    local tail = forwarded ~= nil and ("|explore=" .. forwarded) or ""
    if attempts >= Supplies.MAX_ATTEMPTS or rt.fail_total >= Supplies.MAX_FAILURES then
        rt.gave_up = {
            stage = stage,
            reason = short_reason(reason),
            t = now(),
        }
        return true, string.format("gave_up:%s|%s%s", stage, short_reason(reason), tail)
    end
    return true, string.format("retry:%s#%d|%s%s", stage, attempts, short_reason(reason), tail)
end

return Supplies
