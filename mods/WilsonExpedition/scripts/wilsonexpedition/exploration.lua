--============================================================================
-- [喵喵喵]: WilsonExpedition / 探索决策层（只挑目标点，绝不执行移动）
--
-- 职责边界：
--   * 本文件唯一的产物是"下一个去哪"的 goal，交给
--     require('wilsonexpedition/navigation') 的 Navigation.Step 去执行。
--     这里不调用 Actions、不发动作、不瞬移、不做任何服务端改动。
--   * 只用本地玩家 + 客户端可见信息：快照坐标/威胁/海岸探测点/地标，
--     以及 TheWorld.Map 的本地可走性查询。不建隐藏地图、不扫全图、
--     不读存档、不列 prefab 表。原生 scripts 目录中没有任何
--     MapExplorer:IsExplored 调用（该名字只出现在 C++ 侧），所以本文件
--     既不使用也不假设存在"已探索"查询；"没走过"一律指本文件自己的
--     访问记录里没有这一格，而不是"世界地图上未探索"。
--
-- 对外接口（goal 全部是纯值表，可直接传给 Navigation.Step）：
--   Exploration.Next(player, snapshot, state) -> goal|nil, reason
--       goal = { x, z, range, priority, id, world,
--                kind = "ray"|"shore"|"passage"|"base" }
--   Exploration.Report(state, goal, status, reason) -> ok(boolean), detail
--       status 接受 "arrived" | "blocked"（也接受 "succeeded" | "failed" 作为
--       同义写法，方便直接转发 Navigation 的终态）；arrived 记到访并清零阻塞
--       计数，blocked 记阻塞次数+时间，使同一前沿不会无限重复选中。
--   Exploration.BaseGoal(state, snapshot, fresh) -> goal|nil, reason
--       返回"回已记录基地坐标"的 goal（走 Navigation 回去，不传送）。
--       fresh==true 时递增尝试号，给出新的显式 goal.id（重试必须换 id）。
--       需先在本世界调用过 Next（由它定位世界键）。
--   Exploration.SetBase(state, snapshot, x, z) -> ok(boolean), detail
--       记录/覆盖本世界的基地锚点（纯坐标）；不给坐标时取当前观测位置。
--       需先在本世界调用过 Next；无世界上下文时返回 false,"no_world_context"。
--
-- 调用方持有的状态命名空间（本模块不创建任何全局表）：
--   state.explore          运行期（**不可序列化**）：世界实体引用、分片/会话键、
--                          当前选中的目标、上一访问格、地形缓存、选择计数。
--   state.explore_memory   持久探索记录（**纯可序列化值**：number/string/
--                          普通表；不含实体、函数、userdata）：
--                            v / tick
--                            worlds["<session|shard>"] = {
--                                shard, session, last_tick, seq, n_cells,
--                                base = { x, z, cycle, attempts, t },
--                                cells["gx|gz"] = { gx, gz, visits, picks,
--                                                   blocked_n, blocked_t,
--                                                   silent_n, seq, last_reason },
--                            }
--       容量上限：MAX_WORLDS 个世界键、MAX_CELLS 个格子，超限按最久未更新淘汰。
--       blocked_t 仅为兼容旧记录而保留（新记录写 0），阻塞冷却改存运行期
--       rt.blocked（GetTime 坐标系），因为 GetTime 重登会重置，拿持久值相减会误判。
--
-- 决策行为：
--   * 候选点只在"当前观测半径"内采样（默认 = Observer.NEARBY_RADIUS），
--     不做跨图查询：16 个方向 × 3 层半径(0.4/0.7/1.0 × 半径) 的环形点，
--     外加快照里看得见的海岸探测点(向玩家方向内收，保证落在岸上)与
--     通道地标(passage)。这些点全部经过本地 Map 校验：IsPassableAtPoint
--     (x,0,z,false,true) 必须是陆地(海洋/船面都不算) 且 IsPointNearHole
--     为 false；查询失败/地图缺失一律当"未知"跳过并计数，不猜可走。
--   * 威胁：候选点离任何可见威胁 <= THREAT_RADIUS 且没有比玩家更远
--     (THREAT_PAD 余量) 时淘汰，避免把探索目标点选进怪堆里。
--   * 评分 = 未访问采样比例 × NOVELTY_WEIGHT − 曾到访次数 × VISIT_PENALTY
--     − 距离 × DIST_PENALTY + 海岸/通道加成 − 阻塞次数惩罚。
--     "未访问比例"是沿玩家→候选点线段取样的本文件访问记录，因此天然
--     优先没走过的方向；海岸/通道有加成，于是有用的岸线/通道优先。
--   * goal.id 一旦选中就保持不变（"frontier:hold"），只有在调用方 Report、
--     GOAL_TTL 到期、或复检发现地形/威胁实际不可行时才换新 id；
--     不随轮询改变。每次新选择都递增目标格的 picks，id 里带 picks，因此
--     同一格重试一定是新的显式 id（Navigation 按 id 闩存终态）。
--   * 轮询与访问计数分离：只有在玩家真正换到另一个 4 单位格子时才
--     visits+1；同一格内的重复轮询只刷新时间戳，不刷访问次数。
--   * 有限兜底：本地观测半径内扫完仍无候选 → 返回 nil 和明确原因
--     （no_frontier|scanned=..|terrain=..|threat=..|blocked=..|near=..）；
--     若全部候选都已访问且"连续向外推一步"的预算用完 → no_frontier|
--     local_area_exhausted；连续无进展的选择次数超过 MAX_PICKS →
--     pick_budget_exhausted。两个预算都在"观察到新格子 / 到达目标 / 重新选到
--     未访问方向"时清零，所以只有连续无效尝试受限，串行合法探索不受限。
--     所有分支都有确定终点，不会无限选下去。
--   * 世界身份：带 snapshot 的入口（Next/SetBase/BaseGoal）一律用快照的
--     session+shard 解析记录；Report 没有 snapshot，因此先核对 rt.world 仍是
--     当前世界实体，并只接受与当前选择同一个 goal 身份的回报（迟到的旧报告
--     不会污染/清掉新选择）。
--   * 回基地：BaseGoal 只把已记录的基地坐标包成 goal，由 Navigation 带路；
--     是否出发、何时出发由调用方决定（Next 自己不会在探索途中突然折返）。
--   * 换世界/换分片/换会话：只重建本模块的 state.explore（不动 state.nav
--     等其它处理器的数据）；持久记录按世界键分开，旧世界记录由容量上限淘汰。
--
-- 硬前提（调用方必须遵守）：
--   1) 单活跃控制器：同一时刻只有一个处理器驱动 Actions（原生每个玩家只有
--      一条 WALKTO）。本模块只产出 goal，不仲裁优先级。
--   2) player 必须是本地玩家（ThePlayer）；快照必须 ready 且有坐标。
--   3) Report 必须在同一世界的 Next 之后调用（Report 没有 snapshot 参数，
--      靠 state.explore.world_key 定位记录）。
--============================================================================

local Observer = require('wilsonexpedition/observer')

local Exploration = {}

Exploration.SCHEMA_VERSION = 1

-- [喵喵喵]: 常量全部是有限上限；触顶走明确失败原因，不留无界增长。
Exploration.GRID = 4                          -- 本地访问/地形缓存网格边长(世界单位)
Exploration.DIRECTIONS = 16                    -- 环形采样方向数
Exploration.RING_FRACTIONS = { 0.4, 0.7, 1.0 } -- 采样层半径 = 观测半径 × 该系数
Exploration.SCAN_RADIUS = (type(Observer.NEARBY_RADIUS) == "number" and Observer.NEARBY_RADIUS) or 20
Exploration.SCAN_RADIUS_MAX = 30               -- 兜底钳制(与观测层地标半径一致)
Exploration.MIN_GOAL_DIST = 3                  -- 离玩家这么近的点不值得当目标
Exploration.GOAL_RANGE = 1.5                   -- 与 Navigation.GOAL_RANGE / Actions.DEFAULT_RANGE 一致
Exploration.GOAL_PRIORITY = 0                  -- 与 Actions.DEFAULT_PRIORITY 一致
Exploration.WORLD_LIMIT = 20000                -- 与 Actions.WORLD_LIMIT 一致
Exploration.GOAL_TTL = 45                      -- 同一目标最长保持秒数
Exploration.THREAT_RADIUS = 7                  -- 与 Navigation.THREAT_RADIUS 一致
Exploration.THREAT_PAD = 2.5                   -- 与 Navigation.THREAT_PAD 一致
Exploration.SHORE_PULL_BACK = 0.35             -- 海岸点向玩家方向内收的比例
Exploration.SHORE_BONUS = 15                   -- 海岸候选加分
Exploration.PASSAGE_BONUS = 25                 -- 通道(洞口/虫洞/天坑)候选加分
Exploration.NOVELTY_WEIGHT = 100               -- 未访问比例权重
Exploration.VISIT_PENALTY = 10                 -- 到访过该格的惩罚
Exploration.DIST_PENALTY = 0.5                 -- 距离权重(鼓励逐步向外)
Exploration.TRIES_PENALTY = 30                 -- 被 Report blocked 过的惩罚
Exploration.SILENT_PENALTY = 15                -- 选中后一直没报告的惩罚
Exploration.SAMPLE_COUNT = 4                   -- 玩家→候选点线段上的采样数
Exploration.MAX_BLOCKED_TRIES = 2              -- 阻塞这么多次后本世界内不再选该格
Exploration.MAX_SILENT_TRIES = 3               -- 选而不报这么多次后不再选该格
Exploration.BLOCK_COOLDOWN = 240               -- 阻塞后的冷却秒数(只存在运行期)
Exploration.MAX_EXPANSIONS = 8                 -- "已全部访问"时向外推一步的连续预算
Exploration.MAX_PICKS = 128                    -- 连续无进展的选择次数上限(有真实进展即清零)
Exploration.TERRAIN_TTL = 30                   -- 地形缓存有效期(秒)
Exploration.TERRAIN_CACHE_MAX = 128            -- 地形缓存条目上限
Exploration.MAX_WORLDS = 4                     -- 持久记录保留的世界键数
Exploration.MAX_CELLS = 256                    -- 每个世界保留的格子记录数
Exploration.REASON_MAX = 48                    -- 记录里保留的 reason 长度上限
Exploration.BASE_MIN_DIST = 6                  -- 离基地这么近就算"已在家"
Exploration.EMPTY_COOLDOWN = 0.75              -- "周边无前沿"结论的复用秒数
Exploration.EMPTY_MOVE = 2                     -- 玩家位移超过它就作废上面的结论

-- [喵喵喵]: 运行期冷却表的条目上限，用文件内局部常量，避免新增对外导出。
local BLOCK_DEADLINE_MAX = 128

--------------------------------------------------------------------------
-- [喵喵喵]: 基础小工具（数值/实体/时间/网格）
--------------------------------------------------------------------------
local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

-- [喵喵喵]: 时限统一用原生 GetTime，缺了退回 os.clock，不会出现"永不超时"。
local function now()
    return type(GetTime) == "function" and GetTime() or os.clock()
end

local function distance(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

local function cell_of(x, z)
    return math.floor(x / Exploration.GRID), math.floor(z / Exploration.GRID)
end

local function cell_key(gx, gz)
    return string.format("%d|%d", gx, gz)
end

local function short_reason(reason)
    if type(reason) ~= "string" then
        return nil
    end
    if #reason <= Exploration.REASON_MAX then
        return reason
    end
    return string.sub(reason, 1, Exploration.REASON_MAX)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 世界键解析。session + shard 才是稳定身份；缺 session 时用世界
-- 实体 GUID 兜底 —— 宁可重载后丢记忆，也不能把两个世界混成同一份记录。
--------------------------------------------------------------------------
local function resolve_world_key(snapshot)
    local shard = snapshot.shard
    if type(shard) ~= "string" then
        return nil
    end
    local session = type(snapshot.session) == "string" and snapshot.session or nil
    if session ~= nil then
        return session .. "|" .. shard
    end
    local guid = TheWorld ~= nil and TheWorld.GUID or nil
    return string.format("guid|%s|%s", tostring(guid or "0"), shard)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 持久记录存取（有界：世界数、格子数都按最久未更新淘汰）
--------------------------------------------------------------------------
local function trim_worlds(store)
    local total, oldest_key, oldest_tick = 0, nil, nil
    for key, record in pairs(store.worlds) do
        total = total + 1
        local tick = type(record) == "table" and (tonumber(record.last_tick) or 0) or 0
        if oldest_tick == nil or tick < oldest_tick then
            oldest_key, oldest_tick = key, tick
        end
    end
    if total >= Exploration.MAX_WORLDS and oldest_key ~= nil then
        store.worlds[oldest_key] = nil
    end
end

local function ensure_cell(record, gx, gz)
    local key = cell_key(gx, gz)
    local cell = record.cells[key]
    if type(cell) == "table" then
        return cell, key
    end

    if (record.n_cells or 0) >= Exploration.MAX_CELLS then
        local oldest_key, oldest_seq = nil, nil
        for k, v in pairs(record.cells) do
            local seq = type(v) == "table" and (tonumber(v.seq) or 0) or 0
            if oldest_seq == nil or seq < oldest_seq then
                oldest_key, oldest_seq = k, seq
            end
        end
        if oldest_key ~= nil then
            record.cells[oldest_key] = nil
            record.n_cells = math.max(0, (record.n_cells or 1) - 1)
        end
    end

    -- [喵喵喵]: 纯值记录：只有 number/string，调用方可安全序列化。
    cell = {
        gx = gx,
        gz = gz,
        visits = 0,
        picks = 0,
        blocked_n = 0,
        blocked_t = 0, -- [喵喵喵]: 仅为兼容旧记录保留，新记录恒为 0，冷却不读它。
        silent_n = 0,
        seq = 0,
    }
    record.cells[key] = cell
    record.n_cells = (record.n_cells or 0) + 1
    return cell, key
end

local function lookup_cell(record, gx, gz)
    local cell = record.cells[cell_key(gx, gz)]
    return type(cell) == "table" and cell or nil
end

local function reset_runtime(rt, snapshot, world_key)
    rt.world = TheWorld
    rt.shard = snapshot.shard
    rt.session = snapshot.session
    rt.world_key = world_key
    rt.current = nil
    rt.last_cell = nil
    rt.picks = 0
    rt.expansions = 0
    rt.terrain = {}
    rt.blocked = {}
    rt.empty = nil
    rt.started = now()
end

local function get_world_record(state, snapshot, rt)
    local world_key = resolve_world_key(snapshot)
    if world_key == nil then
        return nil, nil, "snapshot_no_shard"
    end

    -- [喵喵喵]: 换世界/换分片/换会话只重置本模块的运行期命名空间。
    if rt.world ~= TheWorld or rt.world_key ~= world_key then
        reset_runtime(rt, snapshot, world_key)
    end

    local store = state.explore_memory
    if type(store) ~= "table" then
        store = {}
        state.explore_memory = store
    end
    store.v = Exploration.SCHEMA_VERSION
    store.tick = (tonumber(store.tick) or 0) + 1
    if type(store.worlds) ~= "table" then
        store.worlds = {}
    end

    local record = store.worlds[world_key]
    if type(record) ~= "table" then
        trim_worlds(store)
        record = {
            shard = snapshot.shard,
            session = snapshot.session,
            cells = {},
            seq = 0,
            n_cells = 0,
            last_tick = 0,
        }
        store.worlds[world_key] = record
    end
    if type(record.cells) ~= "table" then
        record.cells = {}
    end
    record.shard = record.shard or snapshot.shard
    record.session = record.session or snapshot.session
    record.seq = tonumber(record.seq) or 0
    record.n_cells = tonumber(record.n_cells) or 0
    record.last_tick = store.tick

    return record, world_key, nil
end

--------------------------------------------------------------------------
-- [喵喵喵]: 陆地形查询。true / nil+原因；未知一律当"不可用"跳过，不猜。
--------------------------------------------------------------------------
local function query_terrain(x, z)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, "terrain_bad_coordinates"
    end
    local map = TheWorld ~= nil and TheWorld.Map or nil
    if map == nil or map.IsPassableAtPoint == nil then
        return nil, "terrain_unsupported"
    end

    -- [喵喵喵]: allow_water=false, exclude_boats=true → 海洋与船面都不算可走陆地。
    local ok_call, passable = pcall(function()
        return map:IsPassableAtPoint(x, 0, z, false, true)
    end)
    if not ok_call then
        return nil, "terrain_unreadable"
    end
    if passable ~= true then
        return nil, "terrain_not_land"
    end

    -- [喵喵喵]: 洞口(地面缺口/洞穴入口)同样不可走。Vector3 在原生
    -- scripts/vector3.lua 里是 Class(...) 返回的可调用表（不是 type == "function"），
    -- 所以这里直接在 pcall 里调用构造器；任何失败都当作"未知"返回。
    if map.IsPointNearHole ~= nil then
        local ok_hole, near_hole = pcall(function()
            return map:IsPointNearHole(Vector3(x, 0, z))
        end)
        if not ok_hole then
            return nil, "terrain_hole_query_failed"
        end
        if near_hole == true then
            return nil, "terrain_near_hole"
        end
    end
    return true, nil
end

-- [喵喵喵]: 地形结果按 1 单位网格缓存 TERRAIN_TTL 秒：玩家站着等路线时
-- 同一批候选点会被反复评估，没必要每次都查地图/找洞口实体。
local function terrain_ok(rt, x, z, t)
    local key = string.format("%d|%d", math.floor(x + 0.5), math.floor(z + 0.5))
    local cache = rt.terrain
    if type(cache) ~= "table" then
        cache = {}
        rt.terrain = cache
    end

    local hit = cache[key]
    if type(hit) == "table" and is_finite_number(hit.t) and (t - hit.t) <= Exploration.TERRAIN_TTL then
        return hit.ok == true and true or nil, hit.why
    end

    local ok, why = query_terrain(x, z)
    local count = 0
    for _ in pairs(cache) do
        count = count + 1
    end
    if count >= Exploration.TERRAIN_CACHE_MAX then
        local oldest_key, oldest_t = nil, nil
        for k, v in pairs(cache) do
            local vt = type(v) == "table" and (tonumber(v.t) or 0) or 0
            if oldest_t == nil or vt < oldest_t then
                oldest_key, oldest_t = k, vt
            end
        end
        if oldest_key ~= nil then
            cache[oldest_key] = nil
        end
    end
    cache[key] = { ok = ok == true, why = why, t = t }
    return ok, why
end

-- [喵喵喵]: 只有"地图明确说不可走"才算实际失效；查询失败/地图缺失属于未知，
-- 不能拿它当理由放弃一个已经选中的目标。
local function terrain_definitely_blocked(why)
    return why == "terrain_not_land" or why == "terrain_near_hole"
end

--------------------------------------------------------------------------
-- [喵喵喵]: 威胁安全 = 不把目标点选进可见威胁的贴身范围，也不比玩家更靠近它。
--------------------------------------------------------------------------
local function threat_safe(cx, cz, px, pz, threats)
    if type(threats) ~= "table" then
        return true
    end
    for i = 1, #threats do
        local threat = threats[i]
        local tx = type(threat) == "table" and threat.x or nil
        local tz = type(threat) == "table" and threat.z or nil
        if is_finite_number(tx) and is_finite_number(tz) then
            local cd = distance(cx, cz, tx, tz)
            local pd = distance(px, pz, tx, tz)
            if cd <= Exploration.THREAT_RADIUS and cd < pd + Exploration.THREAT_PAD then
                return false
            end
        end
    end
    return true
end

--------------------------------------------------------------------------
-- [喵喵喵]: 方向新鲜度：沿玩家→候选点线段取样，统计本文件记录里"没到访过"
-- 的格子比例。只用本地记录，不查询地图，也不假设世界地图的探索状态。
--------------------------------------------------------------------------
local function novelty(record, px, pz, cx, cz)
    local pgx, pgz = cell_of(px, pz)
    local unvisited, total = 0, 0
    for i = 1, Exploration.SAMPLE_COUNT do
        local f = i / Exploration.SAMPLE_COUNT
        local sx = px + (cx - px) * f
        local sz = pz + (cz - pz) * f
        local gx, gz = cell_of(sx, sz)
        if gx ~= pgx or gz ~= pgz then
            total = total + 1
            local cell = record.cells[cell_key(gx, gz)]
            if type(cell) ~= "table" or (tonumber(cell.visits) or 0) <= 0 then
                unvisited = unvisited + 1
            end
        end
    end
    if total <= 0 then
        return 0
    end
    return unvisited / total
end

-- [喵喵喵]: 阻塞冷却只能存在运行期：持久记录里的 blocked_t 用的是 GetTime()，
-- 它在重登/重连后会重置，直接跟当前 t 相减会把"上一局留下的时间戳"当成"刚阻塞"，
-- 甚至因为旧 uptime 很大而把合法前沿整局屏蔽掉。所以冷却改成 rt.blocked 里的
-- "到期时刻"（同为本次进程的 GetTime 坐标系），持久记录里的 blocked_t 不再参与判定。
local function set_block_deadline(rt, gx, gz, t)
    local map = rt.blocked
    if type(map) ~= "table" then
        map = {}
        rt.blocked = map
    end
    map[cell_key(gx, gz)] = t + Exploration.BLOCK_COOLDOWN

    local count = 0
    for _ in pairs(map) do
        count = count + 1
    end
    if count > BLOCK_DEADLINE_MAX then
        for key, deadline in pairs(map) do
            if count <= BLOCK_DEADLINE_MAX then
                break
            end
            if (tonumber(deadline) or 0) <= t then
                map[key] = nil
                count = count - 1
            end
        end
    end
end

local function clear_block_deadline(rt, gx, gz)
    local map = rt.blocked
    if type(map) == "table" then
        map[cell_key(gx, gz)] = nil
    end
end

local function block_cooldown_active(rt, gx, gz, t)
    local map = rt.blocked
    if type(map) ~= "table" then
        return false
    end
    local key = cell_key(gx, gz)
    local deadline = tonumber(map[key])
    if deadline == nil then
        return false
    end
    if t < deadline then
        return true
    end
    map[key] = nil
    return false
end

-- [喵喵喵]: 前沿抑制：被 Report blocked（或选而不报）太多次的格子在本世界内
-- 不再选（计数在持久记录里，与时钟无关）；短冷却只看运行期到期时刻。
local function cell_suppressed(rt, cell, t)
    if type(cell) ~= "table" then
        return false
    end
    if (tonumber(cell.blocked_n) or 0) >= Exploration.MAX_BLOCKED_TRIES then
        return true
    end
    if (tonumber(cell.silent_n) or 0) >= Exploration.MAX_SILENT_TRIES then
        return true
    end
    local gx, gz = tonumber(cell.gx), tonumber(cell.gz)
    if gx ~= nil and gz ~= nil and block_cooldown_active(rt, gx, gz, t) then
        return true
    end
    return false
end

--------------------------------------------------------------------------
-- [喵喵喵]: 访问记账：只有玩家真正换到另一个格子才 visits+1（轮询不刷计数）。
--------------------------------------------------------------------------
local function mark_visit(record, rt, x, z)
    local gx, gz = cell_of(x, z)
    local key = cell_key(gx, gz)
    if rt.last_cell == key then
        return false
    end
    rt.last_cell = key
    local cell = ensure_cell(record, gx, gz)
    local before = tonumber(cell.visits) or 0
    cell.visits = before + 1
    record.seq = (tonumber(record.seq) or 0) + 1
    cell.seq = record.seq
    -- [喵喵喵]: 只有"第一次踏进这一格"才算真实进展（用于清零连续失败预算）。
    return before <= 0
end

local function scan_horizon()
    local radius = Exploration.SCAN_RADIUS
    if not is_finite_number(radius) or radius <= 0 then
        radius = 20
    end
    if radius > Exploration.SCAN_RADIUS_MAX then
        radius = Exploration.SCAN_RADIUS_MAX
    end
    if radius < Exploration.MIN_GOAL_DIST * 2 then
        radius = Exploration.MIN_GOAL_DIST * 2
    end
    return radius
end

-- [喵喵喵]: "周边没有前沿"这种结论也要有代价：短时间内玩家没挪动就复用，
-- 避免每帧把 48 个候选点重扫一遍。
local function remember_empty(rt, t, x, z, reason)
    rt.empty = { t = t, x = x, z = z, reason = reason }
end

--------------------------------------------------------------------------
-- [喵喵喵]: 主入口：选一个目标点，或者明确说"现在没得去"。
--------------------------------------------------------------------------
function Exploration.Next(player, snapshot, state)
    if type(state) ~= "table" then
        return nil, "state_not_table"
    end
    if not is_valid(player) then
        return nil, "player_invalid"
    end
    if ThePlayer ~= nil and player ~= ThePlayer then
        return nil, "not_local_player"
    end
    if type(snapshot) ~= "table" then
        return nil, "snapshot_not_table"
    end
    if snapshot.ready ~= true then
        return nil, "snapshot_not_ready:" .. tostring(snapshot.ready_reason)
    end
    local px, pz = snapshot.x, snapshot.z
    if not is_finite_number(px) or not is_finite_number(pz) then
        return nil, "snapshot_no_position"
    end
    -- [喵喵喵]: 站在船/平台上时 Navigation 会拒绝陆地路线，这里不产出注定失败的目标。
    if snapshot.platform ~= nil then
        return nil, "on_platform_land_route_unsupported"
    end

    local rt = state.explore
    if type(rt) ~= "table" then
        rt = {}
        state.explore = rt
    end
    rt.v = Exploration.SCHEMA_VERSION

    local record, world_key, world_why = get_world_record(state, snapshot, rt)
    if record == nil then
        return nil, world_why or "no_world_record"
    end

    local t = now()

    -- [喵喵喵]: 本世界第一次拿到坐标就记基地锚点（纯坐标）；调用方可用
    -- SetBase 覆盖成真正的营地位置。
    if type(record.base) ~= "table"
        or not is_finite_number(record.base.x)
        or not is_finite_number(record.base.z) then
        record.base = {
            x = px,
            z = pz,
            cycle = tonumber(snapshot.cycles) or 0,
            attempts = 0,
            t = t,
        }
    end

    -- [喵喵喵]: 第一次踏进新格子 = 真实进展：把"连续无进展"预算清零。
    -- 不然 70 天长跑里攒满 MAX_PICKS/MAX_EXPANSIONS 后会永久停止选新目标。
    if mark_visit(record, rt, px, pz) then
        rt.picks = 0
        rt.expansions = 0
    end

    -- [喵喵喵]: 刚扫过且没结果、玩家也几乎没动：直接复用结论，不再重扫。
    local empty = rt.empty
    if type(empty) == "table"
        and (t - (tonumber(empty.t) or 0)) < Exploration.EMPTY_COOLDOWN
        and distance(px, pz, tonumber(empty.x) or px, tonumber(empty.z) or pz) <= Exploration.EMPTY_MOVE then
        return nil, empty.reason or "no_frontier"
    end

    -- 阶段一：已选目标保持稳定，id 不随轮询变化。
    local current = rt.current
    if type(current) == "table" then
        local dist = distance(px, pz, current.x, current.z)
        if dist <= Exploration.GOAL_RANGE then
            -- [喵喵喵]: 玩家已经站到目标上了，调用方可能还没来得及 Report：
            -- 这里按"到达"自动入账，并立刻重选，避免返回一个脚下的目标。
            local cell = ensure_cell(record, current.gx, current.gz)
            cell.visits = (tonumber(cell.visits) or 0) + 1
            cell.blocked_n = 0
            clear_block_deadline(rt, current.gx, current.gz)
            rt.picks = 0
            rt.expansions = 0
            record.seq = (tonumber(record.seq) or 0) + 1
            cell.seq = record.seq
            rt.current = nil
        elseif (t - (tonumber(current.t) or t)) <= Exploration.GOAL_TTL then
            -- [喵喵喵]: 保持 id 稳定，但"实际不能走"仍要放弃：地形缓存会甄别
            -- 未知与明确不可走，后者属于真失效，不能一直等下去。
            local ok_now, why_now = terrain_ok(rt, current.x, current.z, t)
            if ok_now ~= true and terrain_definitely_blocked(why_now) then
                local cell = ensure_cell(record, current.gx, current.gz)
                cell.blocked_n = (tonumber(cell.blocked_n) or 0) + 1
                set_block_deadline(rt, current.gx, current.gz, t)
                cell.last_reason = short_reason(why_now)
                record.seq = (tonumber(record.seq) or 0) + 1
                cell.seq = record.seq
                rt.current = nil
            end
            if rt.current ~= nil then
                return {
                    x = current.x,
                    z = current.z,
                    range = current.range,
                    priority = current.priority,
                    id = current.id,
                    kind = current.kind,
                    world = world_key,
                }, string.format("frontier:hold|age=%.1f|dist=%.1f", t - (tonumber(current.t) or t), dist)
            end
        else
            -- [喵喵喵]: 选中后 GOAL_TTL 秒都没有报结果：记一次"静默失败"，
            -- 让同一个前沿不会因为没人报告就被无限重选。
            local cell = ensure_cell(record, current.gx, current.gz)
            cell.silent_n = (tonumber(cell.silent_n) or 0) + 1
            cell.last_reason = "no_report"
            record.seq = (tonumber(record.seq) or 0) + 1
            cell.seq = record.seq
            rt.current = nil
        end
    end

    local picks = (tonumber(rt.picks) or 0) + 1
    if picks > Exploration.MAX_PICKS then
        rt.picks = picks
        return nil, "pick_budget_exhausted"
    end

    local horizon = scan_horizon()
    local threats = type(snapshot.threats) == "table" and snapshot.threats or nil
    local stats = { scanned = 0, terrain = 0, threat = 0, blocked = 0, near = 0 }
    local best = nil

    local function evaluate(cx, cz, kind, bonus)
        if not is_finite_number(cx) or not is_finite_number(cz) then
            return
        end
        if math.abs(cx) > Exploration.WORLD_LIMIT or math.abs(cz) > Exploration.WORLD_LIMIT then
            return
        end
        stats.scanned = stats.scanned + 1
        local dist = distance(px, pz, cx, cz)
        if dist < Exploration.MIN_GOAL_DIST then
            stats.near = stats.near + 1
            return
        end

        local ok_terrain = terrain_ok(rt, cx, cz, t)
        if ok_terrain ~= true then
            stats.terrain = stats.terrain + 1
            return
        end
        if not threat_safe(cx, cz, px, pz, threats) then
            stats.threat = stats.threat + 1
            return
        end

        local gx, gz = cell_of(cx, cz)
        local cell = lookup_cell(record, gx, gz)
        if cell_suppressed(rt, cell, t) then
            stats.blocked = stats.blocked + 1
            return
        end

        local fresh = novelty(record, px, pz, cx, cz)
        local visits = type(cell) == "table" and (tonumber(cell.visits) or 0) or 0
        local blocked_n = type(cell) == "table" and (tonumber(cell.blocked_n) or 0) or 0
        local silent_n = type(cell) == "table" and (tonumber(cell.silent_n) or 0) or 0
        local score = fresh * Exploration.NOVELTY_WEIGHT
            - visits * Exploration.VISIT_PENALTY
            - dist * Exploration.DIST_PENALTY
            + bonus
            - blocked_n * Exploration.TRIES_PENALTY
            - silent_n * Exploration.SILENT_PENALTY

        -- [喵喵喵]: 严格大于才替换，遍历顺序固定 ⇒ 同分结果确定、可复现。
        if best == nil or score > best.score then
            best = {
                x = cx,
                z = cz,
                kind = kind,
                score = score,
                novelty = fresh,
                dist = dist,
                gx = gx,
                gz = gz,
            }
        end
    end

    -- 环形射线：只扫当前观测半径以内，逐层向外(渐进扩展)。
    local direction_count = Exploration.DIRECTIONS
    for i = 0, direction_count - 1 do
        local angle = (i / direction_count) * math.pi * 2
        local cos_a, sin_a = math.cos(angle), math.sin(angle)
        for r = 1, #Exploration.RING_FRACTIONS do
            local radius = horizon * Exploration.RING_FRACTIONS[r]
            evaluate(px + cos_a * radius, pz + sin_a * radius, "ray", 0)
        end
    end

    -- 海岸探测点本身是海面，向玩家方向内收一段后作为"岸边航点"候选。
    if type(snapshot.shore_points) == "table" then
        for i = 1, #snapshot.shore_points do
            local point = snapshot.shore_points[i]
            if type(point) == "table" and is_finite_number(point.x) and is_finite_number(point.z) then
                local shore_dist = distance(px, pz, point.x, point.z)
                if shore_dist > Exploration.MIN_GOAL_DIST and shore_dist <= horizon then
                    local keep = 1 - Exploration.SHORE_PULL_BACK
                    evaluate(px + (point.x - px) * keep, pz + (point.z - pz) * keep, "shore", Exploration.SHORE_BONUS)
                end
            end
        end
    end

    -- 通道类地标(洞口/虫洞/天坑)：只要在观测半径内、本地可走就优先。
    local passage_landmarks = type(snapshot.landmarks) == "table" and snapshot.landmarks.passage or nil
    if type(passage_landmarks) == "table" then
        for i = 1, #passage_landmarks do
            local landmark = passage_landmarks[i]
            if type(landmark) == "table" and is_finite_number(landmark.x) and is_finite_number(landmark.z) then
                local landmark_dist = distance(px, pz, landmark.x, landmark.z)
                if landmark_dist <= horizon then
                    evaluate(landmark.x, landmark.z, "passage", Exploration.PASSAGE_BONUS)
                end
            end
        end
    end

    if best == nil then
        local reason = string.format("no_frontier|scanned=%d|terrain=%d|threat=%d|blocked=%d|near=%d",
            stats.scanned, stats.terrain, stats.threat, stats.blocked, stats.near)
        remember_empty(rt, t, px, pz, reason)
        return nil, reason
    end

    -- [喵喵喵]: 所有候选都已访问时，允许连续有限次"向外推一步"；一旦重新选到
    -- 未访问方向（真实新前沿）就清零预算，所以只有"连续无效"受限，串行进度不受限。
    if best.novelty <= 0 then
        local expansions = (tonumber(rt.expansions) or 0) + 1
        if expansions > Exploration.MAX_EXPANSIONS then
            remember_empty(rt, t, px, pz, "no_frontier|local_area_exhausted")
            return nil, "no_frontier|local_area_exhausted"
        end
        rt.expansions = expansions
    else
        rt.expansions = 0
    end

    rt.picks = picks
    local cell = ensure_cell(record, best.gx, best.gz)
    cell.picks = (tonumber(cell.picks) or 0) + 1
    record.seq = (tonumber(record.seq) or 0) + 1
    cell.seq = record.seq

    local goal = {
        x = best.x,
        z = best.z,
        range = Exploration.GOAL_RANGE,
        priority = Exploration.GOAL_PRIORITY,
        kind = best.kind,
        world = world_key,
        id = string.format("explore|%s|%s|%d|%d|p%d", best.kind, world_key, best.gx, best.gz, cell.picks),
    }
    rt.current = {
        x = goal.x,
        z = goal.z,
        range = goal.range,
        priority = goal.priority,
        id = goal.id,
        kind = goal.kind,
        gx = best.gx,
        gz = best.gz,
        t = t,
    }
    rt.empty = nil
    return goal, string.format("frontier:new|%s|dist=%.1f|novelty=%.2f", best.kind, best.dist, best.novelty)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 只带 state 的入口（Report）用运行期 world_key 定位记录，但必须先核对
-- rt.world 还是当前世界实体：迁移/重载后 rt 里可能躺着旧世界，不能把旧世界坐标
-- 写进/读自新世界的记录。
--------------------------------------------------------------------------
local function get_record_by_runtime(state)
    local rt = state.explore
    if type(rt) ~= "table" or type(rt.world_key) ~= "string" then
        return nil, nil, "no_world_context"
    end
    if rt.world ~= TheWorld then
        return nil, nil, "stale_runtime_world"
    end
    local store = state.explore_memory
    if type(store) ~= "table" or type(store.worlds) ~= "table" then
        return nil, nil, "no_world_record"
    end
    local record = store.worlds[rt.world_key]
    if type(record) ~= "table" then
        return nil, nil, "no_world_record"
    end
    if type(record.cells) ~= "table" then
        record.cells = {}
    end
    return record, rt.world_key, nil
end

--------------------------------------------------------------------------
-- [喵喵喵]: 带 snapshot 的入口（SetBase/BaseGoal）必须用快照的 session/shard 解析记录：
-- 沿用 get_world_record 已有的上下文重置，旧世界的运行期状态会被丢掉，
-- 因此不会出现"用旧 world_key 写/读新世界 base"的情况，也不会去清另一个世界的持久记录。
--------------------------------------------------------------------------
local function resolve_record_for(state, snapshot)
    local rt = state.explore
    if type(rt) ~= "table" then
        rt = {}
        state.explore = rt
    end
    rt.v = Exploration.SCHEMA_VERSION

    if type(snapshot) == "table" and type(snapshot.shard) == "string" then
        local record, world_key, why = get_world_record(state, snapshot, rt)
        if record ~= nil then
            return record, world_key, nil
        end
        return nil, nil, why or "no_world_record"
    end
    -- 没有可用快照身份时才回退运行期上下文（仍受 rt.world 核对保护）。
    return get_record_by_runtime(state)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 结果回报：arrived 记到访并清零阻塞；blocked 累加阻塞次数和时间。
-- 被阻塞太多次的前沿在该世界内不再被 Next 选中，因此不会无限重试同一处。
--------------------------------------------------------------------------
function Exploration.Report(state, goal, status, reason)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    if type(goal) ~= "table" then
        return false, "goal_not_table"
    end
    if not is_finite_number(goal.x) or not is_finite_number(goal.z) then
        return false, "goal_needs_finite_x_z"
    end
    local normalized = status
    if status == "succeeded" then
        normalized = "arrived"
    elseif status == "failed" then
        normalized = "blocked"
    end
    if normalized ~= "arrived" and normalized ~= "blocked" then
        return false, "bad_status:" .. tostring(status)
    end

    local record, world_key, why = get_record_by_runtime(state)
    if record == nil then
        return false, why or "no_world_record"
    end
    -- [喵喵喵]: 拒绝跨世界的陈旧 goal，避免把旧地图坐标记进新世界的记录。
    if type(goal.world) == "string" and goal.world ~= world_key then
        return false, "stale_goal_world"
    end

    local rt = state.explore
    local current = rt.current
    -- [喵喵喵]: 有当前选择时只接受"同一个 goal 身份"的回报：迟到的旧目标报告既不能
    -- 清掉新选择，也不能把 blocked/visits 记到新目标所在的格子上。
    -- rt.current 已经自动入账被清空时，回报仍接受（只是不再动 current）。
    if type(current) == "table" and goal.id ~= current.id then
        return false, "stale_goal_id"
    end

    local t = now()
    local gx, gz = cell_of(goal.x, goal.z)
    local cell = ensure_cell(record, gx, gz)
    cell.gx, cell.gz = gx, gz
    cell.last_reason = short_reason(reason)

    if normalized == "arrived" then
        cell.visits = (tonumber(cell.visits) or 0) + 1
        cell.blocked_n = 0
        cell.silent_n = 0
        clear_block_deadline(rt, gx, gz)
        -- [喵喵喵]: 到达是真实进展，清零连续失败预算。
        rt.picks = 0
        rt.expansions = 0
    else
        cell.blocked_n = (tonumber(cell.blocked_n) or 0) + 1
        -- [喵喵喵]: 冷却只写运行期（同一 GetTime 坐标系），持久记录只留次数与原因。
        set_block_deadline(rt, gx, gz, t)
    end
    record.seq = (tonumber(record.seq) or 0) + 1
    cell.seq = record.seq

    if type(current) == "table" and current.id == goal.id then
        rt.current = nil
    end

    return true, string.format("%s|cell=%d|%d|blocked_n=%d|visits=%d",
        normalized, gx, gz, tonumber(cell.blocked_n) or 0, tonumber(cell.visits) or 0)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 基地锚点：纯坐标，写入持久记录（换世界不串用）。
--------------------------------------------------------------------------
function Exploration.SetBase(state, snapshot, x, z)
    if type(state) ~= "table" then
        return false, "state_not_table"
    end
    -- [喵喵喵]: 带快照时用快照身份解析记录（并复位旧世界运行期），避免写进旧世界。
    local record, _, why = resolve_record_for(state, snapshot)
    if record == nil then
        return false, why or "no_world_record"
    end

    local bx, bz = x, z
    if not is_finite_number(bx) or not is_finite_number(bz) then
        if type(snapshot) == "table" and is_finite_number(snapshot.x) and is_finite_number(snapshot.z) then
            bx, bz = snapshot.x, snapshot.z
        else
            return false, "base_needs_coordinates"
        end
    end

    local cycle = 0
    local t = now()
    if type(snapshot) == "table" then
        cycle = tonumber(snapshot.cycles) or 0
    end
    record.base = { x = bx, z = bz, cycle = cycle, attempts = 0, t = t }
    return true, string.format("base_set|%.1f|%.1f", bx, bz)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 回基地目标：只是把已知坐标包成 Navigation 能吃的 goal，
-- 不传送、不直接下指令。fresh==true 时给新的显式 id，供重试用。
--------------------------------------------------------------------------
function Exploration.BaseGoal(state, snapshot, fresh)
    if type(state) ~= "table" then
        return nil, "state_not_table"
    end
    -- [喵喵喵]: 带快照时用快照身份解析记录，迁移/重载后不会返回旧世界的 base 坐标。
    local record, world_key, why = resolve_record_for(state, snapshot)
    if record == nil then
        return nil, why or "no_world_record"
    end

    local base = record.base
    if type(base) ~= "table" or not is_finite_number(base.x) or not is_finite_number(base.z) then
        return nil, "no_base"
    end

    local dist = nil
    if type(snapshot) == "table"
        and snapshot.ready == true
        and is_finite_number(snapshot.x)
        and is_finite_number(snapshot.z) then
        dist = distance(snapshot.x, snapshot.z, base.x, base.z)
        if dist <= Exploration.BASE_MIN_DIST then
            return nil, string.format("at_base:%.1f", dist)
        end
    end

    if fresh == true then
        base.attempts = (tonumber(base.attempts) or 0) + 1
    end
    local gx, gz = cell_of(base.x, base.z)
    local goal = {
        x = base.x,
        z = base.z,
        range = Exploration.GOAL_RANGE,
        priority = Exploration.GOAL_PRIORITY,
        kind = "base",
        world = world_key,
        id = string.format("base|%s|%d|%d|a%d", world_key, gx, gz, tonumber(base.attempts) or 0),
    }
    if dist ~= nil then
        return goal, string.format("saved_base|dist=%.1f", dist)
    end
    return goal, "saved_base"
end

return Exploration
