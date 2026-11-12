--============================================================================
-- [喵喵喵]: WilsonExpedition / 航行层（第一版，纯客户端）
--
-- 本文件只做三件事：把“开船/上船/下船”翻译成原版鼠标左键那条链路上的动作，
-- 用共享的 Actions.Step 下发，再用调用方给的最新 snapshot 观察结果。
-- 不写服务端组件、不做原始位移、不瞬移、不读隐藏世界信息、不依赖诊断 mod。
--
-- 对外接口：
--   Sailing.Step(player, snapshot, state, goal) -> status, reason
--       status: "pending"|"succeeded"|"failed"；player 必须是本地玩家。
--   Sailing.Cancel(player, state) -> ok(boolean), reason
--       只撤“本模块当次确实拥有”的那一条 Actions 操作，绝不碰别人的。
--
-- goal 契约（只认这些字段，其它字段一律忽略）：
--   goal = {
--     id       = <任意>|nil   稳定身份；终结(成功/失败)按 id+模式+目标+分片闩存，
--                            重复跑同一个 id 只回闩存结果，再来一次必须换新 id。
--     mode     = "sail"|"board"|"land"
--                sail  = 已在船上，划到海面点 (x,z)
--                board = 走到可见的船（原生平台跳跃），(x,z) 用来挑最近那条船；
--                        附近没有可见船且背包里有造船套件时改用 DEPLOY 造船
--                land  = 从船上划近岸并按原生方式下船到陆地点 (x,z)
--     x, z     = number        具体坐标；sail 必须是客户端看得见的海面点（自己的船盖住也算，
--                             但真正的陆地/地面会被拒），land 必须是客户端判定为陆地且不靠地面洞的点
--     range    = number|nil    到点半径(0<r<=40)，缺省按 mode 取 DEFAULT_RANGE
--     priority = number|nil    透传给 Actions.Step
--     boat     = entity|nil    仅 board：显式指定要上的船（必须客户端可见）
--     plank_jump = boolean|nil 仅 land：true 时允许在“落点被客户端地图验证为陆地 +
--                              方向朝目标”前提下用一次原生 ABANDON_SHIP 从跳板跳上岸；
--                              缺省不做（原生跳进水里会掉钱包）。
--   }
--
-- [喵喵喵] 上/下船的原生链路（本 build 核对过的）：BOARDPLATFORM 在原生脚本里根本
-- 没有收集器产出，所以从不伪造它；真正可用的是 walkingplank 收集器：
--   EXTEND_PLANK(右键) → 等 plank_extended 标签 → MOUNT_PLANK(左键, distance=0.5)
--   → 人带 on_walkable_plank → 走上陆地；仅当 goal.plank_jump 且落点已验证才用
--   ABANDON_SHIP(右键)。没有跳板/跳板不可达时，board 才退回原生 WALKTO 平台跳。
--
-- 跨模块硬约束（与 navigation/exploration 一致）：同一玩家同一时刻只能有一个控制器
-- 驱动 Actions（原生只有一条 WALKTO 缓冲）。看到 'held_by_*' 只等待，不抢、不取消别人的
-- 操作；超时如实报 held_by_other_handler。
--
-- 生命周期硬约束：goal 身份 = 模式|目标|半径|id|世界(session 或 TheWorld.GUID)|分片；
-- 换身份/置换运行期/闩存终态前，只释放“我们自己记着且确认过所有权”的那一条操作；
-- 快照未就绪/无坐标有 NOT_READY_TIMEOUT=6s 上限，不会无限 pending。
--
-- 原生依据（逐条对照过 data/databundles/scripts 的实际源码）：
--   * 划桨 = 手持 oar 在海上点右键：POINT 收集器 componentactions.lua 的 oar →
--     Row()(文件开头)；要求 doer 站在 boat 平台上、没有 is_row_failing 标签、
--     不在 row_pre 前几帧，否则给出 ROW_FAIL；picker 侧水面点被 IsPassableAtPoint 拦，
--     只有 oar 自带的 allow_action_on_impassable(prefabs/oar.lua) 才放行。
--   * ROW(actions.lua:566) 的 customarrivecheck=CheckRowRange 用“朝点击点 0.25 外
--     是不是平台”决定先走路还是直接划，所以点击点必须落在我船外的水面上。
--     ROW 与 ROW_FAIL 语义不同，绝不互相顶替。
--   * 上船 = 原生 WALKTO 走向平台点，locomotor 在走路时按 allow_platform_hopping
--     做平台跳跃；BOARDPLATFORM 在原生脚本里没有任何收集器产出，所以这里不伪造。
--   * 锚 = 独立实体(prefabs/anchor.lua: "anchor"/"yotd_anchor"，tag "structure")，
--     anchor_raised/anchor_lowered/anchor_transitioning 由 components/anchor.lua 维护；
--     SCENE 收集器(componentactions.lua) 语义：not anchor_raised 或 transitioning →
--     RAISE_ANCHOR；anchor_raised → LOWER_ANCHOR。
--   * 船血量 = 客户端可读的 healthsyncer 网变量(components/healthsyncer.lua，Common 段
--     的 GetPercent)；船的 health 组件只在主机，replica.health 对船没有 classified，
--     所以不用它，读不到就如实报 unknown。
--   * 船半径 = 客户端组件 boatringdata:GetRadius()(prefabs/boat.lua create_common_pre，
--     早于 ismastersim 返回)，退路 walkableplatform.platform_radius。
--   * 漏 = 客户端可见的 boat_leak 实体(prefabs/boat_leak.lua)；修补 = 背包里带
--     boat_patch 标签的物品对漏执行 REPAIR_LEAK(componentactions.lua 的 boatpatch)。
--   * 造船套件 = 带 boatbuilder/deploykititem 标签的物品(prefabs/boat.lua 共享段)，
--     部署走 kind="use" 的 DEPLOY/DEPLOY_FLOATING(componentactions.lua deployable)。
--============================================================================
local Actions = require("wilsonexpedition/actions")

local Sailing = {}

Sailing.SCHEMA_VERSION = 1

-- [喵喵喵]: 支持的模式；只实现“当前确实需要的操作”，不做占位流程。
Sailing.MODES = { sail = true, board = true, land = true }

Sailing.DEFAULT_RANGE = { sail = 2.5, board = 1.0, land = 1.5 }
Sailing.GOAL_PRIORITY = 0
Sailing.WORLD_LIMIT = 20000

-- [喵喵喵]: 每种模式的整体预算，到点就如实失败，绝不无限 pending。
Sailing.TIMEOUT = { sail = 150, board = 30, land = 200 }

-- [喵喵喵]: 单桨节奏。ROW_REACH_* 只用来找“水面点击点”，不决定船速。
Sailing.ROW_REACH_MIN = 2.2
Sailing.ROW_REACH_STEP = 1.2
Sailing.ROW_REACH_TRIES = 3
Sailing.STROKE_MIN_MOVE = 0.3
Sailing.STROKE_WAIT = 2.6
Sailing.STROKE_SETTLE = 0.35
Sailing.STROKE_MAX_FAIL = 4

-- [喵喵喵]: 划桨前先走到甲板边缘落点，避免 CheckRowRange 判定“还得先走路”。
Sailing.EDGE_RANGE = 1.0
Sailing.EDGE_OFFSET = 0.55

Sailing.HOP_MAX = 6.0
Sailing.AVOID_ANGLE = { 0, 25, -25, 50, -50 }
Sailing.AVOID_RADIUS = 6.5

Sailing.ANCHOR_WAIT = 8.0
Sailing.ANCHOR_APPROACH = 3.0
Sailing.PHASE_TIMEOUT = 20.0

Sailing.REPAIR_PCT = 0.55
Sailing.CRITICAL_PCT = 0.2

Sailing.LAND_APPROACH_PAD = 1.2
Sailing.BOAT_RADIUS_FALLBACK = 4

-- [喵喵喵]: 跳板（walkingplank）相位预算：伸出/上板/走上陆地各自的上限。
Sailing.PLANK_TIMEOUT = 12.0
-- [喵喵喵]: ABANDON_SHIP 的落点只能按“跳板外侧这个距离起”估算（SGwilson 给 motorvel），
-- 实际跳多远是引擎物理，所以只当“必须已验证的保守下限”。
Sailing.PLANK_JUMP_DIST = 2.0

-- [喵喵喵]: 原生 oar prefab 名(prefabs/oar.lua)；客户端没有 oar 组件，也没有专用标签，
-- 只能按 prefab 名认，多一个名字就少一份“以为有桨”。
Sailing.OAR_PREFABS = {
    oar = true,
    oar_driftwood = true,
    oar_monkey = true,
    yotd_oar = true,
}

-- [喵喵喵]: “看得见的障碍/威胁”判定用到的原生标签（自船会单独排除）。
Sailing.OBSTACLE_TAGS = { "boat", "structure", "rock", "mineable", "obstacle", "sea_stack" }

Sailing.ANCHOR_PREFABS = { anchor = true, yotd_anchor = true }

--============================================================================
-- [喵喵喵] 基础工具
--============================================================================
local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

local function is_num(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- [喵喵喵]: 原生 GetTime 做时钟，缺失时退回 os.clock，保证截止时间一定可比。
local function now()
    return type(GetTime) == "function" and GetTime() or os.clock()
end

local function dist(x0, z0, x1, z1)
    local dx, dz = x1 - x0, z1 - z0
    return math.sqrt(dx * dx + dz * dz)
end

local function entity_pos(inst)
    if not is_valid(inst) or inst.Transform == nil then
        return nil
    end
    local ok, x, _, z = pcall(function()
        return inst.Transform:GetWorldPosition()
    end)
    if not ok or not is_num(x) or not is_num(z) then
        return nil
    end
    return x, z
end

local function starts_with(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
end

-- [喵喵喵]: Map 查询一律 pcall 包一层：客户端地图没准备好时返回“未知”，不猜。
local function map_call(name, ...)
    if TheWorld == nil or TheWorld.Map == nil then
        return nil, "map_unavailable"
    end
    local map = TheWorld.Map
    local fn = map[name]
    if fn == nil then
        return nil, "map_method_missing:" .. name
    end
    local ok, result = pcall(fn, map, ...)
    if not ok then
        return nil, "map_error:" .. name
    end
    return result, nil
end

-- [喵喵喵]: 两种“水面”必须分开：
--   point_is_ocean        = ROW 点击点用的严格水面（IsOceanAtPoint 不传 allow_boats，
--                           要求该点不在任何平台上），Row()(componentactions) 就是这么算的。
--   point_is_ocean_goal   = 目标点用的水面（allow_boats=true）：自己的船盖住该点也算水面，
--                           否则 range=2.5 的到点判定永远过不了；但它仍然要求海洋瓦片且不是
--                           视觉地面，所以真正的陆地目标照样被拒。
local function point_is_ocean(x, z)
    local ocean, why = map_call("IsOceanAtPoint", x, 0, z)
    if ocean == nil then
        return nil, why
    end
    if ocean ~= true then
        return false, "not_ocean"
    end
    return true, nil
end

local function point_is_ocean_goal(x, z)
    local ocean, why = map_call("IsOceanAtPoint", x, 0, z, true)
    if ocean == nil then
        return nil, why
    end
    if ocean ~= true then
        return false, "not_ocean"
    end
    return true, nil
end

-- [喵喵喵]: 陆地判定：allow_water=false、exclude_boats=true，再叠一次与 navigation/exploration
-- 同口径的地面洞检查；查询不了就算“未知”，绝不把未知当可走。
local function point_is_land(x, z)
    local passable, why = map_call("IsPassableAtPoint", x, 0, z, false, true)
    if passable == nil then
        return nil, why
    end
    if passable ~= true then
        return false, "not_land"
    end
    -- [喵喵喵]: Vector3 是 Class 造的可调用表，不是 function；构造失败就报未知。
    local okv, pt = pcall(function()
        return Vector3(x, 0, z)
    end)
    if not okv or pt == nil then
        return nil, "vector3_unavailable"
    end
    local near_hole, hwhy = map_call("IsPointNearHole", pt)
    if near_hole == nil then
        return nil, "hole_unknown:" .. tostring(hwhy)
    end
    if near_hole == true then
        return false, "near_hole"
    end
    return true, nil
end

local function platform_at(x, z)
    local plat, why = map_call("GetPlatformAtPoint", x, z)
    if plat == nil then
        -- [喵喵喵]: 查询失败与“这里没有平台”必须分开，否则会把船甲板当海面。
        return nil, why
    end
    return plat, nil
end

--============================================================================
-- [喵喵喵] 观测辅助：船/桨/锚/漏/套件，全部只看 snapshot 与客户端可见副本
--============================================================================
local function is_boat(inst)
    if not is_valid(inst) then
        return false
    end
    local ok, tagged = pcall(function()
        return inst:HasTag("boat")
    end)
    return ok and tagged == true
end

-- [喵喵喵]: 船半径优先读 boatringdata（客户端组件），退路 walkableplatform。
local function platform_radius(boat)
    if is_valid(boat) then
        local ok, radius = pcall(function()
            local ring = boat.components.boatringdata
            return ring ~= nil and ring.GetRadius ~= nil and ring:GetRadius() or nil
        end)
        if ok and is_num(radius) and radius > 0 then
            return radius
        end
        local ok2, radius2 = pcall(function()
            local wp = boat.components.walkableplatform
            return wp ~= nil and wp.platform_radius or nil
        end)
        if ok2 and is_num(radius2) and radius2 > 0 then
            return radius2
        end
    end
    if type(TUNING) == "table" and type(TUNING.BOAT) == "table" and is_num(TUNING.BOAT.RADIUS) then
        return TUNING.BOAT.RADIUS
    end
    return Sailing.BOAT_RADIUS_FALLBACK
end

-- [喵喵喵]: 船血量只认 healthsyncer 的网变量；读不到就是 unknown，绝不假设满血。
local function boat_health(boat)
    if not is_valid(boat) then
        return nil
    end
    local ok, pct = pcall(function()
        local syncer = boat.components.healthsyncer
        return syncer ~= nil and syncer.GetPercent ~= nil and syncer:GetPercent() or nil
    end)
    if ok and is_num(pct) and pct >= 0 then
        return pct
    end
    return nil
end

local function record_entity(record)
    if type(record) ~= "table" then
        return nil
    end
    local ent = record.entity or record.item
    if not is_valid(ent) then
        return nil
    end
    return ent
end

local function nearby_list(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.nearby) ~= "table" then
        return nil
    end
    return snapshot.nearby
end

-- [喵喵喵]: 客户端可见的“这条东西停在哪条船上”，三道原生证据依次用：
--   1) EntityScript:GetCurrentPlatform (锚就是它自己 SetBoat 用的，客户端走 entity:GetPlatform())
--   2) 父实体就是这条船 (ENTITY:GetParent()；甲板挂件/跳板 walkingplank 就是 SetParent 到船上的)
--   3) Map:GetPlatformAtPoint(位置) 的平台查询 (甲板上躺着的东西、动态漏)
-- 返回 true(确实是我们的船)/false(是别的平台/别的船)/nil(查不了)
local function on_boat(ent, boat)
    if not is_valid(ent) or not is_valid(boat) then
        return nil
    end
    local known = false
    if ent.GetCurrentPlatform ~= nil then
        local ok, plat = pcall(function()
            return ent:GetCurrentPlatform()
        end)
        if ok then
            if plat == boat then
                return true
            elseif plat ~= nil then
                return false
            end
            known = true
        end
    end
    -- [喵喵喵]: 父实体是船 → 确定是船的挂件（boatring/hull 的 child，比如跳板）。
    local parent_ok = false
    if ent.entity ~= nil and ent.entity.GetParent ~= nil then
        local okp, parent = pcall(function()
            return ent.entity:GetParent()
        end)
        if okp then
            parent_ok = true
            if parent ~= nil then
                return parent == boat.entity
            end
        end
    end
    if not known and not parent_ok then
        return nil
    end
    -- [喵喵喵]: 两条 Lua 证据都给不出平台，就用客户端地图的平台查询（不靠半径猜）。
    local ex, ez = entity_pos(ent)
    if ex == nil or ez == nil then
        return nil
    end
    local plat2 = platform_at(ex, ez)
    if plat2 == nil then
        return nil
    end
    return plat2 == boat
end

-- [喵喵喵]: 找锚：锚是独立实体，先按 prefab 名/状态标签筛出候选，再必须确认它停在我们这条船上
-- （否则会把隔壁船的锚当自己的）。返回 anchor, why，why ∈ ok/none/foreign/unverified。
local function find_anchor(snapshot, boat)
    local list = nearby_list(snapshot)
    if list == nil then
        return nil, "none"
    end
    local foreign, unverified = false, false
    for i = 1, #list do
        local record = list[i]
        local ent = record_entity(record)
        if ent ~= nil then
            local is_anchor = Sailing.ANCHOR_PREFABS[ent.prefab] == true
            if not is_anchor then
                local ok, tagged = pcall(function()
                    return ent:HasTag("anchor_raised")
                        or ent:HasTag("anchor_lowered")
                        or ent:HasTag("anchor_transitioning")
                end)
                is_anchor = ok and tagged == true
            end
            if is_anchor then
                local mine = on_boat(ent, boat)
                if mine == true then
                    return ent, "ok"
                elseif mine == false then
                    foreign = true
                else
                    unverified = true
                end
            end
        end
    end
    if foreign then
        return nil, "foreign"
    end
    if unverified then
        return nil, "unverified"
    end
    return nil, "none"
end

local function has_tag(ent, tag)
    if not is_valid(ent) then
        return false
    end
    local ok, tagged = pcall(function()
        return ent:HasTag(tag)
    end)
    return ok and tagged == true
end

-- [喵喵喵]: 可见的船：snapshot.nearby 里带 boat 标签的实体（不额外扫世界）。
local function visible_boats(snapshot)
    local out = {}
    local list = nearby_list(snapshot)
    if list == nil then
        return out
    end
    for i = 1, #list do
        local record = list[i]
        local ent = record_entity(record)
        if ent ~= nil and is_boat(ent) then
            local x, z = record.x, record.z
            if not is_num(x) or not is_num(z) then
                x, z = entity_pos(ent)
            end
            out[#out + 1] = { entity = ent, x = x, z = z, guid = record.guid or ent.GUID }
        end
    end
    return out
end

local function nearest_boat(snapshot, x, z, exclude)
    local boats = visible_boats(snapshot)
    local best, best_d = nil, nil
    for i = 1, #boats do
        local entry = boats[i]
        if entry.entity ~= exclude and is_num(entry.x) and is_num(entry.z) then
            local d = (is_num(x) and is_num(z)) and dist(x, z, entry.x, entry.z) or 0
            if best == nil or d < best_d then
                best, best_d = entry, d
            end
        end
    end
    return best
end

local function is_oar_prefab(prefab)
    if type(prefab) ~= "string" then
        return false
    end
    if Sailing.OAR_PREFABS[prefab] == true then
        return true
    end
    -- [喵喵喵]: 原生还有 oar_* 系列命名（如 yotd_oar），按前缀/后缀兜一层。
    return starts_with(prefab, "oar_") or prefab:sub(-4) == "_oar"
end

-- [喵喵喵]: 手持桨：equipment 里 hands 槽就是原生的 EQUIPSLOTS.HANDS。
local function equipped_oar(snapshot)
    local equipment = type(snapshot) == "table" and snapshot.equipment or nil
    if type(equipment) ~= "table" then
        return nil
    end
    local hands_key = (type(EQUIPSLOTS) == "table" and EQUIPSLOTS.HANDS) or "hands"
    local record = equipment[hands_key] or equipment.hands
    local ent = record_entity(record)
    if ent ~= nil and is_oar_prefab(ent.prefab) then
        return ent
    end
    return nil
end

-- [喵喵喵]: 背包里的桨：优先主背包栏(kind=="inventory")，其次溢出/背包。
local function owned_oar(snapshot)
    local inv = type(snapshot) == "table" and snapshot.inventory or nil
    local records = type(inv) == "table" and inv.records or nil
    if type(records) ~= "table" then
        return nil
    end
    local fallback = nil
    for i = 1, #records do
        local record = records[i]
        local ent = record_entity(record)
        if ent ~= nil and is_oar_prefab(ent.prefab) then
            if record.kind == "inventory" then
                return ent
            end
            fallback = fallback or ent
        end
    end
    return fallback
end

-- [喵喵喵]: 造船套件：boatbuilder + deploykititem 都是 prefab 共享段加的标签。
local function owned_boat_kit(snapshot)
    local inv = type(snapshot) == "table" and snapshot.inventory or nil
    local records = type(inv) == "table" and inv.records or nil
    if type(records) ~= "table" then
        return nil
    end
    for i = 1, #records do
        local ent = record_entity(records[i])
        if ent ~= nil and has_tag(ent, "boatbuilder") and has_tag(ent, "deploykititem") then
            return ent
        end
    end
    return nil
end

-- [喵喵喵]: 修补材料：原版 boatpatch / sewing_tape / treegrowthsolution 都带 boat_patch。
local function owned_boat_patch(snapshot)
    local inv = type(snapshot) == "table" and snapshot.inventory or nil
    local records = type(inv) == "table" and inv.records or nil
    if type(records) ~= "table" then
        return nil
    end
    for i = 1, #records do
        local ent = record_entity(records[i])
        if ent ~= nil and has_tag(ent, "boat_patch") then
            return ent
        end
    end
    return nil
end

-- [喵喵喵]: 可见的漏：boat_leak 实体，且必须确认停在我们这条船上；别条船的漏不算。
local function first_visible_leak(snapshot, boat)
    local list = nearby_list(snapshot)
    if list == nil then
        -- [喵喵喵]: 拿不到附近列表就不能说“没有漏”，交给上层写成 unknown。
        return nil, nil
    end
    local found, count = nil, 0
    for i = 1, #list do
        local ent = record_entity(list[i])
        if ent ~= nil and has_tag(ent, "boat_leak") and on_boat(ent, boat) == true then
            count = count + 1
            found = found or ent
        end
    end
    return found, count
end


--============================================================================
-- [喵喵喵] 运行期状态：调用方持有 state.sail（不进存档），同一 goal 复用同一份
--============================================================================

-- [喵喵喵]: 世界身份：优先原生会话标识，退路 TheWorld.GUID；连这个都拿不到就写 "?"，
-- 宁可能失败一次重新规划，也不把两个世界的同一个坐标当成同一个任务。
local function world_key(snapshot)
    if type(snapshot) == "table" and type(snapshot.session) == "string" and snapshot.session ~= "" then
        return snapshot.session
    end
    if TheWorld ~= nil and TheWorld.GUID ~= nil then
        return "guid|" .. tostring(TheWorld.GUID)
    end
    return "?"
end

-- [喵喵喵]: goal 身份 = 模式+目标+半径+显式 id+世界+分片。终结结果按它闩存，
-- 因此“重跑同一个 id”只会拿到闩存结果，真要再来一次必须换 id。
local function goal_key(goal, snapshot, mode, range)
    local id = goal.id ~= nil and tostring(goal.id) or "-"
    local shard = type(snapshot) == "table" and tostring(snapshot.shard) or "-"
    return string.format("%s|%.2f|%.2f|%.2f|%s|%s|%s",
        mode, goal.x, goal.z, range, id, world_key(snapshot), shard)
end

local function reset_runtime(rt, key, mode, goal, range, priority, snapshot)
    rt.v = Sailing.SCHEMA_VERSION
    rt.key = key
    rt.mode = mode
    rt.x, rt.z = goal.x, goal.z
    rt.range = range
    rt.priority = priority
    rt.shard = type(snapshot) == "table" and snapshot.shard or nil
    rt.started = now()
    rt.seq = 0
    rt.op = nil
    rt.owned = false
    rt.phase = "start"
    rt.phase_t = rt.started
    rt.strokes = 0
    rt.stroke_fail = 0
    rt.stroke = nil
    rt.repairs = 0
    rt.repair_t = 0
    rt.attempts = 0
    rt.deploy_sent = nil
    rt.closed = nil
    rt.last_reason = nil
    rt.last_status = nil
    -- [喵喵喵]: 新增运行期字段全部在重设时显式清掉，避免旧任务的阶段/朝向泄漏到新任务。
    rt.not_ready_since = nil
    rt.land_phase = nil
    rt.land_anchored = nil
    rt.land_fail = 0
    rt.edge_fail = 0
    rt.edge_check_t = 0
    rt.row_dirx = nil
    rt.row_dirz = nil
    rt.heading = nil
    rt.heading_t = 0
    rt.stroke_settle_t = 0
    rt.anchor_state = nil
    rt.deploy_fail = 0
    -- [喵喵喵]: 跳板相位自己的计时/标记，换任务时一并清掉。
    rt.plank_t = 0
    rt.disembark_t = 0
    rt.plank_jump_sent = nil
    rt.boat = nil
    rt.board_via = nil
    rt.board_plank_t = 0
end

local function advance(rt, phase)
    rt.phase = phase
    rt.phase_t = now()
end

-- [喵喵喵]: 重设运行期/闩存终态前统一走这里：只释放“我们记着且确认过”的那一条。
local function release_tracked(player, rt)
    if type(rt) ~= "table" then
        return false
    end
    local cancelled = false
    if rt.op ~= nil and rt.owned == true and is_valid(player) then
        Actions.Cancel(player)
        cancelled = true
    end
    rt.op = nil
    rt.owned = false
    return cancelled
end

local function finish(player, rt, status, reason)
    -- [喵喵喵]: 终结前先收掉自己那条还没结束的操作（只在自己确认过的所有权下），
    -- 否则闩存终态后那条操作会变成无主操作，卡住后续不同 id 的下发。
    release_tracked(player, rt)
    rt.closed = { key = rt.key, status = status, reason = reason }
    rt.last_status = status
    rt.last_reason = reason
    return status, reason
end

--============================================================================
-- [喵喵喵] Actions 下发/轮询包装：一条操作同一身份只轮询不重发；
-- 只对“本次调用里确认过是自己的”那条发 Cancel，绝不碰别人的操作。
--============================================================================
local function poll_op(player, rt)
    if rt.op == nil then
        return nil, nil
    end
    local status, reason = Actions.Step(player, rt.op.intent)
    rt.op.seen = now()
    if status == "pending" then
        if type(reason) == "string" and starts_with(reason, "held_by") then
            -- [喵喵喵]: 别人占着本地缓冲：放弃自己的所有权，只等待，不撤别人的。
            rt.op = nil
            rt.owned = false
            return "pending", reason
        end
        rt.owned = true
        return "pending", reason
    end
    rt.op = nil
    rt.owned = false
    return status, reason
end

local function send_op(player, rt, intent)
    rt.seq = rt.seq + 1
    intent.priority = is_num(intent.priority) and intent.priority or rt.priority
    -- [喵喵喵]: 每次真正下发都用新 id，杜绝和 Actions 的终结闩存撞身份。
    intent.id = string.format("%s#%d", rt.key, rt.seq)
    rt.op = {
        intent = intent,
        id = intent.id,
        kind = intent.kind,
        note = intent.note,
        since = now(),
        seen = now(),
    }
    rt.owned = false
    local status, reason = Actions.Step(player, intent)
    if status == "pending" then
        if type(reason) == "string" and starts_with(reason, "held_by") then
            rt.op = nil
            rt.owned = false
            return "pending", reason
        end
        rt.owned = true
        return "pending", reason
    end
    rt.op = nil
    return status, reason
end

local function cancel_own(player, rt)
    if rt.op == nil then
        rt.owned = false
        return false, "no_own_op"
    end
    if rt.owned ~= true then
        -- [喵喵喵]: 没在本轮确认过所有权就不撤，宁可让它自己到期。
        rt.op = nil
        rt.owned = false
        return false, "ownership_unconfirmed"
    end
    local ok, why = Actions.Cancel(player)
    rt.op = nil
    rt.owned = false
    return ok == true, why
end

-- [喵喵喵]: 阶段切换时把“上一阶段的自己那条”收干净：确认过所有权就撤，
-- 没确认过就只丢本地记录，绝不误撤别人的操作。
local function clear_own(player, rt, note)
    if rt.op == nil then
        return
    end
    if note ~= nil and rt.op.note == note then
        return
    end
    if rt.owned == true then
        Actions.Cancel(player)
    end
    rt.op = nil
    rt.owned = false
end

--============================================================================
-- [喵喵喵] 安全方向：只在“客户端看得见的水面”里选点击点，并避开看得见的
-- 礁石/建筑/别的船/威胁；看不清就报未知，不猜。
--============================================================================
local function is_obstacle(ent, self_platform)
    if not is_valid(ent) or ent == self_platform then
        return false
    end
    -- [喵喵喵]: 挂在我们自己甲板上的东西（锚/桅杆/舵/漏/箱子）不算外部障碍，
    -- 否则一装锚就“前方永远被挡住”；别条船以及它们上的东西仍然是障碍。
    if on_boat(ent, self_platform) == true then
        return false
    end
    for i = 1, #Sailing.OBSTACLE_TAGS do
        if has_tag(ent, Sailing.OBSTACLE_TAGS[i]) then
            return true
        end
    end
    return false
end

local function corridor_clear(snapshot, self_platform, x, z)
    local list = nearby_list(snapshot)
    if list == nil then
        return false, "no_nearby_data"
    end
    for i = 1, #list do
        local record = list[i]
        local ent = record_entity(record)
        if ent ~= nil and ent ~= self_platform and on_boat(ent, self_platform) ~= true then
            local rx, rz = record.x, record.z
            if is_num(rx) and is_num(rz) and dist(rx, rz, x, z) <= Sailing.AVOID_RADIUS then
                if record.threat == true or is_obstacle(ent, self_platform) then
                    return false, "obstacle:" .. tostring(ent.prefab)
                end
            end
        end
    end
    return true, nil
end

-- [喵喵喵]: 点击点必须落在“自己这条船之外的水面”上：Row() 只在这个点上才认方向，
-- CheckRowRange 也才会判定“直接划而不是先走路”。
local function choose_click_point(snapshot, self_platform, dx, dz)
    local bx, bz = entity_pos(self_platform)
    if bx == nil or bz == nil then
        return nil, "boat_no_position"
    end
    local radius = platform_radius(self_platform)
    for i = 1, Sailing.ROW_REACH_TRIES do
        local reach = radius + 0.8 + (i - 1) * Sailing.ROW_REACH_STEP
        if reach < Sailing.ROW_REACH_MIN then
            reach = Sailing.ROW_REACH_MIN
        end
        local cx, cz = bx + dx * reach, bz + dz * reach
        local ocean, why = point_is_ocean(cx, cz)
        if ocean == true then
            local clear = corridor_clear(snapshot, self_platform, cx, cz)
            if clear == true then
                return cx, cz
            end
        elseif ocean == nil then
            return nil, "water_unknown:" .. tostring(why)
        end
    end
    return nil, "no_clear_water_point"
end

-- [喵喵喵]: 朝向：先直指目标，被看得见的障碍挡住就按 ±25/±50 度绕，全部不行就报
-- heading_blocked（交给上层决定，绝不硬撞）。
local function choose_heading(snapshot, self_platform, tx, tz)
    local bx, bz = entity_pos(self_platform)
    if bx == nil or bz == nil then
        return nil, "boat_no_position"
    end
    local dx, dz = tx - bx, tz - bz
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.001 then
        return nil, "target_at_boat"
    end
    dx, dz = dx / len, dz / len
    local last_why = nil
    for i = 1, #Sailing.AVOID_ANGLE do
        local a = Sailing.AVOID_ANGLE[i] * math.pi / 180
        local ca, sa = math.cos(a), math.sin(a)
        local rx, rz = dx * ca - dz * sa, dx * sa + dz * ca
        local cx, cz, why = choose_click_point(snapshot, self_platform, rx, rz)
        if cx ~= nil then
            return { x = rx, z = rz, click_x = cx, click_z = cz, angle = Sailing.AVOID_ANGLE[i] }
        end
        last_why = why or last_why
    end
    return nil, "heading_blocked:" .. tostring(last_why)
end

-- [喵喵喵]: 甲板落点：顺朝向走到船内侧一点，让原生 Row() 直接进入“划”的判定。
local function deck_point(self_platform, dx, dz)
    local bx, bz = entity_pos(self_platform)
    if bx == nil or bz == nil then
        return nil, "boat_no_position"
    end
    local radius = platform_radius(self_platform)
    local ex, ez = bx + dx * radius * Sailing.EDGE_OFFSET, bz + dz * radius * Sailing.EDGE_OFFSET
    local plat, why = platform_at(ex, ez)
    if plat == nil then
        return nil, "deck_unknown:" .. tostring(why)
    end
    if plat ~= self_platform then
        -- [喵喵喵]: 落点已经不在自己甲板上（船小/漂移），退回船心，绝不点水面走路。
        return bx, bz
    end
    return ex, ez
end

--============================================================================
-- [喵喵喵] 锚：只认原生三个标签，未知就说未知
--============================================================================
local function anchor_state(anchor)
    if anchor == nil then
        return "none"
    end
    if has_tag(anchor, "anchor_transitioning") then
        return "transitioning"
    end
    if has_tag(anchor, "anchor_raised") then
        return "raised"
    end
    if has_tag(anchor, "anchor_lowered") then
        return "lowered"
    end
    return "unknown"
end
--============================================================================
-- [喵喵喵] 锚：起锚/抛锚都用 SCENE 动作，目标是锚实体本身
-- （原生 RAISE_ANCHOR.fn 读 act.target.components.anchor）
--============================================================================
local function step_anchor(player, rt, anchor, want)
    local action = want == "raised" and "RAISE_ANCHOR" or "LOWER_ANCHOR"
    clear_own(player, rt, "anchor")
    if rt.op ~= nil then
        local status, reason = poll_op(player, rt)
        if status == "pending" then
            return "pending", "anchor_pending:" .. tostring(reason)
        end
        if now() - rt.phase_t > Sailing.ANCHOR_WAIT then
            return "failed", string.format("anchor_timeout|state=%s|why=%s",
                tostring(anchor_state(anchor)), tostring(reason))
        end
        return "pending", "anchor_retrying"
    end
    if now() - rt.phase_t > Sailing.ANCHOR_WAIT then
        return "failed", "anchor_timeout|state=" .. tostring(anchor_state(anchor))
    end
    local status, reason = send_op(player, rt, {
        kind = "action",
        action = action,
        target = anchor,
        right = false,
        note = "anchor",
    })
    if status == "pending" then
        return "pending", "anchor_" .. string.lower(action) .. ":" .. tostring(reason)
    end
    -- [喵喵喵]: 原生拒绝也先如实上报，由外层决定是否放弃这次航行。
    return "pending", "anchor_action_failed:" .. tostring(reason)
end

--============================================================================
-- [喵喵喵] 跳板（walkingplank）：本 build 里“上/下船”的原生真实链路
--   收集器 componentactions.lua walkingplank：
--     右键 + 人已在跳板上        → ABANDON_SHIP
--     右键 + 跳板 interactable   → EXTEND_PLANK / RETRACT_PLANK（看 plank_extended）
--     左键 + plank_extended      → MOUNT_PLANK（distance=0.5）
--   状态标签来自 SGwalkingplank：retracted→interactable，extended→plank_extended+
--   interactable，extending/mounted→无 interactable。
--   人上跳板后玩家自己带 on_walkable_plank（SGwilson mount_plank）。
--   ABANDON_SHIP 是“从跳板往外跳”：SGwilson 落点若不在可走地面就 drownable
--   掉钱包（DropInventory）→ 因此本模块只在客户端验证过落点是陆地时才用。
--============================================================================
local function find_plank(snapshot, boat)
    local list = nearby_list(snapshot)
    if list == nil then
        return nil, "none"
    end
    local foreign, unverified = false, false
    for i = 1, #list do
        local ent = record_entity(list[i])
        if ent ~= nil and has_tag(ent, "walkingplank") then
            local mine = on_boat(ent, boat)
            if mine == true then
                return ent, "ok"
            elseif mine == false then
                foreign = true
            else
                unverified = true
            end
        end
    end
    if foreign then
        return nil, "foreign"
    end
    if unverified then
        return nil, "unverified"
    end
    return nil, "none"
end

-- [喵喵喵]: 只认原生两个标签，两个都读不到就是 busy（动画中/被人占着），不猜。
local function plank_state(plank)
    if plank == nil then
        return "none"
    end
    if has_tag(plank, "plank_extended") then
        return "extended"
    end
    if has_tag(plank, "interactable") then
        return "retracted"
    end
    return "busy"
end

-- [喵喵喵]: 把跳板推进到“伸出 + 人已站上去”；每拍最多一步，全部以标签为证据。
-- 返回 "mounted"/"pending"/"failed"。
local function step_plank_mount(player, snapshot, rt, plank)
    -- 1) 已经在跳板上（原生玩家标签）
    if has_tag(player, "on_walkable_plank") then
        if rt.op ~= nil and (rt.op.note == "plank_mount" or rt.op.note == "plank_extend") then
            -- [喵喵喵]: 人已上板，这条自有动作可以收掉，别挡住后面的移动。
            cancel_own(player, rt)
        end
        return "mounted", "on_plank"
    end
    -- 2) 上一发还在跑：只轮询同一条，绝不再发一次
    if rt.op ~= nil and (rt.op.note == "plank_extend" or rt.op.note == "plank_mount") then
        local s, r = poll_op(player, rt)
        if s == "pending" then
            return "pending", rt.op.note .. ":" .. tostring(r)
        end
        return "pending", rt.op.note .. "_done:" .. tostring(s)
    end
    local state = plank_state(plank)
    -- 3) 未伸出 → EXTEND_PLANK（原生右键收集器）
    if state == "retracted" then
        if now() - (rt.plank_t or 0) < 0.5 then
            return "pending", "plank_extend_settle"
        end
        rt.plank_t = now()
        local s, r = send_op(player, rt, {
            kind = "action",
            action = "EXTEND_PLANK",
            target = plank,
            right = true,
            note = "plank_extend",
        })
        if s == "failed" then
            return "pending", "plank_extend_failed:" .. tostring(r)
        end
        return "pending", "plank_extend:" .. tostring(s) .. "|" .. tostring(r)
    end
    -- 4) 已伸出 → MOUNT_PLANK（原生左键，distance=0.5，原生负责先走近）
    if state == "extended" then
        if now() - (rt.plank_t or 0) < 0.5 then
            return "pending", "plank_mount_settle"
        end
        rt.plank_t = now()
        local s, r = send_op(player, rt, {
            kind = "action",
            action = "MOUNT_PLANK",
            target = plank,
            right = false,
            note = "plank_mount",
        })
        if s == "failed" then
            return "pending", "plank_mount_failed:" .. tostring(r)
        end
        return "pending", "plank_mount:" .. tostring(s) .. "|" .. tostring(r)
    end
    return "pending", "plank_busy:" .. tostring(state)
end

-- [喵喵喵]: ABANDON_SHIP 的落点无法客户端精确预测（SGwilson 按朝向给 motorvel），
-- 所以只在“跳板外侧 2 格与再外 1 格都是客户端可见陆地、且方向朝目标”时才允许。
local function plank_jump_safe(boat, plank, goal)
    local px, pz = entity_pos(plank)
    local bx, bz = entity_pos(boat)
    if px == nil or pz == nil or bx == nil or bz == nil then
        return false, "no_position"
    end
    local dx, dz = px - bx, pz - bz
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then
        return false, "degenerate_direction"
    end
    dx, dz = dx / len, dz / len
    local gx, gz = goal.x - px, goal.z - pz
    local glen = math.sqrt(gx * gx + gz * gz)
    if glen < 0.01 or (gx * dx + gz * dz) / glen < 0.3 then
        return false, "goal_not_outward"
    end
    for i = 1, 2 do
        local reach = Sailing.PLANK_JUMP_DIST + (i - 1) * 1.5
        local lx, lz = px + dx * reach, pz + dz * reach
        local land, why = point_is_land(lx, lz)
        if land ~= true then
            return false, string.format("landing_not_verified@%.1f:%s", reach, tostring(why))
        end
    end
    return true, nil
end

-- [喵喵喵]: 只有在跳板跳的落点被客户端地图验证为陆地、且方向朝目标时，才允许一次
-- ABANDON_SHIP（原生从跳板往外跳）；每个任务最多一次，落点不被验证就绝不下发。
local function maybe_plank_jump(player, rt, boat, plank, goal)
    if goal.plank_jump ~= true then
        return "not_allowed"
    end
    if rt.plank_jump_sent == true then
        return "already_sent"
    end
    if rt.op ~= nil then
        return "busy"
    end
    local safe, why = plank_jump_safe(boat, plank, goal)
    if not safe then
        return "unsafe:" .. tostring(why)
    end
    rt.plank_jump_sent = true
    local s, r = send_op(player, rt, {
        kind = "action",
        action = "ABANDON_SHIP",
        target = plank,
        right = true,
        note = "plank_jump",
    })
    return "sent:" .. tostring(s) .. "|" .. tostring(r)
end

--============================================================================
-- [喵喵喵] 可见漏/血量：只报看得见的事实，读不到就写 unknown
--============================================================================
local function health_note(boat, snapshot)
    local pct = boat_health(boat)
    local _, leak_count = first_visible_leak(snapshot, boat)
    return string.format("hp=%s|leaks=%s",
        pct ~= nil and string.format("%.2f", pct) or "unknown",
        leak_count ~= nil and tostring(leak_count) or "unknown")
end

-- [喵喵喵]: 紧急修补：只有在“看得见漏”且“背包里真有 boat_patch 物品”时才动手；
-- 材料缺失时绝不假装安全，血量已知过低就直接报 critical。
local function step_repair(player, snapshot, rt, boat)
    local leak, leak_count = first_visible_leak(snapshot, boat)
    local pct = boat_health(boat)
    local patch = owned_boat_patch(snapshot)
    if leak ~= nil and patch == nil and pct ~= nil and pct <= Sailing.CRITICAL_PCT then
        return "failed", string.format("boat_health_critical|hp=%.2f|leaks=%s|missing_repair_material",
            pct, tostring(leak_count or 0))
    end
    if leak == nil then
        return "ok", nil
    end
    if rt.op ~= nil and rt.op.note == "repair" then
        local status, reason = poll_op(player, rt)
        if status == "pending" then
            return "busy", "repairing:" .. tostring(reason)
        end
        if status == "succeeded" then
            rt.repairs = (rt.repairs or 0) + 1
        end
        rt.repair_t = now()
        return "ok", nil
    end
    if rt.op ~= nil then
        -- [喵喵喵]: 修补只是顺手，别把航行中那条操作挤掉。
        return "ok", nil
    end
    if (rt.repairs or 0) >= 4 then
        return "ok", nil
    end
    if now() - (rt.repair_t or 0) < 1.0 then
        return "ok", nil
    end
    if patch == nil then
        return "ok", nil
    end
    rt.repair_t = now()
    local status, reason = send_op(player, rt, {
        kind = "use",
        action = "REPAIR_LEAK",
        item = patch,
        target = leak,
        note = "repair",
    })
    if status == "pending" then
        return "busy", "repair_sent:" .. tostring(reason)
    end
    return "ok", nil
end

--============================================================================
-- [喵喵喵] 桨：先用 kind="inventory" 的 EQUIP 装备真正持有的 oar，
-- 没有桨就明确报 missing_paddle（交给策略层去采集）
--============================================================================
local function step_oar(player, snapshot, rt)
    local held = equipped_oar(snapshot)
    if held ~= nil then
        rt.oar = held
        return "ok", nil
    end
    clear_own(player, rt, "equip")
    if rt.op ~= nil and rt.op.note == "equip" then
        local status, reason = poll_op(player, rt)
        local now_held = equipped_oar(snapshot)
        if now_held ~= nil then
            rt.oar = now_held
            return "ok", nil
        end
        if status == "pending" then
            return "pending", "equipping:" .. tostring(reason)
        end
        if status == "failed" then
            return "failed", "equip_paddle_failed:" .. tostring(reason)
        end
        -- [喵喵喵]: 已经报成功但装备槽还没刷新：等下一帧观察，受 phase 超时约束。
        return "pending", "equip_unconfirmed"
    end
    local oar = owned_oar(snapshot)
    if oar == nil then
        return "failed", "missing_paddle"
    end
    local status, reason = send_op(player, rt, {
        kind = "inventory",
        action = "EQUIP",
        item = oar,
        note = "equip",
    })
    if status == "pending" then
        return "pending", "equip_sent:" .. tostring(reason)
    end
    return "pending", "equip_unconfirmed:" .. tostring(reason)
end

--============================================================================
-- [喵喵喵] 甲板边缘：先沿朝向走到自己甲板内侧，原生 Row() 才会直接判成“划”
--============================================================================
local function step_edge(player, snapshot, rt, boat, dirx, dirz)
    local ex, ez, why = deck_point(boat, dirx, dirz)
    if ex == nil then
        return "pending", "deck_unknown:" .. tostring(why)
    end
    local px, pz = snapshot.x, snapshot.z
    if is_num(px) and is_num(pz) and dist(px, pz, ex, ez) <= Sailing.EDGE_RANGE then
        return "ok", nil
    end
    clear_own(player, rt, "edge")
    if rt.op ~= nil and rt.op.note == "edge" then
        local status, reason = poll_op(player, rt)
        if status == "pending" then
            return "pending", "walking_to_edge:" .. tostring(reason)
        end
        if status == "succeeded" then
            return "ok", nil
        end
        rt.edge_fail = (rt.edge_fail or 0) + 1
        if rt.edge_fail >= 3 then
            return "failed", "edge_move_failed:" .. tostring(reason)
        end
        return "pending", "edge_retry:" .. tostring(status)
    end
    local status, reason = send_op(player, rt, {
        kind = "move",
        x = ex,
        z = ez,
        range = Sailing.EDGE_RANGE * 0.8,
        note = "edge",
    })
    if status == "pending" then
        return "pending", "edge_move:" .. tostring(reason)
    end
    return "pending", "edge_move_" .. tostring(status)
end

--============================================================================
-- [喵喵喵] 单桨：一次只发一个 ROW，必须等到“看得见船真的位移”才算这一桨成立，
-- 然后撤掉自己那条操作再规划下一桨。ROW_FAIL / action_unavailable 只当“此刻忙”，
-- 绝不当划成功，也绝不每帧连发。
--============================================================================
local function is_row_fail_reason(reason)
    return type(reason) == "string" and reason:find("ROW_FAIL", 1, true) ~= nil
end

local function stroke_result(rt, ok, reason)
    rt.stroke = nil
    rt.stroke_settle_t = now()
    if ok then
        rt.strokes = (rt.strokes or 0) + 1
        rt.stroke_fail = 0
        -- [喵喵喵]: 真的位移了算“有进展”，重置 phase 计时，否则长航程会被 20 秒误杀。
        rt.phase_t = now()
        return "ok", nil
    end
    rt.stroke_fail = (rt.stroke_fail or 0) + 1
    if rt.stroke_fail >= Sailing.STROKE_MAX_FAIL then
        return "failed", "row_no_progress|" .. tostring(reason)
    end
    return "ok", nil
end

local function step_stroke(player, snapshot, rt, boat, heading)
    local bx, bz = entity_pos(boat)
    clear_own(player, rt, "row")
    -- A) 本桨已经下发：只轮询同一条操作，同时观察船是否真的动了。
    if rt.op ~= nil and rt.op.note == "row" then
        local status, reason = poll_op(player, rt)
        local moved = rt.stroke ~= nil and rt.stroke.bx ~= nil and bx ~= nil and bz ~= nil
            and dist(rt.stroke.bx, rt.stroke.bz, bx, bz) >= Sailing.STROKE_MIN_MOVE
        if status == "pending" then
            if moved then
                cancel_own(player, rt)
                local ok, why = stroke_result(rt, true, "displaced")
                if ok ~= "ok" then
                    return ok, why
                end
                return "pending", "stroke_displaced"
            end
            if rt.stroke == nil or now() - rt.stroke.t >= Sailing.STROKE_WAIT then
                cancel_own(player, rt)
                local ok, why = stroke_result(rt, false, "no_displacement|" .. tostring(reason))
                if ok ~= "ok" then
                    return ok, why
                end
                return "pending", "stroke_timeout"
            end
            return "pending", "stroke_running:" .. tostring(reason)
        end
        -- [喵喵喵]: 这一发被原生终结（成功/拒绝）都不等于船动了，仍以位移为准。
        local stroke = rt.stroke
        local moved_now = stroke ~= nil and stroke.bx ~= nil and bx ~= nil and bz ~= nil
            and dist(stroke.bx, stroke.bz, bx, bz) >= Sailing.STROKE_MIN_MOVE
        if moved_now then
            local ok, why = stroke_result(rt, true, "displaced")
            if ok ~= "ok" then
                return ok, why
            end
            return "pending", "stroke_done:" .. tostring(reason)
        end
        if status == "failed" and is_row_fail_reason(reason) then
            rt.stroke = nil
            rt.stroke_settle_t = now()
            return "pending", "row_busy:" .. tostring(reason)
        end
        local ok, why = stroke_result(rt, false, tostring(status) .. "|" .. tostring(reason))
        if ok ~= "ok" then
            return ok, why
        end
        return "pending", "stroke_retry:" .. tostring(status)
    end

    -- B) 两桨之间留一点间隔，避免每帧猛点。
    if now() - (rt.stroke_settle_t or 0) < Sailing.STROKE_SETTLE then
        return "pending", "stroke_settle"
    end

    local cx, cz, why = choose_click_point(snapshot, boat, heading.x, heading.z)
    if cx == nil then
        return "pending", "click_point_unavailable:" .. tostring(why)
    end
    -- [喵喵喵]: 远程客户端的 kind="action" 自身没有完成证据，只会拖到 deadline；
    -- 因此把“船真的位移了”作为 confirm(player,intent) 交给 Actions(见 actions.lua check_action
    -- 的 caller_confirmed)，一桨只下发一次、一旦成立立即终结这条自有操作。
    local start_x, start_z = bx, bz
    local confirm = nil
    if is_num(start_x) and is_num(start_z) then
        confirm = function()
            local nx, nz = entity_pos(boat)
            if nx == nil or nz == nil then
                return false
            end
            return dist(start_x, start_z, nx, nz) >= Sailing.STROKE_MIN_MOVE
        end
    end
    local status, reason = send_op(player, rt, {
        kind = "action",
        action = "ROW",
        x = cx,
        z = cz,
        right = true,
        confirm = confirm,
        -- [喵喵喵]: 不传 item：ROW 只可能由“手上那张桨”的 POINT 收集器产出，
        -- 动作码本身已经把语义钉死；再传实体反而会因为快照与此刻手牌一瞬不一致
        -- 而把一次本来能划的桨误判成 item_mismatch。
        note = "row",
    })
    rt.stroke = { t = now(), bx = bx, bz = bz, click_x = cx, click_z = cz }
    if status == "pending" then
        if type(reason) == "string" and starts_with(reason, "held_by") then
            rt.stroke = nil
            return "pending", "held:" .. tostring(reason)
        end
        return "pending", "stroke_sent:" .. tostring(reason)
    end
    rt.stroke = nil
    rt.stroke_settle_t = now()
    if is_row_fail_reason(reason) then
        return "pending", "row_busy:" .. tostring(reason)
    end
    rt.stroke_fail = (rt.stroke_fail or 0) + 1
    if rt.stroke_fail >= Sailing.STROKE_MAX_FAIL then
        return "failed", "row_failed:" .. tostring(reason)
    end
    return "pending", "stroke_refused:" .. tostring(reason)
end

--============================================================================
-- [喵喵喵] 朝向缓存：Map 查询不做成每帧一次，最多 1.5 秒重算一次
--============================================================================
local function current_heading(snapshot, rt, boat, tx, tz)
    if rt.heading ~= nil and now() - (rt.heading_t or 0) < 1.5 then
        return rt.heading, nil
    end
    local heading, why = choose_heading(snapshot, boat, tx, tz)
    if heading == nil then
        rt.heading = nil
        return nil, why
    end
    rt.heading = heading
    rt.heading_t = now()
    return heading, nil
end

-- [喵喵喵]: 两桨之间(没有自己的桨操作在飞时)才检查：船在动/朝向变了就必须重新回到
-- 新朝向的甲板边缘，否则会在旧位置上反复发出“原生此时不可用”的 ROW。
-- 检查自身限频 0.5 秒，不需要每帧查图。
local function needs_re_edge(snapshot, rt, boat, heading)
    if now() - (rt.edge_check_t or 0) < 0.5 then
        return false, nil
    end
    rt.edge_check_t = now()
    if is_num(rt.row_dirx) and is_num(rt.row_dirz) then
        local dot = heading.x * rt.row_dirx + heading.z * rt.row_dirz
        if dot < 0.866 then
            return true, "heading_changed"
        end
    end
    local ex, ez = deck_point(boat, heading.x, heading.z)
    local px, pz = snapshot.x, snapshot.z
    if ex ~= nil and is_num(px) and is_num(pz) then
        if dist(px, pz, ex, ez) > Sailing.EDGE_RANGE * 1.6 then
            return true, "deck_moved"
        end
    end
    return false, nil
end

--============================================================================
-- [喵喵喵] 划向某个可见水面点：桨 → 起锚 → 走到甲板边缘 → 逐桨推进。
-- 到达只认 snapshot 里船/玩家的实际位置，绝不认 RPC 回执。
--============================================================================
local function sail_towards(player, snapshot, rt, boat, tx, tz, tag)
    local bx, bz = entity_pos(boat)
    local px, pz = snapshot.x, snapshot.z
    local rx, rz = bx, bz
    if not is_num(rx) or not is_num(rz) then
        rx, rz = px, pz
    end
    local d = dist(rx, rz, tx, tz)
    local note = health_note(boat, snapshot)
    -- [喵喵喵]: 先判“目标到底是不是水面”，再判到没到。否则一个真正的陆地目标只要
    -- 船心距离落在 range 内就会被误报 arrived。这里用 allow_boats=true 的语义：
    -- 自己的船盖住该点仍算海洋（否则船体 4 格半径下 range=2.5 永远到不了），
    -- 但真正的陆地/建筑地面依旧不是海洋，仍会被拒。
    local ok_water, wwhy = point_is_ocean_goal(tx, tz)
    if ok_water ~= true then
        return "failed", string.format("%s|target_not_water:%s", tag, tostring(wwhy))
    end
    if d <= rt.range then
        return "succeeded", string.format("arrived:%.2f|%s", d, note)
    end
    -- [喵喵喵]: 看得见的漏 + 真正的修补材料 > 一切航行进度
    local rstatus, rreason = step_repair(player, snapshot, rt, boat)
    if rstatus == "failed" then
        return "failed", rreason
    end
    if rstatus == "busy" then
        return "pending", tostring(rreason) .. "|" .. note
    end
    if now() - rt.phase_t > Sailing.PHASE_TIMEOUT then
        return "failed", string.format("phase_timeout:%s|%s", tostring(rt.phase), note)
    end

    -- 1) 桨
    if rt.phase == "start" or rt.phase == "oar" then
        rt.phase = "oar"
        local s, r = step_oar(player, snapshot, rt)
        if s == "failed" then
            return "failed", tostring(r) .. "|" .. note
        end
        if s ~= "ok" then
            return "pending", tag .. "|" .. tostring(r) .. "|" .. note
        end
        advance(rt, "anchor")
    end

    -- 2) 锚：只有 anchor_raised 才允许划；lowered/unknown 都按原生收集器起锚
    if rt.phase == "anchor" then
        local anchor, awhy = find_anchor(snapshot, boat)
        local state = anchor_state(anchor)
        if awhy == "unverified" then
            -- [喵喵喵]: 看得见锚但确认不了它停在哪条船上：既不动手，也不推断它已收起。
            return "pending", tag .. "|anchor_unverified|" .. note
        end
        if state == "none" or state == "raised" then
            rt.anchor_state = state == "none" and ("none|" .. tostring(awhy)) or state
            advance(rt, "edge")
        elseif state == "transitioning" then
            return "pending", tag .. "|anchor_transitioning|" .. note
        else
            local s, r = step_anchor(player, rt, anchor, "raised")
            if s == "failed" then
                return "failed", tostring(r) .. "|" .. note
            end
            return "pending", tag .. "|" .. tostring(r) .. "|anchor=" .. tostring(state) .. "|" .. note
        end
    end

    -- 3) 甲板边缘
    if rt.phase == "edge" then
        local heading, hwhy = current_heading(snapshot, rt, boat, tx, tz)
        if heading == nil then
            return "pending", tag .. "|" .. tostring(hwhy) .. "|" .. note
        end
        local s, r = step_edge(player, snapshot, rt, boat, heading.x, heading.z)
        if s == "failed" then
            return "failed", tostring(r) .. "|" .. note
        end
        if s ~= "ok" then
            return "pending", tag .. "|" .. tostring(r) .. "|" .. note
        end
        -- [喵喵喵]: 记下进入划桨时的朝向，后面用它判“方向是否已经跑偏”。
        rt.row_dirx, rt.row_dirz = heading.x, heading.z
        rt.edge_check_t = 0
        advance(rt, "row")
    end

    -- 4) 逐桨推进
    if rt.phase == "row" then
        local heading, hwhy = current_heading(snapshot, rt, boat, tx, tz)
        if heading == nil then
            return "pending", tag .. "|" .. tostring(hwhy) .. "|" .. note
        end
        -- [喵喵喵]: 只在两桨之间且确实脱位/换向时才回甲板边缘，不动正在飞的那一桨。
        if rt.op == nil or rt.op.note ~= "row" then
            local re, why_re = needs_re_edge(snapshot, rt, boat, heading)
            if re then
                advance(rt, "edge")
                return "pending", tag .. "|re_edge:" .. tostring(why_re) .. "|" .. note
            end
        end
        local s, r = step_stroke(player, snapshot, rt, boat, heading)
        if s == "failed" then
            return "failed", tostring(r) .. "|strokes=" .. tostring(rt.strokes or 0)
                .. "|anchor=" .. tostring(rt.anchor_state or "unknown") .. "|" .. note
        end
        return "pending", string.format("%s|%s|strokes=%d|dist=%.1f|%s",
            tag, tostring(r), rt.strokes or 0, d, note)
    end

    return "pending", tag .. "|phase:" .. tostring(rt.phase)
end

--============================================================================
-- [喵喵喵] 造船：只有“背包里真有套件 + 站在陆地 + 看得见的水面点 + 原生
-- 客户端部署校验通过”才下发 kind="use" 的 DEPLOY/DEPLOY_FLOATING；
-- 成功只认“看得见的新船”，绝不把“套件消失了”当成功。
--============================================================================
local function deploy_allowed(kit, player, x, z)
    local item = kit ~= nil and kit.replica ~= nil and kit.replica.inventoryitem or nil
    if item == nil or item.CanDeploy == nil then
        -- [喵喵喵]: 读不到客户端校验就交给原生 picker 去拒，不在这里猜。
        return true
    end
    local ok, can = pcall(function()
        return item:CanDeploy(Vector3(x, 0, z), nil, player, 0)
    end)
    return ok and can == true
end

local function deploy_point(player, snapshot, kit)
    local px, pz = snapshot.x, snapshot.z
    if not is_num(px) or not is_num(pz) then
        return nil, "no_player_position"
    end
    local radius = Sailing.BOAT_RADIUS_FALLBACK
    local okr, kit_radius = pcall(function()
        return kit._boat_radius
    end)
    if okr and is_num(kit_radius) and kit_radius > 0 then
        radius = kit_radius
    end
    local want = radius + 1.2
    local pts = type(snapshot.shore_points) == "table" and snapshot.shore_points or nil
    if pts == nil then
        return nil, "no_shore_points"
    end
    for i = 1, #pts do
        local sp = pts[i]
        if type(sp) == "table" and is_num(sp.x) and is_num(sp.z) then
            local dx, dz = sp.x - px, sp.z - pz
            local len = math.sqrt(dx * dx + dz * dz)
            if len > 0.01 then
                local cx, cz = px + dx / len * want, pz + dz / len * want
                local ocean = point_is_ocean(cx, cz)
                if ocean == true and deploy_allowed(kit, player, cx, cz) then
                    return cx, cz
                end
            end
        end
    end
    return nil, "no_deploy_point_found"
end

local function deploy_boat(player, snapshot, rt, kit)
    local px, pz = snapshot.x, snapshot.z
    local on_land, why = point_is_land(px, pz)
    if on_land ~= true then
        return "failed", "deploy_needs_land_standing:" .. tostring(why)
    end
    clear_own(player, rt, "deploy")
    if rt.op ~= nil and rt.op.note == "deploy" then
        local s, r = poll_op(player, rt)
        if s == "pending" then
            return "pending", "deploying:" .. tostring(r)
        end
        rt.deploy_sent = now()
        if s == "failed" then
            rt.deploy_fail = (rt.deploy_fail or 0) + 1
            if rt.deploy_fail >= 3 then
                return "failed", "deploy_failed:" .. tostring(r)
            end
        else
            rt.deploy_fail = 0
        end
    end
    local entry = nearest_boat(snapshot, px, pz, nil)
    if entry ~= nil then
        return "pending", "deploy_boat_visible:" .. tostring(entry.entity.prefab)
    end
    if rt.deploy_sent ~= nil and now() - rt.deploy_sent < 1.0 then
        return "pending", "deploy_settle"
    end
    if rt.op == nil then
        local cx, cz, why2 = deploy_point(player, snapshot, kit)
        if cx == nil then
            return "failed", "no_deploy_point:" .. tostring(why2)
        end
        local action = "DEPLOY"
        local inv = player ~= nil and player.replica ~= nil and player.replica.inventory or nil
        if inv ~= nil and inv.IsFloaterHeld ~= nil then
            local okh, held = pcall(function()
                return inv:IsFloaterHeld()
            end)
            if okh and held == true then
                action = "DEPLOY_FLOATING"
            end
        end
        local s, r = send_op(player, rt, {
            kind = "use",
            action = action,
            item = kit,
            x = cx,
            z = cz,
            note = "deploy",
        })
        if s == "pending" then
            return "pending", "deploy_sent:" .. tostring(r)
        end
        rt.deploy_sent = now()
        rt.deploy_fail = (rt.deploy_fail or 0) + 1
        if rt.deploy_fail >= 3 then
            return "failed", "deploy_refused:" .. tostring(r)
        end
        return "pending", "deploy_refused:" .. tostring(r)
    end
    return "pending", "deploy_await_boat"
end

--============================================================================
-- [喵喵喵] mode="board"：走向可见的船（原生 WALKTO + 平台跳跃），
-- 成功只认 snapshot.platform 真的变成那条船，绝不从“目标卸载/物品消失”推断。
--============================================================================
local function board_mode(player, snapshot, rt, goal)
    local platform = snapshot.platform
    local px, pz = snapshot.x, snapshot.z
    local on_boat = platform ~= nil and is_boat(platform.entity)
    local target_boat = nil
    if goal.boat ~= nil and is_boat(goal.boat) then
        target_boat = goal.boat
    end
    if on_boat and (target_boat == nil or target_boat == platform.entity) then
        return "succeeded", "on_board:" .. tostring(platform.prefab)
    end
    if target_boat == nil then
        local qx = is_num(goal.x) and goal.x or px
        local qz = is_num(goal.z) and goal.z or pz
        local entry = nearest_boat(snapshot, qx, qz, on_boat and platform.entity or nil)
        if entry ~= nil then
            target_boat = entry.entity
        end
    end
    if target_boat == nil then
        local kit = owned_boat_kit(snapshot)
        if kit == nil then
            return "failed", "no_visible_boat|missing_kit"
        end
        return deploy_boat(player, snapshot, rt, kit)
    end
    -- [喵喵喵]: 已经在别的船上时只允许“跳到够近的那条”，远距离不做无证据的推断。
    if on_boat then
        local bx, bz = entity_pos(target_boat)
        if bx ~= nil and bz ~= nil and dist(px, pz, bx, bz) > Sailing.HOP_MAX then
            return "failed", string.format("target_boat_too_far_to_hop:%.1f", dist(px, pz, bx, bz))
        end
    end
    -- [喵喵喵]: 只收拾与本阶段无关的自有操作；跳板/上船那一条要留着继续轮询。
    if rt.op ~= nil and rt.op.note ~= "board" and rt.op.note ~= "board_deck"
        and rt.op.note ~= "plank_extend" and rt.op.note ~= "plank_mount" then
        clear_own(player, rt, nil)
    end
    -- [喵喵喵]: 优先用本 build 原生跳板链路（EXTEND_PLANK→MOUNT_PLANK）：跳板端已经伸到
    -- 客户端可见的陆地上，才能真正走到/站上去；否则才退回“WALKTO + 原生平台跳”。
    if not on_boat then
        local plank, pwhy = find_plank(snapshot, target_boat)
        local plank_reachable = false
        if plank ~= nil then
            local lx, lz = entity_pos(plank)
            plank_reachable = lx ~= nil and point_is_land(lx, lz) == true
        end
        if plank_reachable and rt.board_via ~= "hop" then
            if rt.board_via ~= "plank" then
                release_tracked(player, rt)
                rt.board_via = "plank"
                rt.board_plank_t = now()
            end
            local ms, mr = step_plank_mount(player, snapshot, rt, plank)
            if ms == "mounted" or has_tag(player, "on_walkable_plank") then
                -- 上板后走到甲板占位点（原生平台跳会把最后一段接上）
                local bx2, bz2 = entity_pos(target_boat)
                if bx2 == nil or bz2 == nil then
                    return "failed", "boat_no_position"
                end
                if rt.op == nil then
                    local s2, r2 = send_op(player, rt, {
                        kind = "move",
                        x = bx2,
                        z = bz2,
                        range = 1.2,
                        note = "board_deck",
                    })
                    return "pending", "board_plank->deck:" .. tostring(s2) .. "|" .. tostring(r2)
                end
                local s3, r3 = poll_op(player, rt)
                if s3 == "pending" then
                    return "pending", "board_plank->deck_running:" .. tostring(r3)
                end
                rt.board_done_pending = (s3 == "succeeded") and true or nil
                return "pending", "board_plank->deck_done:" .. tostring(s3)
            end
            if now() - (rt.board_plank_t or 0) > Sailing.PLANK_TIMEOUT then
                -- [喵喵喵]: 跳板链路超时就降级到平台跳，两条路都有上限，不无限挂。
                rt.board_via = "hop"
            else
                return "pending", "board_plank:" .. tostring(mr) .. "|p=" .. tostring(pwhy)
            end
        end
    end
    if rt.op ~= nil and rt.op.note == "board_deck" then
        local sd, rd = poll_op(player, rt)
        if sd == "pending" then
            return "pending", "boarding_deck:" .. tostring(rd)
        end
        rt.board_done_pending = (sd == "succeeded") and true or nil
    end
    if rt.op ~= nil and rt.op.note == "board" then
        local s, r = poll_op(player, rt)
        if s == "pending" then
            return "pending", "boarding:" .. tostring(r)
        end        if s == "failed" then
            rt.attempts = (rt.attempts or 0) + 1
            if rt.attempts >= 3 then
                return "failed", "board_move_failed:" .. tostring(r)
            end
            return "pending", "board_retry:" .. tostring(r)
        end
    end
    if snapshot.platform ~= nil and snapshot.platform.entity == target_boat then
        return "succeeded", "boarded:" .. tostring(target_boat.prefab)
    end
    -- [喵喵喵]: 原生 move 已终结但仍不在那条船上：算一次失败尝试，不能无限重发。
    if rt.op == nil and rt.board_done_pending == true then
        rt.board_done_pending = nil
        rt.attempts = (rt.attempts or 0) + 1
        if rt.attempts >= 3 then
            return "failed", "board_move_no_platform:" .. tostring(target_boat.prefab)
        end
        return "pending", "board_retry_no_platform"
    end
    if rt.op == nil then
        local bx, bz = entity_pos(target_boat)
        if bx == nil or bz == nil then
            return "failed", "boat_no_position"
        end
        local s, r = send_op(player, rt, {
            kind = "move",
            x = bx,
            z = bz,
            range = 1.2,
            note = "board",
        })
        if s == "pending" then
            return "pending", "board_move:" .. tostring(r)
        end
        if s == "succeeded" then
            rt.board_done_pending = true
        end
        return "pending", "board_move_" .. tostring(s)
    end
    return "pending", "boarding_await_observation"
end

--============================================================================
-- [喵喵喵] mode="sail"：当前船上，划到明确的海面点
--============================================================================
local function sail_mode(player, snapshot, rt, goal)
    local platform = snapshot.platform
    if platform == nil or not is_boat(platform.entity) then
        return "failed", "not_on_boat"
    end
    return sail_towards(player, snapshot, rt, platform.entity, goal.x, goal.z, "sail")
end

--============================================================================
-- [喵喵喵] mode="land"：先划到岸边可见水面驻点，近岸抛锚，再用原生 move 走上陆地；
-- 成功只认“真的不在船平台上了 + 位置到点”，绝不把船消失当上岸。
--============================================================================
local function land_mode(player, snapshot, rt, goal)
    local land_ok, lwhy = point_is_land(goal.x, goal.z)
    if land_ok ~= true then
        return "failed", "goal_not_land:" .. tostring(lwhy)
    end
    local px, pz = snapshot.x, snapshot.z
    local platform = snapshot.platform
    local boat = nil
    if platform ~= nil then
        if is_boat(platform.entity) then
            boat = platform.entity
            rt.boat = boat
        else
            -- [喵喵喵]: 站在非船平台（码头等）：只有真到陆地目标才算成功。
            local d0 = dist(px, pz, goal.x, goal.z)
            if d0 <= rt.range + 1.5 and point_is_land(px, pz) == true then
                return "succeeded", string.format("landed:%.2f", d0)
            end
            return "failed", "not_on_boat"
        end
    else
        -- [喵喵喵]: 平台查询为 nil 有两种：已上岸，或已经站在跳板上（原生跳板位置在
        -- 平台半径外）。后者必须看“真的在陆地上”才算成功，不能只看距离。
        if not has_tag(player, "on_walkable_plank") then
            local d0 = dist(px, pz, goal.x, goal.z)
            if d0 <= rt.range and point_is_land(px, pz) == true then
                return "succeeded", string.format("landed:%.2f", d0)
            end
        end
        boat = is_valid(rt.boat) and rt.boat or nil
        if boat == nil then
            return "failed", "not_on_boat"
        end
    end
    local bx, bz = entity_pos(boat)
    local rx, rz = bx, bz
    if not is_num(rx) or not is_num(rz) then
        rx, rz = px, pz
    end
    local d = dist(rx, rz, goal.x, goal.z)
    local note = health_note(boat, snapshot)

    -- [喵喵喵]: 靠岸分三个子阶段（sail/anchor/disembark），只在真正换阶段时收掉自己上一条
    -- 操作。旧实现每帧先 clear_own("anchor") 再 clear_own("land")，会把刚发的下船移动
    -- 每帧撤掉一次。
    local function land_phase(want)
        if rt.land_phase == want then
            return false
        end
        release_tracked(player, rt)
        rt.land_phase = want
        rt.phase_t = now()
        return true
    end

    -- 1) 还没到岸边：先划到“目标点外侧的水面驻点”
    -- [喵喵喵]: 一旦已经为靠岸抛了锚，就绝不再回到划桨，避免抛/起锚来回折腾。
    if rt.land_anchored ~= true and d > rt.range + Sailing.LAND_APPROACH_PAD then
        if d < 0.001 then
            return "failed", "goal_at_boat"
        end
        local dx, dz = (goal.x - rx) / d, (goal.z - rz) / d
        local approach = nil
        for i = 1, 4 do
            local back = rt.range + Sailing.LAND_APPROACH_PAD + (i - 1) * 1.5
            local ax, az = goal.x - dx * back, goal.z - dz * back
            local ocean = point_is_ocean(ax, az)
            if ocean == true then
                approach = { x = ax, z = az }
                break
            end
        end
        if approach == nil then
            return "failed", "no_approach_water|" .. note
        end
        land_phase("sail")
        return sail_towards(player, snapshot, rt, boat, approach.x, approach.z, "land_approach")
    end

    -- 2) 近岸：先减速/抛锚（原生 LOWER_ANCHOR），等标签真的变化
    local anchor, awhy = find_anchor(snapshot, boat)
    local astate = anchor_state(anchor)
    if rt.land_anchored ~= true then
        land_phase("anchor")
        if rt.land_phase == "anchor" and (rt.op == nil or rt.op.note ~= "anchor") then
            if awhy == "unverified" then
                return "pending", "anchor_unverified|" .. note
            end
            if astate == "raised" then
                local s, r = step_anchor(player, rt, anchor, "lowered")
                if s == "failed" then
                    return "failed", tostring(r) .. "|" .. note
                end
                return "pending", "anchoring:" .. tostring(r) .. "|" .. note
            elseif astate == "transitioning" then
                return "pending", "anchor_transitioning|" .. note
            elseif astate == "lowered" then
                -- [喵喵喵]: 锚真的落底了：记下来，之后只走“下船”不再划桨。
                rt.land_anchored = true
                rt.phase_t = now()
            end
        elseif rt.op ~= nil and rt.op.note == "anchor" then
            -- [喵喵喵]: 锚动作还在飞：只轮询同一条，等标签变化。
            local s, r = poll_op(player, rt)
            if s == "pending" then
                return "pending", "anchoring:" .. tostring(r) .. "|" .. note
            end
            -- [喵喵喵]: 动作终结了也不等于锚已落底：必须等真正的 anchor_lowered 标签。
            return "pending", "anchor_polled:" .. tostring(s) .. "|" .. tostring(r) .. "|" .. note
        end
    end

    -- 3) 真的下船后按观测确认（必须：不在跳板上 + 平台为 nil + 玩家位置是客户端可见陆地）
    if snapshot.platform == nil and not has_tag(player, "on_walkable_plank")
        and dist(px, pz, goal.x, goal.z) <= rt.range + 1.5
        and point_is_land(px, pz) == true then
        return "succeeded", string.format("landed:%.2f", dist(px, pz, goal.x, goal.z))
    end

    -- 4) 下船：走本 build 原生跳板链路（EXTEND_PLANK → MOUNT_PLANK → 走上陆地）；
    --    ABANDON_SHIP 只在“落点被客户端验证为陆地 + 方向朝目标 + goal.plank_jump==true”
    --    时最多用一次（原生跳进水里会掉钱包，不能盲跳）。
    land_phase("disembark")
    if rt.disembark_t == 0 then
        rt.disembark_t = now()
    end
    local plank, pwhy = find_plank(snapshot, boat)
    if not has_tag(player, "on_walkable_plank") then
        if plank == nil then
            -- [喵喵喵]: 没有可用跳板就是明确阻塞：不靠 WALKTO 猜“能不能直接走下船”。
            return "failed", "missing_plank:" .. tostring(pwhy) .. "|" .. note
        end
        local ms, mr = step_plank_mount(player, snapshot, rt, plank)
        if ms == "failed" then
            return "failed", "plank_mount_failed:" .. tostring(mr) .. "|" .. note
        end
        if ms ~= "mounted" then
            if now() - rt.disembark_t > Sailing.PLANK_TIMEOUT then
                return "failed", "plank_timeout:" .. tostring(mr) .. "|" .. note
            end
            return "pending", "disembark:" .. tostring(mr) .. "|" .. note
        end
    end

    -- 4b) 已在跳板上：跳上岸（可选）或沿跳板走上陆地
    if rt.op ~= nil and rt.op.note == "plank_jump" then
        local sj, rj = poll_op(player, rt)
        if sj == "pending" then
            return "pending", "plank_jumping:" .. tostring(rj) .. "|" .. note
        end
        return "pending", "plank_jump_done:" .. tostring(sj) .. "|" .. note
    end
    if rt.op ~= nil and rt.op.note == "land" then
        local s, r = poll_op(player, rt)
        if s == "pending" then
            return "pending", "landing:" .. tostring(r) .. "|" .. note
        end
        rt.land_fail = (rt.land_fail or 0) + 1
        if rt.land_fail >= 2 then
            local verdict = maybe_plank_jump(player, rt, boat, plank, goal)
            if verdict:sub(1, 5) == "sent:" then
                return "pending", "plank_jump:" .. verdict .. "|" .. note
            end
            if rt.land_fail >= 3 then
                return "failed", string.format("land_stuck_on_platform:%s|%s|jump=%s|",
                    tostring(platform ~= nil and platform.prefab or "?"), tostring(s), tostring(verdict)) .. note
            end
        end
        return "pending", "land_retry:" .. tostring(s) .. "|" .. tostring(r) .. "|" .. note
    end
    if rt.op == nil then
        local s, r = send_op(player, rt, {
            kind = "move",
            x = goal.x,
            z = goal.z,
            range = rt.range,
            note = "land",
        })
        if s == "pending" then
            return "pending", "land_move:" .. tostring(r) .. "|" .. note
        end
        return "pending", "land_move_" .. tostring(s) .. "|" .. note
    end
    return "pending", "landing_await_observation|" .. note
end

--============================================================================
-- [喵喵喵] 对外接口
--============================================================================
-- [喵喵喵]: 快照缺失/无坐标也是“会阻塞”的状态，必须有自己的上限（与 navigation 同值）。
local NOT_READY_TIMEOUT = 6.0

local HANDLERS = {
    sail = sail_mode,
    board = board_mode,
    land = land_mode,
}

function Sailing.Step(player, snapshot, state, goal)
    if type(state) ~= "table" then
        return "failed", "state_not_table"
    end
    if not is_valid(player) then
        return "failed", "player_invalid"
    end
    -- [喵喵喵]: 只对本地玩家下发，绝不对别的玩家发动作。
    if ThePlayer ~= nil and player ~= ThePlayer then
        return "failed", "not_local_player"
    end
    if type(goal) ~= "table" then
        return "failed", "goal_not_table"
    end
    local mode = goal.mode
    if type(mode) ~= "string" or Sailing.MODES[mode] ~= true then
        return "failed", "goal_bad_mode:" .. tostring(mode)
    end
    if not is_num(goal.x) or not is_num(goal.z) then
        return "failed", "goal_needs_finite_x_z"
    end
    if math.abs(goal.x) > Sailing.WORLD_LIMIT or math.abs(goal.z) > Sailing.WORLD_LIMIT then
        return "failed", "goal_out_of_world"
    end
    local range = goal.range == nil and Sailing.DEFAULT_RANGE[mode] or goal.range
    if not is_num(range) or range <= 0 or range > 40 then
        return "failed", "goal_bad_range"
    end
    local priority = goal.priority == nil and Sailing.GOAL_PRIORITY or goal.priority
    if not is_num(priority) then
        return "failed", "goal_bad_priority"
    end
    if type(snapshot) ~= "table" then
        return "failed", "snapshot_not_table"
    end

    -- [喵喵喵]: 身份 key 先算出来：换目标/换 id/换世界才算新任务，否则复用同一份运行期。
    local key = goal_key(goal, snapshot, mode, range)
    local rt = state.sail
    if type(rt) ~= "table" or rt.key ~= key or rt.v ~= Sailing.SCHEMA_VERSION then
        -- [喵喵喵]: 换任务前只释放“我们自己记着且确认过所有权”的那一条，
        -- 绝不把别人正在走的动作或未被跟踪的操作当成自己的。
        if type(rt) == "table" then
            release_tracked(player, rt)
        end
        rt = {}
        state.sail = rt
        reset_runtime(rt, key, mode, goal, range, priority, snapshot)
    end
    if rt.closed ~= nil and rt.closed.key == key then
        -- [喵喵喵]: 闩存终态：同一身份只回结果，不再下发任何东西。
        return rt.closed.status, rt.closed.reason
    end

    -- [喵喵喵]: 总预算放在快照检查之前：没就绪/没坐标也不能无限 pending。
    local budget = Sailing.TIMEOUT[mode] or 120
    if now() - rt.started > budget then
        return finish(player, rt, "failed",
            string.format("timeout:%s|phase=%s|%s", mode, tostring(rt.phase), tostring(rt.last_reason)))
    end

    if snapshot.ready ~= true or not is_num(snapshot.x) or not is_num(snapshot.z) then
        local why = snapshot.ready ~= true
            and ("snapshot_not_ready:" .. tostring(snapshot.ready_reason))
            or "snapshot_no_position"
        if rt.not_ready_since == nil then
            rt.not_ready_since = now()
        end
        if now() - rt.not_ready_since >= NOT_READY_TIMEOUT then
            return finish(player, rt, "failed", "snapshot_unavailable|" .. why)
        end
        return "pending", why
    end
    rt.not_ready_since = nil

    local handler = HANDLERS[mode]
    local status, reason = handler(player, snapshot, rt, goal)
    rt.last_status = status
    rt.last_reason = reason
    if status ~= "pending" then
        return finish(player, rt, status, reason)
    end
    return status, reason
end

function Sailing.Cancel(player, state)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    local rt = state.sail
    if type(rt) ~= "table" then
        state.sail = nil
        return true, "cancelled|no_sailing_state"
    end
    local suffix = ""
    -- [喵喵喵]: 只有本轮确认过“这条操作是我们的”才发 Cancel，绝不撤别人的。
    if rt.owned == true and rt.op ~= nil and is_valid(player) then
        local ok, why = Actions.Cancel(player)
        suffix = ok == true and "|action_cancelled" or ("|action_cancel_refused:" .. tostring(why))
        rt.owned = false
        rt.op = nil
    elseif rt.op ~= nil then
        suffix = "|no_owned_action"
    end    if rt.phase ~= nil then
        suffix = suffix .. "|phase=" .. tostring(rt.phase)
    end
    state.sail = nil
    return true, "cancelled" .. suffix
end

return Sailing
