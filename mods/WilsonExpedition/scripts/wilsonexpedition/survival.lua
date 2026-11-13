-- WilsonExpedition 四季生存策略
-- [喵喵喵]: 即时安全、照明、温度、身体、基础储备、装备与季节准备、探索按优先级调度。
-- Plan(player, snapshot, state) -> command|nil, reason
-- Report(state, command, status, reason) -> ok, detail
-- Cancel(state) -> ok, detail；Progress(state) -> 纯值诊断摘要。
-- 只规划不执行；state.survival 属于运行期，原生动作结果通过唯一执行器回传。
-- [喵喵喵]: 抢占时释放旧采购命令，再根据新快照规划；不重放过期目标与确认基线。

local Observer = require('wilsonexpedition/observer')
local Actions = require('wilsonexpedition/actions')
local Navigation = require('wilsonexpedition/navigation')
local Exploration = require('wilsonexpedition/exploration')
local Sailing = require('wilsonexpedition/sailing')
local Supplies = require('wilsonexpedition/supplies')

local Survival = {}

Survival.SCHEMA_VERSION = 1
Survival.OWNER = "survival"

--------------------------------------------------------------------------
-- [喵喵喵]: 常量：全部来自被依赖模块的真实字段，取不到就用等价兜底，
-- 绝不把“读不到”变成 0/true 之类的假结论。
--------------------------------------------------------------------------
local function num_or(value, fallback)
    return type(value) == "number" and value or fallback
end

local ACTIONS_DEFAULT_PRIORITY = num_or(Actions.DEFAULT_PRIORITY, 0)
local ACTIONS_TIMEOUT_MAX = num_or(Actions.TIMEOUT_MAX, 90)
local SUPPLIES_OWNER = type(Supplies.OWNER) == "string" and Supplies.OWNER or "supplies"
local SUPPLIES_GOAL_PRIORITY = num_or(Supplies.GOAL_PRIORITY, 0)

-- [喵喵喵]: 优先级必须严格高于 Supplies 的 GOAL_PRIORITY(0) 与 Actions 默认优先级，
-- 否则 Actions 只会回 'held_by_*'，整个黑暗保护会被低优先级任务饿死。
Survival.PRIORITY_LIGHT = ACTIONS_DEFAULT_PRIORITY + 90

-- [喵喵喵]: 逃命优先级必须高于照明（即使正在点灯也要先离开伤害源）：
--   escape 96 > light 90 > Supplies GOAL_PRIORITY 0。
Survival.PRIORITY_ESCAPE = ACTIONS_DEFAULT_PRIORITY + 96

-- [喵喵喵]: 危险判据全部是“客户端真的看得见/读得到”的量：
--   IMMINENT_RADIUS 贴脸距离（原生攻击距离通常 1.5~3）；BOSS_RADIUS 首领威慑半径；
--   HP_FLEE/HP_FLEE_BOSS 受伤阈值；BURN_RADIUS 脚下火源判定半径。
Survival.IMMINENT_RADIUS = 3.5
Survival.BOSS_RADIUS = 8
Survival.HP_FLEE = 0.6
Survival.HP_FLEE_BOSS = 0.8
Survival.BURN_RADIUS = 2.5

-- [喵喵喵]: 撤退目标距离取 Navigation 自己的常量（Retreat 会按它算安全点），
-- 取不到就用它的默认值 8；BOAT_SEARCH_RADIUS 只收看得见的船。
Survival.ESCAPE_DISTANCE = num_or(Navigation.RETREAT_DISTANCE, 8)
Survival.ESCAPE_CLEARANCE = 4
-- [喵喵喵]: 视线中断不代表追击结束；按原版疯猪最长单次追击时间加余量保留当前撤退联系点，期间不读取隐藏实体。 (2026-11-13)
local THREAT_CONTACT_GRACE = 10 * math.max(1, TUNING.SPRING_COMBAT_MOD or 1.33) + 2
Survival.BOAT_SEARCH_RADIUS = num_or(Observer.NEARBY_RADIUS, 20)
Survival.SAIL_BOARD_RANGE = (type(Sailing.DEFAULT_RANGE) == "table" and num_or(Sailing.DEFAULT_RANGE.board, 1.0)) or 1.0

-- [喵喵喵]: 被挂起的 Supplies 命令最长保留秒数；超时就走显式取消（转发回 Supplies）。
Survival.SUSPEND_TTL = 120

-- [喵喵喵]: 身体/饥饿/装备片（本 pass）的优先级：
--   escape 96 > light 90 > heal 86 > starve 84 > eat 60 > equip 52 > reserve 20 > explore 8。
-- 食物/治疗必须能打断囤货与探索，但不得抢在淋黑/活命之前。
Survival.PRIORITY_HEAL = ACTIONS_DEFAULT_PRIORITY + 86
Survival.PRIORITY_STARVE = ACTIONS_DEFAULT_PRIORITY + 84
Survival.PRIORITY_EAT = ACTIONS_DEFAULT_PRIORITY + 60
Survival.PRIORITY_EQUIP = ACTIONS_DEFAULT_PRIORITY + 52
Survival.PRIORITY_STOCK = ACTIONS_DEFAULT_PRIORITY + 36
Survival.PRIORITY_RESERVE = ACTIONS_DEFAULT_PRIORITY + 20
Survival.PRIORITY_EXPLORE = ACTIONS_DEFAULT_PRIORITY + 8

-- [喵喵喵]: 环境片（寒冷/过热/淋湿）夹在照明与身体之间：
--   escape 96 > light 90 > env 87 > heal 86 > starve 84 > eat 60 > equip 52 > reserve 20。
Survival.PRIORITY_ENV = ACTIONS_DEFAULT_PRIORITY + 87

-- [喵喵喵]: 温度阈值来自原生 components/temperature.lua：伤害发生在 current < 0 与
-- current > TUNING.OVERHEAT_TEMP(70) 时（temperature.lua:519-521）。这里把“已经开始
-- 掉血的线”和“快到了的预警线”分开，只在真的危险时抢动作。
Survival.COLD_CRITICAL = 0
Survival.COLD_WARN = 8
-- [喵喵喵]: TUNING 是原生全局表；此处不能调后面才声明的局部函数（is_finite_number/tune），
-- 所以就地只用 type 判型取值，取不到用原生默认 70（tuning.lua:2301）。
local OVERHEAT_NATIVE = 70
if type(TUNING) == "table" and type(TUNING.OVERHEAT_TEMP) == "number" then
    OVERHEAT_NATIVE = TUNING.OVERHEAT_TEMP
end
Survival.HOT_CRITICAL = OVERHEAT_NATIVE
Survival.HOT_WARN = Survival.HOT_CRITICAL - 10

-- [喵喵喵]: 潮湿阈值：0..1 比例（Observer 用 moisture/maxmoisture 算）；
-- 只是“很湿”就记录并优先靠火；不自己造烘干手段。
Survival.WET_CRITICAL = 0.75

-- [喵喵喵]: 烘火/降温/加燃料的距离与半径：
--   FIRE_SEEK_RADIUS 只在 snapshot.nearby(20) 内找看得见的火；
--   FIRE_WARM_DIST 到了这个距离就算“在火边”（Actions 的交互距离 2.5 之内）；
--   ADDFUEL_RADIUS 是“能走过去加柴”的可达半径。
Survival.FIRE_SEEK_RADIUS = num_or(Observer.NEARBY_RADIUS, 20)
Survival.FIRE_WARM_DIST = 2.5
Survival.ADDFUEL_RADIUS = 6

-- [喵喵喵]: 可当燃料的原生物品（prefabs/*.lua 均带 "fuel" 标签 + componentactions 的
-- fuel 收集器；这里只拿 Supplies 真能弄到的几种做 ADDFUEL）。
local FUEL_PREFABS = {
    log = true,
    twigs = true,
    cutgrass = true,
    charcoal = true,
}

-- [喵喵喵]: 运行期小表的硬上限：attempts/softn 按 key 增长，70 天里可能积很多 guid 键，
-- 超过上限就淘汰数值最小的（重试计数最少的），保证内存有界。
Survival.KEY_MAP_MAX = 128

-- [喵喵喵]: 四季/装备/基地层级（低于身体片，高于普通囤货与探索）：
--   ... > vitals(eat 60/equip 52) > gear 34 > season 30 > reserve 20 > base 16 > explore 8。
Survival.PRIORITY_GEAR = ACTIONS_DEFAULT_PRIORITY + 34
Survival.PRIORITY_SEASON = ACTIONS_DEFAULT_PRIORITY + 30
Survival.PRIORITY_BASE = ACTIONS_DEFAULT_PRIORITY + 16

-- [喵喵喵]: 冬季燃料备量（火堆吃柴，烧一次就要再补）、湿了才换雨具的阀值、
-- 以及基地锚点/回营的距离参数。
Survival.WINTER_LOG_RESERVE = 8
Survival.WET_EQUIP = 0.30
Survival.BASE_MIN_SAFE = 10
Survival.BASE_FIRE_RADIUS = 12
Survival.BASE_ANCHOR_TOL = 6
Survival.BASE_RETURN_DIST = 30
Survival.BASE_RETURN_PROGRESS = 0.92

-- [喵喵喵]: 猎犬群：看得见的猎犬达到这一数量且贴得这么近，就不再当“普通怪”放着，
-- 而是找路后退（本阶段没有战斗控制器，绝不假装能打）。
Survival.HOUND_RADIUS = 8
Survival.HOUND_PACK_MIN = 2

-- [喵喵喵]: 原生 prefab 名（observer 的 THREAT_PREFABS 同口径）。
local HOUND_PREFABS = { hound = true, firehound = true, icehound = true }

-- [喵喵喵]: 四季准备清单：每项都是本阶段 Supplies 真能做的原生配方（见 supplies.lua）：
--   winter: firepit(log2+rocks12, TECH.NONE) 稳定热源；log 是原生燃料(BURNABLE)；
--   spring: grass_umbrella(防水 MED) + strawhat(头部小雨伞+夏季隔热) + lightning_rod(防雷击失火)；
--   summer: minifan(装备时 endothermic 降温) + strawhat(隔热)；
--   autumn: 不列特别项，沿用基础囤货（食物/火把/草甲/长矛）。
local SEASON_PLAN = {
    autumn = {
        { item = "researchlab2", count = 1, key = "season:autumn:alchemy" },
        { item = "heatrock", count = 1, key = "season:autumn:heatrock" },
        { item = "firepit", count = 1, key = "season:autumn:firepit" },
        { item = "log", count = Survival.WINTER_LOG_RESERVE, key = "season:autumn:log" },
    },
    winter = {
        { item = "firepit", count = 1, key = "season:winter:firepit" },
        { item = "heatrock", count = 1, key = "season:winter:heatrock" },
        { item = "log", count = Survival.WINTER_LOG_RESERVE, key = "season:winter:log" },
        { item = "winterhat", count = 1, key = "season:winter:hat" },
    },
    spring = {
        { item = "grass_umbrella", count = 1, key = "season:spring:umbrella" },
        { item = "strawhat", count = 1, key = "season:spring:strawhat" },
        { item = "lightning_rod", count = 1, key = "season:spring:rod" },
    },
    summer = {
        { item = "coldfirepit", count = 1, key = "season:summer:coldfirepit" },
        { item = "heatrock", count = 1, key = "season:summer:heatrock" },
        { item = "log", count = Survival.WINTER_LOG_RESERVE, key = "season:summer:log" },
        { item = "minifan", count = 1, key = "season:summer:minifan" },
        { item = "strawhat", count = 1, key = "season:summer:strawhat" },
    },
}

-- [喵喵喵]: 季节本身只用原生世界状态快照（TheWorld.state.season/seasonprogress），
-- 不读主机时间、不看存档天数。读不到就是 nil（未知），不猜。
local SEASONS = { autumn = true, winter = true, spring = true, summer = true }
local function read_season(snapshot)
    local season = type(snapshot) == "table" and snapshot.season or nil
    if type(season) == "string" and SEASONS[season] == true then
        return season
    end
    return nil
end

-- [喵喵喵]: 阈值（health/hunger/sanity 都是 Observer 快照里的 0..1 百分比）：
--   血量危重 0.30；饥饿 0.10 以下算饥荒、0.35 以下该吃；0.95 以上不吃（原生也会拒）；
--   理智 0.30 以下只记录（本片没有可用的原生手段）。
Survival.HP_CRITICAL = 0.30
Survival.HUNGER_STARVE = 0.10
Survival.HUNGER_EAT = 0.35
Survival.HUNGER_FULL = 0.95
Survival.SANITY_LOW = 0.30

-- [喵喵喵]: 装备/囤货阈值：威胁这么近才值得戴甲/拿武器（否则只为囤货而不扰动作）。
--   TORCH_RESERVE/FOOD_RESERVE/COOK_RESERVE/ARMOR_RESERVE 都是“存多少才安心”。
Survival.ARMOR_RADIUS = 6
Survival.TORCH_RESERVE = 2
Survival.FOOD_RESERVE = 4
local FOOD_REFILL_TARGET = 8
-- [喵喵喵]: 低水位触发后补到一批目标量，避免每消耗一份就重新跑采购；均不超过原版一组。 (2026-11-12)
local MATERIAL_STOCK = {
    { item = "cutgrass", low = 8, target = 20 },
    { item = "twigs", low = 8, target = 20 },
    { item = "flint", low = 4, target = 8 },
    { item = "log", low = 6, target = 12 },
}
Survival.COOK_RESERVE = 2
Survival.ARMOR_RESERVE = 1

-- [喵喵喵]: 光照阈值只用于日志/原因里复述观测口径，判暗仍然只看 Observer 的 dark 字段。
Survival.LIGHT_THRESHOLD = num_or(Observer.LIGHT_THRESHOLD, 0.1)

-- [喵喵喵]: 有界等待：超过它还没收到终态回执，就把“命令还挂着”明确收掉并把
-- 取消结果转发回原策略，避免永久 in_flight 阻塞后续规划。
Survival.MAX_HOLD = ACTIONS_TIMEOUT_MAX + 60
Survival.MAX_POLLS = 1200

-- [喵喵喵]: 同一步的逻辑重试上限与作废冷却；触顶/冷却期内换下一条可达请求。
Survival.STEP_FAIL_LIMIT = 3
Survival.BLOCK_TTL = 90
Survival.BLOCK_MAX = 16
-- [喵喵喵]: “软”冷却：Supplies 只是此刻做不了（need_fire/in_flight 等软原因）时
-- 短暂让路给下一条储备请求；同一个 key 软挡满 STEP_FAIL_LIMIT 次就转成硬冷却。
Survival.SOFT_BLOCK_TTL = 8

-- [喵喵喵]: 按原版时钟的剩余秒数留出装备时间；储备火把不等于提前点燃。 (2026-11-12)
Survival.LIGHT_EQUIP_LEAD = 5

Survival.REQUEST_TORCH = "torch"
Survival.REQUEST_CAMPFIRE = "campfire"
Survival.REQUEST_COUNT = 1

-- [喵喵喵]: 真实光源 prefab 与真实装备槽：
--   torch   prefabs/torch.lua:428 AddTag("torch") + 452 AddComponent("equippable")
--           （原生 equippable.lua:26 缺省 equipslot=EQUIPSLOTS.HANDS）
--   lantern prefabs/mininglantern.lua:302 Prefab("lantern")（手持）
--   minerhat 原生 prefab 名 minerhat（头戴）
-- 只列这三样：其余“看起来会亮”的东西没有装备槽证据，不猜。
Survival.HAND_LIGHT = { torch = true, lantern = true }
Survival.HEAD_LIGHT = { minerhat = true }
Survival.LIGHT_PREFERENCE = { "torch", "lantern", "minerhat" }

-- [喵喵喵]: 只有这几种来源算“随身可点”：世界容器(箱子)里的光源不算，
-- 因为拿不到就等于点不了（同 Supplies 的 COUNTED_KINDS 口径）。
Survival.CARRIED_KINDS = {
    inventory = true,
    active = true,
    equipment = true,
    backpack = true,
}

-- [喵喵喵]: 能直接走“点背包栏”这条路的主栏来源；溢出背包只能兜底尝试
-- (原生 components/inventory.lua:2259 CanAccessItem 要求 owner 是本人或已打开的容器)。
local MAIN_KINDS = { inventory = true, active = true }

--------------------------------------------------------------------------
-- [喵喵喵] 小工具：只用原生全局或纯 Lua；读不到一律 nil（未知），不造值。
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

local function short(text, limit)
    local out = tostring(text)
    local max = is_finite_number(limit) and limit or 96
    if #out <= max then
        return out
    end
    return string.sub(out, 1, max)
end

-- [喵喵喵]: 原因串的“信息量”过滤：light_ok 只表示“光照这一项没事”，
-- 不能把它当成整轮结论盖掉环境/身体的真实缺口（如 wet:0.90）。
local function informative_reason(text)
    if type(text) ~= "string" then
        return nil
    end
    if string.sub(text, 1, 8) == "light_ok" then
        return nil
    end
    return text
end

-- [喵喵喵]: 装备槽键来自原生 constants.lua:654 EQUIPSLOTS；模块加载时机不保证
-- constants 已经跑过，所以每次现取，取不到再用原生字面值。
local function equip_slots()
    local hands = type(EQUIPSLOTS) == "table" and EQUIPSLOTS.HANDS or "hands"
    local head = type(EQUIPSLOTS) == "table" and EQUIPSLOTS.HEAD or "head"
    local body = type(EQUIPSLOTS) == "table" and EQUIPSLOTS.BODY or "body"
    return hands, head, body
end

local function equipment_prefab(snapshot, slot)
    local equipment = type(snapshot) == "table" and snapshot.equipment or nil
    if type(equipment) ~= "table" then
        return nil
    end
    local record = equipment[slot]
    if type(record) == "table" and type(record.prefab) == "string" then
        return record.prefab, record
    end
    return nil
end

local function world_key_of(snapshot)
    local session = type(snapshot.session) == "string" and snapshot.session or nil
    if session == nil and TheWorld ~= nil then
        session = "guid|" .. tostring(TheWorld.GUID)
    end
    local shard = type(snapshot.shard) == "string" and snapshot.shard or "-"
    return tostring(session) .. "|" .. shard
end

--------------------------------------------------------------------------
-- [喵喵喵] 持有物读取：只用 Observer 快照里的真实记录，不自己扫世界。
--   snapshot.inventory.records[] = { item, entity, guid, prefab, count, slot,
--                                    container, kind }
--   kind: inventory(主栏) / equipment(装备槽) / backpack(溢出背包) /
--         active(手持) / container(打开的世界容器)
--------------------------------------------------------------------------

local function carried_records(snapshot)
    local inventory = type(snapshot) == "table" and snapshot.inventory or nil
    local records = type(inventory) == "table" and inventory.records or nil
    if type(records) ~= "table" then
        return nil
    end
    return records
end

-- [喵喵喵]: 按偏好找一件“随身、可点”的光源；主栏优先，溢出背包只在没有主栏候选时兜底。
local function find_owned_light(snapshot)
    local records = carried_records(snapshot)
    if records == nil then
        return nil, "inventory_unreadable"
    end
    local fallback = nil
    for i = 1, #Survival.LIGHT_PREFERENCE do
        local prefab = Survival.LIGHT_PREFERENCE[i]
        for j = 1, #records do
            local record = records[j]
            if type(record) == "table"
                and record.prefab == prefab
                and is_valid(record.entity) and not record.entity:HasTag("fueldepleted")
                and Survival.CARRIED_KINDS[record.kind] == true then
                if MAIN_KINDS[record.kind] == true then
                    return record, nil
                end
                if fallback == nil then
                    fallback = record
                end
            end
        end
    end
    if fallback ~= nil then
        return fallback, "in_overflow_only"
    end
    return nil, "no_light_item"
end

-- [喵喵喵]: 已经戴在身上的光源：只认真实装备槽里那个 prefab，不做“看起来像”的推断。
local function equipped_light(snapshot)
    local hands_slot, head_slot = equip_slots()
    for _, slot in ipairs({ hands_slot, head_slot }) do
        local prefab, record = equipment_prefab(snapshot, slot)
        if record ~= nil and (Survival.HAND_LIGHT[prefab] or Survival.HEAD_LIGHT[prefab])
            and is_valid(record.entity) and not record.entity:HasTag("fueldepleted") then
            return prefab, slot
        end
    end
    return nil, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 食物/治疗/护甲的真实数值表：
--   营养价值一律从原生 tuning.lua 的卡路里/治疗常量现取（prefabs/veggies.lua 的
--   MakeVegStats 就是拿这同一批常量算熟与生）：
--     berries       : CALORIES_TINY / 0            (veg ees.lua berries)
--     berries_cooked: CALORIES_SMALL / HEALING_TINY
--     berries_juicy : CALORIES_SMALL / HEALING_TINY
--     berries_juicy_cooked: CALORIES_MEDSMALL / HEALING_SMALL
--     carrot        : CALORIES_SMALL / HEALING_TINY
--     carrot_cooked : CALORIES_SMALL / HEALING_SMALL
--   只列这六种 Supplies 真能弄到的安全食物：怪物肉/陈旧食物之类一律不入口
--   （不在表里的 prefab 永远不会被选为进食目标）。
--------------------------------------------------------------------------

local function tune(name, fallback)
    if type(TUNING) == "table" and is_finite_number(TUNING[name]) then
        return TUNING[name]
    end
    return fallback
end

local CAL_TINY = tune("CALORIES_TINY", 9.375)
local CAL_SMALL = tune("CALORIES_SMALL", 12.5)
local CAL_MEDSMALL = tune("CALORIES_MEDSMALL", 18.75)
local HEAL_TINY = tune("HEALING_TINY", 1)
local HEAL_SMALL = tune("HEALING_SMALL", 3)

local FOODS = {}
local FOOD_ORDER = {}
local function add_food(prefab, hunger, health, rank, sanity)
    FOODS[prefab] = { prefab = prefab, hunger = hunger, health = health, rank = rank, sanity = sanity or 0 }
    FOOD_ORDER[#FOOD_ORDER + 1] = prefab
end
-- [喵喵喵]: rank 只用于“饿了先吃哪个”的排序（熟食优先，同分比治疗值）。
add_food("berries_juicy_cooked", CAL_MEDSMALL, HEAL_SMALL, 1)
add_food("berries_cooked", CAL_SMALL, HEAL_TINY, 2)
add_food("carrot_cooked", CAL_SMALL, HEAL_SMALL, 2)
add_food("berries_juicy", CAL_SMALL, HEAL_TINY, 3)
add_food("carrot", CAL_SMALL, HEAL_TINY, 3)
add_food("berries", CAL_TINY, 0, 4)
add_food("cave_banana", CAL_SMALL, HEAL_TINY, 3)
add_food("cave_banana_cooked", CAL_SMALL, HEAL_SMALL, 2)
add_food("cactus_meat_cooked", CAL_SMALL, HEAL_TINY, 1, tune("SANITY_MED", 15))
add_food("cookedmeat", tune("CALORIES_MED", 25), HEAL_SMALL, 1)
add_food("cookedsmallmeat", CAL_SMALL, HEAL_TINY, 2)
-- [喵喵喵]: 熟绿菇用于理智恢复；微量扣血由健康阈值约束，不作为饥饿或治疗食物。
add_food("green_cap_cooked", 0, -HEAL_TINY, 9, tune("SANITY_MED", 15))

-- [喵喵喵]: 生 -> 熟的原生对应（各 prefab 的 cookable.product，Supplies 的 COOK
-- 请求也认这三个产品名）。
local RAW_TO_COOKED = {
    { raw = "berries_juicy", product = "berries_juicy_cooked" },
    { raw = "berries", product = "berries_cooked" },
    { raw = "carrot", product = "carrot_cooked" },
    { raw = "cactus_meat", product = "cactus_meat_cooked" },
    { raw = "cave_banana", product = "cave_banana_cooked" },
    { raw = "smallmeat", product = "cookedsmallmeat" },
    { raw = "meat", product = "cookedmeat" },
}

-- [喵喵喵]: 治疗类物品：原生 componentactions.lua 的 INVENTORY healer 收集器
-- （doer.replica.health:CanHeal() 且物品带 healer 组件）才会给出 ACTIONS.HEAL。
-- 这里只列原生带 healer 组件的真实 prefab；本文件不自己算治愈量。
local HEAL_ITEMS = {
    healingsalve = true,
    bandage = true,
    spidergland = true,
}

-- [喵喵喵]: 护甲只用于“是否需要戴起来”的排序；吸收率同样从原生 tuning 常量现取
-- (ARMORWOOD_ABSORPTION = prefabs/armor_wood.lua 的 InitCondition 第二个参数)。
local ARMORS = {}
local ARMOR_ORDER = {}
local function add_armor(prefab, absorb_key, fallback)
    ARMORS[prefab] = { prefab = prefab, absorb = tune(absorb_key, fallback) }
    ARMOR_ORDER[#ARMOR_ORDER + 1] = prefab
end
add_armor("armormarble", "ARMORMARBLE_ABSORPTION", 0.95)
add_armor("armorwood", "ARMORWOOD_ABSORPTION", 0.8)
add_armor("footballhat", "ARMOR_FOOTBALLHAT_ABSORPTION", 0.8)
add_armor("armorgrass", "ARMORGRASS_ABSORPTION", 0.6)

-- [喵喵喵]: 近身武器：本片只认 Supplies 真能造的长矛（prefabs/spear.lua）。
local WEAPONS = { spear = true }

-- [喵喵喵]: 食物储备的请求顺序：都是 Supplies 支持的可再生项，前面的不行就换下一个。
local FOOD_FALLBACK = { "berries", "carrot", "berries_juicy", "cactus_meat_cooked", "cave_banana", "cookedsmallmeat" }
local FOOD_SOURCES = {
    berrybush = "berries", berrybush2 = "berries", carrot_planted = "carrot", berrybush_juicy = "berries_juicy",
    cactus = "cactus_meat_cooked", oasis_cactus = "cactus_meat_cooked",
    cave_banana_tree = "cave_banana", rabbithole = "cookedsmallmeat",
}

-- [喵喵喵]: 随身持有量（主栏/手持/装备槽/溢出背包）；世界容器里的不算。
local function count_owned(snapshot, prefab)
    if type(prefab) ~= "string" then
        return nil
    end
    local records = carried_records(snapshot)
    if records == nil then
        return nil
    end
    local total = 0
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table"
            and record.prefab == prefab
            and Survival.CARRIED_KINDS[record.kind] == true then
            total = total + (is_finite_number(record.count) and record.count or 1)
        end
    end
    return total
end

local function food_freshness(item)
    local inventoryitem = item ~= nil and item.replica ~= nil and item.replica.inventoryitem or nil
    local classified = inventoryitem ~= nil and inventoryitem.classified or nil
    if classified == nil or classified.perish == nil then return nil end
    local ok, remaining = pcall(function() return classified.perish:value() end)
    -- [喵喵喵]: 原生perish的0..62可读，63表示未知；未知值不能当成新鲜或即将腐坏。 (2026-11-13)
    return ok and is_finite_number(remaining) and remaining >= 0 and remaining <= 62 and remaining / 62 or nil
end

local function food_is_fresh(item)
    local freshness = food_freshness(item)
    return freshness ~= nil and freshness > tune("PERISH_FRESH", 0.5)
end

local function edible_food(record)
    local food, freshness = FOODS[record.prefab], food_freshness(record.entity)
    if food == nil or food.hunger <= 0 or food.health < 0 or freshness == nil
        or freshness <= tune("PERISH_STALE", 0.2) then return nil end
    if freshness <= tune("PERISH_FRESH", 0.5) then
        -- [喵喵喵]: 陈旧但未腐坏的安全食物仍可吃，使用原版衰减值，不按新鲜营养估计饱食缺口。 (2026-11-13)
        food = { prefab = food.prefab, rank = food.rank, sanity = 0,
            hunger = food.hunger * tune("STALE_FOOD_HUNGER", 0.667),
            health = food.health * tune("STALE_FOOD_HEALTH", 0.333) }
    end
    return food, freshness
end

local function count_food_total(snapshot)
    local records = carried_records(snapshot)
    if records == nil then
        return nil
    end
    local total = 0
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table"
            and FOODS[record.prefab] ~= nil and FOODS[record.prefab].hunger > 0
            and food_is_fresh(record.entity)
            and Survival.CARRIED_KINDS[record.kind] == true then
            total = total + (is_finite_number(record.count) and record.count or 1) * FOODS[record.prefab].hunger / CAL_SMALL
        end
    end
    return total
end

-- [喵喵喵]: 选一作食物：prefer_health=true 时先看治疗值（重伤时），否则先看饱食度；
-- 主栏优先，溢出背包只当兜底（原生 CanAccessItem 会做最终校验）。
local function pick_food_record(snapshot, prefer_health)
    local records = carried_records(snapshot)
    if records == nil then
        return nil, nil, "inventory_unreadable"
    end
    local best, best_food, best_score, best_main = nil, nil, nil, nil
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table" and is_valid(record.entity) then
            local entry = edible_food(record)
            if entry ~= nil and Survival.CARRIED_KINDS[record.kind] == true then
                local score
                if prefer_health then
                    score = entry.health * 100 + entry.hunger - entry.rank
                else
                    score = entry.hunger * 100 - entry.rank
                end
                local main = MAIN_KINDS[record.kind] == true
                local better = false
                if best == nil then
                    better = true
                elseif main ~= best_main then
                    better = main == true
                elseif score > best_score then
                    better = true
                end
                if better then
                    best, best_food, best_score, best_main = record, entry, score, main
                end
            end
        end
    end
    if best == nil then
        return nil, nil, "no_edible_owned"
    end
    return best, best_food, nil
end

-- [喵喵喵]: 在一个“prefab 名 -> true”的集合里找一件随身物品（不分槽位）。
local function find_owned_prefab(snapshot, set)
    local records = carried_records(snapshot)
    if records == nil then
        return nil, "inventory_unreadable"
    end
    local fallback = nil
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table"
            and is_valid(record.entity)
            and set[record.prefab] == true
            and Survival.CARRIED_KINDS[record.kind] == true then
            if MAIN_KINDS[record.kind] == true then
                return record, nil
            end
            if fallback == nil then
                fallback = record
            end
        end
    end
    if fallback ~= nil then
        return fallback, "in_overflow_only"
    end
    return nil, "not_owned"
end

-- [喵喵喵]: 装备槽只认原生 equippable 复制品（REPLICATABLE_COMPONENTS 里就有它），
-- EquipSlot() 客户端可读；读不到就是未知，绝不按 prefab 名推测槽位。
local function slot_of(item)
    local replica = item ~= nil and item.replica or nil
    local equippable = type(replica) == "table" and replica.equippable or nil
    if equippable == nil or equippable.EquipSlot == nil then
        return nil
    end
    local ok, slot = pcall(function()
        return equippable:EquipSlot()
    end)
    if ok and type(slot) == "string" and slot ~= "" then
        return slot
    end
    return nil
end

-- [喵喵喵]: 指定槽位上最好的一件护甲（吸收率高者优先）；槽位必须由 EquipSlot() 证实。
local function pick_armor_record(snapshot, slot_name)
    local records = carried_records(snapshot)
    if records == nil then
        return nil, "inventory_unreadable"
    end
    local best, best_absorb, best_main = nil, nil, nil
    for i = 1, #records do
        local record = records[i]
        if type(record) == "table"
            and is_valid(record.entity)
            and ARMORS[record.prefab] ~= nil
            and Survival.CARRIED_KINDS[record.kind] == true then
            local slot = slot_of(record.entity)
            if slot == slot_name then
                local absorb = ARMORS[record.prefab].absorb
                local main = MAIN_KINDS[record.kind] == true
                local better = false
                if best == nil then
                    better = true
                elseif main ~= best_main then
                    better = main == true
                elseif absorb > best_absorb then
                    better = true
                end
                if better then
                    best, best_absorb, best_main = record, absorb, main
                end
            end
        end
    end
    if best == nil then
        return nil, "no_armor_for_slot"
    end
    return best, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 光照/相位判定：dark 只用观测值；读不到就保持未知。
-- 返回 "lit" / "dark" / nil + 原因。
--------------------------------------------------------------------------

local function read_light(snapshot)
    local light = type(snapshot) == "table" and snapshot.light or nil
    if type(light) ~= "table" then
        return nil, "light_missing"
    end
    if light.available ~= true then
        return nil, "light_unavailable"
    end
    if light.dark == true then
        return "dark", nil
    end
    if light.dark == false then
        return "lit", nil
    end
    return nil, "light_dark_unknown"
end

local function read_phase(snapshot)
    local phase = type(snapshot) == "table" and snapshot.phase or nil
    if type(phase) == "string" and phase ~= "" then
        return phase
    end
    return nil
end

-- [喵喵喵]: 光照读数摘要，只用于原因串，便于事后解释“当时看到的是什么”。
local function light_brief(snapshot)
    local light = type(snapshot) == "table" and snapshot.light or nil
    if type(light) ~= "table" then
        return "light=none"
    end
    return string.format("light=%s|level=%s|th=%.2f",
        tostring(light.dark == true and "dark" or (light.available == true and "lit" or "unknown")),
        tostring(light.level),
        Survival.LIGHT_THRESHOLD)
end

--------------------------------------------------------------------------
-- [喵喵喵] 危险观测（即时脱离用）：只读客户端可见的位置/状态/副本，读不到就是未知。
--   坐标与威胁来自 Observer 快照（FindEntities + 威胁标签）；
--   “正在被烧”来自原生健康副本的 istakingfiredamage（客户端可见的 classified 值）；
--   “是不是在水里”来自 TheWorld.Map:IsOceanAtPoint 的单点查询（与 Sailing 同口径，
--   不传 allow_boats，所以船面也算水面，必须再叠 platform==nil 才算落水）。
--------------------------------------------------------------------------

local function map_is_ocean(x, z)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, "bad_coordinates"
    end
    local map = TheWorld ~= nil and TheWorld.Map or nil
    if map == nil or map.IsOceanAtPoint == nil then
        return nil, "map_unsupported"
    end
    local ok, ocean = pcall(function()
        return map:IsOceanAtPoint(x, 0, z)
    end)
    if not ok then
        return nil, "map_error"
    end
    if type(ocean) ~= "boolean" then
        return nil, "map_unreadable"
    end
    return ocean, nil
end

-- [喵喵喵]: 看得见的火源：burnable.lua:13 在点燃时 AddTag("fire")，所以标签就是
-- 客户端可见证据；只收 BURN_RADIUS 之内的，作为 Retreat 的“要避开的东西”。
local function burning_hazards(snapshot, radius)
    local nearby = type(snapshot) == "table" and snapshot.nearby or nil
    if type(nearby) ~= "table" then
        return nil, "nearby_unreadable"
    end
    local limit = is_finite_number(radius) and radius or Survival.BURN_RADIUS
    local list = {}
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and is_finite_number(record.x)
            and is_finite_number(record.z)
            and is_valid(record.entity)
            and record.entity.HasTag ~= nil then
            local ok, flag = pcall(function()
                return record.entity:HasTag("fire")
            end)
            if ok and flag == true then
                local d = is_finite_number(record.distance) and record.distance
                    or math.sqrt((record.x - snapshot.x) ^ 2 + (record.z - snapshot.z) ^ 2)
                if d <= limit then
                    list[#list + 1] = record
                end
            end
        end
    end
    return list, nil
end

-- [喵喵喵]: 看得见的、正在烧的火（烘火/降温都用它），返回最近的一条。
local COLD_FIRES = { coldfire = true, coldfirepit = true, coldfirefire = true }
local CAMP_FIRES = { campfire = true, firepit = true, campfirefire = true, coldfire = true, coldfirepit = true, coldfirefire = true }

local function nearest_burning(snapshot, radius, cooling)
    local fires, why = burning_hazards(snapshot, radius)
    if fires == nil then
        return nil, why
    end
    local best = nil
    for i = 1, #fires do
        local record = fires[i]
        local d = is_finite_number(record.distance) and record.distance
            or math.sqrt((record.x - snapshot.x) ^ 2 + (record.z - snapshot.z) ^ 2)
        if CAMP_FIRES[record.prefab] and (COLD_FIRES[record.prefab] == true) == (cooling == true)
            and (best == nil or d < best.distance) then
            best = { record = record, distance = d }
        end
    end
    if best == nil then
        return nil, "no_visible_fire"
    end
    return best, nil
end

-- [喵喵喵]: 看得见的“烧光了的石火堆”：只有 firepit 熄灭后还留在世界里，
-- 才能用原生 ADDFUEL 重新点着（营火烧完会 ErodeAway，没有任何加柴机会）。
local function nearest_out_firepit(snapshot, radius, cooling)
    local nearby = type(snapshot) == "table" and snapshot.nearby or nil
    if type(nearby) ~= "table" then
        return nil, "nearby_unreadable"
    end
    local limit = is_finite_number(radius) and radius or Survival.ADDFUEL_RADIUS
    local best = nil
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and record.prefab == (cooling and "coldfirepit" or "firepit")
            and is_finite_number(record.x)
            and is_finite_number(record.z)
            and is_valid(record.entity)
            and record.entity.HasTag ~= nil then
            local ok, burning = pcall(function()
                return record.entity:HasTag("fire")
            end)
            local okb, burnt = pcall(function()
                return record.entity:HasTag("burnt")
            end)
            if ok and burning == false and not (okb and burnt == true) then
                local d = is_finite_number(record.distance) and record.distance
                    or math.sqrt((record.x - snapshot.x) ^ 2 + (record.z - snapshot.z) ^ 2)
                if d <= limit and (best == nil or d < best.distance) then
                    best = { record = record, distance = d }
                end
            end
        end
    end
    if best == nil then
        return nil, "no_out_firepit"
    end
    return best, nil
end

-- [喵喵喵]: “正在被烧”只给 true/false/nil(未知)：replica 读不到时再用看得见的
-- 燃烧实体作退路；两者都没有就是未知，绝不当作安全。
local function read_on_fire(player, snapshot)
    local replica = player ~= nil and player.replica or nil
    local health = type(replica) == "table" and replica.health or nil
    if health ~= nil and health.IsTakingFireDamage ~= nil then
        local ok, flag = pcall(function()
            return health:IsTakingFireDamage()
        end)
        if ok and type(flag) == "boolean" then
            return flag, "health_replica"
        end
    end
    local hazards = burning_hazards(snapshot, Survival.BURN_RADIUS)
    for _, record in ipairs(hazards or {}) do
        if not CAMP_FIRES[record.prefab] then return true, "visible_burning_entity" end
    end
    return nil, (hazards == nil) and "nearby_unreadable" or "fire_state_unknown"
end

-- [喵喵喵]: 最近的可见威胁（只用快照里的威胁坐标）；返回 nil + 原因时区分
-- “读不到”与“确实没有威胁”这两种完全不同的结论。
local function nearest_threat(snapshot)
    local threats = type(snapshot) == "table" and snapshot.threats or nil
    if type(threats) ~= "table" then
        return nil, "threats_unreadable"
    end
    local best = nil
    for i = 1, #threats do
        local record = threats[i]
        if type(record) == "table" and is_finite_number(record.x) and is_finite_number(record.z) then
            local d = is_finite_number(record.distance) and record.distance
                or math.sqrt((record.x - snapshot.x) ^ 2 + (record.z - snapshot.z) ^ 2)
            if best == nil or d < best.distance then
                best = { record = record, distance = d }
            end
        end
    end
    if best == nil then
        return nil, "no_threat"
    end
    return best, nil
end

-- [喵喵喵]: 数一数某类威胁在这么近的地方有几只（同 prefab 白名单，只看快照里可见的）。
local function count_threat_prefabs(snapshot, set, radius)
    local threats = type(snapshot) == "table" and snapshot.threats or nil
    if type(threats) ~= "table" then
        return nil
    end
    local limit = is_finite_number(radius) and radius or Survival.HOUND_RADIUS
    local total = 0
    for i = 1, #threats do
        local record = threats[i]
        if type(record) == "table" and set[record.prefab] == true then
            local d = record.distance
            if not is_finite_number(d) then
                if is_finite_number(record.x) and is_finite_number(record.z) then
                    d = math.sqrt((record.x - snapshot.x) ^ 2 + (record.z - snapshot.z) ^ 2)
                else
                    d = nil
                end
            end
            if is_finite_number(d) and d <= limit then
                total = total + 1
            end
        end
    end
    return total
end

-- [喵喵喵]: 首领/史诗级只在客户端可见标签上认；读不到返回 nil（未知）。
local function record_is_epic(record)
    local entity = type(record) == "table" and record.entity or nil
    if not is_valid(entity) or entity.HasTag == nil then
        return nil
    end
    local ok, flag = pcall(function()
        return entity:HasTag("epic")
    end)
    if ok and type(flag) == "boolean" then
        return flag
    end
    return nil
end

-- [喵喵喵]: 落水自救只能去“看得见的船”：船就是带 boat 标签的可见实体（与 Observer 分类同口径）。
local function visible_boat(snapshot, px, pz)
    local nearby = type(snapshot) == "table" and snapshot.nearby or nil
    if type(nearby) ~= "table" then
        return nil, "nearby_unreadable"
    end
    local best = nil
    for i = 1, #nearby do
        local record = nearby[i]
        if type(record) == "table"
            and is_finite_number(record.x)
            and is_finite_number(record.z)
            and is_valid(record.entity)
            and record.entity.HasTag ~= nil then
            local ok, flag = pcall(function()
                return record.entity:HasTag("boat")
            end)
            if ok and flag == true then
                local d = is_finite_number(record.distance) and record.distance
                    or math.sqrt((record.x - px) ^ 2 + (record.z - pz) ^ 2)
                if d <= Survival.BOAT_SEARCH_RADIUS and (best == nil or d < best.distance) then
                    best = { record = record, distance = d }
                end
            end
        end
    end
    if best == nil then
        return nil, "no_visible_boat"
    end
    return best, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 运行期状态：只按世界/分片键重置，全部是运行期字段（禁止序列化）。
--------------------------------------------------------------------------

local function reset_runtime(rt, world)
    rt.v = Survival.SCHEMA_VERSION
    rt.world = world
    rt.active = nil
    rt.suspended = nil
    rt.escape_runs = 0
    rt.escape_t = nil
    rt.retreat_guid = nil
    rt.retreat_contact = nil
    rt.attempts = {}
    rt.blocked = {}
    rt.soft = {}
    rt.softn = {}
    rt.last = nil
    -- [喵喵喵]: 基地是“本世界/本分片”的锚点：换世界、换分片必须重新用观测到的营地锚。
    rt.base = nil
    rt.base_note = nil
    rt.season = nil
    rt.thermal = nil
    rt.refills = nil
    rt.food_refill = nil
end

local function ensure_runtime(state, snapshot)
    local rt = state.survival
    if type(rt) ~= "table" then
        rt = {}
        state.survival = rt
    end
    local world = world_key_of(snapshot)
    if rt.world ~= world then
        -- [喵喵喵]: 换世界/换分片：旧世界的持有命令必须先交还（见 Plan 的 world 分支），
        -- 这里只负责把本文件自己的记账清干净，绝不让旧 active 成为孤儿记录。
        reset_runtime(rt, world)
    end
    rt.v = Survival.SCHEMA_VERSION
    return rt
end

-- [喵喵喵]: 有界清理：blocked 表超过上限就按时间淘汰最旧的一条。
local function prune_blocked(rt)
    if type(rt.blocked) ~= "table" then
        rt.blocked = {}
        return
    end
    local count, oldest_key, oldest_t = 0, nil, nil
    for key, t in pairs(rt.blocked) do
        count = count + 1
        local value = is_finite_number(t) and t or 0
        if oldest_t == nil or value < oldest_t then
            oldest_key, oldest_t = key, value
        end
    end
    if count > Survival.BLOCK_MAX and oldest_key ~= nil then
        rt.blocked[oldest_key] = nil
    end
end

local function is_blocked(rt, key)
    local hard = type(rt.blocked) == "table" and rt.blocked[key] or nil
    if is_finite_number(hard) and (now() - hard) < Survival.BLOCK_TTL then
        return true
    end
    local soft = type(rt.soft) == "table" and rt.soft[key] or nil
    if is_finite_number(soft) and (now() - soft) < Survival.SOFT_BLOCK_TTL then
        return true
    end
    return false
end

local function attempt_of(rt, key)
    local n = type(rt.attempts) == "table" and rt.attempts[key] or nil
    return is_finite_number(n) and n or 0
end

-- [喵喵喵]: key->数字的小表有界化：超过上限就淘汰数值最小的那条（重试次数最少的），
-- 保证 70 天里按 guid 增长的键不会无限涨；只影响“下一次是不是新 id”的计数。
local function prune_key_map(map, limit)
    if type(map) ~= "table" then
        return
    end
    local total, smallest_key, smallest_value = 0, nil, nil
    for key, value in pairs(map) do
        total = total + 1
        local v = is_finite_number(value) and value or 0
        if smallest_value == nil or v < smallest_value then
            smallest_key, smallest_value = key, v
        end
    end
    if total > limit and smallest_key ~= nil then
        map[smallest_key] = nil
    end
end

local function bump_attempt(rt, key)
    if type(rt.attempts) ~= "table" then
        rt.attempts = {}
    end
    local n = attempt_of(rt, key) + 1
    rt.attempts[key] = n
    rt.fails = num_or(rt.fails, 0) + 1
    prune_key_map(rt.attempts, Survival.KEY_MAP_MAX)
    return n
end

local function mark_blocked(rt, key)
    -- [喵喵喵]: 危险持续时每轮重算退路；单条 Navigation 路线已有预算，不能因累计命令 ID 让逃生进入采购冷却。 (2026-11-13)
    if string.sub(key, 1, 7) == "escape:" then return end
    if type(rt.blocked) ~= "table" then
        rt.blocked = {}
    end
    rt.blocked[key] = now()
    prune_blocked(rt)
end

-- [喵喵喵]: 软冷却：只表示“这一会儿没拿到命令”，不是目标不可用；
-- 同一个 key 软挡多了就升级成硬冷却，避免两个软原因互相轮流而无限循环。
local function soft_block(rt, key)
    if type(rt.soft) ~= "table" then
        rt.soft = {}
    end
    rt.soft[key] = now()
    if type(rt.softn) ~= "table" then
        rt.softn = {}
    end
    local n = num_or(rt.softn[key], 0) + 1
    rt.softn[key] = n
    prune_key_map(rt.softn, Survival.KEY_MAP_MAX)
    if n >= Survival.STEP_FAIL_LIMIT then
        rt.softn[key] = nil
        mark_blocked(rt, key)
    end
end

-- [喵喵喵]: 命令 id 含世界键 + 逻辑步 + 真实重试计数：
-- 轮询期间同一逻辑步不动 id（稳定），真失败后才推进 aN（否则 Actions 会把
-- 同身份的终结结果闩存起来，重试永远拿到旧的 failed）。
local function command_id(rt, key)
    return string.format("survival|%s|%s|a%d",
        tostring(rt.world or "-"), tostring(key), attempt_of(rt, key))
end

--------------------------------------------------------------------------
-- [喵喵喵] 交还当前持有命令：只在这里把“取消/被打断/换世界”的反馈转发回
-- 原策略（SuppliesReport），保证它自己的 in-flight 记录被清掉，
-- 不会因为本文件丢掉命令而变成孤儿记录堵住后续规划。
-- 己方命令(EQUIP)没有第三方记账，直接丢即可。
--------------------------------------------------------------------------

local function release_active(state, rt, why)
    local active = rt.active
    rt.active = nil
    if type(active) ~= "table" then
        return true, "no_active"
    end
    if active.owner == SUPPLIES_OWNER and type(active.command) == "table" then
        local ok, detail = Supplies.Report(state, active.command, "failed", why)
        return ok == true, "supplies:" .. tostring(detail)
    end
    return true, "released:" .. tostring(active.key)
end

--------------------------------------------------------------------------
-- [喵喵喵] 顶替 = 挂起，不是抹除：
--   * Supplies 的在飞记录是它自己的账本，本文件无权“为了换个命令”就报失败（
--     那会替它作废目标、烧掉它的尝试预算），所以直接进 rt.suspended，原 id/原表保留；
--   * 己方命令（照明/逃命）没有第三方记帐，直接丢弃，执行器由 runner 撤。
--   * 全局最多挂起一条；已有挂起则先把旧的显式收尾（这是真正的取消，必须转发）。
--------------------------------------------------------------------------

local function suspend_active(state, rt)
    local active = rt.active
    rt.active = nil
    if type(active) ~= "table" then
        return nil
    end
    local descriptor = {
        id = active.id,
        owner = active.owner,
        via = active.via,
        purpose = active.purpose,
        suspended = false,
    }
    if active.owner ~= SUPPLIES_OWNER then
        return descriptor
    end
    -- [喵喵喵]: 执行器会取消旧动作，保留旧命令会重放过期目标/确认基线；释放执行位后按新快照重规划。 (2026-11-11)
    Supplies.Report(state, active.command, "failed", "preempted_for_replan")
    return descriptor
end

-- [喵喵喵]: 挂起命令的收尾：只有换世界/本局失败/调用方 Cancel/挂起超时才会走到这里，
-- 都属于真正的取消，所以必须把结果转发回 Supplies，不能悄悄丢掉。
local function finalize_suspended(state, rt, why)
    local suspended = rt.suspended
    rt.suspended = nil
    if type(suspended) ~= "table" then
        return false, "no_suspended"
    end
    local ok, detail = Supplies.Report(state, suspended.command, "failed", why)
    return ok == true, tostring(detail)
end

-- [喵喵喵]: 恢复：把挂起的那条原样再交出去（同一个 id、同一张命令表），
-- 所以 Supplies 侧的 in-flight 记录一直连续，后续回执照旧能对上。
local function resume_suspended(state, rt, why)
    local suspended = rt.suspended
    if type(suspended) ~= "table" then
        return nil, nil
    end
    local age = now() - (is_finite_number(suspended.t) and suspended.t or now())
    if age > Survival.SUSPEND_TTL then
        rt.suspended = nil
        local ok, detail = Supplies.Report(state, suspended.command, "failed",
            string.format("suspend_expired:%.1f", age))
        return nil, string.format("suspend_expired:%.1f|%s|%s",
            age, tostring(ok), tostring(detail))
    end
    rt.suspended = nil
    rt.active = {
        id = suspended.id,
        owner = suspended.owner,
        via = suspended.via,
        purpose = suspended.purpose,
        key = suspended.key,
        priority = suspended.priority,
        command = suspended.command,
        t = now(),
        polls = 0,
        resumed = num_or(suspended.resumed, 0) + 1,
    }
    return suspended.command, string.format("resumed:%s|age=%.1f|n=%d|%s",
        tostring(suspended.purpose), age, num_or(rt.active.resumed, 1), tostring(why))
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策片一：把自己已经拥有的光源戴起来。
-- intent 走原生“点背包栏”的那条链路（Actions 的 kind='inventory'）：
-- 下发前 Actions 会用原版 playeractionpicker 核对此刻真的存在 EQUIP 动作，
-- 完成判定只认“该实体真的出现在 replica 装备槽里”，不看材料/数量变化。
--------------------------------------------------------------------------

local function equip_light_decision(rt, record, note)
    local key = "light:equip:" .. tostring(record.guid)
    local priority = Survival.PRIORITY_LIGHT
    local purpose = "light:equip:" .. tostring(record.prefab)
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        note = note,
        origin = "survival",
        plan = function()
            local id = command_id(rt, key)
            return {
                via = "actions",
                intent = {
                    kind = "inventory",
                    action = "EQUIP",
                    item = record.entity,
                    priority = priority,
                    id = id,
                },
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策片二：把“弄一个能亮的/能吃的/能穿的”交给 Supplies（它自己的预算/
-- 采集/制作/放置/烹饪链路）。本文件只转发命令与回执，绝不自造物品、绝不解锁配方。
-- request 形状与 Supplies.Plan 契约一致：{ item, count, id }。
-- id 用 command_id，重试（gave_up 后）会得到新的 id，等于 Supplies 侧新的预算。
--------------------------------------------------------------------------

local function supplies_request_decision(rt, player, snapshot, state, key, purpose, priority, item, count)
    local request = { item = item, count = count }
    rt.demands[#rt.demands + 1] = request
    return {
        key = key,
        request = request,
        priority = priority,
        purpose = purpose,
        origin = "supplies",
        plan = function()
            local request = {
                item = item,
                count = count,
                id = command_id(rt, key),
            }
            local cmd, reason = Supplies.Plan(player, snapshot, state, request)
            if type(cmd) ~= "table" then
                return nil, string.format("%s:<%s>", purpose, tostring(reason))
            end
            return cmd, nil
        end,
    }
end

local function request_light_decision(rt, player, snapshot, state, item)
    local key = "light:request:" .. tostring(item)
    return supplies_request_decision(rt, player, snapshot, state, key,
        "light:request:" .. tostring(item), Survival.PRIORITY_LIGHT, item, Survival.REQUEST_COUNT)
end

--------------------------------------------------------------------------
-- [喵喵喵] 背包动作（EAT / HEAL / EQUIP）的统一入口：
-- 全部走 Actions 的 kind='inventory'（原生 ControllerUseItemOnSelfFromInvTile →
-- GetItemSelfAction）。Actions 会用同一个原生 picker 核对“此刻真的会选这个动作”，
-- 且完成判定只认该动作自己的证据（EQUIP=槽里有该实体、HEAL=可见血量上升、
-- 消耗类=同一 prefab 持有量下降），所以本文件绝不自己宣布“吃到了/治好了”。
--------------------------------------------------------------------------

local function inventory_action_decision(rt, key, purpose, priority, action, item)
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        origin = "survival",
        plan = function()
            local id = command_id(rt, key)
            return {
                via = "actions",
                intent = {
                    kind = "inventory",
                    action = action,
                    item = item,
                    priority = priority,
                    id = id,
                },
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

--------------------------------------------------------------------------
-- [喵喵喵] 主决策：只在“黑暗/可能黑暗”时产出命令，其余情况给明确原因。
-- 返回 decision|nil, reason
--   decision = { key, priority, purpose, note, plan=function()->command|nil,reason }
--------------------------------------------------------------------------

local navigation_decision

local function prepare_torch_decision(player, snapshot, state, rt)
    local until_night = snapshot.time_until_night
    if snapshot.shard_kind ~= "surface" or not is_finite_number(until_night) then return nil end
    local until_day = snapshot.time_until_day
    if snapshot.phase == "day" and is_finite_number(snapshot.time) then
        until_day = tune("TOTAL_DAY_TIME", 480) * (1 - snapshot.time)
    end
    if not is_finite_number(until_day) or until_day < until_night then return nil end
    local records = carried_records(snapshot)
    if records == nil then return nil end
    local owned, fuel = 0, 0
    local full = tune("TORCH_FUEL", 75)
        / (1 + tune("TORCH_RAIN_RATE", 1.5) * num_or(snapshot.precipitation_rate, 0))
    for _, record in ipairs(records) do
        if Survival.CARRIED_KINDS[record.kind] and is_valid(record.entity) then
            if record.prefab == "torch" then
                local replica = record.entity.replica and record.entity.replica.inventoryitem
                local classified = replica and replica.classified
                local ok, percent = pcall(function() return classified.percentused:value() end)
                if not ok or not is_finite_number(percent) or percent < 0 or percent > 100 then return nil end
                owned = owned + record.count
                fuel = fuel + math.max(0, percent - 1) / 100 * full * record.count
            elseif (Survival.HAND_LIGHT[record.prefab] or Survival.HEAD_LIGHT[record.prefab])
                and not record.entity:HasTag("fueldepleted") then
                return nil
            end
        end
    end
    -- [喵喵喵]: 没有可用照明时先备过夜材料，不能让整批普通储备吃掉第一天；已有燃料则沿用临夜补给窗口。 (2026-11-12)
    if fuel > 0 and snapshot.phase ~= "night" and until_night > num_or(Supplies.PLAN_TIMEOUT, 180) then
        return nil
    end
    -- [喵喵喵]: 两把残火把不等于一夜照明；按剩余燃料、原版昼夜长度和雨耗提前补齐，不能等全灭。 (2026-11-12)
    local needed = until_day - until_night + Survival.LIGHT_EQUIP_LEAD - fuel
    local key = "light:reserve_fuel"
    if needed <= 0 or is_blocked(rt, key) then return nil end
    -- [喵喵喵]: 预备照明不延误已经拿到手的救命食物；吃完这口后仍可抢占漫长采购。 (2026-11-12)
    if is_finite_number(snapshot.hunger) and snapshot.hunger <= Survival.HUNGER_STARVE
        and pick_food_record(snapshot, false) ~= nil then return nil end
    local priority = Survival.PRIORITY_STARVE - 1
    -- [喵喵喵]: 即将入夜或正在过夜时仍先保照明；白天的燃料储备低于正在发生的饥荒。 (2026-11-12)
    if snapshot.phase == "night" or until_night <= Survival.LIGHT_EQUIP_LEAD then
        priority = Survival.PRIORITY_LIGHT
    end
    return supplies_request_decision(rt, player, snapshot, state, key, key,
        priority, "torch", owned + math.ceil(needed / full))
end

local function choose_light(player, snapshot, state, rt)
    local phase = read_phase(snapshot)
    local light_state, light_why = read_light(snapshot)

    -- [喵喵喵]: 原版时钟已考虑四季昼长；仅在入夜前数秒预装备，不按整段黄昏消耗燃料。 (2026-11-12)
    local prepare = (phase == "day" or phase == "dusk")
        and is_finite_number(snapshot.time_until_night)
        and snapshot.time_until_night >= 0
        and snapshot.time_until_night <= Survival.LIGHT_EQUIP_LEAD
    local equipped_prefab, equipped_slot = equipped_light(snapshot)

    -- [喵喵喵]: 制作会自动装备火把；收灯须能抢占普通采购，且环境光必须独立于自身光源。 (2026-11-12)
    if equipped_prefab ~= nil and not prepare
        and snapshot.shard_kind == "surface" and (phase == "day" or phase == "dusk")
        and light_state == "lit" and type(snapshot.light) == "table"
        and is_finite_number(snapshot.light.ambient) and snapshot.light.ambient >= Survival.LIGHT_THRESHOLD then
        local record = snapshot.equipment[equipped_slot]
        return inventory_action_decision(rt, "light:unequip:" .. tostring(record.guid),
            "light:unequip:" .. tostring(equipped_prefab), Survival.PRIORITY_LIGHT, "UNEQUIP", record.entity), nil
    end

    -- [喵喵喵]: 夜里光照读不到属于致命前提，保守当作“需要照明”；黄昏/白天读不到则
    -- 明确未知 + 有界等待，绝不当成安全也绝不当成危险。
    local need_light = false
    if light_state == "dark" then
        need_light = true
    elseif phase == "night" then
        -- [喵喵喵]: 静态火堆只照亮当前位置；夜间必须持有可用照明或停留在火边，不能据此批准远行。 (2026-11-11)
        need_light = true
    elseif prepare then
        need_light = true
    end

    local fuel_reserve = prepare_torch_decision(player, snapshot, state, rt)
    if not need_light then
        if fuel_reserve ~= nil then return fuel_reserve, nil end
        if light_state == "lit" then
            return nil, string.format("light_ok:phase=%s|%s", tostring(phase), light_brief(snapshot))
        end
        return nil, string.format("light_unknown:%s|phase=%s|%s",
            tostring(light_why), tostring(phase), light_brief(snapshot))
    end

    local tag = "night_unknown"
    if light_state == "dark" then
        tag = "dark"
    elseif prepare then
        tag = "prepare"
    end

    -- 1) 已装备照明时继续补齐本夜燃料，库存足够则无需动作。
    if equipped_prefab ~= nil then
        if fuel_reserve ~= nil then return fuel_reserve, nil end
        return nil, string.format("light_ok:equipped=%s@%s|phase=%s|trigger=%s",
            tostring(equipped_prefab), tostring(equipped_slot), tostring(phase), tag)
    end

    -- 2) 随身有光源：戴起来。同一步反复失败会进入冷却，冷却期内改走“要一个光源”。
    local record, record_why = find_owned_light(snapshot)
    local equip_blocked = false
    if record ~= nil then
        local equip_key = "light:equip:" .. tostring(record.guid)
        if not is_blocked(rt, equip_key) then
            return equip_light_decision(rt, record, record_why), nil
        end
        equip_blocked = true
    end

    -- [喵喵喵]: 复用可见火源；材料足够时原地补火把，否则先靠火等待，不为下一项采购离开照明。 (2026-11-11)
    local fire = nearest_burning(snapshot, Survival.FIRE_SEEK_RADIUS)
    local cooling = nearest_burning(snapshot, Survival.FIRE_SEEK_RADIUS, true)
    if cooling ~= nil and (fire == nil or cooling.distance < fire.distance) then fire = cooling end
    if fire ~= nil and snapshot.platform == nil then
        if record == nil and (count_owned(snapshot, "cutgrass") or 0) >= 2
            and (count_owned(snapshot, "twigs") or 0) >= 2
            and not is_blocked(rt, "light:request:" .. Survival.REQUEST_TORCH) then
            return request_light_decision(rt, player, snapshot, state, Survival.REQUEST_TORCH), nil
        end
        if fire.distance > Survival.FIRE_WARM_DIST then
            return navigation_decision(rt, "light:seek_fire", "light:seek_fire",
                Survival.PRIORITY_LIGHT, fire.record.x, fire.record.z, Survival.FIRE_WARM_DIST * 0.6), nil
        end
        return {
            key = "light:hold", purpose = "light:hold", priority = Survival.PRIORITY_LIGHT, origin = "survival",
            plan = function() return nil, "light_shelter:waiting_for_portable_light_or_day" end,
        }, nil
    end

    -- 3) 没有可用火源：先补缺失的火把；已有火把但暂时无法装备时只尝试营火。
    local sources = record == nil and { Survival.REQUEST_TORCH, Survival.REQUEST_CAMPFIRE }
        or { Survival.REQUEST_CAMPFIRE }
    local tried = {}
    for i = 1, #sources do
        local item = sources[i]
        local key = "light:request:" .. tostring(item)
        if not is_blocked(rt, key) then
            return request_light_decision(rt, player, snapshot, state, item), nil
        end
        tried[#tried + 1] = tostring(item)
    end
    local reason = string.format("no_light_source:%s|equip_blocked=%s|phase=%s|blocked=%s",
        tostring(record_why), tostring(equip_blocked), tostring(phase), table.concat(tried, ","))
    return {
        key = "light:hold", purpose = "light:hold", priority = Survival.PRIORITY_LIGHT, origin = "survival",
        plan = function() return nil, reason end,
    }, reason
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策片三：即时脱离危险（本文件优先级最高的动作片）。
--   * 撤退点永远由 Navigation.Retreat 算：它只用快照里的威胁/火源坐标 + 客户端
--     Map 校验（IsPassableAtPoint(...,false,true) + IsPointNearHole），所以不可能
--     被规划成穿过海洋/洞口的点；算不出来就 nil + 原因，绝不自己编一个点。
--   * 落水只能去“看得见的船”，并且交给真实存在的 Sailing board 模式；没有船就
--     明确失败，绝不凭空给目的地。
--   * 站在船上（snapshot.platform ~= nil）时不下发陆地路线：Navigation.Step 本来
--     就会拒绝，这里先如实说明。
--------------------------------------------------------------------------

-- [喵喵喵]: 通用移动决定：goal 的 id 用 command_id（同一目标轮询用同一 id，真失败才有新 id），
-- 附加 priority 交给 Navigation.Step 转交给 Actions。
navigation_decision = function(rt, key, purpose, priority, x, z, range)
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        origin = "survival",
        plan = function()
            local id = command_id(rt, key)
            local nav_goal = {
                x = x,
                z = z,
                range = num_or(range, Navigation.GOAL_RANGE),
                priority = priority,
                id = id,
            }
            return {
                via = "navigation",
                goal = nav_goal,
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

local function navigation_escape_decision(rt, key, purpose, goal)
    local priority = Survival.PRIORITY_ESCAPE
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        origin = "survival",
        plan = function()
            -- [喵喵喵]: goal.id 用 command_id：同一撤退点多轮轮询只有一个 id，
            -- 真正失败后才换成新 id（Navigation 按 id 闩存终态）。
            local id = command_id(rt, key)
            local nav_goal = {
                x = goal.x,
                z = goal.z,
                range = num_or(goal.range, Navigation.GOAL_RANGE),
                priority = priority,
                id = id,
            }
            return {
                via = "navigation",
                goal = nav_goal,
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

local function board_escape_decision(rt, boat)
    local record = boat.record
    local key = "escape:board:" .. tostring(record.guid)
    local priority = Survival.PRIORITY_ESCAPE
    local purpose = "escape:board:" .. tostring(record.prefab)
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        origin = "survival",
        plan = function()
            local id = command_id(rt, key)
            return {
                via = "sailing",
                goal = {
                    id = id,
                    mode = "board",
                    x = record.x,
                    z = record.z,
                    range = Survival.SAIL_BOARD_RANGE,
                    priority = priority,
                    boat = record.entity,
                },
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

-- [喵喵喵]: kind='use' + ADDFUEL：给看得见的、已经熄了的石火堆加柴。
-- 远程客户端可读的证据只有火堆自己的原生标签（components/burnable.lua:13 点燃时
-- AddTag("fire")），所以：
--   * 只在基线“确实没在烧”时才发（否则“它一直着着”无法归因给我们）；
--   * confirm 只认“fire 标签真的出现了”；材料变少/动作被接受都不算完成。
-- 如果标签也读不到，confirm 返回 false，Actions 会准时到截止时间报失败。
local function addfuel_decision(rt, firepit, fuel)
    local target = firepit.record.entity
    local key = "env:addfuel:" .. tostring(firepit.record.guid)
    local priority = Survival.PRIORITY_ENV
    local purpose = "env:addfuel:" .. tostring(fuel.prefab)
    return {
        key = key,
        priority = priority,
        purpose = purpose,
        origin = "survival",
        plan = function()
            local id = command_id(rt, key)
            local confirm = function(player, intent)
                if not is_valid(target) or target.HasTag == nil then
                    return false
                end
                local ok, burning = pcall(function()
                    return target:HasTag("fire")
                end)
                if not ok or type(burning) ~= "boolean" then
                    return false
                end
                return burning == true
            end
            return {
                via = "actions",
                intent = {
                    kind = "use",
                    action = "ADDFUEL",
                    item = fuel.entity,
                    target = target,
                    priority = priority,
                    id = id,
                    confirm = confirm,
                },
                id = id,
                purpose = purpose,
                owner = Survival.OWNER,
                stage = key,
                priority = priority,
            }, nil
        end,
    }
end

local function wait_for_escape(why)
    -- [喵喵喵]: 没有已确认退路仍处于危险中，先撤普通采购并持续重评，不恢复原路线。 (2026-11-12)
    return {
        key = "escape:wait", purpose = "escape:wait", origin = "survival",
        priority = Survival.PRIORITY_ESCAPE,
        plan = function() return nil, "escape:wait: " .. tostring(why) end,
    }
end

local function retreat_armor(snapshot, rt)
    local _, head, body = equip_slots()
    for _, slot in ipairs({ head, body }) do
        local current = equipment_prefab(snapshot, slot)
        if current == nil or (slot == body and current == "backpack") then
            local record = pick_armor_record(snapshot, slot)
            -- [喵喵喵]: 逃生不换减速大理石甲；替换背包只用主栏护甲，让原版换装腾出的槽位接住背包。 (2026-11-13)
            if record ~= nil and record.prefab ~= "armormarble"
                and (current == nil or record.kind == "inventory") then
                local key = "vital:equip:armor:" .. tostring(record.guid)
                if not is_blocked(rt, key) then
                    return inventory_action_decision(rt, key, "vital:equip:armor:" .. record.prefab,
                        Survival.PRIORITY_ESCAPE - 1, "EQUIP", record.entity)
                end
            end
        end
    end
end

local function choose_escape(player, snapshot, state, rt)
    local px, pz = snapshot.x, snapshot.z
    local notes = {}

    -- 1) 正在被烧：立刻离开看得见的火源。
    local on_fire, fire_why = read_on_fire(player, snapshot)
    if on_fire == true then
        local key = "escape:fire"
        if snapshot.platform ~= nil then
            return nil, "escape_on_platform:fire|platform=" .. tostring(snapshot.platform.prefab)
        end
        local hazards, hwhy = burning_hazards(snapshot, Survival.BURN_RADIUS)
        if hazards == nil or #hazards == 0 then
            return nil, string.format("escape_fire:no_hazard_position|via=%s|%s",
                tostring(fire_why), tostring(hwhy))
        end
        -- [喵喵喵]: Retreat 只读 snapshot.x/z/threats 的几何，所以这里给它一张
        -- 只含“当前看得见的火源”的影子快照：同一批可见实体，不是新观测。
        local shadow = { x = px, z = pz, threats = hazards }
        local goal, why = Navigation.Retreat(player, shadow, state, Survival.ESCAPE_DISTANCE)
        if goal == nil then
            return nil, "escape_fire:no_safe_point|" .. tostring(why)
        end
        return navigation_escape_decision(rt, key, "escape:fire", goal), nil
    elseif on_fire == nil then
        notes[#notes + 1] = "fire_unknown:" .. tostring(fire_why)
    end

    -- 2) 落水：脚下没平台且地图明确是海洋 => 只能上看得见的船。
    if snapshot.platform == nil then
        local ocean, owhy = map_is_ocean(px, pz)
        if ocean == true then
            local key = "escape:drown"
            local boat, bwhy = visible_boat(snapshot, px, pz)
            if boat == nil then
                return nil, "drowning:no_visible_boat|" .. tostring(bwhy)
            end
            return board_escape_decision(rt, boat), nil
        elseif ocean == nil then
            notes[#notes + 1] = "water_unknown:" .. tostring(owhy)
        end
    end

    -- 3) 可见威胁：索敌区外提前避让，正在撤退的目标须额外拉开距离。
    local nearest, twhy = nearest_threat(snapshot)
    local threats = snapshot.threats or {}
    local contact = rt.retreat_contact
    if contact ~= nil then
        -- [喵喵喵]: 重见同一实体时完全使用新观测，包含变回中立猪；旧坐标只在短暂失去视线时指导继续撤离。 (2026-11-13)
        for _, record in ipairs(snapshot.nearby or {}) do
            if record.guid == contact.guid then contact = nil; break end
        end
        for _, record in ipairs(threats) do
            if contact ~= nil and record.guid == contact.guid then contact = nil; break end
        end
        if contact ~= nil and now() - contact.t > THREAT_CONTACT_GRACE then contact = nil end
        if contact ~= nil then
            threats = {}
            for _, record in ipairs(snapshot.threats or {}) do threats[#threats + 1] = record end
            threats[#threats + 1] = contact
        end
    end
    local danger = nil
    for _, record in ipairs(threats) do
        if is_finite_number(record.x) and is_finite_number(record.z) then
            local distance = math.sqrt((px - record.x) ^ 2 + (pz - record.z) ^ 2)
            local radius = record == contact and contact.radius
                or (type(Navigation.THREAT_RADII) == "table" and Navigation.THREAT_RADII[record.prefab] or nil)
            radius = num_or(radius, Survival.ARMOR_RADIUS)
            if record_is_epic(record) == true then radius = math.max(radius, Survival.BOSS_RADIUS) end
            local base_radius = radius
            -- [喵喵喵]: 到达一个撤退点不代表脱离追击；使用不同的进入/退出距离。 (2026-11-12)
            if rt.retreat_guid ~= nil and rt.retreat_guid == record.guid then
                radius = radius + Survival.ESCAPE_CLEARANCE
            end
            if (record == contact or distance <= radius) and (danger == nil or distance < danger.distance) then
                danger = { record = record, distance = distance, radius = base_radius }
            end
        end
    end
    rt.retreat_guid = danger ~= nil and danger.record.guid or nil
    rt.retreat_contact = nil
    if danger ~= nil then
        local record = danger.record
        rt.retreat_contact = record == contact and contact or {
            guid = record.guid, prefab = record.prefab, x = record.x, z = record.z,
            radius = danger.radius, t = now(),
        }
        local key = "escape:threat"
        if snapshot.platform ~= nil then
            return wait_for_escape("on_platform"), "escape_on_platform:threat|platform=" .. tostring(snapshot.platform.prefab)
        end
        -- [喵喵喵]: 尚有间距时先穿已有护甲；贴脸或正在撤退不为换装停步，敌人逼近可按更高优先级打断换装。 (2026-11-13)
        if nearest ~= nil and nearest.distance > Survival.IMMINENT_RADIUS
            and (rt.active == nil or rt.active.priority < Survival.PRIORITY_ESCAPE) then
            local armor = retreat_armor(snapshot, rt)
            if armor ~= nil then return armor, nil end
        end
        local retreat_snapshot = { x = px, z = pz, threats = threats }
        -- [喵喵喵]: 固定短点会在追击中反复到达停步；优先走完警戒半径及退出余量，受阻时仍由Retreat缩短并校验整段。 (2026-11-13)
        local distance = math.max(Survival.ESCAPE_DISTANCE, danger.radius + Survival.ESCAPE_CLEARANCE + Navigation.GOAL_RANGE)
        local goal, why = Navigation.Retreat(player, retreat_snapshot, state, distance)
        if goal == nil and distance > Survival.ESCAPE_DISTANCE then
            goal, why = Navigation.Retreat(player, retreat_snapshot, state, Survival.ESCAPE_DISTANCE)
        end
        if goal == nil then
            return wait_for_escape(why), string.format("escape_threat:no_safe_point|%s|d=%.1f", tostring(why), danger.distance)
        end
        return navigation_escape_decision(rt, key, "escape:threat", goal), nil
    end
    if nearest ~= nil then
        -- [喵喵喵]: 猎犬波：成群的 hound 不是“普通怪”，但本阶段也没有战斗控制器，
        -- 所以只做“戴上甲/武器（vitals 片）+ 找一条安全路后退”，绝不假装能杀。
        local hounds = count_threat_prefabs(snapshot, HOUND_PREFABS, Survival.HOUND_RADIUS)
        if hounds ~= nil and hounds >= Survival.HOUND_PACK_MIN
            and nearest.distance <= Survival.HOUND_RADIUS then
            local key = "escape:hounds"
            if snapshot.platform ~= nil then
                return wait_for_escape("on_platform"), string.format("escape_on_platform:hounds|platform=%s|n=%d",
                    tostring(snapshot.platform.prefab), hounds)
            end
            local goal, why = Navigation.Retreat(player, snapshot, state, Survival.ESCAPE_DISTANCE)
            if goal == nil then
                return wait_for_escape(why), string.format("escape_hounds:no_safe_point|%s|n=%d|d=%.1f",
                    tostring(why), hounds, nearest.distance)
            end
            return navigation_escape_decision(rt, key, "escape:hounds", goal), nil
        end
    elseif twhy ~= nil and twhy ~= "no_threat" then
        notes[#notes + 1] = tostring(twhy)
    end

    if #notes == 0 then
        return nil, nil
    end
    return nil, table.concat(notes, "|")
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策片四：身体（治疗/进食）与装备。
--   只用原生背包动作与真实持有物：没有药品/食物就不假装吃到，没有护甲就不假装穿上。
--   槽位冲突（手上抢火把）由“同一时刻只有一条在飞命令” + 不抢光源 两条规矩避开。
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- [喵喵喵] 决策片三之二：环境（寒冷/过热/淋湿）。
--   只用客户端可见的温度、看得见的火、真实持有的燃料、以及原生 ADDFUEL 标签证据；
--   可回复的手段只有三个：走到火边 / 给熄了的石火堆加柴 / 让 Supplies 放一个营火。
--   潮湿在本片没有可用的原生干衣手段（烘干来自靠火/遮蔽/睡袋/装备，不是玩家的一个动作），
--   所以只如实记录，并借“靠火取暖”当唯一的可观测响应；绝不能假装烘干了。
--------------------------------------------------------------------------

local function thermal_hold(temp)
    return {
        key = "env:hold", purpose = "env:hold", priority = Survival.PRIORITY_ENV, origin = "survival",
        plan = function() return nil, string.format("temperature_recovering:%.1f", temp) end,
    }
end

local function choose_environment(player, snapshot, state, rt)
    local notes = {}
    local temp = snapshot.temperature
    local moisture = snapshot.moisture
    local cold, hot = false, false

    -- [喵喵喵]: 夏季闷烧优先处理可见的营地物件，成功证据是同一目标解除 smolder。
    for _, record in ipairs(snapshot.nearby or {}) do
        if is_valid(record.entity) and record.entity:HasTag("smolder") and not record.entity:HasTag("fire")
            and is_finite_number(record.distance) and record.distance <= 6 then
            local target = record.entity
            local key = "env:smother:" .. tostring(record.guid)
            if not is_blocked(rt, key) then
                return { key = key, purpose = key, priority = Survival.PRIORITY_ENV, origin = "survival",
                    plan = function()
                        local id = command_id(rt, key)
                        return { via = "actions", owner = Survival.OWNER, id = id, stage = key, purpose = key,
                            priority = Survival.PRIORITY_ENV,
                            intent = { kind = "action", action = "SMOTHER", target = target, id = id,
                                priority = Survival.PRIORITY_ENV,
                                confirm = function() return is_valid(target) and not target:HasTag("smolder")
                                    and not target:HasTag("fire") and not target:HasTag("burnt") end,
                            },
                        }
                    end,
                }, nil
            end
        end
    end

    if is_finite_number(temp) then
        -- [喵喵喵]: 回温到 25℃、降温到 40℃再恢复采购，避免在警戒温度附近往返。 (2026-11-11)
        cold = temp <= Survival.COLD_WARN or (rt.thermal == "cold" and temp < 25)
        hot = temp >= Survival.HOT_WARN or (rt.thermal == "hot" and temp > 40)
        rt.thermal = cold and "cold" or (hot and "hot" or nil)
    else
        -- [喵喵喵]: 体温读不到就不下“冷/热”结论，也不当成正常体温。
        notes[#notes + 1] = "temperature_unknown"
    end

    if is_finite_number(moisture) then
        if moisture >= Survival.WET_CRITICAL then
            notes[#notes + 1] = string.format("wet:%.2f|no_dry_tool", moisture)
        end
    else
        notes[#notes + 1] = "moisture_unknown"
    end

    if cold then
        -- 1) 已经站在看得见的火边：不需要动作。
        local fire, fire_why = nearest_burning(snapshot, Survival.FIRE_SEEK_RADIUS)
        if fire ~= nil then
            if fire.distance <= Survival.FIRE_WARM_DIST then
                return thermal_hold(temp), string.format("env:warm_near_fire|t=%.0f", temp)
            end
            if snapshot.platform ~= nil then
                return nil, string.format("env:warm_on_platform|t=%.0f|platform=%s",
                    temp, tostring(snapshot.platform.prefab))
            end
            return navigation_decision(rt, "env:seek_fire", "env:seek_fire",
                Survival.PRIORITY_ENV, fire.record.x, fire.record.z, Navigation.GOAL_RANGE), nil
        end

        -- 2) 看得见的熄火堆 + 手里有原生燃料 => ADDFUEL 点起来（标签证据）。
        local pit, pit_why = nearest_out_firepit(snapshot, Survival.ADDFUEL_RADIUS)
        if pit ~= nil then
            local fuel_record, fuel_why = find_owned_prefab(snapshot, FUEL_PREFABS)
            if fuel_record ~= nil then
                local key = "env:addfuel:" .. tostring(pit.record.guid)
                if not is_blocked(rt, key) then
                    return addfuel_decision(rt, pit, fuel_record), nil
                end
            elseif fuel_why == "inventory_unreadable" then
                notes[#notes + 1] = "fuel_unknown"
            else
                notes[#notes + 1] = "no_fuel_owned"
            end
        end

        -- 3) 都没有：让 Supplies 造/放一个营火（放下即点着，本身也是光源）。
        if snapshot.platform == nil then
            local key = "env:cold:campfire"
            if not is_blocked(rt, key) then
                return supplies_request_decision(rt, player, snapshot, state, key,
                    "env:cold:campfire", Survival.PRIORITY_ENV, "campfire", 1), nil
            end
        end
        return nil, string.format("env:cold:no_heat_source|t=%.0f|%s|%s", temp,
            tostring(fire_why), tostring(pit_why))
    end

    if hot then
        local _, head = equip_slots()
        if equipment_prefab(snapshot, head) == "winterhat" then
            return inventory_action_decision(rt, "env:remove:winterhat", "env:remove:winterhat",
                Survival.PRIORITY_ENV, "UNEQUIP", snapshot.equipment[head].entity), nil
        end
        local cooling = nearest_burning(snapshot, Survival.FIRE_SEEK_RADIUS, true)
        if cooling ~= nil and snapshot.platform == nil then
            if cooling.distance <= Survival.FIRE_WARM_DIST then return thermal_hold(temp), nil end
            return navigation_decision(rt, "env:cool_fire", "env:cool_fire",
                Survival.PRIORITY_ENV, cooling.record.x, cooling.record.z, Navigation.GOAL_RANGE), nil
        end
        local pit = nearest_out_firepit(snapshot, Survival.ADDFUEL_RADIUS, true)
        local fuel = find_owned_prefab(snapshot, FUEL_PREFABS)
        if pit ~= nil and fuel ~= nil and not is_blocked(rt, "env:addfuel:" .. tostring(pit.record.guid)) then
            return addfuel_decision(rt, pit, fuel), nil
        end
        local key = "env:hot:coldfire"
        if snapshot.platform == nil and not is_blocked(rt, key) then
            return supplies_request_decision(rt, player, snapshot, state, key,
                key, Survival.PRIORITY_ENV, "coldfire", 1), nil
        end
        -- 4) 过热：贴着看的见的火就往后退一步（几何由 Retreat 算，不会穿洞/下海）。
        local fire, fire_why = nearest_burning(snapshot, Survival.FIRE_WARM_DIST + 1.5)
        if fire ~= nil and snapshot.platform == nil then
            local shadow = { x = snapshot.x, z = snapshot.z, threats = { fire.record } }
            local goal, why = Navigation.Retreat(player, shadow, state, 6)
            if goal ~= nil then
                return navigation_decision(rt, "env:cool_step_away", "env:cool_step_away",
                    Survival.PRIORITY_ENV, goal.x, goal.z,
                    num_or(goal.range, Navigation.GOAL_RANGE)), nil
            end
            notes[#notes + 1] = string.format("hot_near_fire|t=%.0f|%s", temp, tostring(why))
        else
            notes[#notes + 1] = string.format("hot:no_cool_tool|t=%.0f|%s", temp, tostring(fire_why))
        end
    end

    if #notes == 0 then
        return nil, nil
    end
    return nil, table.concat(notes, "|")
end

local function cooking_fire_available(snapshot)
    for _, record in ipairs(snapshot.nearby or {}) do
        if is_valid(record.entity) and record.entity:HasTag("cooker") and record.entity:HasTag("fire")
            and is_finite_number(record.distance) and record.distance <= num_or(Supplies.PLACED_RADIUS, 12) then
            return true
        end
    end
    return false
end

local function cooking_has_benefit(snapshot, pair)
    local raw, cooked = FOODS[pair.raw], FOODS[pair.product]
    if cooked == nil then return false end
    if raw == nil then return true end
    return raw.health < 0
        or (is_finite_number(snapshot.hunger) and snapshot.hunger <= Survival.HUNGER_EAT and cooked.hunger > raw.hunger)
        or (is_finite_number(snapshot.health) and snapshot.health < 1 and cooked.health > raw.health)
end

local function food_request_order(snapshot)
    local order, seen, inputs = {}, {}, {}
    for _, pair in ipairs(RAW_TO_COOKED) do inputs[pair.product] = pair.raw end
    local starving = is_finite_number(snapshot.hunger) and snapshot.hunger <= Survival.HUNGER_STARVE
    local fire = cooking_fire_available(snapshot)
    local function add(item)
        -- [喵喵喵]: 地表不为洞穴专属食材盲目探索；已持有食材仍由进食/加工路径处理。 (2026-11-12)
        if snapshot.shard_kind == "surface" and item == "cave_banana" then return end
        -- [喵喵喵]: 熟食补给只加工已有食材；饥荒时还须有现成炊火，避免为一餐递归造甲或找柴。 (2026-11-12)
        local raw = item ~= nil and inputs[item] or nil
        if raw ~= nil and ((count_owned(snapshot, raw) or 0) < 1 or (starving and not fire)) then return end
        if item ~= nil and not seen[item] then order[#order + 1], seen[item] = item, true end
    end
    for _, pair in ipairs(RAW_TO_COOKED) do
        if (count_owned(snapshot, pair.raw) or 0) > 0 and cooking_has_benefit(snapshot, pair)
            and (FOODS[pair.raw] == nil or FOODS[pair.raw].health < 0 or fire) then
            add(pair.product)
        end
    end
    for _, record in ipairs(snapshot.nearby or {}) do
        if is_valid(record.entity) and not record.threat then
            local item = FOOD_SOURCES[record.prefab]
            if record.entity:HasTag("pickable") or record.prefab == "rabbithole" then add(item) end
        end
    end
    for _, item in ipairs(FOOD_FALLBACK) do add(item) end
    return order
end

local function safe_meal(snapshot, player, rt)
    if type(snapshot.threats) ~= "table" or nearest_threat(snapshot) ~= nil
        or read_light(snapshot) ~= "lit" or (rt.active ~= nil and rt.active.via == "actions") then return nil end
    local hunger = player.replica ~= nil and player.replica.hunger or nil
    if hunger == nil or type(hunger.Max) ~= "function" or type(hunger.GetCurrent) ~= "function" then return nil end
    local maximum, current = hunger:Max(), hunger:GetCurrent()
    if not is_finite_number(maximum) or not is_finite_number(current) or maximum <= current then return nil end
    local command = rt.active ~= nil and rt.active.command or nil
    local goal = command ~= nil and command.goal or nil
    local cooking_nearby = goal ~= nil and is_finite_number(goal.x) and is_finite_number(goal.z)
        and (goal.x - snapshot.x)^2 + (goal.z - snapshot.z)^2 <= num_or(Supplies.PLACED_RADIUS, 12)^2
        and cooking_fire_available(snapshot)
    local best, best_freshness, best_hunger
    for _, record in ipairs(carried_records(snapshot) or {}) do
        if Survival.CARRIED_KINDS[record.kind] and is_valid(record.entity) then
            local food, freshness = edible_food(record)
            local cooking = false
            if cooking_nearby then
                for _, pair in ipairs(RAW_TO_COOKED) do
                    if pair.raw == record.prefab and command.purpose == "approach_fire:" .. pair.product then
                        cooking = true
                        break
                    end
                end
            end
            if food ~= nil and not cooking and food.hunger <= maximum - current
                and (best == nil or freshness < best_freshness
                    or (freshness == best_freshness and food.hunger > best_hunger)) then
                best, best_freshness, best_hunger = record, freshness, food.hunger
            end
        end
    end
    return best
end

local function choose_vitals(player, snapshot, state, rt)
    local notes = {}
    local health = snapshot.health
    local hunger = snapshot.hunger
    local sanity = snapshot.sanity

    -- 1) 重伤：先用真治疗物品（原生 HEAL），没有就吃带治疗值的食物。
    if is_finite_number(health) and health <= Survival.HP_CRITICAL then
        local heal_record, heal_why = find_owned_prefab(snapshot, HEAL_ITEMS)
        if heal_record ~= nil then
            local key = "vital:heal:" .. tostring(heal_record.guid)
            return inventory_action_decision(rt, key, "vital:heal:" .. tostring(heal_record.prefab),
                Survival.PRIORITY_HEAL, "HEAL", heal_record.entity), nil
        end
        local food_record, food = pick_food_record(snapshot, true)
        if food_record ~= nil
            and food ~= nil
            and is_finite_number(food.health)
            and food.health > 0
            and not (is_finite_number(hunger) and hunger >= Survival.HUNGER_FULL) then
            local key = "vital:eat:" .. tostring(food_record.guid)
            return inventory_action_decision(rt, key, "vital:eat:" .. tostring(food_record.prefab),
                Survival.PRIORITY_HEAL, "EAT", food_record.entity), nil
        end
        notes[#notes + 1] = "health_critical:no_heal_item|" .. tostring(heal_why)
    elseif not is_finite_number(health) then
        -- [喵喵喵]: 血量读不到就不下“重伤”结论，但也不能当成健康。
        notes[#notes + 1] = "health_unknown"
    end

    -- 2) 饥饿：饿到线以下就吃（只吃白名单里的原生食物，可疑/有害的一律不入口）。
    local hunger_priority, hunger_tag = nil, nil
    if is_finite_number(hunger) then
        if hunger <= Survival.HUNGER_STARVE then
            hunger_priority, hunger_tag = Survival.PRIORITY_STARVE, "starve"
        elseif hunger <= Survival.HUNGER_EAT then
            hunger_priority, hunger_tag = Survival.PRIORITY_EAT, "low"
        end
    else
        notes[#notes + 1] = "hunger_unknown"
    end
    if hunger_priority ~= nil then
        local food_record = pick_food_record(snapshot, false)
        if food_record ~= nil then
            local key = "vital:eat:" .. tostring(food_record.guid)
            return inventory_action_decision(rt, key,
                string.format("vital:eat:%s|%s", tostring(food_record.prefab), hunger_tag),
                hunger_priority, "EAT", food_record.entity), nil
        end
        -- [喵喵喵]: 一口吃的都没有：走同一个 Supplies 请求通道去要（优先级高于囤货）。
        for _, item in ipairs(food_request_order(snapshot)) do
            local key = "vital:request:food:" .. item
            if not is_blocked(rt, key) then
                return supplies_request_decision(rt, player, snapshot, state, key,
                    key, hunger_priority, item, (count_owned(snapshot, item) or 0) + 1), nil
            end
        end
        notes[#notes + 1] = "food_sources_blocked"
    end

    if is_finite_number(sanity) and sanity <= Survival.SANITY_LOW then
        for _, record in ipairs(carried_records(snapshot) or {}) do
            local food = FOODS[record.prefab]
            if food ~= nil and food.sanity > 0 and Survival.CARRIED_KINDS[record.kind]
                and food_is_fresh(record.entity) and is_finite_number(health) and health > 0.4 then
                return inventory_action_decision(rt, "vital:sanity:" .. tostring(record.guid),
                    "vital:sanity:" .. record.prefab, Survival.PRIORITY_EAT, "EAT", record.entity), nil
            end
        end
        for _, item in ipairs({ "green_cap_cooked", "cactus_meat_cooked" }) do
            local key = "vital:sanity:request:" .. item
            if not is_blocked(rt, key) then
                return supplies_request_decision(rt, player, snapshot, state, key,
                    key, Survival.PRIORITY_EAT, item, (count_owned(snapshot, item) or 0) + 1), nil
            end
        end
        notes[#notes + 1] = string.format("sanity_low:%.2f", sanity)
    end

    -- [喵喵喵]: 安全时先吃更易变质且能完整吸收的口粮；仅在移动或空闲时插入，不打断正在采集/加工的动作。 (2026-11-13)
    if hunger_priority == nil and is_finite_number(hunger) and hunger < 1 then
        local meal = safe_meal(snapshot, player, rt)
        if meal ~= nil then
            return inventory_action_decision(rt, "vital:eat:" .. tostring(meal.guid),
                "vital:eat:" .. meal.prefab .. "|safe", Survival.PRIORITY_EAT, "EAT", meal.entity), nil
        end
    end

    -- 4) 装备：只有威胁真的在近处才换（否则为了囤货去动装备只会添乱）。
    local nearest = nearest_threat(snapshot)
    if nearest ~= nil and nearest.distance <= Survival.ARMOR_RADIUS then
        local hands_slot, head_slot, body_slot = equip_slots()
        if equipment_prefab(snapshot, body_slot) == nil then
            local record = pick_armor_record(snapshot, body_slot)
            if record ~= nil then
                local key = "vital:equip:armor:" .. tostring(record.guid)
                return inventory_action_decision(rt, key,
                    "vital:equip:armor:" .. tostring(record.prefab),
                    Survival.PRIORITY_EQUIP, "EQUIP", record.entity), nil
            end
        end
        if equipment_prefab(snapshot, head_slot) == nil then
            local record = pick_armor_record(snapshot, head_slot)
            if record ~= nil then
                local key = "vital:equip:armor:" .. tostring(record.guid)
                return inventory_action_decision(rt, key,
                    "vital:equip:armor:" .. tostring(record.prefab),
                    Survival.PRIORITY_EQUIP, "EQUIP", record.entity), nil
            end
        end
        -- [喵喵喵]: 武器只在手上空着时换：手里已经拿着火把/提灯就不抢
        -- （夜里把光源换成长矛等于自己送到 Charlie 面前）。
        if equipment_prefab(snapshot, hands_slot) == nil then
            local weapon_record = find_owned_prefab(snapshot, WEAPONS)
            if weapon_record ~= nil then
                local key = "vital:equip:weapon:" .. tostring(weapon_record.guid)
                return inventory_action_decision(rt, key,
                    "vital:equip:weapon:" .. tostring(weapon_record.prefab),
                    Survival.PRIORITY_EQUIP, "EQUIP", weapon_record.entity), nil
            end
        end
    end

    if #notes == 0 then
        return nil, nil
    end
    return nil, table.concat(notes, "|")
end

--------------------------------------------------------------------------
-- [喵喵喵] 基础补给先于普通装备/科技推进；紧急生存及御寒装备仍可抢占。
--------------------------------------------------------------------------

local function choose_stock(player, snapshot, state, rt)
    local food_total = count_food_total(snapshot)
    if food_total == nil then return nil, "reserve:inventory_unreadable" end
    if food_total < Survival.FOOD_RESERVE then
        rt.food_refill = true
    elseif food_total >= FOOD_REFILL_TARGET then
        rt.food_refill = nil
    end
    local food_decision = nil
    local food_t = now()
    if rt.food_seen ~= nil and food_total > rt.food_seen then
        rt.food_search_t0, rt.food_pause_until = nil, nil
    end
    rt.food_seen = food_total
    if rt.food_refill and (rt.food_pause_until == nil or food_t >= rt.food_pause_until) then
        rt.food_search_t0 = rt.food_search_t0 or food_t
        if food_t - rt.food_search_t0 >= 60 then
            -- [喵喵喵]: 普通储粮跨来源共享60秒无收获预算，再让建设/材料推进60秒；实际饥荒走choose_vitals不受限。 (2026-11-12)
            rt.food_pause_until, rt.food_search_t0 = food_t + 60, nil
            if type(rt.active) == "table" and string.sub(rt.active.key or "", 1, 13) == "reserve:food:" then
                release_active(state, rt, "food_search_budget")
            end
        else
            for _, item in ipairs(food_request_order(snapshot)) do
                local food = FOODS[item]
                local key = "reserve:food:" .. item
                if food ~= nil and food.hunger > 0 and not is_blocked(rt, key) then
                    -- [喵喵喵]: 未来口粮低于设施和材料；当前饥饿由choose_vitals抢占，热量换算保持按实际缺口。 (2026-11-12)
                    local missing = math.ceil((FOOD_REFILL_TARGET - food_total) * CAL_SMALL / food.hunger)
                    local decision = supplies_request_decision(rt, player, snapshot, state, key,
                        key, Survival.PRIORITY_RESERVE - 1, item, (count_owned(snapshot, item) or 0) + missing)
                    food_decision = food_decision or decision
                end
            end
        end
    end

    -- [喵喵喵]: 各材料独立保持补货批次；采另一种缺料不会忘记原批次。只登记实际缺口，不额外规划未来配方。 (2026-11-12)
    rt.refills = rt.refills or {}
    local preferred
    for _, stock in ipairs(MATERIAL_STOCK) do
        local count = count_owned(snapshot, stock.item)
        local key = "reserve:material:" .. stock.item
        if count ~= nil then
            if count >= stock.target then rt.refills[stock.item] = nil
            elseif count < stock.low then rt.refills[stock.item] = true end
            if rt.refills[stock.item] and not is_blocked(rt, key) then
                local decision = supplies_request_decision(rt, player, snapshot, state, key,
                    key, Survival.PRIORITY_STOCK, stock.item, stock.target)
                preferred = preferred or decision
            end
        end
    end
    return preferred or food_decision, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 低优先储备：补充装备和加工已有食材。
--------------------------------------------------------------------------

local function choose_reserves(player, snapshot, state, rt)
    local preferred
    -- 1) 便携照明备量（火把：原生 TECH.NONE，可再制）。
    local torch = count_owned(snapshot, "torch")
    if torch == nil then
        return nil, "reserve:inventory_unreadable"
    end
    if torch < Survival.TORCH_RESERVE then
        local key = "reserve:torch"
        if not is_blocked(rt, key) then
            preferred = supplies_request_decision(rt, player, snapshot, state, key, "reserve:torch",
                Survival.PRIORITY_RESERVE, "torch", Survival.TORCH_RESERVE)
        end
    end

    -- [喵喵喵]: 仅复用可见炊火并满足当前营养需求；不为把可安全生吃的食物变成熟食而占用开荒时间。 (2026-11-11)
    if cooking_fire_available(snapshot) then
        for _, pair in ipairs(RAW_TO_COOKED) do
            local cooked = count_owned(snapshot, pair.product) or 0
            local raw = count_owned(snapshot, pair.raw) or 0
            local key = "reserve:cook:" .. pair.product
            if raw > 0 and cooked < Survival.COOK_RESERVE and cooking_has_benefit(snapshot, pair)
                and not is_blocked(rt, key) then
                local decision = supplies_request_decision(rt, player, snapshot, state, key,
                    key, Survival.PRIORITY_RESERVE, pair.product, cooked + 1)
                return preferred or decision, nil
            end
        end
    end

    local rotten = find_owned_prefab(snapshot, { spoiled_food = true })
    if rotten ~= nil then
        return inventory_action_decision(rt, "reserve:discard:rot:" .. tostring(rotten.guid), "reserve:discard:rot",
            Survival.PRIORITY_RESERVE, "DROP", rotten.entity), nil
    end

    if (count_owned(snapshot, "backpack") or 0) == 0 then
        for _, record in ipairs(snapshot.nearby or {}) do
            if record.prefab == "backpack" and is_valid(record.entity) and not record.entity:HasTag("fire")
                and (nearest_threat(snapshot) == nil) then
                local target = record.entity
                local key = "reserve:recover:backpack:" .. tostring(record.guid)
                if not is_blocked(rt, key) then
                    return { key = key, purpose = key, origin = "survival", priority = Survival.PRIORITY_RESERVE,
                        plan = function()
                            local id = command_id(rt, key)
                            return { owner = Survival.OWNER, via = "actions", id = id, stage = key, purpose = key,
                                priority = Survival.PRIORITY_RESERVE,
                                intent = { kind = "action", action = "PICKUP", target = target,
                                    priority = Survival.PRIORITY_RESERVE, id = id },
                            }
                        end,
                    }, nil
                end
            end
        end
        local key = "reserve:backpack"
        if not is_blocked(rt, key) then
            local decision = supplies_request_decision(rt, player, snapshot, state, key,
                key, Survival.PRIORITY_RESERVE, "backpack", 1)
            return preferred or decision, nil
        end
    end
    local _, _, body = equip_slots()
    if equipment_prefab(snapshot, body) == nil then
        local pack = find_owned_prefab(snapshot, { backpack = true })
        if pack then return inventory_action_decision(rt, "reserve:equip:backpack", "reserve:equip:backpack",
            Survival.PRIORITY_RESERVE, "EQUIP", pack.entity), nil end
    end

    -- 4) 护甲储量：草甲（原生 TECH.NONE）优先；已经有木甲/大理石甲就不再多造。
    local grass = count_owned(snapshot, "armorgrass") or 0
    local wood = count_owned(snapshot, "armorwood") or 0
    if (grass + wood) < Survival.ARMOR_RESERVE then
        local key = "reserve:armor:armorgrass"
        if not is_blocked(rt, key) then
            local decision = supplies_request_decision(rt, player, snapshot, state, key,
                "reserve:armor:armorgrass", Survival.PRIORITY_RESERVE, "armorgrass",
                Survival.ARMOR_RESERVE)
            return preferred or decision, nil
        end
    end

    return preferred, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 决策片六：真正没事可做时让 Exploration.Next 挑一个前沿点，
-- 只把它的 goal 原样转发给 Navigation（含它自己的 goal.id/world），
-- 回执再用 Exploration.Report 回灌，避免“无急事就空转”。
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- [喵喵喵] 决策片七：四季准备与基地。
--   四季只由原生 TheWorld.state.season / seasonprogress 决定（不读主机时间、不看存档天数）。
--   每一项准备都是 Supplies 真正支持的配方请求；做不出来的（需 silk/beefalowool/gears/
--   transistor 的季节装备）不请求，而是给出显式缺口原因。
--------------------------------------------------------------------------

local function choose_season(player, snapshot, state, rt)
    local season = read_season(snapshot)
    if season == nil then
        return nil, "season_unknown"
    end
    if is_finite_number(snapshot.season_progress) and snapshot.season_progress >= 0.75 then
        season = ({ autumn = "winter", winter = "spring", spring = "summer", summer = "autumn" })[season]
    end
    local plan = SEASON_PLAN[season]
    if plan == nil then
        -- [喵喵喵]: 秋季是基线季：没有额外装备需求，交给普通囤货/探索。
        return nil, "season:autumn_baseline"
    end
    for i = 1, #plan do
        local entry = plan[i]
        local have = count_owned(snapshot, entry.item)
        if entry.item == "firepit" or entry.item == "coldfirepit" or entry.item == "researchlab2"
            or entry.item == "lightning_rod" then
            have = 0
            for _, record in ipairs(snapshot.nearby or {}) do
                if record.prefab == entry.item and is_valid(record.entity) and not record.entity:HasTag("burnt") then
                    have = have + 1
                end
            end
            if have == 0 then
                local cats = snapshot.shard_memory and snapshot.shard_memory.cats
                for _, station in ipairs(cats and cats.station or {}) do
                    if station.prefab == entry.item
                        and (snapshot.x - station.x) ^ 2 + (snapshot.z - station.z) ^ 2 > Observer.NEARBY_RADIUS ^ 2 then
                        -- [喵喵喵]: 已发现的耐久结构不因离开视野而重造；回到现场后必须重新观测。
                        have = 1
                        break
                    end
                end
            end
        end
        if have == nil then return nil, "season:inventory_unreadable" end
        -- [喵喵喵]: 跳过观测已满足的清单项；不能反复请求首项并饿死后续准备。 (2026-11-11)
        if have < entry.count and not is_blocked(rt, entry.key) then
            return supplies_request_decision(rt, player, snapshot, state, entry.key,
                entry.key, Survival.PRIORITY_SEASON, entry.item, entry.count), nil
        end
    end
    return nil, "season:" .. tostring(season) .. ":prepared_or_cooling"
end

-- [喵喵喵]: 季节装备“戴起来”：只在真的湿/热证据下，且不抢走夜里的手光源。
local function choose_season_gear(player, snapshot, state, rt)
    local season = read_season(snapshot)
    if season == nil then
        return nil, "season_unknown"
    end
    local hands_slot, head_slot = equip_slots()
    local hands_prefab = equipment_prefab(snapshot, hands_slot)
    local head_prefab = equipment_prefab(snapshot, head_slot)
    local hands_is_light = hands_prefab ~= nil and Survival.HAND_LIGHT[hands_prefab] == true
    local dark = read_light(snapshot) ~= "lit" or snapshot.phase == "night" or snapshot.shard_kind == "cave"
    local moisture = snapshot.moisture
    local temp = snapshot.temperature

    local function equip(prefix, record)
        local key = prefix .. tostring(record.guid)
        return inventory_action_decision(rt, key, prefix .. tostring(record.prefab),
            Survival.PRIORITY_GEAR, "EQUIP", record.entity)
    end

    -- 湿：弹簧伞（防水 MED）优先，其次头部草帽
    if is_finite_number(moisture) and moisture >= Survival.WET_EQUIP then
        if not (dark and hands_is_light) and hands_prefab ~= "grass_umbrella" then
            local record = find_owned_prefab(snapshot, { grass_umbrella = true })
            if record ~= nil then
                return equip("gear:umbrella:", record), nil
            end
        end
        if head_prefab == nil then
            local record = find_owned_prefab(snapshot, { strawhat = true })
            if record ~= nil then
                return equip("gear:strawhat:", record), nil
            end
        end
    end

    -- 热：小风扇（手持 endothermic 降温），其次草帽（头部夏季隔热）
    if is_finite_number(temp) and temp >= Survival.HOT_WARN then
        if head_prefab == "winterhat" then
            return inventory_action_decision(rt, "gear:remove:winterhat", "gear:remove:winterhat",
                Survival.PRIORITY_GEAR, "UNEQUIP", snapshot.equipment[head_slot].entity), nil
        end
        if not (dark and hands_is_light) and hands_prefab ~= "minifan" then
            local record = find_owned_prefab(snapshot, { minifan = true })
            if record ~= nil then
                return equip("gear:minifan:", record), nil
            end
        end
        if head_prefab == nil then
            local record = find_owned_prefab(snapshot, { strawhat = true })
            if record ~= nil then
                return equip("gear:strawhat:", record), nil
            end
        end
    end

    if is_finite_number(temp) and temp <= 20 and head_prefab ~= "winterhat" then
        local record = find_owned_prefab(snapshot, { winterhat = true })
        if record ~= nil then return equip("gear:winterhat:", record), nil end
    end
    return nil, nil
end

--------------------------------------------------------------------------
-- [喵喵喵] 基地锚点：只用“看得见的营地”当证据——附近真有烧着的火、脚下是陆地、
-- 周围 BASE_MIN_SAFE 内没威胁。锚点写进 Exploration.SetBase（持久纯坐标），
-- 本文件只留一份运行期缓存用于距离判断；回营用 Exploration.BaseGoal。
--------------------------------------------------------------------------

local function choose_base(snapshot, state, rt)
    if snapshot.platform ~= nil then
        return nil, "base:on_platform"
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil, "base:no_position"
    end
    if map_is_ocean(px, pz) ~= false then
        return nil, "base:not_land"
    end
    local nearest = nearest_threat(snapshot)
    if nearest ~= nil and nearest.distance < Survival.BASE_MIN_SAFE then
        return nil, string.format("base:threat_near|d=%.1f", nearest.distance)
    end
    if type(rt.base) == "table" and is_finite_number(rt.base.x) and is_finite_number(rt.base.z) then
        return nil, "base:anchored"
    end
    local saved = Exploration.BaseGoal(state, snapshot, false)
    if type(saved) == "table" then
        rt.base = { x = saved.x, z = saved.z, cycle = snapshot.cycles, t = now() }
        return nil, "base:restored"
    end
    local fire = nearest_burning(snapshot, Survival.BASE_FIRE_RADIUS)
        or nearest_burning(snapshot, Survival.BASE_FIRE_RADIUS, true)
    if fire == nil or not CAMP_FIRES[fire.record.prefab] then
        return nil, "base:no_camp_fire"
    end
    local bx, bz = fire.record.x, fire.record.z
    local ok, detail = Exploration.SetBase(state, snapshot, bx, bz)
    rt.base = { x = bx, z = bz, cycle = snapshot.cycles, t = now() }
    return nil, string.format("base:set_%s|%s", tostring(ok), tostring(detail))
end

local function base_return_decision(rt, snapshot, state)
    if type(rt.base) ~= "table" or not is_finite_number(rt.base.x) then
        return nil, "base:none"
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil, "base:no_position"
    end
    local dx, dz = px - rt.base.x, pz - rt.base.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist <= Survival.BASE_RETURN_DIST then
        return nil, string.format("base:near|d=%.1f", dist)
    end
    -- [喵喵喵]: 只在“天快黑了”或“季节快换”时回营（不把回营当默认行为）：
    -- 夜里换季节最容易出事，回营靠火比在外面冒险强。
    local phase = read_phase(snapshot)
    local progress = snapshot.season_progress
    local evening = phase == "dusk"
    local late_season = is_finite_number(progress) and progress >= Survival.BASE_RETURN_PROGRESS
    if not evening and not late_season then
        return nil, string.format("base:not_needed|d=%.1f", dist)
    end
    local goal, why = Exploration.BaseGoal(state, snapshot, false)
    if type(goal) ~= "table" then
        -- [喵喵喵]: Exploration 那边没有记录时，用本文件缓存的纯坐标自己拼一个同形状 goal。
        goal = { x = rt.base.x, z = rt.base.z, range = Navigation.GOAL_RANGE }
        why = "own_base|" .. tostring(why)
    end
    local priority = Survival.PRIORITY_BASE
    return {
        key = "base:return",
        priority = priority,
        purpose = "base:return",
        origin = "survival",
        plan = function()
            local id = command_id(rt, "base:return")
            return {
                via = "navigation",
                goal = {
                    x = goal.x,
                    z = goal.z,
                    range = num_or(goal.range, Navigation.GOAL_RANGE),
                    priority = priority,
                    id = id,
                },
                id = id,
                purpose = "base:return",
                owner = Survival.OWNER,
                stage = "base:return",
                priority = priority,
            }, nil
        end,
    }, nil
end

local function explore_decision(rt, player, snapshot, state)
    local starving = is_finite_number(snapshot.hunger) and snapshot.hunger <= Survival.HUNGER_STARVE
    local priority = starving and Survival.PRIORITY_STARVE or Survival.PRIORITY_EXPLORE
    local purpose = starving and "vital:search:food" or "explore"
    return {
        key = purpose,
        priority = priority,
        purpose = purpose,
        origin = "exploration",
        plan = function()
            local goal, why = Exploration.Next(player, snapshot, state)
            if type(goal) ~= "table" then
                return nil, purpose .. ":<" .. tostring(why) .. ">"
            end
            local id = goal.id ~= nil and tostring(goal.id) or command_id(rt, purpose)
            if starving then goal.priority = priority end
            return {
                via = "navigation",
                goal = goal,
                id = id,
                purpose = purpose .. ":" .. tostring(goal.kind),
                owner = Survival.OWNER,
                stage = purpose,
                priority = priority,
                explore_goal = goal,
            }, nil
        end,
    }
end

--------------------------------------------------------------------------
-- [喵喵喵] 下发（登记持有记录，不执行）：命令一旦返回给调用方，
-- 直到收到同 id 的终态回执为止都算“在飞”，期间不再重复下发。
-- preempt 描述“因为这次命令而被顶下去的旧命令”，runner 据它先撤执行器。
--------------------------------------------------------------------------

local function dispatch(rt, decision, preempt)
    local cmd, reason = nil, nil
    if type(decision.cmd) == "table" then
        cmd = decision.cmd
    elseif type(decision.plan) == "function" then
        cmd, reason = decision.plan()
    end
    if type(cmd) ~= "table" then
        -- [喵喵喵]: 没拿到命令时只做两件“有界记账”，绝不当成完成：
        --   satisfied:..  Supplies 认为你其实已经有了，与本次观测矛盾 → 短暂作废这一步；
        --   gave_up:..   它自己的预算已放弃 → 推进 attempt（下次是新 id/新预算）并冷却，
        --                让下一条可达请求（torch -> campfire）接手。
        if type(reason) == "string" then
            if string.find(reason, "satisfied:", 1, true) ~= nil then
                mark_blocked(rt, decision.key)
            elseif string.find(reason, "gave_up:", 1, true) ~= nil then
                bump_attempt(rt, decision.key)
                mark_blocked(rt, decision.key)
            elseif decision.origin == "supplies" then
                -- [喵喵喵]: 软原因（need_fire/need_tool/in_flight 等）只算“此刻做不了”：
                -- 短暂让给下一条储备请求，不让同一个请求堵死整条储备链。
                soft_block(rt, decision.key)
            end
        end
        return nil, short(reason or "no_command", 96)
    end
    -- [喵喵喵]: 己方命令带上顶替信息（runner 先撤旧执行器再跑新的）；
    -- Supplies 的命令保持原样，顶替信息只出现在返回的 reason 里。
    if type(preempt) == "table" and cmd.owner == Survival.OWNER then
        cmd.preempt = preempt
    end
    if decision.origin == "supplies" and type(rt.soft) == "table" then
        rt.soft[decision.key], rt.softn[decision.key] = nil, nil
    end
    rt.active = {
        id = cmd.id,
        owner = cmd.owner,
        via = cmd.via,
        purpose = cmd.purpose,
        key = decision.key,
        priority = decision.priority,
        command = cmd,
        t = now(),
        polls = 0,
    }
    local tail = ""
    if type(preempt) == "table" then
        tail = string.format("|preempt=%s|suspended=%s",
            tostring(preempt.purpose), tostring(preempt.suspended == true))
    end
    return cmd, "planned:" .. tostring(cmd.purpose) .. tail
end

--------------------------------------------------------------------------
-- [喵喵喵] 回执状态归一：接受执行层/探索层的同义写法，其余一律拒绝，不猜。
--------------------------------------------------------------------------

local function normalize_status(status)
    if status == "succeeded" or status == "arrived" then
        return "succeeded"
    elseif status == "failed" or status == "blocked" or status == "refused" then
        return "failed"
    elseif status == "pending" then
        return "pending"
    end
    return nil
end

-- [喵喵喵]: Supplies.Report 的回执前缀就是它的终态语义：
--   terminal:succeeded|stage  成功
--   retry:stage#n|reason      本阶段失败并已记账（下一次是新 attempt）
--   gave_up:stage|reason      该请求放弃（必须换请求/换 id）
--   stalled:age=..            它自己的 pending 预算到点
--   pending_recorded...       仍在飞
local function supply_terminal(detail)
    local text = tostring(detail)
    return string.sub(text, 1, 9) == "terminal:"
        or string.sub(text, 1, 6) == "retry:"
        or string.sub(text, 1, 8) == "gave_up:"
        or string.sub(text, 1, 8) == "stalled:"
end

local function supply_failure(detail)
    local text = tostring(detail)
    return string.sub(text, 1, 6) == "retry:"
        or string.sub(text, 1, 8) == "gave_up:"
        or string.sub(text, 1, 8) == "stalled:"
end

--------------------------------------------------------------------------
-- [喵喵喵] 对外接口一：决定下一步。绝不执行、绝不下发、绝不改世界。
--------------------------------------------------------------------------

function Survival.Plan(player, snapshot, state)
    if type(state) ~= "table" then
        return nil, "state_not_table"
    end
    if type(snapshot) ~= "table" then
        return nil, "snapshot_not_table"
    end
    if not is_valid(player) then
        return nil, "player_invalid"
    end
    if ThePlayer ~= nil and player ~= ThePlayer then
        return nil, "not_local_player"
    end

    -- [喵喵喵]: 换世界/换分片时先把旧世界的持有命令按规矩交还（转发取消给 Supplies），
    -- 再让 ensure_runtime 重置本文件的记账——顺序反过来就会丢掉反馈、留下孤儿记录。
    -- 挂起命令同样属于旧世界，必须一并显式收尾。
    local previous = state.survival
    local world = world_key_of(snapshot)
    if type(previous) == "table" and type(previous.world) == "string" and previous.world ~= world then
        if type(previous.active) == "table" then
            release_active(state, previous, "world_changed")
        end
        if type(previous.suspended) == "table" then
            finalize_suspended(state, previous, "world_changed")
        end
    end
    local rt = ensure_runtime(state, snapshot)

    -- [喵喵喵]: 快照未就绪：不臆测任何状态；已持有的命令继续等它的回执。
    if snapshot.ready ~= true then
        local why = "snapshot_not_ready:" .. tostring(snapshot.ready_reason)
        if type(rt.active) == "table" then
            return nil, "in_flight:" .. tostring(rt.active.purpose) .. "|" .. why
        end
        return nil, why
    end

    -- [喵喵喵]: 本模块只操作 Wilson 本人。
    local prefab = snapshot.prefab
    if prefab ~= "wilson" then
        return nil, "not_wilson:" .. tostring(prefab)
    end
    if not is_finite_number(snapshot.x) or not is_finite_number(snapshot.z) then
        return nil, "snapshot_no_position"
    end

    rt.day = snapshot.day
    rt.season = read_season(snapshot)
    rt.demands = {}

    -- [喵喵喵]: 已经下过 challenge_failed 结论就一直保持一致，不再产生任何命令。
    if type(rt.failed) == "table" then
        return nil, string.format("challenge_failed:%s|day=%s",
            tostring(rt.failed.reason), tostring(rt.failed.day))
    end

    -- [喵喵喵]: 生命状态先于一切动作：幽灵/血量归零就是本局结束的明确结论，
    -- 不复活、不喂食、不发任何“死后还能继续”的动作。
    local fail_reason = nil
    if snapshot.ghost == true then
        fail_reason = "player_ghost"
    elseif is_finite_number(snapshot.health) and snapshot.health <= 0 then
        fail_reason = "health_depleted"
    end
    if fail_reason ~= nil then
        release_active(state, rt, "challenge_failed:" .. fail_reason)
        finalize_suspended(state, rt, "challenge_failed:" .. fail_reason)
        rt.failed = { reason = fail_reason, day = snapshot.day, t = now() }
        return nil, string.format("challenge_failed:%s|day=%s",
            fail_reason, tostring(snapshot.day))
    end

    -- [喵喵喵]: 基地锚点是纯维护动作（无命令）：只在看得见的营地/安全地面上升级它，
    -- 并写进 Exploration 的持久记录；日志只留在 rt.base_note 里供诊断。
    local _, base_note = choose_base(snapshot, state, rt)
    rt.base_note = base_note

    -- [喵喵喵]: 有界持有：长时间收不到终态就按预算收掉，并把取消转发回原策略。
    if type(rt.active) == "table" then
        local held = now() - (is_finite_number(rt.active.t) and rt.active.t or now())
        if held > Survival.MAX_HOLD then
            release_active(state, rt, string.format("hold_expired:%.1f", held))
        end
    end

    -- [喵喵喵]: 次序：逃命 > 照明 > 环境(冷/热/湿) > 身体(治疗/进食/装备) > 储量 > 探索。
    local escape, escape_reason = choose_escape(player, snapshot, state, rt)
    if type(escape) == "table" and escape.key == "escape:wait"
        and (read_phase(snapshot) == "night" or read_light(snapshot) == "dark") then
        -- [喵喵喵]: 退路未确认时仍可原地装备现成光源，但不以点灯为由重开采购或远行。 (2026-11-12)
        local immediate = choose_light(player, snapshot, state, rt)
        if type(immediate) == "table" and string.sub(immediate.key or "", 1, 12) == "light:equip:" then
            escape = immediate
        end
    end
    local light, light_reason = nil, nil
    local env, env_reason = nil, nil
    local vitals, vitals_reason = nil, nil
    local stock, stock_reason = nil, nil
    local gear, gear_reason = nil, nil
    local season, season_reason = nil, nil
    if type(escape) ~= "table" then
        light, light_reason = choose_light(player, snapshot, state, rt)
        if type(light) == "table" and light.key == "light:hold" then
            local immediate = choose_vitals(player, snapshot, state, rt)
            if type(immediate) == "table" and immediate.origin == "survival" then
                light = nil
                vitals = immediate
            end
        end
        if (type(light) ~= "table" or (light.key == "light:reserve_fuel"
            and light.priority < Survival.PRIORITY_LIGHT)) and vitals == nil then
            env, env_reason = choose_environment(player, snapshot, state, rt)
            if type(env) == "table" and env.key == "env:hold" then
                -- [喵喵喵]: 温度恢复期间允许原地进食、治疗和换装；不让采购/探索把角色拉离冷热源。
                local immediate = choose_vitals(player, snapshot, state, rt)
                if type(immediate) == "table" and immediate.origin == "survival" then
                    env = nil
                    vitals = immediate
                end
            end
            if type(env) ~= "table" and vitals == nil then
                vitals, vitals_reason = choose_vitals(player, snapshot, state, rt)
                if is_finite_number(snapshot.hunger) and snapshot.hunger <= Survival.HUNGER_STARVE
                    and (type(vitals) ~= "table" or vitals.priority < Survival.PRIORITY_STARVE) then
                    -- [喵喵喵]: 食物请求冷却不代表饥荒解除；继续安全找食，不能回退补草、装备或建设。 (2026-11-12)
                    vitals = explore_decision(rt, player, snapshot, state)
                end
                if type(vitals) ~= "table" or (vitals.origin == "supplies" and vitals.priority < Survival.PRIORITY_STARVE) then
                    stock, stock_reason = choose_stock(player, snapshot, state, rt)
                    gear, gear_reason = choose_season_gear(player, snapshot, state, rt)
                    local reserves, reserves_reason = choose_reserves(player, snapshot, state, rt)
                    if type(gear) ~= "table" or (type(reserves) == "table" and reserves.priority > gear.priority) then
                        gear, gear_reason = reserves, reserves_reason
                    end
                    local food = count_food_total(snapshot)
                    local fed = is_finite_number(snapshot.hunger) and snapshot.hunger >= 0.6
                    if food ~= nil and (food >= Survival.FOOD_RESERVE or fed)
                        and (count_owned(snapshot, "torch") or 0) >= 1
                        and (count_owned(snapshot, "cutgrass") or 0) >= 4
                        and (count_owned(snapshot, "twigs") or 0) >= 2 then
                        season, season_reason = choose_season(player, snapshot, state, rt)
                    end
                end
            end
        end
    end
    -- [喵喵喵]: 危险解除时清理本次遭遇的撤退计数与命令身份。
    if type(escape) ~= "table" and escape_reason == nil then
        rt.escape_runs = 0
        -- [喵喵喵]: 仅在确认安全后重置身份，持续撤退中的终态仍须由新 ID 区分。
        if type(rt.attempts) == "table" then
            rt.attempts["escape:fire"] = nil
            rt.attempts["escape:threat"] = nil
            rt.attempts["escape:drown"] = nil
            rt.attempts["escape:hounds"] = nil
        end
        if type(rt.blocked) == "table" then
            rt.blocked["escape:fire"] = nil
            rt.blocked["escape:threat"] = nil
            rt.blocked["escape:drown"] = nil
            rt.blocked["escape:hounds"] = nil
        end
    end

    local candidates = { escape, light, env, vitals, stock, gear, season }
    local primary
    for i = 1, 7 do
        local candidate = candidates[i]
        if type(candidate) == "table" and (primary == nil or candidate.priority > primary.priority) then
            primary = candidate
        end
    end
    local nearby, nearby_better
    -- [喵喵喵]: 只有非危急采购参与就近合并；实际进食/换装、临夜备灯和避险保持原有抢占。 (2026-11-12)
    if (primary == nil or (primary.origin == "supplies" and primary.priority < Survival.PRIORITY_STARVE))
        and (light == nil or (is_finite_number(snapshot.time_until_night)
            and snapshot.time_until_night > Supplies.PLAN_TIMEOUT))
        and (rt.active == nil or (rt.active.via == "navigation"
            and (rt.active.owner == SUPPLIES_OWNER or rt.active.key == "explore")
            and rt.active.priority < Survival.PRIORITY_STARVE)) then
        local request = Supplies.NearbyRequest(player, snapshot, state, rt.demands, primary and primary.request)
        local key = request and ("nearby:" .. request.item .. ":" .. tostring(request.guid))
        if key ~= nil and not is_blocked(rt, key) then
            nearby_better = rt.active == nil
            if rt.active ~= nil then
                local goal = rt.active.command and rt.active.command.goal
                if goal ~= nil and is_finite_number(goal.x) and is_finite_number(goal.z) then
                    local distance = math.sqrt((goal.x - snapshot.x)^2 + (goal.z - snapshot.z)^2)
                    nearby_better = request.distance + Navigation.GOAL_RANGE < distance
                end
            end
            if nearby_better then
                local priority = math.max(primary and primary.priority or Survival.PRIORITY_EXPLORE,
                    rt.active and rt.active.priority or Survival.PRIORITY_EXPLORE)
                nearby = supplies_request_decision(rt, player, snapshot, state,
                    key, "acquire:" .. request.item, priority, request.item, request.count)
                candidates[8] = nearby
            end
        end
    end
    if type(rt.active) == "table" then
        -- [喵喵喵]: 同一采购随饥饿恶化升级优先级，不重发动作，也不能再被未来的备灯采购抢占。 (2026-11-12)
        for i = 1, 8 do
            local decision = candidates[i]
            if type(decision) == "table" and decision.key == rt.active.key then
                rt.active.priority = decision.priority
            end
        end
        local candidate = nil
        for i = 1, 8 do
            local decision = candidates[i]
            if type(decision) == "table"
                and decision.key ~= rt.active.key
                -- [喵喵喵]: 普通需求只改道移动，不打断已开始的采集或连续砍挖；危急抢占照常。 (2026-11-12)
                and not (rt.active.owner == SUPPLIES_OWNER and rt.active.via == "actions"
                    and decision.origin == "supplies" and decision.priority < Survival.PRIORITY_STARVE)
                and (decision.priority > rt.active.priority
                    or decision == nearby
                    or (decision.priority == rt.active.priority
                        and ((decision.origin == "survival" and rt.active.owner == SUPPLIES_OWNER)
                            -- [喵喵喵]: 进入备灯窗口后停止非危急绕路，同级照明请求也必须接管移动。 (2026-11-12)
                            or (decision == light and string.sub(rt.active.key or "", 1, 7) == "nearby:"
                                and (not is_finite_number(snapshot.time_until_night)
                                    or snapshot.time_until_night <= Supplies.PLAN_TIMEOUT))
                            or rt.active.key == "vital:search:food")))
                and (candidate == nil or decision.priority > candidate.priority
                    or (decision == nearby and decision.priority == candidate.priority)) then
                candidate = decision
            end
        end
        if candidate ~= nil then
            local preempt = suspend_active(state, rt)
            return dispatch(rt, candidate, preempt)
        end
        local tail = ""
        if type(escape) == "table" then
            tail = "|waiting:" .. tostring(escape.purpose)
        elseif type(light) == "table" then
            tail = "|waiting:" .. tostring(light.purpose)
        elseif type(env) == "table" then
            tail = "|waiting:" .. tostring(env.purpose)
        elseif type(vitals) == "table" then
            tail = "|waiting:" .. tostring(vitals.purpose)
        elseif type(stock) == "table" then
            tail = "|waiting:" .. tostring(stock.purpose)
        elseif type(gear) == "table" then
            tail = "|waiting:" .. tostring(gear.purpose)
        elseif type(season) == "table" then
            tail = "|waiting:" .. tostring(season.purpose)
        elseif escape_reason ~= nil or light_reason ~= nil
            or env_reason ~= nil or vitals_reason ~= nil
            or stock_reason ~= nil or gear_reason ~= nil or season_reason ~= nil then
            tail = "|" .. tostring(informative_reason(escape_reason)
                or informative_reason(env_reason)
                or informative_reason(vitals_reason)
                or informative_reason(stock_reason)
                or informative_reason(gear_reason)
                or informative_reason(season_reason)
                or light_reason)
        end
        return nil, "in_flight:" .. tostring(rt.active.purpose) .. tail
    end

    -- [喵喵喵]: 空闲与在途使用同一优先级；备灯储量不能因排列在前而压过饥荒求食。 (2026-11-12)
    local decision = nil
    for i = 1, 8 do
        local candidate = candidates[i]
        if type(candidate) == "table" and (decision == nil or candidate.priority > decision.priority
            or (candidate == nearby and candidate.priority == decision.priority)) then
            decision = candidate
        end
    end
    local decision_reason = informative_reason(escape_reason)
        or informative_reason(env_reason)
        or informative_reason(vitals_reason)
        or informative_reason(stock_reason)
        or informative_reason(gear_reason)
        or informative_reason(season_reason)
        or light_reason

    -- [喵喵喵]: 挂起的是一条 Supplies 命令时，新发出的 Supplies 请求会被它自己的
    -- 单在飞槽位挡住（in_flight:..|request_pending_switch），所以先把挂起的那条恢复执行。
    if type(decision) == "table"
        and decision.origin == "supplies"
        and type(rt.suspended) == "table" then
        return resume_suspended(state, rt, "resumed_before:" .. tostring(decision.purpose))
    end

    -- [喵喵喵]: 没有即时决定且没有挂起命令，才轮到储量/回营/探索（都不抢别人的在飞槽位）。
    if type(decision) ~= "table" and type(rt.suspended) ~= "table" then
        local reserves, reserves_reason = choose_reserves(player, snapshot, state, rt)
        if type(reserves) == "table" then
            decision = reserves
        elseif reserves_reason ~= nil then
            decision_reason = decision_reason or reserves_reason
        end
        if type(decision) ~= "table" then
            local base_decision, base_reason = base_return_decision(rt, snapshot, state)
            if type(base_decision) == "table" then
                decision = base_decision
            elseif base_reason ~= nil then
                decision_reason = decision_reason or base_reason
            end
        end
        if type(decision) ~= "table" then
            -- [喵喵喵]: 漆黑且手上没有光源时不往外走：Exploration.Next 自己不看光照。
            local light_state = read_light(snapshot)
            if light_state == "dark" and equipped_light(snapshot) == nil then
                decision_reason = "explore_blocked:dark_no_light|" .. tostring(decision_reason or "no_action")
            else
                decision = explore_decision(rt, player, snapshot, state)
            end
        end
    end

    if type(decision) == "table" then
        local cmd, why = dispatch(rt, decision, nil)
        if cmd ~= nil and decision.priority >= Survival.PRIORITY_ESCAPE then
            rt.escape_runs = num_or(rt.escape_runs, 0) + 1
        end
        return cmd, why
    end

    -- [喵喵喵]: 没有新决定时优先恢复被挂起的采购命令（同一 id 原样交出），
    -- 而不是把它晾在那里等超时。
    local resumed, rdetail = resume_suspended(state, rt, "resumed_idle")
    if resumed ~= nil then
        return resumed, rdetail
    end

    -- [喵喵喵]: nil 是明确的“本轮无动作”，原因里带上观测到的相位/光照/未知项，
    -- 不是“已经安全”，也不是完成。
    return nil, decision_reason or "no_action"
end

--------------------------------------------------------------------------
-- [喵喵喵] 对外接口二：记录执行回执。只记账，绝不下发任何动作。
-- 回执必须与当前持有的命令同 id；迟到/别人的回执一律拒绝，绝不误清记录。
--------------------------------------------------------------------------

-- [喵喵喵]: 成功计数（只用于进度/日志，不参与任何判定）。
local function count_success(rt, key)
    local text = tostring(key)
    if string.sub(text, 1, 11) == "vital:equip" then
        rt.equips = num_or(rt.equips, 0) + 1
    elseif string.sub(text, 1, 10) == "vital:heal" then
        rt.heals = num_or(rt.heals, 0) + 1
    elseif string.sub(text, 1, 9) == "vital:eat" then
        rt.eats = num_or(rt.eats, 0) + 1
    elseif string.sub(text, 1, 5) == "gear:" then
        rt.gears = num_or(rt.gears, 0) + 1
    elseif string.sub(text, 1, 11) == "light:equip" then
        rt.lights = num_or(rt.lights, 0) + 1
    end
end

function Survival.Report(state, command, status, reason)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    local rt = state.survival
    if type(rt) ~= "table" then
        return false, "no_runtime"
    end
    if type(command) ~= "table" then
        return false, "command_not_table"
    end
    if command.owner ~= Survival.OWNER and command.owner ~= SUPPLIES_OWNER then
        return false, "foreign_command:" .. tostring(command.owner)
    end
    local normalized = normalize_status(status)
    if normalized == nil then
        return false, "bad_status:" .. tostring(status)
    end

    -- [喵喵喵]: 回执归属只看 id：先认当前在飞那条，不是它就是被挂起那条的迟到回执，
    -- 两者都不是才报错。这样“已经交给 executor 又被挂起”的那条不会把它的终态丢掉，
    -- 也不会把当前在飞的新命令误判成它的。
    local current = rt.active
    local suspended = rt.suspended
    local record = nil
    local is_current = false
    if type(current) == "table" and current.id == command.id then
        record = current
        is_current = true
    elseif type(suspended) == "table" and suspended.id == command.id then
        record = suspended
    elseif type(current) == "table" then
        return false, "not_current_command"
    else
        return false, "no_in_flight"
    end

    rt.last = {
        id = record.id,
        owner = record.owner,
        status = normalized,
        reason = short(reason, 96),
        suspended = not is_current,
        t = now(),
    }

    -- [喵喵喵]: 释放只动“这条记录”自己：在飞的清 rt.active，挂起的清 rt.suspended。
    -- 处理迟到回执时绝不能把当前在飞的新命令一起抹掉（那才会造成两个控制器/丢记账）。
    local function drop_record()
        if is_current then
            if rt.active == record then
                rt.active = nil
            end
        elseif rt.suspended == record then
            rt.suspended = nil
        end
    end

    -- [喵喵喵]: Supplies 产出的命令：每一个回执都原样转发（含被挂起那条的迟到终态），
    -- 由它自己记账/放弃；本文件只同步“这条是否还算在飞”。
    if record.owner == SUPPLIES_OWNER then
        local target = type(record.command) == "table" and record.command or command
        local ok, detail = Supplies.Report(state, target, normalized, reason)
        local text = short(detail, 96)
        if ok ~= true then
            -- [喵喵喵]: 它已经不再认这条记录（迟到/被替换/换世界）：本文件对应的持有记录也必须
            -- 同步清掉，否则会永久 in_flight 把后续规划堵死。
            drop_record()
            return false, "supplies_rejected:" .. tostring(text)
        end
        if supply_terminal(text) then
            drop_record()
            if supply_failure(text) then
                local key = tostring(record.key)
                if bump_attempt(rt, key) >= Survival.STEP_FAIL_LIMIT then
                    mark_blocked(rt, key)
                end
            end
            return true, "forwarded:" .. tostring(text)
                .. (is_current and "" or "|was_suspended")
        end
        return true, "forwarded:" .. tostring(text)
    end

    -- 己方命令：没有第三方记账，只维护本文件自己的重试/有界预算。
    if normalized == "pending" then
        if not is_current then
            -- [喵喵喵]: 被挂起那条的 pending 回执照旧算“它还在飞”，但不推进本文件的
            -- 轮询预算（它由 SUSPEND_TTL 兜底），也不把它重新激活。
            return true, "pending_recorded:suspended|purpose=" .. tostring(record.purpose)
        end
        record.polls = num_or(record.polls, 0) + 1
        local age = now() - (is_finite_number(record.t) and record.t or now())
        if age <= Survival.MAX_HOLD and record.polls <= Survival.MAX_POLLS then
            return true, string.format("pending_recorded:polls=%d|age=%.1f", record.polls, age)
        end
        drop_record()
        bump_attempt(rt, record.key)
        mark_blocked(rt, record.key)
        return true, string.format("hold_expired:polls=%d|age=%.1f|%s",
            record.polls, age, short(reason, 48))
    end

    drop_record()
    local key = tostring(record.key)
    -- [喵喵喵]: 来自 Exploration.Next 的 goal 必须把“到了/走不通”回灌给探索层，
    -- 否则同一前沿永远不会解除它的阻塞计数。
    if type(record.command) == "table" and record.command.explore_goal ~= nil then
        Exploration.Report(state, record.command.explore_goal,
            normalized == "succeeded" and "arrived" or "blocked", reason)
    end
    if normalized == "succeeded" then
        -- [喵喵喵]: 成功也推进 attempt：下一次同一逻辑步（例如再回一次营、再跑一趟火边）
        -- 拿到的是**新 id**，不会撞上 Navigation/Actions 对同一身份的终态闩存。
        -- 轮询期间 id 仍然不变（当时没有终态、不会走到这里）。
        if type(rt.attempts) == "table" then
            rt.attempts[key] = attempt_of(rt, key) + 1
        end
        count_success(rt, key)
        return true, "terminal:succeeded|" .. key
    end
    -- [喵喵喵]: 失败推进命令身份；普通操作触顶后冷却，逃生则保留下一快照重评的机会。
    local n = bump_attempt(rt, key)
    if n >= Survival.STEP_FAIL_LIMIT then
        mark_blocked(rt, key)
    end
    return true, string.format("terminal:failed|%s|a%d|%s", key, n, short(reason, 64))
end

--------------------------------------------------------------------------
-- [喵喵喵] 显式交出：调用方换控制器/收尾时用；仍然走同一套“先转发再清记录”。
--------------------------------------------------------------------------

function Survival.Cancel(state)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    local rt = state.survival
    if type(rt) ~= "table" then
        return false, "no_runtime"
    end
    if type(rt.active) ~= "table" then
        -- [喵喵喵]: 只有挂起记录时也算有东西要交还，不能回 no_in_flight 把它留在那里。
        if type(rt.suspended) == "table" then
            local sok, sdetail = finalize_suspended(state, rt, "cancelled_by_caller")
            return sok == true, "suspended:" .. tostring(sdetail)
        end
        return false, "no_in_flight"
    end
    local ok, detail = release_active(state, rt, "cancelled_by_caller")
    if type(rt.suspended) == "table" then
        finalize_suspended(state, rt, "cancelled_by_caller")
    end
    return ok == true, tostring(detail)
end

--------------------------------------------------------------------------
-- [喵喵喵] 最小可持久化进度：只挑纯值(number/string/boolean)，不含实体引用、
-- 函数、回调或 GetTime 相对时限，因此可以安全写进存档。
--------------------------------------------------------------------------

function Survival.Progress(state)
    if type(state) ~= "table" then
        return nil
    end
    local rt = state.survival
    if type(rt) ~= "table" then
        return nil
    end
    local blocked = 0
    if type(rt.blocked) == "table" then
        for _ in pairs(rt.blocked) do
            blocked = blocked + 1
        end
    end
    local failed = type(rt.failed) == "table" and rt.failed or nil
    return {
        v = Survival.SCHEMA_VERSION,
        world = type(rt.world) == "string" and rt.world or nil,
        day = is_finite_number(rt.day) and rt.day or nil,
        lights = num_or(rt.lights, 0),
        gear_wears = num_or(rt.gears, 0),
        fails = num_or(rt.fails, 0),
        season = type(rt.season) == "string" and rt.season or nil,
        base_x = type(rt.base) == "table" and is_finite_number(rt.base.x) and rt.base.x or nil,
        base_z = type(rt.base) == "table" and is_finite_number(rt.base.z) and rt.base.z or nil,
        eats = num_or(rt.eats, 0),
        heals = num_or(rt.heals, 0),
        equips = num_or(rt.equips, 0),
        escape_runs = num_or(rt.escape_runs, 0),
        suspended = type(rt.suspended) == "table" and tostring(rt.suspended.purpose) or nil,
        blocked = blocked,
        failed = failed ~= nil and tostring(failed.reason) or nil,
        failed_day = failed ~= nil and is_finite_number(failed.day) and failed.day or nil,
    }
end

return Survival
