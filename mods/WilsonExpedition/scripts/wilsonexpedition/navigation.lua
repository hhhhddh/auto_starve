--============================================================================
-- [喵喵喵]: WilsonExpedition / 陆地导航层（把"去某个点"拆成航点 + 原生异步寻路）
--
-- 职责边界：
--   * 本文件只做"路线/航点"决策，真正让玩家移动的永远只有
--     require('wilsonexpedition/actions') 的 Actions.Step(kind="move")；
--     绝不调用 pc:DoAction、绝不发原始 RPC、绝不瞬移。
--   * 只用本地玩家 + 客户端可见信息（快照坐标、威胁坐标、TheWorld.Map 可走性、
--     TheWorld.Pathfinder 公开查询）。不读存档、不猜未知地块、不建隐藏地图。
--   * 原生路径服务主客两端都有（prefabs/world.lua:447 在 ismastersim 分支之前
--     就 AddMap()/AddPathfinder()），客户端可用同一套 SubmitSearch/IsClear。
--
-- 接口：
--   Navigation.Step(player, snapshot, state, goal) -> "pending"|"succeeded"|"failed", reason
--       goal = { x, z, range?, priority?, id? }，range 默认 Actions.DEFAULT_RANGE(1.5)
--   Navigation.Cancel(player, state) -> ok(boolean), reason
--   Navigation.Retreat(player, snapshot, state, distance) -> goal|nil, reason
--
-- state 是调用方自有的运行期表（绝不序列化），本模块只用 state.nav 命名空间：
--   route(路线键) / world(每次 Step 记下的实际 TheWorld 身份，不只提交搜索时) / shard
--   handle(自有搜索句柄，至多一个) / handle_world(提交它的那个世界) / search_started
--   waypoints / wp_index / wp / gen(航点批代号，进显式 id) / truncated
--   detour(当前航点表是不是"侧移/后退"临时目标) / action_active(那条 move 是否我们下发的)
--   replans / skips / stall_t / stall_x / stall_z / wp_started / not_ready_since
--   blocked_since(等别人交出 Actions 的时间) / closed({route,status,reason} 终结闩存)
--   last_abandon(最近一次交还路线的原因，仅诊断用)
--   retreat(最近算出的安全撤退点) / retreat_t
--
-- 原生常量（components/locomotor.lua:8-10）：搜索状态 0=CALCULATING 1=FOUNDPATH
-- 2=NOPATH；接口 SubmitSearch/GetSearchStatus/GetSearchResult/KillSearch/IsClear，
-- pathcaps=nil 即"只走陆地"，与玩家自身 locomotor 缺省一致。
--
-- 两个硬前提（调用方必须遵守）：
--   1) 单活跃控制器：同一时刻只能有一个处理器（本模块/战斗/采集…）驱动 Actions，
--      因为原生每个玩家只有一条 WALKTO 缓冲。Actions.Cancel 只清它拥有的那一条，
--      所以本模块只在 nav.action_active 为真(那条是我们下发的)时才撤，绝不盲撤；
--      交接由上层串行化。
--   2) 同一路线/同一航点重跑必须给新的显式 id：终结结果会被闩存，重试同理。
--============================================================================

local Actions = require('wilsonexpedition/actions')

local Navigation = {}

Navigation.SCHEMA_VERSION = 1

-- [喵喵喵]: 原生 Pathfinder 搜索状态，与 locomotor.lua 里的本地常量一致。
Navigation.STATUS_CALCULATING = 0
Navigation.STATUS_FOUNDPATH = 1
Navigation.STATUS_NOPATH = 2

-- [喵喵喵]: 全部是有限上限，触顶即明确失败，绝不留无限 pending。
Navigation.STEP_RANGE = 1.2          -- 中间航点容差（交给 Actions 的 range，需 0<r<=40）
Navigation.GOAL_RANGE = Actions.DEFAULT_RANGE
Navigation.MAX_WAYPOINTS = 12        -- 单次搜索结果最多跟多少航点
Navigation.SEARCH_TIMEOUT = 2.5      -- 自有搜索句柄最长存活秒数
Navigation.WAYPOINT_TIMEOUT = 12     -- 单个航点最长耗时秒数
Navigation.WAYPOINT_ATTEMPTS = 3     -- 单个航点最多下发几次（每次新显式 id）
Navigation.MAX_REPLANS = 6           -- 整条路线重规划次数上限
Navigation.MAX_SKIPS = 4             -- 因威胁/地形被跳过的航点数上限
Navigation.STALL_TIME = 1.2          -- 停滞观察窗口
Navigation.STALL_DIST = 0.6          -- 窗口内位移小于它算停滞
Navigation.THREAT_RADIUS = 7         -- 航点靠威胁多近算不安全
-- [喵喵喵]: 发条战车在 12 米内索敌；余量覆盖观测和转向延迟。 (2026-11-12)
local ROOK_AVOID_RADIUS = (type(TUNING.ROOK_TARGET_DIST) == "number" and TUNING.ROOK_TARGET_DIST or 12) + 2
-- [喵喵喵]: 护巢索敌比主动索敌更远，春季还会扩大；统一避让范围需覆盖原版上限。 (2026-11-12)
local TALLBIRD_AVOID_RADIUS = math.max(TUNING.TALLBIRD_TARGET_DIST or 8, TUNING.TALLBIRD_DEFEND_DIST or 12)
    * math.max(1, TUNING.SPRING_COMBAT_MOD or 1.33) + 2
Navigation.THREAT_RADII = {
    rook = ROOK_AVOID_RADIUS,
    rook_nightmare = ROOK_AVOID_RADIUS,
    tallbird = TALLBIRD_AVOID_RADIUS,
}
Navigation.THREAT_PAD = 2.5          -- 航点须比"我们现在"更远离威胁的余量
Navigation.NOT_READY_TIMEOUT = 6     -- 快照一直不 ready 就失败
Navigation.RETREAT_DISTANCE = 8
Navigation.SIDE_STEP = 6             -- 卡住时先侧移/后退一小步再重规划
Navigation.WAYPOINT_SPACING = 0.5    -- 搜索结果里过密的点合并

local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

-- [喵喵喵]: 时限统一用原生 GetTime，缺了退回 os.clock，不会永久 pending。
local function now()
    return type(GetTime) == "function" and GetTime() or os.clock()
end

local function get_pathfinder()
    local world = TheWorld
    if world == nil or world.Pathfinder == nil then
        return nil
    end
    return world.Pathfinder
end

local function get_map()
    local world = TheWorld
    if world == nil or world.Map == nil then
        return nil
    end
    return world.Map
end
--------------------------------------------------------------------------
-- [喵喵喵]: 陆地地形判定：true / false+原因 / 未知(nil+原因)。未知一律当不支持处理，
-- 不按"应该能走"猜，也就不会凭空造出隐藏地图。
--------------------------------------------------------------------------
local function terrain_ok(x, z)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, "terrain_bad_coordinates"
    end
    local map = get_map()
    if map == nil or map.IsPassableAtPoint == nil then
        return nil, "terrain_unsupported"
    end
    -- [喵喵喵]: allow_water=false, exclude_boats=true → 海洋与船面都不算可走陆地。
    local ok, passable = pcall(function()
        return map:IsPassableAtPoint(x, 0, z, false, true)
    end)
    if not ok then
        return nil, "terrain_unreadable"
    end
    if passable ~= true then
        return false, "terrain_not_land"
    end
    -- [喵喵喵]: 洞(洞穴/地面缺口)同样不可走。原生 vector3.lua:3 里 Vector3 是 Class 造出的
    -- "可调用表"，type() 是 "table" 不是 "function"，所以不能用 type 判可用性，直接在
    -- terrain 查询的 pcall 里调用原生构造器；拿不到原生构造器/调用失败/返回值不是布尔
    -- 都属于"洞口状态未知"，按未知处理(绝不能因为查不了洞就把点当可走)。
    -- 必须是真 Vector3 实例：components/map.lua:218 走 hole:GetDistanceSqToPoint(pt)
    -- → entityscript.lua:1416 会调 pt:Get()，形表会抛错，所以不能拿 {x=,y=,z=} 凑。
    if map.IsPointNearHole == nil or Vector3 == nil then
        return nil, "terrain_hole_query_unsupported"
    end
    local ok2, near_hole = pcall(function()
        return map:IsPointNearHole(Vector3(x, 0, z))
    end)
    if not ok2 then
        return nil, "terrain_hole_query_failed"
    end
    if type(near_hole) ~= "boolean" then
        return nil, "terrain_hole_query_failed"
    end
    if near_hole then
        return false, "terrain_near_hole"
    end
    return true
end

--------------------------------------------------------------------------
-- [喵喵喵]: 威胁相关纯几何（只用快照里的可见威胁坐标，不查世界）。
--------------------------------------------------------------------------
local function nearest_threat(x, z, threats)
    if type(threats) ~= "table" then
        return nil
    end
    local best = nil
    for i = 1, #threats do
        local t = threats[i]
        local tx = type(t) == "table" and t.x or nil
        local tz = type(t) == "table" and t.z or nil
        if is_finite_number(tx) and is_finite_number(tz) then
            local dx, dz = x - tx, z - tz
            local d = math.sqrt(dx * dx + dz * dz)
            if best == nil or d < best.distance then
                best = { x = tx, z = tz, distance = d }
            end
        end
    end
    return best
end

-- [喵喵喵]: 两端安全也可能穿过索敌区；圈内撤退须全程远离每个可见威胁。 (2026-11-12)
local function waypoint_is_safe(x, z, px, pz, threats)
    local dx, dz = x - px, z - pz
    local length2 = dx * dx + dz * dz
    for _, threat in ipairs(threats or {}) do
        if is_finite_number(threat.x) and is_finite_number(threat.z) then
            local tx, tz = threat.x - px, threat.z - pz
            local current2 = tx * tx + tz * tz
            local radius = Navigation.THREAT_RADII[threat.prefab] or Navigation.THREAT_RADIUS
            local projection = tx * dx + tz * dz
            if current2 <= radius * radius then
                if projection > 0 then return false, "threat_blocked" end
            else
                local fraction = length2 > 0 and math.max(0, math.min(1, projection / length2)) or 0
                local near_x, near_z = tx - fraction * dx, tz - fraction * dz
                if near_x * near_x + near_z * near_z < radius * radius then
                    return false, "threat_blocked"
                end
            end
        end
    end
    return true, "threats_clear"
end

-- [喵喵喵]: 候选点必须不落在任何可见威胁的当前半径之内(否则就是"往怪里走")。
local function not_nearer_than_player(x, z, px, pz, threats)
    if type(threats) ~= "table" then
        return true
    end
    for i = 1, #threats do
        local t = threats[i]
        local tx = type(t) == "table" and t.x or nil
        local tz = type(t) == "table" and t.z or nil
        if is_finite_number(tx) and is_finite_number(tz) then
            local mdx, mdz = px - tx, pz - tz
            local cdx, cdz = x - tx, z - tz
            if cdx * cdx + cdz * cdz < mdx * mdx + mdz * mdz - 0.01 then
                return false
            end
        end
    end
    return true
end

-- [喵喵喵]: 远离可见威胁的安全点：取威胁合力反方向，再依次偏 ±30/60/90 度，
-- 只接受客户端地图明确可走(且不在洞里)的点；都不行就明确 nil+原因。
local function safe_away_point(px, pz, threats, distance)
    if type(threats) ~= "table" or #threats == 0 then
        return nil, "no_visible_threats"
    end
    local ax, az, n = 0, 0, 0
    for i = 1, #threats do
        local t = threats[i]
        local tx = type(t) == "table" and t.x or nil
        local tz = type(t) == "table" and t.z or nil
        if is_finite_number(tx) and is_finite_number(tz) then
            local dx, dz = px - tx, pz - tz
            local d = math.sqrt(dx * dx + dz * dz)
            if d > 0.001 then
                ax, az, n = ax + dx / d, az + dz / d, n + 1
            end
        end
    end
    if n == 0 then
        return nil, "no_threat_positions"
    end
    ax, az = ax / n, az / n
    local alen = math.sqrt(ax * ax + az * az)
    if alen < 0.001 then
        -- [喵喵喵]: 被围着(合力抵消)时退向最近威胁的反方向。
        local near = nearest_threat(px, pz, threats)
        if near == nil or near.distance < 0.001 then
            return nil, "no_retreat_direction"
        end
        ax, az = (px - near.x) / near.distance, (pz - near.z) / near.distance
        alen = 1
    end
    local base = math.atan2(az, ax)
    local offsets = { 0, 0.52, -0.52, 1.05, -1.05, 1.57, -1.57 }
    local last_reason = nil
    for i = 1, #offsets do
        local angle = base + offsets[i]
        local cx = px + math.cos(angle) * distance
        local cz = pz + math.sin(angle) * distance
        if not_nearer_than_player(cx, cz, px, pz, threats)
            and waypoint_is_safe(cx, cz, px, pz, threats) then
            local ok, why = terrain_ok(cx, cz)
            if ok == true then
                return cx, cz
            end
            last_reason = why
        else
            last_reason = "toward_threat"
        end
    end
    return nil, last_reason or "no_safe_point"
end

--------------------------------------------------------------------------
-- [喵喵喵]: 自有搜索句柄的生死只在这里：只杀自己那一个；换世界时用旧世界杀。
--------------------------------------------------------------------------
local function kill_search(nav)
    local handle = nav.handle
    local world = nav.handle_world
    nav.handle = nil
    nav.handle_world = nil
    nav.search_started = nil
    if handle == nil or world == nil then
        return false
    end
    local pf = world.Pathfinder
    if pf == nil or pf.KillSearch == nil then
        return false
    end
    pcall(function()
        pf:KillSearch(handle)
    end)
    return true
end

local function submit_search(nav, px, pz, gx, gz)
    local pf = get_pathfinder()
    if pf == nil or pf.SubmitSearch == nil then
        return false, "pathfinder_unsupported"
    end
    -- [喵喵喵]: pathcaps=nil → 与玩家自身 locomotor 缺省一致，只走陆地。
    local ok, handle = pcall(function()
        return pf:SubmitSearch(px, 0, pz, gx, 0, gz, nil)
    end)
    if not ok then
        return false, "search_submit_error"
    end
    if handle == nil then
        return false, "search_submit_refused"
    end
    nav.handle = handle
    nav.handle_world = TheWorld
    nav.search_started = now()
    return true
end

-- [喵喵喵]: 与原生 locomotor.lua:1837 同一调用形状(含 caps=nil)；读不出来返回 nil。
local function los_clear(px, pz, gx, gz)
    local pf = get_pathfinder()
    if pf == nil or pf.IsClear == nil then
        return nil
    end
    local ok, clear = pcall(function()
        return pf:IsClear(px, 0, pz, gx, 0, gz, nil)
    end)
    if not ok then
        return nil
    end
    return clear == true
end

--------------------------------------------------------------------------
-- [喵喵喵]: 航点表：把原生搜索结果收敛成"有限个、不过密、末尾有目标点"的序列。
-- 超上限就截断；截断时最后一格不当目标，剩下的靠重规划从新位置再来。
--------------------------------------------------------------------------
local function build_waypoints(nav, result, goal, px, pz)
    local steps = type(result) == "table" and result.steps or nil
    if type(steps) ~= "table" then
        return nil, "search_result_without_steps"
    end
    local wps = {}
    local last_x, last_z = px, pz
    local truncated = false
    for i = 1, #steps do
        local s = steps[i]
        local sx = type(s) == "table" and s.x or nil
        local sz = type(s) == "table" and s.z or nil
        if is_finite_number(sx) and is_finite_number(sz) then
            local too_close = last_x ~= nil and last_z ~= nil
                and (sx - last_x) * (sx - last_x) + (sz - last_z) * (sz - last_z)
                    < Navigation.WAYPOINT_SPACING * Navigation.WAYPOINT_SPACING
            if not too_close then
                if #wps >= Navigation.MAX_WAYPOINTS then
                    truncated = true
                    break
                end
                wps[#wps + 1] = { x = sx, z = sz, attempts = 0 }
                last_x, last_z = sx, sz
            end
        end
    end
    if not truncated then
        -- [喵喵喵]: 走完整条路径后补目标点本身，到达判定用 goal.range。
        wps[#wps + 1] = { x = goal.x, z = goal.z, final = true, attempts = 0 }
    end
    if #wps == 0 then
        return nil, "search_result_empty"
    end
    for i = 1, #wps do
        wps[i].index = i
    end
    nav.truncated = truncated
    return wps
end

-- [喵喵喵]: 航点 id 含路线键/航点代号/序号/尝试次数。代号 gen 在每装一批新航点时推进：
-- 重规划后又会从 wp1/a0 开始，没有代号就会撞上上一批遗留的终结闩存而被当成已完成。
local function waypoint_id(nav, wp)
    return string.format("%s|g%d|wp%d|a%d",
        tostring(nav.route), nav.gen or 0, wp.index or 0, wp.attempts or 0)
end

-- [喵喵喵]: 安装一批航点：推进 gen、定下每个航点的显式 id、清掉上一批的计时/截断/侧移标记。
-- is_detour=true 表示这批只是"挪开一步"的临时目标(预算已在上一轮计过，不再重计)。
local function install_waypoints(nav, wps, truncated, is_detour)
    nav.gen = (nav.gen or 0) + 1
    nav.waypoints = wps
    nav.wp_index = 1
    nav.wp = nil
    nav.truncated = truncated == true
    nav.detour = is_detour == true
    nav.wp_started = nil
    nav.stall_t = nil
    nav.stall_x = nil
    nav.stall_z = nil
    for i = 1, #wps do
        wps[i].index = i
        wps[i].id = waypoint_id(nav, wps[i])
    end
    return wps
end

-- [喵喵喵]: 卡住时的侧移/后退：只在"客户端地图明确可走 + 不靠近威胁"的点上
-- 走一小步，目的只是把自己从卡住的位置挪开，然后重新搜索。找不到就不编，返回 false。
local function try_side_step(nav, px, pz, goal, threats)
    local gdx, gdz = goal.x - px, goal.z - pz
    local glen = math.sqrt(gdx * gdx + gdz * gdz)
    if glen < 0.001 then
        return false
    end
    local dirx, dirz = gdx / glen, gdz / glen
    local angles = { math.pi / 2, -math.pi / 2, math.pi }
    for i = 1, #angles do
        local a = angles[i]
        local rx = dirx * math.cos(a) - dirz * math.sin(a)
        local rz = dirx * math.sin(a) + dirz * math.cos(a)
        local cx = px + rx * Navigation.SIDE_STEP
        local cz = pz + rz * Navigation.SIDE_STEP
        if not_nearer_than_player(cx, cz, px, pz, threats)
            and waypoint_is_safe(cx, cz, px, pz, threats)
            and terrain_ok(cx, cz) == true then
            -- [喵喵喵]: 侧移目标单独占一代 gen(自己的显式 id)，并标记 detour：它的完成
            -- 不再消耗新的重规划预算，而是继续上一轮已经计过数的那次重规划。
            install_waypoints(nav, { { x = cx, z = cz, attempts = 0 } }, false, true)
            return true
        end
    end
    return false
end
--------------------------------------------------------------------------
-- [喵喵喵]: 路线生命周期
--------------------------------------------------------------------------

-- [喵喵喵]: 只撤"我们自己的"那条 Actions move；没在跑就绝不撤(避免打断别人)。
local function release_own(player, nav)
    if nav == nil or nav.action_active ~= true then
        return nil, "not_owned_by_navigation"
    end
    nav.action_active = false
    if not is_valid(player) then
        return nil, "player_invalid"
    end
    return Actions.Cancel(player)
end

-- [喵喵喵]: 交还一条旧路线，顺序不能反：
--   1) 先撤本控制器自己那条 move(靠 action_active 证明所有权，绝不盲撤别人)；
--   2) 再用"提交时那个世界"的 Pathfinder 杀掉自有句柄(换世界后旧句柄只能旧世界杀)；
--   3) 最后才作废航点/终结闩存/路线键。
-- 反过来(先抹 action_active 再收拾)会让自有 move 在 Actions 里变成无人认领的悬挂操作，
-- 后续不同 id 的下发还会被误判成"别人的动作"。
local function abandon_route(player, nav, why)
    local released = release_own(player, nav)
    local killed = kill_search(nav)
    nav.waypoints = nil
    nav.wp_index = nil
    nav.wp = nil
    nav.truncated = false
    nav.detour = nil
    nav.wp_started = nil
    nav.stall_t = nil
    nav.stall_x = nil
    nav.stall_z = nil
    nav.closed = nil
    nav.route = nil
    -- [喵喵喵]: 只记一条运行期诊断原因(world_changed/shard_changed/goal_changed)，便于上层定位。
    nav.last_abandon = why
    return released, killed
end

-- [喵喵喵]: 只重置本路线的预算/计时，不碰归属状态(交给 abandon_route 按顺序处理)。
local function start_route(nav, route_key, shard)
    nav.route = route_key
    nav.shard = shard
    nav.gen = 0
    nav.replans = 0
    nav.skips = 0
    nav.not_ready_since = nil
    nav.blocked_since = nil
    nav.retreat = nil
    nav.retreat_t = nil
    nav.started = now()
end

local function finish(player, nav, status, reason)
    -- [喵喵喵]: 到达/终结时若自有 move 还在跑，release_own 会先把它撤掉再丢 action_active，
    -- 这样不会把一条悬挂的行走丢在 Actions 里(也不会去碰别人的动作)。
    release_own(player, nav)
    kill_search(nav)
    nav.waypoints = nil
    nav.wp_index = nil
    nav.wp = nil
    nav.truncated = false
    nav.detour = nil
    nav.stall_t = nil
    nav.wp_started = nil
    nav.not_ready_since = nil
    nav.blocked_since = nil
    nav.closed = { route = nav.route, status = status, reason = reason }
    return status, reason
end

-- [喵喵喵]: 重规划计数：有上限，触顶就是终态失败(不会无尽搜下去)。
-- 先交还自有 move 再清航点表，否则旧 move 继续走而我们已丢失它的归属。
local function replanned(player, nav, reason)
    release_own(player, nav)
    kill_search(nav)
    nav.waypoints = nil
    nav.wp_index = nil
    nav.wp = nil
    nav.truncated = false
    nav.detour = nil
    nav.wp_started = nil
    nav.replans = (nav.replans or 0) + 1
    if nav.replans > Navigation.MAX_REPLANS then
        return "failed", reason .. "|replans_exhausted"
    end
    return "pending", reason .. "|replan:" .. tostring(nav.replans)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 规划一步：直线视线优先(省一次原生搜索)，否则提交一次异步搜索并轮询；
-- 绝不每帧重提，句柄有存活上限，取到结果就立刻 KillSearch。
--------------------------------------------------------------------------
local function plan_step(player, nav, px, pz, goal)
    if nav.waypoints ~= nil then
        return "ready"
    end

    if nav.handle ~= nil then
        local pf = nav.handle_world ~= nil and nav.handle_world.Pathfinder or nil
        if pf == nil or pf.GetSearchStatus == nil then
            kill_search(nav)
            return "failed", "pathfinder_lost"
        end
        local ok, status = pcall(function()
            return pf:GetSearchStatus(nav.handle)
        end)
        if not ok then
            kill_search(nav)
            return "failed", "search_status_unreadable"
        end
        if status == Navigation.STATUS_CALCULATING then
            if now() - (nav.search_started or 0) > Navigation.SEARCH_TIMEOUT then
                return replanned(player, nav, "search_timeout")
            end
            return "pending", "search_running"
        end
        local result = nil
        if status == Navigation.STATUS_FOUNDPATH then
            local ok2, res = pcall(function()
                return pf:GetSearchResult(nav.handle)
            end)
            if ok2 then
                result = res
            end
        end
        -- [喵喵喵]: 结果取完即杀句柄，和原生 locomotor 用法一致，不占引擎搜索槽。
        kill_search(nav)
        if result == nil then
            return replanned(player, nav, status == Navigation.STATUS_NOPATH and "no_path" or "search_failed")
        end
        local wps, why = build_waypoints(nav, result, goal, px, pz)
        if wps == nil then
            return replanned(player, nav, why or "search_result_unusable")
        end
        install_waypoints(nav, wps, nav.truncated, false)
        return "ready"
    end

    local clear = los_clear(px, pz, goal.x, goal.z)
    if clear == true then
        -- [喵喵喵]: 直线可达：一个航点就是目标，省掉一次异步搜索。
        install_waypoints(nav,
            { { x = goal.x, z = goal.z, final = true, attempts = 0 } }, false, false)
        return "ready"
    end

    -- [喵喵喵]: clear==nil(路径服务不可用/未知)同样走搜索，不假装能直线走。
    local ok, why = submit_search(nav, px, pz, goal.x, goal.z)
    if not ok then
        return "failed", why or "search_submit_failed"
    end
    return "pending", "search_submitted"
end

--------------------------------------------------------------------------
-- [喵喵喵]: 原版到航点会停步；下一段已直线可走时提前交接，保留最终目标的到达判定。
-- 只合并客户端确认可走且不穿过可见威胁的路段，不为连贯移动切过障碍。 (2026-11-12)
local function can_pass_waypoint(wp, next_wp, px, pz, threats)
    if wp.final == true or next_wp == nil
        or terrain_ok(next_wp.x, next_wp.z) ~= true
        or los_clear(px, pz, next_wp.x, next_wp.z) ~= true then
        return false
    end
    return waypoint_is_safe(next_wp.x, next_wp.z, px, pz, threats)
end

--------------------------------------------------------------------------
-- 主循环
--------------------------------------------------------------------------
function Navigation.Step(player, snapshot, state, goal)
    if type(state) ~= "table" then
        return "failed", "state_not_table"
    end
    if type(goal) ~= "table" then
        return "failed", "goal_not_table"
    end
    if not is_valid(player) then
        return "failed", "player_invalid"
    end
    if ThePlayer ~= nil and player ~= ThePlayer then
        return "failed", "not_local_player"
    end
    if not is_finite_number(goal.x) or not is_finite_number(goal.z) then
        return "failed", "goal_needs_finite_x_z"
    end
    if math.abs(goal.x) > Actions.WORLD_LIMIT or math.abs(goal.z) > Actions.WORLD_LIMIT then
        return "failed", "goal_out_of_world"
    end
    local range = goal.range == nil and Navigation.GOAL_RANGE or goal.range
    if not is_finite_number(range) or range <= 0 or range > 40 then
        return "failed", "goal_bad_range"
    end
    local priority = goal.priority == nil and Actions.DEFAULT_PRIORITY or goal.priority
    if not is_finite_number(priority) then
        return "failed", "goal_bad_priority"
    end

    if type(state.nav) ~= "table" then
        state.nav = {}
    end
    local nav = state.nav
    nav.v = Navigation.SCHEMA_VERSION

    -- [喵喵喵]: 换世界/换分片：注意 nav.world 必须每次记下"实际世界身份"，不能只在有搜索
    -- 句柄时记(旧代码只有 handle 非空才清理，没句柄就根本触发不到)。处理顺序：先交还旧路线
    -- (撤自有 move → 用旧世界杀句柄 → 作废终结态)，再记新世界。
    local shard = type(snapshot) == "table" and snapshot.shard or nil
    if nav.world ~= nil and nav.world ~= TheWorld then
        abandon_route(player, nav, "world_changed")
    end
    if nav.shard ~= nil and shard ~= nil and nav.shard ~= shard then
        abandon_route(player, nav, "shard_changed")
    end
    nav.world = TheWorld

    -- [喵喵喵]: 路线身份含 goal.id：重跑同一目标必须换显式 id(和 Actions 同一规矩)。
    local route_key = string.format("%.2f|%.2f|%.3f|%s|%s",
        goal.x, goal.z, range, tostring(goal.id), tostring(shard))

    if nav.route ~= route_key then
        -- [喵喵喵]: 目标身份变了：先按"只撤自己"的规矩把旧路线交还干净(旧 move + 旧句柄 +
        -- 旧终结闩存)，再重置预算。旧代码先抹 action_active 再收拾，会丢下悬挂的自有 move。
        abandon_route(player, nav, "goal_changed")
        start_route(nav, route_key, shard)
    elseif nav.closed ~= nil and nav.closed.route == route_key then
        -- [喵喵喵]: 已终结的同一路线只回闩存结果，不重发、不重新搜索。
        return nav.closed.status, nav.closed.reason
    end

    -- [喵喵喵]: 快照未就绪/无坐标：短期 pending，超时明确失败(未知不当已知用)。
    local ready = type(snapshot) == "table" and snapshot.ready == true
    local px = type(snapshot) == "table" and snapshot.x or nil
    local pz = type(snapshot) == "table" and snapshot.z or nil
    if not ready or not is_finite_number(px) or not is_finite_number(pz) then
        if type(snapshot) ~= "table" then
            return finish(player, nav, "failed", "snapshot_not_table")
        end
        local reason = (not ready and ("snapshot_not_ready:" .. tostring(snapshot.ready_reason)))
            or "snapshot_no_position"
        nav.not_ready_since = nav.not_ready_since or now()
        if now() - nav.not_ready_since >= Navigation.NOT_READY_TIMEOUT then
            return finish(player, nav, "failed", reason .. "|stale")
        end
        return "pending", reason
    end
    nav.not_ready_since = nil

    -- [喵喵喵]: 到达判定只看观测位置(快照坐标)，不认 RPC 是否被接受。
    local gdx, gdz = goal.x - px, goal.z - pz
    if gdx * gdx + gdz * gdz <= range * range then
        return finish(player, nav, "succeeded",
            string.format("arrived:%.2f", math.sqrt(gdx * gdx + gdz * gdz)))
    end

    -- [喵喵喵]: 站在船/平台上 → 陆地路由不支持，明确拒绝而不是乱走。
    if snapshot.platform ~= nil then
        return finish(player, nav, "failed", "on_platform_land_route_unsupported")
    end

    local goal_ok, goal_why = terrain_ok(goal.x, goal.z)
    if goal_ok == nil then
        return finish(player, nav, "failed", "goal_terrain_unknown:" .. tostring(goal_why))
    elseif goal_ok == false then
        return finish(player, nav, "failed", "goal_terrain:" .. tostring(goal_why))
    end

    local threats = type(snapshot.threats) == "table" and snapshot.threats or nil
    -- [喵喵喵]: 顺手留一个可见的安全撤退点，上层求生可直接当 goal 用（限时限次重算）。
    if threats ~= nil and #threats > 0
        and (nav.retreat == nil or (now() - (nav.retreat_t or 0)) > 3) then
        local rx, rz = safe_away_point(px, pz, threats, Navigation.RETREAT_DISTANCE)
        nav.retreat_t = now()
        if rx ~= nil then
            nav.retreat = { x = rx, z = rz, id = string.format("retreat|%.1f|%.1f", rx, rz) }
        end
    end

    local plan_status, plan_why = plan_step(player, nav, px, pz, goal)
    if plan_status == "failed" then
        return finish(player, nav, "failed", plan_why or "plan_failed")
    elseif plan_status ~= "ready" then
        return "pending", plan_why or "planning"
    end

    -- [喵喵喵]: 中间航点在下一段已确认安全时提前交接；最终目标仍按原到达半径结束。
    local wp = nav.waypoints[nav.wp_index]
    while wp ~= nil do
        local reach = wp.final == true and range or Navigation.STEP_RANGE
        local dx, dz = wp.x - px, wp.z - pz
        if dx * dx + dz * dz <= reach * reach
            or can_pass_waypoint(wp, nav.waypoints[nav.wp_index + 1], px, pz, threats) then
            release_own(player, nav)
            nav.wp_index = nav.wp_index + 1
            nav.wp = nil
            nav.wp_started = nil
            nav.stall_t = nil
            wp = nav.waypoints[nav.wp_index]
        else
            break
        end
    end

    if wp == nil then
        if nav.detour == true then
            -- [喵喵喵]: 侧移/后退只是"先挪开一步"的临时目标：它走到就回切回"需要重新搜索"，
            -- 但它属于上一轮已经计过数的重规划，这里绝不再加一次预算(否则一次侧移 + 它本该
            -- 继续的那次搜索会吃掉两份 replan 额度)。
            nav.detour = nil
            nav.waypoints = nil
            nav.wp_index = nil
            nav.wp = nil
            nav.truncated = false
            nav.wp_started = nil
            kill_search(nav)
            return "pending", "detour_done|replan:" .. tostring(nav.replans or 0)
        end
        -- [喵喵喵]: 航点走完还没到(多半是 MAX_WAYPOINTS 截断)：重规划，有上限。
        local status, why = replanned(player, nav,
            nav.truncated and "waypoints_truncated" or "waypoints_exhausted")
        if status == "failed" then
            return finish(player, nav, "failed", why)
        end
        return "pending", why
    end

    -- [喵喵喵]: 航点安全：靠威胁或客户端地图明确不可走就跳过，跳过数有限。
    local safe, safe_why = waypoint_is_safe(wp.x, wp.z, px, pz, threats)
    if safe then
        local ok_terrain, terrain_why = terrain_ok(wp.x, wp.z)
        if ok_terrain == nil then
            return finish(player, nav, "failed", "waypoint_terrain_unknown:" .. tostring(terrain_why))
        elseif ok_terrain == false then
            safe, safe_why = false, terrain_why
        end
    end
    if not safe then
        nav.skips = (nav.skips or 0) + 1
        release_own(player, nav)
        nav.wp_index = nav.wp_index + 1
        nav.wp = nil
        if nav.skips > Navigation.MAX_SKIPS then
            return finish(player, nav, "failed", "route_blocked:" .. tostring(safe_why))
        end
        return "pending", "waypoint_skipped:" .. tostring(safe_why)
    end

    -- [喵喵喵]: 换航点：先撤掉我们上一条 move(只撤自己的)，再带新显式 id 下发。
    if nav.wp ~= wp then
        release_own(player, nav)
        nav.wp = wp
        wp.attempts = 0
        nav.wp_started = now()
        nav.stall_t = now()
        nav.stall_x, nav.stall_z = px, pz
    end

    local reach = wp.final == true and range or Navigation.STEP_RANGE
    local status, reason = Actions.Step(player, {
        kind = "move",
        x = wp.x,
        z = wp.z,
        range = reach,
        priority = priority,
        id = wp.id or waypoint_id(nav, wp),
    })

    if status == "pending" and type(reason) == "string" and reason:sub(1, 8) == "held_by_" then
        -- [喵喵喵]: Actions 里挂着的那条是别人的动作：绝不设 action_active
        -- (因此永远不会去撤它)，只等交接；等太久就明确失败把控制权交回去。
        nav.blocked_since = nav.blocked_since or now()
        if now() - nav.blocked_since >= Navigation.WAYPOINT_TIMEOUT then
            return finish(player, nav, "failed", "held_by_other_handler:" .. reason)
        end
        return "pending", "blocked:" .. reason
    end
    nav.blocked_since = nil

    if status == "pending" then
        nav.action_active = true
        local mx, mz = px - (nav.stall_x or px), pz - (nav.stall_z or pz)
        if mx * mx + mz * mz >= Navigation.STALL_DIST * Navigation.STALL_DIST then
            nav.stall_t = now()
            nav.stall_x, nav.stall_z = px, pz
        end
        local timed_out = nav.wp_started ~= nil
            and (now() - nav.wp_started) > Navigation.WAYPOINT_TIMEOUT
        local stalled = nav.stall_t == nil or (now() - nav.stall_t) > Navigation.STALL_TIME
        if not timed_out and not stalled then
            return "pending", "moving:" .. tostring(reason)
        end
        -- [喵喵喵]: 停滞/超时：先换新 id 重试同一航点，次数用完就重规划。
        if (wp.attempts or 0) < Navigation.WAYPOINT_ATTEMPTS then
            release_own(player, nav)
            wp.attempts = (wp.attempts or 0) + 1
            wp.id = waypoint_id(nav, wp)
            nav.wp_started = now()
            nav.stall_t = now()
            nav.stall_x, nav.stall_z = px, pz
            return "pending", "waypoint_retry:" .. tostring(wp.attempts)
                .. (timed_out and "|timeout" or "|stall")
        end
        -- [喵喵喵]: 重试额度用完：重规划(只在这里交还一次自有 move，内部按序处理)。
        local replan_status, replan_why = replanned(player, nav,
            timed_out and "waypoint_timeout" or "waypoint_stalled")
        if replan_status == "failed" then
            return finish(player, nav, "failed", replan_why)
        end
        -- [喵喵喵]: 重试额度用完：先在可见安全点上侧移/后退一步再重新搜索；该步不额外计预算。
        if try_side_step(nav, px, pz, goal, threats) then
            return "pending", replan_why .. "|side_step"
        end
        return "pending", replan_why
    end

    if status == "succeeded" then
        -- [喵喵喵]: Actions 的 succeeded 本身就是"观测位置进入 range"。这时那条 move 已经
        -- 由 Actions 自己终结/清好（终结结果闩存），所以只需丢掉归属标记，不需要再 Cancel。
        nav.action_active = false
        nav.wp_index = nav.wp_index + 1
        nav.wp = nil
        nav.wp_started = nil
        nav.stall_t = nil
        return "pending", "waypoint_reached"
    end

    -- [喵喵喵]: Actions 报失败：换新 id 重试，次数用完就丢弃该航点(并被 MAX_SKIPS 限住)。
    -- 同样地这条 move 已被 Actions 终结(闩存)，换新 id 时让它自己释放闩存记录，不额外 Cancel。
    nav.action_active = false
    if (wp.attempts or 0) < Navigation.WAYPOINT_ATTEMPTS then
        wp.attempts = (wp.attempts or 0) + 1
        wp.id = waypoint_id(nav, wp)
        nav.wp_started = now()
        nav.stall_t = now()
        nav.stall_x, nav.stall_z = px, pz
        return "pending", "waypoint_failed_retry:" .. tostring(reason)
            .. "|a" .. tostring(wp.attempts)
    end
    nav.skips = (nav.skips or 0) + 1
    nav.wp_index = nav.wp_index + 1
    nav.wp = nil
    if nav.skips > Navigation.MAX_SKIPS then
        return finish(player, nav, "failed", "route_failed:" .. tostring(reason))
    end
    return "pending", "waypoint_abandoned:" .. tostring(reason)
end

--------------------------------------------------------------------------
-- [喵喵喵]: 取消：只杀自己的搜索句柄；只有确知那条 move 是我们的才撤 Actions。
-- 没有我们自己的状态时什么都不动(可能是别的处理器在跑)，直接说不属于我们。
--------------------------------------------------------------------------
function Navigation.Cancel(player, state)
    local nav = type(state) == "table" and state.nav or nil
    if type(nav) ~= "table" then
        return false, "no_navigation_state"
    end
    local killed = kill_search(nav) == true
    local released = false
    if nav.action_active == true and is_valid(player) then
        local ok = Actions.Cancel(player)
        released = ok == true
    end
    nav.action_active = false
    nav.waypoints = nil
    nav.wp_index = nil
    nav.wp = nil
    nav.truncated = false
    nav.detour = nil
    nav.wp_started = nil
    nav.stall_t = nil
    nav.not_ready_since = nil
    nav.blocked_since = nil
    -- [喵喵喵]: 清路线键：下一次 Step 即使目标相同也会重新开始(和"新显式 id"一致)。
    nav.route = nil
    nav.closed = nil
    return true, "cancelled"
        .. (killed and "|search_killed" or "")
        .. (released and "|action_cancelled" or "|no_owned_action")
end

--------------------------------------------------------------------------
-- [喵喵喵]: 求生助手：只用快照里的可见威胁 + 地图可走性算一个安全目标点，
-- 不知道安全就不编一个假目标(返回 nil+原因)。返回值可直接丢给 Navigation.Step。
--------------------------------------------------------------------------
function Navigation.Retreat(player, snapshot, state, distance)
    if type(snapshot) ~= "table"
        or not is_finite_number(snapshot.x) or not is_finite_number(snapshot.z) then
        return nil, "snapshot_unavailable"
    end
    local dist = Navigation.RETREAT_DISTANCE
    if is_finite_number(distance) and distance > 0 then
        dist = math.min(distance, 40)
    end
    local threats = type(snapshot.threats) == "table" and snapshot.threats or nil
    if threats == nil or #threats == 0 then
        return nil, "no_visible_threats"
    end
    local x, z, why = safe_away_point(snapshot.x, snapshot.z, threats, dist)
    if x == nil then
        return nil, why or "no_safe_point"
    end
    -- [喵喵喵]: 同一点用同一个 id：反复求生不会把同一目标当成"新路线"狂重开。
    local goal = {
        x = x,
        z = z,
        range = Navigation.GOAL_RANGE,
        id = string.format("retreat|%.1f|%.1f", x, z),
    }
    if type(state) == "table" then
        state.nav = state.nav or {}
        state.nav.retreat = { x = x, z = z, id = goal.id }
    end
    return goal
end

return Navigation
