--============================================================================
-- [喵喵喵]: WilsonExpedition / 动作执行层（第一段：core + kind="move"；
--            第二段：kind="action" 场景交互与持续工作；第三段：kind="attack" 单次攻击；
--            第四段：kind="inventory" 背包内装备/卸下/吃/自用/物品对物品；
--            第五段：kind="transfer" 槽位/容器搬运；第六段：kind="craft" 原版制作；
--            第七段：kind="use" 已持有物品用于场景实体/场景点）
--
-- 只走"玩家点左键"的客户端可见路径，全部使用原生脚本全局(ThePlayer / ACTIONS /
-- BufferedAction / SendRPCToServer / RPC / CONTROL_PRIMARY / GetTime)，不瞬移、
-- 不伪造输入序列、不做队列重试：
--   * 有预测(pc.locomotor ~= nil) → PlayerController:DoAction → PreviewAction →
--     GoToPoint，与原生左键行走同链路；预测行走由控制器自己同步。
--   * 无预测(pc.locomotor == nil) → 复用 act.non_preview_cb 发一次"已松手"的
--     RPC.LeftClick(WALKTO.code, 平台相对 x/z, ...)，等价原生单击。
--
-- 对外接口：
--   Actions.Step(player, intent) -> status, reason
--       status: "pending"|"succeeded"|"failed"；player 必须是本地玩家。
--   Actions.Cancel(player) -> ok(boolean), reason
--       只撤销本文件拥有的那一个本地移动动作，不碰别人的动作。
--
-- intent(kind="move")：{ kind="move", x=<number>, z=<number>,
--                        range=<number|nil>, priority=<number|nil>, id=<任意|nil> }
-- intent(kind="action")：{ kind="action", action=<ACTIONS 字符串 id>,
--                        target=<实体|nil>, item=<实体|nil>, x=<number|nil>, z=<number|nil>,
--                        right=<boolean|nil>, rotation=<number|nil>, confirm=<function|nil>,
--                        priority=<number|nil>, id=<任意|nil> }
--   action 先用原生 playeractionpicker:DoGetMouseActions 选择目标动作，再走房主
--   DoAction 或客户端 preview_cb/non_preview_cb。CHOP/MINE/HAMMER 持有工作控件，
--   由原版状态机对同一目标续接，目标完成、取消或抢占时释放；其余交互发一次已松手点击。
--   工作完成依据 finishedwork 或目标可作业标签消失，目标丢失仍作为未确认失败。
--   其他交互依据主机成功回调、调用方 confirm 或同一目标的可见后置变化确认。
-- intent(kind="attack")：{ kind="attack", target=<实体>, priority=<number|nil>,
--                        id=<任意|nil>, confirm=<function|nil> }
--   出手前先用原生 PlayerController:GetAttackTarget(false, target, false, ...) 问一次
--   “现在点左键会打谁”；原生选的是别人、选不出来或目标已死就绝不下发。
--   主机：controller:DoAction(BufferedAction(player, target, ACTIONS.ATTACK))；
--   有预测客户端：preview_cb 里发一次 RemoteAttackButton(target, false, false, true)；
--   无预测客户端：non_preview_cb 里同一次调用。isreleased=true 即“显式松手”的一次点击，
--   每一轮操作只发一发，不连点。
--   完成判定只认四样：主机侧原生 AddSuccessAction 给出的权威成功、调用方
--   confirm(player, intent)==true、目标血量(health_replica:GetCurrent)基线之后真的往下掉、
--   或“我们下发的那一次攻击周期”被观测到开始后又被观测到结束(状态机退出 attack)。
--   可见状态只认：sg 有 attack/abouttoattack 标签且 statemem.attacktarget(或 retarget)
--   就是这个目标——即真正在打它，而不是“选中了它”。
--   reason 语义(给后续战斗调用方看)：
--     pending  "attack_cycle_started_unconfirmed"  攻击周期刚开始，命中未确认，别当打完；
--     pending  "attack_cycle_running_unconfirmed"  同一周期还在跑；
--     pending  "awaiting_attack_confirmation"      还没看到任何攻击状态；
--     pending  "pre_existing_attack_state"         下发前就在打这个目标，等它先结束再算新周期；
--     pending  "target_removed_unconfirmed"        客户端看不到目标，不等于击杀；
--     success  "attack_cycle_finished_hit_unconfirmed" 周期跑完了，但命中/伤害仍未确认；
--     success  "hit_observed:a->b" / "caller_confirmed" / "host_attack_succeeded" 才是硬证据。
--   客户端实体消失(含 boss 移除)一律不作为击杀/击败证据。
-- intent(kind="inventory")：{ kind="inventory", action=<ACTIONS 字符串 id>,
--                        item=<已持有实体>, target_item=<已持有实体|nil>,
--                        priority=<number|nil>, id=<任意|nil>, confirm=<function|nil> }
--   背包自用先用 GetInventoryActions 核对原版候选，再交给原生动作发送链路；物品对物品使用
--   ControllerUseItemOnItemFromInvTile(target_item, item)。与请求 action 不一致就拒绝。支持的动作 id：
--   无 target_item 时 EQUIP/UNEQUIP/EAT/USEITEM/HEAL；有 target_item 时 USEITEM/EAT/HEAL/FEED/FILL/SEW。
--   完成判定只认：调用方 confirm、EQUIP=该精确实体已在 replica 装备槽、
--   UNEQUIP=基线在槽里之后出槽且仍持有、消耗类=同一 prefab 堆叠数/总持有量下降。
--   所有权用 replica.inventoryitem:IsGrandOwner(含溢出背包)，不是自己背包里的一律拒绝；
--   不动用户手里的光标物品(不使用 UseItemFromInvTile 路径)。
-- intent(kind="transfer")：{ kind="transfer", source=<玩家实体|容器实体>, slot=<正整数>,
--                        destination=<玩家实体|容器实体>, count=<正整数|nil>,
--                        priority=<number|nil>, id=<任意|nil>, confirm=<function|nil> }
--   只调原生复制品搬运方法(inventory_replica.lua:584-608 / container_replica.lua:621-643)：
--   源是本地玩家 → replica.inventory:MoveItemFromAllOfSlot(slot, 目标实体) 或
--   :MoveItemFromCountOfSlot(slot, 目标实体, count)；源是容器 → 该容器 replica.container
--   的同名方法。目标参数是“实体”：玩家实体(destcontainer 为 nil → 服务端塞回发起者自己)
--   或容器实体。因此“背包→背包(另一个玩家)”没有对应 RPC 分支，直接拒绝。
--   世界容器必须此刻就在 inventory:GetOpenContainers() 里(原生服务端还要 IsOpenedBy)；
--   溢出背包用 inventory:GetOverflowContainer()(返回容器复制品，取 .inst 当目标实体)。
--   count 超过源堆叠量一律拒绝(原生 math.clamp 会把它悄悄改成别的数量)。
--   完成判定只认：调用方 confirm，或“源那一个精确实体/槽位的数量下降”与
--   “目标聚合量上升”两件事同时成立(先后不保证)；只少了源而目标没涨 → 保持 pending，
--   绝不当成功；部分搬运如实报 transferred_partial:src:a->b|dest:c->d。
-- intent(kind="craft")：{ kind="craft", recipe=<配方名字符串>, x?, z?, rotation?,
--                        priority?, id?, confirm? }
--   只走原版“玩家点制作栏”的那条路：replica.builder:MakeRecipeFromMenu(recipe)
--   或 recipe.placer ~= nil 时 replica.builder:MakeRecipeAtPoint(recipe, Vector3, rot)
--   (builder_replica.lua:440-453 → playercontroller.lua:5709-5748 → RPC；服务端
--   components/builder.lua:1041/1113 → MakeRecipe/DoBuild)。
--   下发前按原版 DoRecipeClick(widgets/widgetutil.lua:52-165) 的门槛逐条核对：
--   配方有效、KnowsRecipe 或(科技允许 CanPrototypeRecipe 且 CanLearn 的合法试制)、
--   HasIngredients 或已是原生缓冲建造(IsBuildBuffered)、builder 不忙、背包界面开着；
--   CanBuild 是过时的 HasIngredients 别名，绝不用它当知识证据；不发放物品、
--   不开 freebuild、不依赖任何诊断 mod。
--   放置类配方必须给出明确 x/z，并用原生 CanBuildAtPoint(Vector3, recipe, rot) 再判一次；
--   没有原生缓冲时会先发一次原生 BufferBuild(与原版点制作栏一致)，等缓冲可见才发 MakeRecipeAtPoint。
--   每个操作只做一次制作，不连做、不重发；完成判定只认：调用方 confirm、
--   主机侧本次操作的 builditem/buildstructure 原生事件、产品数量确实上升(背包/装备/溢出/光标)、
--   或目标点附近新增了这个 prefab 的实体。材料变少、配方变已知一律不算完成，超时即失败。
-- intent(kind="use")：{ kind="use", action=<ACTIONS 字符串 id>, item=<已持有实体>,
--                       target=<世界实体|nil>, x=<number|nil>, z=<number|nil>,
--                       rotation=<number|nil>, priority?, id?, confirm? }
--   把“自己背包里那个物品”对场景做一次原版下发，两条互斥链路：
--   * 有 target(实体)：与原生服务端 Inventory:ControllerUseItemOnSceneFromInvTile
--     (components/inventory.lua:2368-2420) 同源——先用
--     PlayerController:GetItemUseAction(item, target)(playercontroller.lua:5484-5560；
--     内部 GetUseItemActions(target, useitem, right) 先 rmb 后 lmb，再过 ValidateItemUseAction)
--     算出“这个物品对这个目标此刻真正会触发的那个动作”，并要求它就是请求的 action
--     (按 code+mod_name 比)。主机 → pc:DoAction(那个 BufferedAction)；客户端 →
--     pc:RemoteControllerUseItemOnSceneFromInvTile(buffaction, item)(playercontroller.lua:5629-5647，
--     正是 inventory_classified.lua:975-1001 自己走的那条)，它把 buffaction.target 原样放进
--     RPC.ControllerUseItemOnSceneFromInvTile(networkclientrpc.lua:773-789，target 为 optentity)，
--     所以“显式目标 + 真实物品”成立，完全不用改动用户光标/装备。
--     ADDFUEL / REPAIR / REPAIR_LEAK / GIVE / COOK 全走这条。
--     注：这条只能把 COOK 选在“火堆(带 cooker 标签、components.cooker)”上；往锅里放料是
--     stewer/容器方向的动作，不会被 cookable 收集器生成，因此本 kind 不会把“填锅”当 COOK。
--   * 无 target(x/z 点)：只有原版“控制器部署”链路能把“显式物品”送到点上——
--     SendRPCToServer(RPC.ControllerActionButtonDeploy, item, 平台相对 x/z, rotation, isreleased,
--     platform, platform_relative)(playercontroller.lua:888-900)；服务端
--     PlayerController:OnRemoteControllerActionButtonDeploy(playercontroller.lua:1045-1064)
--     只校验 invobject 的 GrandOwner 是本人，然后 DoAction(BufferedAction(..., DEPLOY|DEPLOY_FLOATING,
--     invobject, position, nil, 1, nil, rotation))；主机侧照抄同一构造。
--     因此点模式只支持 ACTIONS.DEPLOY / ACTIONS.DEPLOY_FLOATING(按原生 action 表同一性判定，
--     不是猜字符串)，且要求它确实出现在原生
--     PlayerActionPicker:GetPointActions(pos, item, right=true) 的候选里
--     (componentactions.lua:2072-2094 的 deployable 收集器)。其它点动作(如 TOSS)没有任何原生
--     RPC 能携带显式物品，一律如实拒绝 point_use_unsupported:<id>。
--     这条链路不需要临时占用用户光标物品(原生 RPC 自带 item)，所以绝不改光标状态。
--   完成判定(严格：没有可核实的相关副作用就不算成功)：
--     * 只认三样：调用方 confirm(player, intent)、主机侧本次下发那个 BufferedAction 的原生
--       AddSuccessAction、或者“物品真的少了一份”且“预期产物真的出现”同时成立；
--     * 预期产物只从原生源码映射，不猜字符串、也不认“随便多了一个实体”：部署物品读
--       inst.deploy_product(prefabs/boat.lua:1505/1526/1551 → ondeploy 里 SpawnPrefab(inst.deploy_product))，
--       点周围数这个 prefab；火堆烹饪读服务端 components/cookable.product，并数自己背包里
--       该熟食的数量(ACTIONS.COOK.fn 把产物 GiveItem 给 doer)；
--     * 消耗/持有量下降、所有权转移、目标或实体消失本身一律不是成功，哪怕带上后缀说明；
--     * 读不到预期产物时(例如客户端读不到 cookable.product、ADDFUEL/REPAIR/GIVE 根本没有
--       客户端可读的目标值：fueled/finiteuses 没有客户端副本)，就停在 pending
--       effect_unconfirmed:<...>，直到调用方 confirm / 主机成功 / 截止时间如实报失败；
--       GIVE 送礼消失、任务物品交出去都绝不当任务完成。
-- 约定：每个玩家同时最多持有一个自有操作；相同意图身份 key 只轮询不重复下发；
-- 操作终结(成功/失败)后只把终态+原因闩存在该身份上，直到 Cancel() 或换成别的意图/id；
-- 不同意图仅在 priority 更高时抢占，且抢占只释放自有那条本地 BufferedAction。
-- 终结(无论成功或失败)也会做一次同一身份校验的本地清理：只有仍是“我们那条”
-- BufferedAction(与 locomotor/entity 槽位同一对象)才撤，绝不碰别人的动作；
-- 唯一例外是攻击——若我们下发的那一次攻击周期此刻还在状态机里跑(还没到判定帧)，
-- 就先保留这份所有权(记录 reason 后缀 `|held:attack_cycle_in_progress`)，
-- 以便之后 Cancel() 仍能撤掉它，同时不会把这一刀提前取消。
--============================================================================
local Actions = {}

Actions.SCHEMA_VERSION = 1
Actions.DEFAULT_RANGE = 1.5
Actions.DEFAULT_PRIORITY = 0
Actions.DEFAULT_TIMEOUT = 15
Actions.TIMEOUT_PER_UNIT = 0.35
Actions.TIMEOUT_MAX = 90
Actions.WORLD_LIMIT = 20000

-- [喵喵喵]: 每个玩家至多一条自有操作；弱键避免实体回收后泄漏。
local OWNED = setmetatable({}, { __mode = "k" })

local function is_valid(inst)
    return inst ~= nil and inst.IsValid ~= nil and inst:IsValid() == true
end

local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- [喵喵喵]: 截止时间用原生 GetTime，缺失时退回 os.clock，避免永久 pending。
local function now()
    return type(GetTime) == "function" and GetTime() or os.clock()
end

local function get_xz(inst)
    if inst == nil or inst.Transform == nil then
        return nil
    end
    local ok, x, _, z = pcall(function() return inst.Transform:GetWorldPosition() end)
    if not ok or not is_finite_number(x) or not is_finite_number(z) then
        return nil
    end
    return x, z
end

-- [喵喵喵]: 内部处理器管线(不对外注册)：prepare->params|nil,reason /
-- dispatch->ok,reason / check->status,reason；后续阶段按同一形状追加 kind。
local PIPELINE = {}

local function move_key(intent)
    if not is_finite_number(intent.x) or not is_finite_number(intent.z) then
        return nil
    end
    local range = intent.range == nil and Actions.DEFAULT_RANGE or intent.range
    if not is_finite_number(range) then
        return nil
    end
    -- [喵喵喵]: key 含可选 id，同一目的地可用显式 id 重新武装；只看意图字段，
    -- 因此实体/位置消失后仍能算出同一身份。
    return string.format("move|%.3f|%.3f|%.3f|%s", intent.x, intent.z, range, tostring(intent.id))
end

local function prepare_move(player, intent)
    local key = move_key(intent)
    if key == nil then
        return nil, "move_needs_finite_x_z"
    end
    if math.abs(intent.x) > Actions.WORLD_LIMIT or math.abs(intent.z) > Actions.WORLD_LIMIT then
        return nil, "move_target_out_of_world"
    end
    local range = intent.range == nil and Actions.DEFAULT_RANGE or intent.range
    if not is_finite_number(range) or range <= 0 or range > 40 then
        return nil, "move_bad_range"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "move_bad_priority"
    end
    local px, pz = get_xz(player)
    local dist = px ~= nil and math.sqrt((px - intent.x) ^ 2 + (pz - intent.z) ^ 2) or 0
    return {
        kind = "move",
        key = key,
        id = intent.id,
        x = intent.x,
        z = intent.z,
        range = range,
        range2 = range * range,
        priority = priority,
        deadline = now() + math.min(Actions.DEFAULT_TIMEOUT + dist * Actions.TIMEOUT_PER_UNIT, Actions.TIMEOUT_MAX),
        dispatched = false,
    }
end

local function dispatch_move(player, pc, op)
    -- [喵喵喵]: 第 10 参 arrivedist = range，让预测行走在 range 处停步。
    local buff = BufferedAction(player, nil, ACTIONS.WALKTO, nil, Vector3(op.x, 0, op.z), nil, nil, nil, nil, op.range)
    if pc.locomotor == nil then
        -- [喵喵喵]: 无预测时镜像原生单击：一次"已松手"的 LeftClick。
        local platform, rx, rz = pc:GetPlatformRelativePosition(op.x, op.z)
        buff.non_preview_cb = function()
            pc.remote_controls[CONTROL_PRIMARY] = 0
            SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, rx, rz, nil, true, nil, true, nil, platform, platform ~= nil)
            -- [喵喵喵]: 已松手点击发完即还控件，别把 CONTROL_PRIMARY 留在按下态。
            pc.remote_controls[CONTROL_PRIMARY] = nil
        end
        op.no_prediction = true
    end
    pc:DoAction(buff)
    op.buffaction = buff
    return true
end

local function check_move(player, pc, op)
    local x, z = get_xz(player)
    if x == nil then
        return "pending", "no_player_position"
    end
    local dx, dz = x - op.x, z - op.z
    local d2 = dx * dx + dz * dz
    if d2 <= op.range2 then
        return "succeeded", "arrived"
    end
    op.last_distance = math.sqrt(d2)
    -- [喵喵喵]: 本地预测缓冲被别的动作顶掉判失败，绝不清别人的动作。
    local loco = pc.locomotor
    if not op.no_prediction and loco ~= nil and loco.bufferedaction ~= nil
        and loco.bufferedaction ~= op.buffaction then
        return "failed", "superseded_by_other_action"
    end
    return "pending", "moving"
end

PIPELINE.move = { prepare = prepare_move, dispatch = dispatch_move, check = check_move, identify = move_key }

--============================================================================
-- [喵喵喵]: kind="action"：普通交互重放一次已松手点击；CHOP/MINE/HAMMER
-- 则持有原版工作控件，让状态机在同一目标上连续作业，完成/抢占时释放。
-- 坐标和目标均来自意图，不读取桌面光标；服务端继续负责动作与距离校验。
--============================================================================
local ACTION_MISMATCH_LIMIT = 2
local CONTINUOUS_WORK = { CHOP = true, MINE = true, HAMMER = true }

-- [喵喵喵]: 只有这些动作的“目标”本身就是进背包的东西，才能用持有关系当完成证据。
local ACTION_ACQUIRES_TARGET = {
    PICKUP = true,
    PICKUPITEM = true,
}

-- [喵喵喵]: 只有原生的容器开启动作才允许用“被点的那个容器新开”当完成证据：
-- 原生 ACTIONS.RUMMAGE.fn(actions.lua:1054-1129) 才会 container:Open(doer)
-- 并把该容器写进 doer 的 opencontainers / HUD 容器控件；其余动作下目标出现在
-- 打开集合里与本次操作无关。
local ACTION_OPENS_TARGET = {
    RUMMAGE = true,
}

-- [喵喵喵]: 前置声明：持有关系判定实现在 inventory 段(IsGrandOwner / 溢出背包)。
local item_owned_by

-- [喵喵喵]: 本地预测/预览缓冲被别的动作顶掉 = 本操作已被取代(不清别人的动作)。
-- 下发后 1 秒宽限期，避免瞬时动作刚完成就被当成“被抢占”。
local SUPERSEDE_GRACE = 1.0
local function local_action_superseded(player, op)
    if op.no_prediction or op.buffaction == nil then
        return false
    end
    if op.dispatch_time ~= nil and now() - op.dispatch_time < SUPERSEDE_GRACE then
        return false
    end
    local pc = player.components ~= nil and player.components.playercontroller or nil
    local loco = pc ~= nil and pc.locomotor or nil
    if loco == nil or loco.bufferedaction == nil then
        return false
    end
    return loco.bufferedaction ~= op.buffaction
end

local function to_key_ref(inst)
    if inst == nil then
        return "-"
    end
    return tostring(inst.GUID ~= nil and inst.GUID or inst)
end

-- [喵喵喵]: 客户端与主机都有副本，返回以容器实体为键的表；缺失时返回 nil。
local function get_open_containers(player)
    local inv = player.replica ~= nil and player.replica.inventory or nil
    if inv == nil or inv.GetOpenContainers == nil then
        return nil
    end
    local ok, list = pcall(function() return inv:GetOpenContainers() end)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return list
end

local function copy_keys(list)
    local out = {}
    if list ~= nil then
        for k in pairs(list) do
            out[k] = true
        end
    end
    return out
end

-- [喵喵喵]: 身份 key 只由意图字段算出(GUID/数字)，实体已经失效也照样能算。
local function action_key(intent)
    if type(intent.action) ~= "string" then
        return nil
    end
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil
    end
    local has_x = intent.x ~= nil
    if has_x ~= (intent.z ~= nil) then
        return nil
    end
    local posstr = "-"
    if has_x then
        if not is_finite_number(intent.x) or not is_finite_number(intent.z) then
            return nil
        end
        posstr = string.format("%.3f|%.3f", intent.x, intent.z)
    elseif intent.target == nil then
        return nil
    end
    -- [喵喵喵]: 有实体时关键在实体 GUID，位置漂移不会重发。
    return string.format("action|%s|%s|%s|%s|%s|%s|%s",
        tostring(action.id),
        to_key_ref(intent.target), to_key_ref(intent.item),
        tostring(intent.right == true), tostring(intent.rotation),
        posstr,
        tostring(intent.id))
end

local function prepare_action(player, intent)
    if type(intent.action) ~= "string" then
        return nil, "action_needs_string_id"
    end
    -- [喵喵喵]: 只接受原版 ACTIONS 里的字符串 id，避免造自定义动作。
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil, "action_unknown:" .. intent.action
    end
    local target = intent.target
    if target ~= nil and not is_valid(target) then
        return nil, "action_target_invalid"
    end
    local item = intent.item
    if item ~= nil and not is_valid(item) then
        return nil, "action_item_invalid"
    end
    if intent.right ~= nil and type(intent.right) ~= "boolean" then
        return nil, "action_bad_right"
    end
    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "action_bad_confirm"
    end
    if intent.rotation ~= nil and not is_finite_number(intent.rotation) then
        return nil, "action_bad_rotation"
    end
    local has_x = intent.x ~= nil
    if has_x ~= (intent.z ~= nil) then
        return nil, "action_needs_both_x_and_z"
    end
    local x, z = intent.x, intent.z
    if not has_x then
        if target == nil then
            return nil, "action_needs_target_or_x_z"
        end
        x, z = get_xz(target)
        if x == nil then
            return nil, "action_target_no_position"
        end
    end
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, "action_needs_finite_x_z"
    end
    if math.abs(x) > Actions.WORLD_LIMIT or math.abs(z) > Actions.WORLD_LIMIT then
        return nil, "action_target_out_of_world"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "action_bad_priority"
    end
    local right = intent.right == true
    -- [喵喵喵]: 身份 key 必须在 prepare 阶段就算得出来，否则无法做“同一意图只轮询”的闩存。
    local key = action_key(intent)
    if key == nil then
        return nil, "action_bad_intent_key"
    end
    return {
        kind = "action",
        key = key,
        id = intent.id,
        action_id = intent.action,
        action = action,
        work_tag = CONTINUOUS_WORK[intent.action] and (intent.action .. "_workable") or nil,
        target = target,
        item = item,
        intent = intent,
        confirm = intent.confirm,
        explicit_xz = has_x,
        x = x,
        z = z,
        right = right,
        rotation = intent.rotation,
        priority = priority,
        -- [喵喵喵]: 每种 kind 都必须有有限截止时间，poll 不会再有 nil 比较。
        deadline = now() + Actions.DEFAULT_TIMEOUT,
        dispatched = false,
    }
end

-- [喵喵喵]: 实体目标动作的 BufferedAction.pos 通常为 nil(GetActionPoint 也就返回 nil)，
-- 所以点击坐标优先用 prepare 已校验的 op.x/op.z，其次原生目标位置，最后才用动作点。
local function resolve_click_point(buff, op)
    local x, z = op.x, op.z
    if not is_finite_number(x) or not is_finite_number(z) then
        x, z = get_xz(buff ~= nil and buff.target or op.target)
    end
    if (not is_finite_number(x) or not is_finite_number(z))
        and buff ~= nil and buff.GetActionPoint ~= nil then
        local ok, pt = pcall(function() return buff:GetActionPoint() end)
        if ok and pt ~= nil and is_finite_number(pt.x) and is_finite_number(pt.z) then
            x, z = pt.x, pt.z
        end
    end
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil, nil
    end
    return x, z
end

local function get_work_tool(player)
    local inventory = player.replica ~= nil and player.replica.inventory or nil
    return inventory ~= nil and inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
end

local function hold_work_control(player, pc, op, cand)
    if cand.target ~= op.target or not is_valid(op.target) or not op.target:HasTag(op.work_tag) then
        return false, "work_target_unavailable"
    end
    local tool = get_work_tool(player)
    if not is_valid(tool) or not tool:HasTag(op.action_id .. "_tool") then
        return false, "work_tool_unavailable"
    end
    local control = op.right and CONTROL_SECONDARY or CONTROL_PRIMARY
    if not pc.ismastersim and (pc.RemoteStopControl == nil or pc.remote_controls[control] ~= nil) then
        return false, "work_control_unavailable"
    end
    op.work_controller, op.work_tool, op.work_control = pc, tool, control
    op.deadline = now() + Actions.TIMEOUT_MAX
    if pc.ismastersim then
        -- [喵喵喵]: 房主状态机查询本地输入；只为自有工作提供按住状态，保留其他控件的原始判断。 (2026-11-11)
        local previous = pc.IsAnyOfControlsPressed
        op.previous_work_query = rawget(pc, "IsAnyOfControlsPressed")
        op.work_query = function(controller, ...)
            local sg = player.sg
            if OWNED[player] == op and op.work_controller == controller and controller:IsEnabled()
                and sg ~= nil and sg.statemem.action == op.buffaction
                and is_valid(op.target) and op.target:HasTag(op.work_tag)
                and is_valid(op.work_tool) and get_work_tool(player) == op.work_tool then
                for i = 1, select("#", ...) do
                    if select(i, ...) == op.work_control then return true end
                end
            end
            return previous(controller, ...)
        end
        pc.IsAnyOfControlsPressed = op.work_query
        op.work_finished = function(_, data)
            if OWNED[player] == op and data ~= nil and data.target == op.target and data.action == op.action then
                op.work_complete = true
            end
        end
        op.work_failed = function(_, data)
            if OWNED[player] == op and data ~= nil and data.action == op.buffaction then op.result = "failed" end
        end
        player:ListenForEvent("finishedwork", op.work_finished)
        player:ListenForEvent("actionfailed", op.work_failed)
    end
    return true
end

local function release_work_control(player, op)
    local pc = op.work_controller
    if pc == nil then return false end
    op.work_controller = nil
    if pc.ismastersim then
        if pc.IsAnyOfControlsPressed == op.work_query then pc.IsAnyOfControlsPressed = op.previous_work_query end
        player:RemoveEventCallback("finishedwork", op.work_finished)
        player:RemoveEventCallback("actionfailed", op.work_failed)
    elseif op.work_sent then
        -- [喵喵喵]: 松开必须发送原版 StopControl；只删客户端表项会让服务器继续循环作业。 (2026-11-11)
        pc:RemoteStopControl(op.work_control)
    end
    op.work_query, op.previous_work_query, op.work_finished, op.work_failed = nil, nil, nil, nil
    op.work_control, op.work_tool = nil, nil
    return true
end

-- [喵喵喵]: 工作使用 isreleased=false 交给原版状态机续接；其他交互仍为一次已松手点击。
local function make_click_cb(pc, buff, right, rotation, target, x, z, op)
    if not is_finite_number(x) or not is_finite_number(z) then
        return nil
    end
    local platform, rx, rz = pc:GetPlatformRelativePosition(x, z)
    if not is_finite_number(rx) or not is_finite_number(rz) then
        return nil
    end
    local controlmods = pc.EncodeControlMods ~= nil and pc:EncodeControlMods() or nil
    local control = right and CONTROL_SECONDARY or CONTROL_PRIMARY
    local mod_name = buff.action.mod_name
    local code = buff.action.code
    local rot = rotation ~= nil and rotation ~= 0 and rotation or nil
    return function()
        local holding = op.work_tag ~= nil
        if holding and (OWNED[pc.inst] ~= op or op.work_controller ~= pc) then return end
        pc.remote_controls[control] = 0
        if holding then op.work_sent = true end
        if right then
            SendRPCToServer(RPC.RightClick, code, rx, rz, target,
                rot, not holding, controlmods, nil, mod_name,
                platform, platform ~= nil)
        else
            SendRPCToServer(RPC.LeftClick, code, rx, rz, target,
                not holding, controlmods, nil, mod_name, platform, platform ~= nil, nil, nil)
        end
        if not holding then pc.remote_controls[control] = nil end
    end
end

-- [喵喵喵]: 取玩家此刻点鼠标能触发的那个动作；hard=true 表示可直接拒绝。
local function find_click_action(player, pc, op)
    local picker = player.components.playeractionpicker
    if picker == nil or picker.DoGetMouseActions == nil then
        return nil, "picker_unavailable", true
    end
    local x, z = op.x, op.z
    if not op.explicit_xz then
        if not is_valid(op.target) then
            return nil, "target_gone", true
        end
        x, z = get_xz(op.target)
        if x == nil then
            return nil, "target_no_position", true
        end
    end
    local ok, lmb, rmb = pcall(function()
        return picker:DoGetMouseActions(Vector3(x, 0, z), op.target)
    end)
    if not ok then
        return nil, "picker_error", true
    end
    local cand = op.right and rmb or lmb
    if cand == nil or cand.action == nil then
        return nil, "action_unavailable:" .. tostring(op.action_id)
    end
    if cand.action.code ~= op.action.code or cand.action.mod_name ~= op.action.mod_name then
        return nil, "action_mismatch:" .. tostring(cand.action.id)
    end
    if op.item ~= nil and cand.invobject ~= op.item then
        return nil, "item_mismatch"
    end
    return cand
end

local function dispatch_action(player, pc, op)
    -- [喵喵喵]: 右键在原版要求鼠标控件可用(PlayerController:OnRightClick)。
    if op.right and pc.UsingMouse ~= nil and not pc:UsingMouse() then
        return false, "mouse_unavailable", true
    end
    local cand, why, hard = find_click_action(player, pc, op)
    if cand == nil then
        if hard then
            return false, why, true
        end
        -- [喵喵喵]: 只在短暂不匹配时宽容几次，之后当真拒绝。
        op.mismatch = (op.mismatch or 0) + 1
        if op.mismatch >= ACTION_MISMATCH_LIMIT then
            return false, why, true
        end
        return false, why
    end
    op.mismatch = 0

    local target = cand.target
    if target ~= nil and type(CanEntitySeeTarget) == "function" and not CanEntitySeeTarget(player, target) then
        return false, "target_not_visible", true
    end

    if pc.ismastersim then
        -- [喵喵喵]: 主机侧直接用原生 AddSuccessAction/AddFailAction 拿权威结果。
        op.result = nil
        cand:AddSuccessAction(function()
            if OWNED[player] == op then op.result = "succeeded" end
        end)
        cand:AddFailAction(function()
            if OWNED[player] == op then op.result = "failed" end
        end)
    else
        -- [喵喵喵]: 只有存在预测 locomotor 时才谈 CanLocomote；无预测客户端走
        -- non_preview_cb，原版 DoAction 会立即调用它发一次已松手点击。
        if pc.locomotor ~= nil and pc.CanLocomote ~= nil and not pc:CanLocomote() then
            -- [喵喵喵]: 预测链此刻不可用，DoAction 不会下发任何 RPC：等下一帧。
            return false, "cannot_locomote_prediction"
        end
        local cx, cz = resolve_click_point(cand, op)
        local clicked = cx ~= nil and make_click_cb(pc, cand, op.right, op.rotation, cand.target, cx, cz, op) or nil
        if clicked == nil then
            return false, "no_click_point", true
        end
        if pc.locomotor == nil then
            cand.non_preview_cb = clicked
            op.no_prediction = true
        else
            cand.preview_cb = clicked
        end
    end

    if op.work_tag ~= nil then
        local held, reason = hold_work_control(player, pc, op, cand)
        if not held then return false, reason, true end
    end

    -- [喵喵喵]: 基线取在下发前，后置条件只认基线之后新出现的可见事实。
    op.target = cand.target
    local open = get_open_containers(player)
    op.baseline_containers = open ~= nil and copy_keys(open) or nil
    -- [喵喵喵]: 收货类动作自己的基线：下发前就已在背包里的目标，之后“仍持有”不是
    -- 本次操作的完成证据。
    op.baseline_target_owned = ACTION_ACQUIRES_TARGET[op.action_id] == true
        and item_owned_by(cand.target, player) or nil
    op.buffaction = cand
    pc:DoAction(cand)
    return true
end

local function check_action(player, pc, op)
    if op.work_tag ~= nil then
        -- [喵喵喵]: 单次成功回调/工具掉耐久只证明挥了一次；工作持续到目标不再可作业或调用方明确终止。 (2026-11-11)
        if op.work_complete then return "succeeded", "host_work_finished" end
        if not is_valid(op.target) then return "failed", "work_target_lost_unconfirmed" end
        if not op.target:HasTag(op.work_tag) then return "succeeded", "work_target_exhausted" end
        if op.result == "failed" then return "failed", "host_work_failed" end
        if not is_valid(op.work_tool) or get_work_tool(player) ~= op.work_tool then
            return "failed", "work_tool_changed"
        end
        if pc ~= op.work_controller or not pc:IsEnabled()
            or (op.work_sent and pc.remote_controls[op.work_control] == nil) then
            return "failed", "work_control_released"
        end
        if local_action_superseded(player, op) then return "failed", "superseded_by_other_action" end
        if op.confirm ~= nil then
            local ok, done = pcall(op.confirm, player, op.intent)
            if ok and done == true then return "succeeded", "caller_confirmed" end
        end
        return "pending", "working:" .. op.action_id
    end
    if op.result == "succeeded" then
        return "succeeded", "host_action_succeeded"
    elseif op.result == "failed" then
        return "failed", "host_action_failed"
    end

    -- [喵喵喵]: 调用方自带基线时，以它返回 true 作为完成证据。
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    if op.target ~= nil and is_valid(op.target) then
        -- [喵喵喵]: 只认“被点的那个容器自己”在基线之后新开，而且只对容器开启
        -- 动作(RUMMAGE)成立；别的容器打开、别的动作下的打开都不算。
        if ACTION_OPENS_TARGET[op.action_id] == true then
            local open = get_open_containers(player)
            if open ~= nil and open[op.target] == true
                and (op.baseline_containers == nil or op.baseline_containers[op.target] == nil) then
                return "succeeded", "intended_container_open"
            end
        end
        -- [喵喵喵]: 持有关系只对“把目标收进背包”的动作成立，只认同一个目标，
        -- 且必须用动作自己的基线：客户端走 replica.inventoryitem:IsGrandOwner(player)
        -- (inventoryitem_replica.lua:210，已含溢出背包)，主机再补 components 回退。
        if ACTION_ACQUIRES_TARGET[op.action_id] == true
            and op.baseline_target_owned ~= true
            and item_owned_by(op.target, player) then
            return "succeeded", "intended_target_acquired"
        end
    end

    -- [喵喵喵]: 其他成功证据(任意实体消失/任意容器打开/任意持有)一律不算，因为
    -- 它们可能是剔除、别人开的箱、上游其他动作造成的。只等超时。
    if local_action_superseded(player, op) then
        return "failed", "superseded_by_other_action"
    end

    return "pending", "awaiting_confirmation"
end

PIPELINE.action = { prepare = prepare_action, dispatch = dispatch_action, check = check_action, identify = action_key }

--============================================================================
-- [喵喵喵]: kind="attack"：单次攻击。不自己找敌人、不换武器、不管走位策略，只把
-- “玩家此刻点左键打这个目标”这件事交给原生控制器做一次，然后等一个可见证据。
--============================================================================
local ATTACK_SELECT_LIMIT = 2

-- [喵喵喵]: 血量基线只看客户端可见的 replica，而且只能用 health_replica 的
-- GetCurrent(那个文件里不存在 Get)。拿不到就当作“没有血量证据”。
local function get_health(inst)
    if not is_valid(inst) then
        return nil
    end
    local rep = inst.replica
    local health = rep ~= nil and rep.health or nil
    if health == nil or health.GetCurrent == nil then
        return nil
    end
    local ok, val = pcall(function() return health:GetCurrent() end)
    if not ok or not is_finite_number(val) then
        return nil
    end
    return val
end

-- [喵喵喵]: “真的正在打这个目标”的可见状态：必须同时有 attack/abouttoattack 标签
-- 且状态机记着这个目标(SGwilson_client.lua:4978-4990 进入 attack 时写 statemem.attacktarget，
-- 5240-5290 退出时才 RemoveStateTag("attack"))。pc:GetCombatTarget()
-- (playercontroller.lua:2643 -> sg.statemem.attacktarget) 单独命中不算，
-- replica.combat:GetTarget() 只是“选中了它”也不是攻击，只能作为“开始”证据，绝不是命中/击杀证据。
local function is_attack_state_for(player, target)
    if not is_valid(target) then
        return false
    end
    local sg = player.sg
    if sg ~= nil then
        if not (sg:HasStateTag("attack") or sg:HasStateTag("abouttoattack")) then
            return false
        end
        local statemem = sg.statemem
        if statemem ~= nil and (statemem.attacktarget == target or statemem.retarget == target) then
            return true
        end
        local pc = player.components ~= nil and player.components.playercontroller or nil
        if pc ~= nil and pc.GetCombatTarget ~= nil then
            local ok, t = pcall(function() return pc:GetCombatTarget() end)
            if ok and t == target then
                return true
            end
        end
        return false
    end
    -- [喵喵喵]: 拿不到状态机时只能靠真正可观测的攻击信号：
    -- combat:InCooldown() 只在原生 attack 状态 onenter 调 combat:StartAttack() 后
    -- (SGwilson_client.lua:4999) 或服务端 min_attack_period 内为真；
    -- 光有 combat:GetTarget()==target 只是选目标，不代表在打，一律当“未知”。
    local combat = player.replica ~= nil and player.replica.combat or nil
    if combat == nil or combat.GetTarget == nil or combat.InCooldown == nil then
        return false
    end
    local ok_t, t = pcall(function() return combat:GetTarget() end)
    if not ok_t or t ~= target then
        return false
    end
    local ok_c, cooling = pcall(function() return combat:InCooldown() end)
    return ok_c and cooling == true
end

-- [喵喵喵]: 身份 key：只绑目标 GUID + 可选 id，不再要求实体此刻有效。
local function attack_key(intent)
    if intent.target == nil then
        return nil
    end
    return string.format("attack|%s|%s", to_key_ref(intent.target), tostring(intent.id))
end

local function prepare_attack(player, intent)
    local target = intent.target
    if target == nil then
        return nil, "attack_needs_target"
    end
    if not is_valid(target) then
        return nil, "attack_target_invalid"
    end
    -- [喵喵喵]: 原生限制：不写自伤、不接受非实体目标；打谁由控制器再校验一次。
    if target == player then
        return nil, "attack_self_refused"
    end
    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "attack_bad_confirm"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "attack_bad_priority"
    end
    return {
        kind = "attack",
        -- [喵喵喵]: key 绑目标 GUID，同名不同实体不会被当成同一次攻击。
        key = attack_key(intent),
        id = intent.id,
        target = target,
        intent = intent,
        confirm = intent.confirm,
        priority = priority,
        deadline = now() + Actions.DEFAULT_TIMEOUT,
        dispatched = false,
    }
end

local function dispatch_attack(player, pc, op)
    local target = op.target
    if not is_valid(target) then
        return false, "target_gone", true
    end
    if type(IsEntityDead) == "function" and IsEntityDead(target) then
        return false, "target_dead", true
    end
    if pc.GetAttackTarget == nil then
        return false, "no_get_attack_target", true
    end
    -- [喵喵喵]: force_attack=false 保持原版“只打有敌意/反击过的目标”的限制，
    -- 不越权打开强制攻击；force_target=target 让原生只校验这一个目标。
    local ok, chosen = pcall(function() return pc:GetAttackTarget(false, target, false, false) end)
    if not ok then
        return false, "attack_target_error", true
    end
    if chosen ~= nil and chosen ~= target then
        -- [喵喵喵]: 原生此刻会打到别的实体，绝不替调用方换目标。
        return false, "attack_target_mismatch:" .. tostring(chosen.prefab), true
    end
    if chosen == nil then
        -- 原生选不出(超出射程/状态机在攻击中/重物限制)：先短暂等待，之后当真拒绝。
        op.mismatch = (op.mismatch or 0) + 1
        if op.mismatch >= ATTACK_SELECT_LIMIT then
            return false, "attack_target_not_selectable", true
        end
        return false, "attack_target_not_selectable"
    end
    op.mismatch = 0

    if type(CanEntitySeeTarget) == "function" and not CanEntitySeeTarget(player, target) then
        return false, "target_not_visible", true
    end

    op.baseline_health = get_health(target)
    -- [喵喵喵]: 下发前的攻击状态基线：已经在这个目标身上开打就不算“新开始”，
    -- 那一轮旧周期结束后新出现的才算我们这次下发的。
    op.baseline_attacking = is_attack_state_for(player, target)
    op.attack_phase = op.baseline_attacking == true and "preexisting" or "armed"
    op.attack_started_at = nil
    local buff = BufferedAction(player, target, ACTIONS.ATTACK)

    if pc.ismastersim then
        -- [喵喵喵]: 主机侧交给控制器(内部 locomotor:PushAction(buff, true))，结果以权威状态为准：
        -- BufferedAction:Do -> Succeed/Fail 会回调这两个钩子(bufferedaction.lua:22-37,82,104)。
        op.result = nil
        buff:AddSuccessAction(function()
            if OWNED[player] == op then op.result = "succeeded" end
        end)
        buff:AddFailAction(function()
            if OWNED[player] == op then op.result = "failed" end
        end)
        pc:DoAction(buff)
    else
        -- [喵喵喵]: 只有存在预测 locomotor 时才谈 CanLocomote(它内部会因
        -- locomotor==nil 直接返回 false)；无预测客户端仍走 non_preview_cb。
        if pc.locomotor ~= nil and pc.CanLocomote ~= nil and not pc:CanLocomote() then
            return false, "cannot_locomote_prediction"
        end
        if pc.locomotor == nil then
            -- [喵喵喵]: 无预测客户端镜像 DoAttackButton 的 remote 分支；
            -- 参数为 (target, force_attack=false, isleftmouse=false, isreleased=true)，
            -- 显式松手，RemoteAttackButton 自己把 remote_controls 清成 nil。
            buff.non_preview_cb = function()
                pc:RemoteAttackButton(target, false, false, true)
            end
            op.no_prediction = true
        else
            -- [喵喵喵]: 预测客户端同原生：先 PreviewAction 把路走过去，preview_cb 到点才发
            -- 一次 AttackButton，同样 isreleased=true 只按一次。
            buff.preview_cb = function()
                pc:RemoteAttackButton(target, false, false, true)
            end
        end
        pc:DoAction(buff)
    end

    op.buffaction = buff
    return true
end

local function check_attack(player, pc, op)
    -- [喵喵喵]: 主机侧原生 AddSuccessAction/AddFailAction 给出的权威结果优先。
    if op.result == "succeeded" then
        return "succeeded", "host_attack_succeeded"
    elseif op.result == "failed" then
        return "failed", "host_attack_failed"
    end

    -- [喵喵喵]: 调用方自带基线时优先采信。
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    -- [喵喵喵]: 唯一算“命中”的客观证据：目标血量在基线之后真的下降。
    local hp = get_health(op.target)
    if op.baseline_health ~= nil and hp ~= nil and hp < op.baseline_health - 0.000001 then
        return "succeeded", string.format("hit_observed:%.3f->%.3f", op.baseline_health, hp)
    end

    -- [喵喵喵]: 客户端看不到实体了(含 boss 被移除)不作为击杀证据，只等超时。
    -- 放在周期判定之前：目标消失不能被误当成“我们的攻击周期结束”。
    if not is_valid(op.target) then
        return "pending", "target_removed_unconfirmed"
    end

    -- [喵喵喵]: 只跟踪“我们下发的那一次攻击周期”，而且只认可见状态机：
    -- 开始只算 pending(未确认命中)，绝不因为“开始打了”就宣称成功。
    local attacking = is_attack_state_for(player, op.target)
    local phase = op.attack_phase

    if phase == "preexisting" then
        if attacking then
            -- [喵喵喵]: 下发前就在打的旧周期还没结束，归因不到我们。
            return "pending", "pre_existing_attack_state"
        end
        -- [喵喵喵]: 旧周期已经结束；之后新出现的攻击状态才算我们这次下发的。
        op.attack_phase = "armed"
        phase = "armed"
    end

    if phase ~= "started" then
        if attacking then
            op.attack_phase = "started"
            op.attack_started_at = now()
            return "pending", "attack_cycle_started_unconfirmed"
        end
        return "pending", "awaiting_attack_confirmation"
    end

    if attacking then
        return "pending", "attack_cycle_running_unconfirmed"
    end

    -- [喵喵喵]: 我们已经观测到的那一个攻击周期结束了(状态机退出 attack)，
    -- 但客户端仍看不到命中/伤害，所以 reason 明确写 hit_unconfirmed。
    return "succeeded", "attack_cycle_finished_hit_unconfirmed"
end

PIPELINE.attack = { prepare = prepare_attack, dispatch = dispatch_attack, check = check_attack, identify = attack_key }

--============================================================================
-- [喵喵喵]: kind="inventory"：对“自己已经持有的某个实体物品”做一次原版背包动作
-- (EQUIP / UNEQUIP / EAT / 自用 / 物品对物品)。
-- intent：{ kind="inventory", action=<ACTIONS 字符串 id>, item=<持有实体>,
--           target_item=<持有实体|nil>, priority?, id?, confirm? }
-- 下发方式：自用动作直接询问原生 GetInventoryActions，不受键鼠/手柄部署模式影响：
--   * 无 target_item → 主机 locomotor:PushAction，客户端 RemoteControllerUseItemOnSelfFromInvTile
--   * 有 target_item → replica.inventory:ControllerUseItemOnItemFromInvTile(target_item, item)
--     (内部 GetItemUseAction(item(useitem), target_item)，参数顺序照原生 item, active_item)
-- 一次下发前必须先用同一批原生 picker 算出“这个方法此刻会选中的那个动作”，
-- 请求的 action 与之不同就拒绝，绝不默默换成别的动作；也不用 UseItemFromInvTile
-- (它在该方法内部会把用户手里的光标物品当 useitem 用掉)。
-- 完成判定只认：调用方 confirm、EQUIP=该实体真在 replica 装备槽里、UNEQUIP=基线在槽里
-- 之后出槽且仍在持有中、消耗类=同一物品的堆叠数/总持有量在基线之后下降。
--============================================================================

-- [喵喵喵]: 只接受明确支持的“背包内自用”动作；其余精确 id 一律拒绝(不下发)。
-- HEAL 来自原生 componentactions.lua 的 INVENTORY healer 收集器
-- (doer.replica.health:CanHeal() 时入 ACTIONS.HEAL)，是治疗类物品自用的真实动作 id。
-- USEITEM 来自 useableitem 收集器。
local INVENTORY_SELF_ACTIONS = {
    EQUIP = true,
    UNEQUIP = true,
    EAT = true,
    USEITEM = true,
    HEAL = true,
    DROP = true,
    MURDER = true,
}

-- [喵喵喵]: 物品对物品的合法动作集合(仍要与 picker 选中的那个完全一致才下发)。
-- USEITEM 收集器里 healer 也会入 ACTIONS.HEAL(把药用在别的持有物品/没有上)。
local INVENTORY_ON_ITEM_ACTIONS = {
    USEITEM = true,
    EAT = true,
    HEAL = true,
    FEED = true,
    FILL = true,
    SEW = true,
}

local function get_inventory_replica(player)
    local rep = player.replica
    return rep ~= nil and rep.inventory or nil
end

-- [喵喵喵]: 持有关系判定：客户端走 replica.inventoryitem:IsGrandOwner(已含溢出背包)
-- (inventoryitem_replica.lua:210)，主机再补一次 components.inventoryitem:GetGrandOwner()。
-- 注意它赋值给上面前置声明的 local(不能用 local function，否则前面的 kind 看不到)。
item_owned_by = function(item, player)
    if item == nil or not is_valid(item) or player == nil then
        return false
    end
    local rep = item.replica
    local invitem = rep ~= nil and rep.inventoryitem or nil
    if invitem ~= nil and invitem.IsGrandOwner ~= nil then
        local ok, yes = pcall(function() return invitem:IsGrandOwner(player) end)
        if ok then
            return yes == true
        end
    end
    local comp = item.components ~= nil and item.components.inventoryitem or nil
    if comp ~= nil and comp.GetGrandOwner ~= nil then
        local ok, owner = pcall(function() return comp:GetGrandOwner() end)
        if ok then
            return owner == player
        end
    end
    return false
end

-- [喵喵喵]: 原生方法用的是 equippable:IsEquipped()；客户端用 replica，主机退回 components。
local function item_is_equipped(item)
    local rep = item.replica ~= nil and item.replica.equippable or nil
    if rep ~= nil and rep.IsEquipped ~= nil then
        local ok, yes = pcall(function() return rep:IsEquipped() end)
        if ok then
            return yes == true
        end
    end
    local comp = item.components ~= nil and item.components.equippable or nil
    if comp ~= nil and comp.IsEquipped ~= nil then
        local ok, yes = pcall(function() return comp:IsEquipped() end)
        if ok then
            return yes == true
        end
    end
    return false
end

-- [喵喵喵]: 在玩家的 replica 装备槽里找这个精确实体；第二个返回值表示槽表是否可读。
local function find_equip_slot(player, item)
    local inv = get_inventory_replica(player)
    if inv == nil or inv.GetEquips == nil then
        return nil, false
    end
    local ok, equips = pcall(function() return inv:GetEquips() end)
    if not ok or type(equips) ~= "table" then
        return nil, false
    end
    for slot, v in pairs(equips) do
        if v == item then
            return slot, true
        end
    end
    return nil, true
end

local function item_stack_size(item)
    if not is_valid(item) then
        return nil
    end
    local rep = item.replica
    local stackable = rep ~= nil and rep.stackable or nil
    if stackable ~= nil and stackable.StackSize ~= nil then
        local ok, n = pcall(function() return stackable:StackSize() end)
        if ok and is_finite_number(n) then
            return n
        end
    end
    local comp = item.components ~= nil and item.components.stackable or nil
    if comp ~= nil and comp.StackSize ~= nil then
        local ok, n = pcall(function() return comp:StackSize() end)
        if ok and is_finite_number(n) then
            return n
        end
    end
    return nil
end

local function count_items_in(list, prefab)
    local total = 0
    if type(list) ~= "table" then
        return total
    end
    for _, v in pairs(list) do
        if v ~= nil and v.prefab == prefab then
            total = total + (item_stack_size(v) or 1)
        end
    end
    return total
end

-- [喵喵喵]: “这个 prefab 在我(app 背包槽 + 装备槽 + 溢出背包)里还有多少件”。
-- 溢出背包里的物品也算持有；读不到任何一份清单时返回 nil(不下成功结论)。
local function count_owned_prefab(player, prefab)
    if type(prefab) ~= "string" then
        return nil
    end
    local inv = get_inventory_replica(player)
    if inv == nil then
        return nil
    end
    local readable = false
    local total = 0
    if inv.GetItems ~= nil then
        local ok, items = pcall(function() return inv:GetItems() end)
        if ok and type(items) == "table" then
            readable = true
            total = total + count_items_in(items, prefab)
        end
    end
    if inv.GetEquips ~= nil then
        local ok, equips = pcall(function() return inv:GetEquips() end)
        if ok and type(equips) == "table" then
            readable = true
            total = total + count_items_in(equips, prefab)
        end
    end
    if inv.GetOverflowContainer ~= nil then
        local okc, container = pcall(function() return inv:GetOverflowContainer() end)
        if okc and container ~= nil and container.GetItems ~= nil then
            local oki, items = pcall(function() return container:GetItems() end)
            if oki and type(items) == "table" then
                readable = true
                total = total + count_items_in(items, prefab)
            end
        end
    end
    return readable and total or nil
end

local function inventory_key(intent)
    if type(intent.action) ~= "string" then
        return nil
    end
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil
    end
    return string.format("inventory|%s|%s|%s|%s",
        tostring(action.id),
        to_key_ref(intent.item), to_key_ref(intent.target_item),
        tostring(intent.id))
end

local function prepare_inventory(player, intent)
    if type(intent.action) ~= "string" then
        return nil, "inventory_needs_string_id"
    end
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil, "action_unknown:" .. intent.action
    end
    local item = intent.item
    if item == nil then
        return nil, "inventory_needs_item"
    end
    if not is_valid(item) then
        return nil, "inventory_item_invalid"
    end
    local target_item = intent.target_item
    if target_item ~= nil then
        if not is_valid(target_item) then
            return nil, "inventory_target_item_invalid"
        end
        if target_item == item then
            return nil, "inventory_target_is_item"
        end
    end
    -- [喵喵喵]: 精确动作必须在受支持集合里，否则不下发(避免无声换成别的动作)。
    if target_item ~= nil then
        if INVENTORY_ON_ITEM_ACTIONS[intent.action] ~= true then
            return nil, "unsupported_inventory_action:" .. intent.action
        end
    elseif INVENTORY_SELF_ACTIONS[intent.action] ~= true then
        return nil, "unsupported_inventory_action:" .. intent.action
    end
    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "inventory_bad_confirm"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "inventory_bad_priority"
    end
    -- [喵喵喵]: 所有权必须在 prepare 与下发前各查一次(背包可能中途被拿走)。
    if not item_owned_by(item, player) then
        return nil, "item_not_owned"
    end
    if target_item ~= nil and not item_owned_by(target_item, player) then
        return nil, "target_item_not_owned"
    end
    if intent.action == "UNEQUIP" then
        if target_item ~= nil then
            return nil, "inventory_target_not_supported_for:UNEQUIP"
        end
        if not item_is_equipped(item) then
            return nil, "item_not_equipped"
        end
        if item:HasTag("heavy") then
            return nil, "heavy_item_unequip_unsupported"
        end
        if type(GetGameModeProperty) == "function" and GetGameModeProperty("non_item_equips") then
            return nil, "unequip_not_available_in_gamemode"
        end
    end
    local key = inventory_key(intent)
    if key == nil then
        return nil, "inventory_bad_intent_key"
    end
    return {
        kind = "inventory",
        key = key,
        id = intent.id,
        action_id = intent.action,
        action = action,
        item = item,
        target_item = target_item,
        prefab = item.prefab,
        intent = intent,
        confirm = intent.confirm,
        priority = priority,
        -- [喵喵喵]: 与其它 kind 一样必须有有限截止时间。
        deadline = now() + Actions.DEFAULT_TIMEOUT,
        dispatched = false,
        -- [喵喵喵]: 背包动作走原版 Inventory 复制品方法发 RPC/推 locomotor 缓冲，
        -- 那个 BufferedAction 不是我们的，本地无处可撤。
        no_prediction = true,
    }
end

local function same_action(cand_action, op)
    return cand_action ~= nil
        and cand_action.code ~= nil
        and cand_action.code == op.action.code
        and cand_action.mod_name == op.action.mod_name
end

-- [喵喵喵]: 原生 GetMapTarget 非 nil 时 classified 会去开地图而不是发 RPC：这种也不下发。
local function map_target_redirect(pc, buff)
    if pc.GetMapTarget == nil or buff == nil then
        return false
    end
    local ok, maptarget = pcall(function() return pc:GetMapTarget(buff) end)
    return ok and maptarget ~= nil
end

-- [喵喵喵]: classified / components 两边都会先判 busy，busy 时它们什么都不发：
-- 这里先判，避免“标记已下发但其实没发”把操作卡到截止时间。
local function inventory_busy(player, pc)
    if pc.IsBusy ~= nil then
        local ok, busy = pcall(function() return pc:IsBusy() end)
        if ok and busy then
            return true
        end
    end
    if player.HasTag ~= nil and player:HasTag("busy") then
        return true
    end
    local sg = player.sg
    return sg ~= nil and sg.HasStateTag ~= nil and sg:HasStateTag("busy") == true
end

local function capture_inventory_baseline(player, pc, op)
    op.baseline_stack = item_stack_size(op.item)
    op.baseline_total = count_owned_prefab(player, op.prefab)
    if op.target_item ~= nil then
        op.baseline_target_stack = item_stack_size(op.target_item)
        op.baseline_target_prefab = op.target_item.prefab
        op.baseline_target_total = count_owned_prefab(player, op.baseline_target_prefab)
    end
    if op.action_id == "EQUIP" or op.action_id == "UNEQUIP" then
        local slot = find_equip_slot(player, op.item)
        op.baseline_equip_slot = slot
    end
    -- [喵喵喵]: 治疗类另存一份“可见资源状态”基线(replica.health:GetCurrent)，
    -- 作为“物品真的被用掉了”的补充证据。
    if op.action_id == "HEAL" then
        op.baseline_health = get_health(player)
    end
end

local function dispatch_inventory(player, pc, op)
    -- [喵喵喵]: 下发前重查所有权与目标有效性(背包可能已被别人拿走/物品已消失)。
    if not is_valid(op.item) then
        return false, "item_gone", true
    end
    if not item_owned_by(op.item, player) then
        return false, "item_not_owned", true
    end
    local inv = get_inventory_replica(player)
    if inv == nil then
        return false, "inventory_replica_unavailable", true
    end
    if inventory_busy(player, pc) then
        return false, "inventory_busy"
    end

    if op.action_id == "DROP" then
        if inv.DropItemFromInvTile == nil then return false, "drop_method_unavailable", true end
        if op.item:HasTag("heavy") or item_is_equipped(op.item) then return false, "drop_requires_inventory_item", true end
        local x, z = get_xz(player)
        if x == nil or TheWorld.Map:IsOceanAtPoint(x, 0, z) then return false, "drop_requires_ground", true end
        local picker = player.components.playeractionpicker
        if picker == nil then return false, "picker_unavailable", true end
        local choices = picker:GetPointActions(Vector3(x, 0, z), op.item, false, nil)
        local drop_allowed = false
        for _, choice in ipairs(choices or {}) do
            if choice.action == ACTIONS.DROP then drop_allowed = true break end
        end
        if not drop_allowed then return false, "drop_not_available", true end
        capture_inventory_baseline(player, pc, op)
        op.drop_x, op.drop_z = x, z
        inv:DropItemFromInvTile(op.item, false)
        return true
    end

    local target_item = op.target_item
    if target_item ~= nil then
        -- [喵喵喵]: 物品对物品：原生复制品方法参数顺序是 (item=被用的目标, active_item=使用的物品)。
        if not is_valid(target_item) then
            return false, "target_item_gone", true
        end
        if not item_owned_by(target_item, player) then
            return false, "target_item_not_owned", true
        end
        if pc.GetItemUseAction == nil then
            return false, "picker_unavailable", true
        end
        local ok, cand = pcall(function() return pc:GetItemUseAction(op.item, target_item) end)
        if not ok then
            return false, "picker_error", true
        end
        if cand == nil or cand.action == nil then
            return false, "action_unavailable:" .. op.action_id, true
        end
        if not same_action(cand.action, op) then
            return false, "action_mismatch:" .. tostring(cand.action.id), true
        end
        if map_target_redirect(pc, cand) then
            return false, "map_target_redirect", true
        end
        if inv.ControllerUseItemOnItemFromInvTile == nil then
            return false, "replica_method_missing:ControllerUseItemOnItemFromInvTile", true
        end
        capture_inventory_baseline(player, pc, op)
        inv:ControllerUseItemOnItemFromInvTile(target_item, op.item)
        return true
    end

    -- [喵喵喵]: 无目标：只走“对自己/对这个物品本身”的原生方法，不碰光标物品。
    if op.action_id == "UNEQUIP" then
        if not item_is_equipped(op.item) then
            return false, "item_not_equipped", true
        end
        -- [喵喵喵]: 原生卸下分支还要求背包有槽位(主机 maxslots>0 / 客户端 _items 非空)，
        -- 这里按可读的槽位数再挡一次，挡不住就交给原生(它不发就会沉默到截止时间)。
        if inv.GetNumSlots ~= nil then
            local okn, nslots = pcall(function() return inv:GetNumSlots() end)
            if okn and is_finite_number(nslots) and nslots <= 0 then
                return false, "unequip_no_inventory_slot", true
            end
        end
    end

    local picker = player.components.playeractionpicker
    if picker == nil or picker.GetInventoryActions == nil then
        return false, "picker_unavailable", true
    end
    -- [喵喵喵]: GetItemSelfAction 在键鼠 deploy_mode 下直接返回 nil；显式物品沿原生 picker 和动作发送链路执行，不依赖输入模式。 (2026-11-11)
    local ok, cand = pcall(function()
        return picker:GetInventoryActions(op.item, true)[1] or picker:GetInventoryActions(op.item, false)[1]
    end)
    if not ok then
        return false, "picker_error", true
    end
    if cand == nil or cand.action == nil then
        return false, "action_unavailable:" .. op.action_id, true
    end
    if not same_action(cand.action, op) then
        return false, "action_mismatch:" .. tostring(cand.action.id), true
    end
    if map_target_redirect(pc, cand) then
        return false, "map_target_redirect", true
    end
    op.buffaction = cand
    if player.components.inventory ~= nil then
        if player.components.locomotor == nil then return false, "locomotor_unavailable", true end
        capture_inventory_baseline(player, pc, op)
        player.components.locomotor:PushAction(cand, true)
    else
        if pc.RemoteControllerUseItemOnSelfFromInvTile == nil then
            return false, "controller_method_missing:RemoteControllerUseItemOnSelfFromInvTile", true
        end
        capture_inventory_baseline(player, pc, op)
        pc:RemoteControllerUseItemOnSelfFromInvTile(cand, op.item)
    end
    return true
end

local function check_inventory(player, pc, op)
    -- [喵喵喵]: 调用方 confirm 优先(真主机/原版服务端回调由上层转述)。
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    if op.action_id == "DROP" then
        -- [喵喵喵]: 丢下物品须确认同一实体落在下发位置，不能把消失/总数下降当作布置陷阱。 (2026-11-11)
        if is_valid(op.item) and not op.item:HasTag("INLIMBO") and not item_owned_by(op.item, player) then
            local x, z = get_xz(op.item)
            if x ~= nil and (x - op.drop_x) ^ 2 + (z - op.drop_z) ^ 2 <= 9 then
                return "succeeded", "item_on_ground"
            end
        end
        return "pending", "awaiting_ground_item"
    end

    if op.action_id == "EQUIP" then
        local slot, readable = find_equip_slot(player, op.item)
        if readable and slot ~= nil then
            return "succeeded", "equipped:" .. tostring(slot)
        end
        return "pending", "awaiting_confirmation"
    end

    if op.action_id == "UNEQUIP" then
        local slot, readable = find_equip_slot(player, op.item)
        if readable and slot == nil and op.baseline_equip_slot ~= nil then
            -- [喵喵喵]: 出槽之外还必须“仍在持有中”，被剔除/掉落不算完成。
            if item_owned_by(op.item, player) then
                return "succeeded", "unequipped:was:" .. tostring(op.baseline_equip_slot)
            end
            return "pending", "unequipped_not_owned_yet"
        end
        return "pending", "awaiting_confirmation"
    end

    -- [喵喵喵]: 消耗类(EAT/自用/物品对物品)：只认堆叠数或总持有量在基线之后下降。
    local stack = item_stack_size(op.item)
    if op.baseline_stack ~= nil and stack ~= nil and stack < op.baseline_stack then
        return "succeeded", string.format("stack_reduced:%s->%s", tostring(op.baseline_stack), tostring(stack))
    end
    local total = count_owned_prefab(player, op.prefab)
    if op.baseline_total ~= nil and total ~= nil and total < op.baseline_total then
        return "succeeded", string.format("total_reduced:%s->%s", tostring(op.baseline_total), tostring(total))
    end
    if op.target_item ~= nil then
        local tstack = item_stack_size(op.target_item)
        if op.baseline_target_stack ~= nil and tstack ~= nil and tstack < op.baseline_target_stack then
            return "succeeded", string.format("target_stack_reduced:%s->%s",
                tostring(op.baseline_target_stack), tostring(tstack))
        end
        local ttotal = count_owned_prefab(player, op.baseline_target_prefab)
        if op.baseline_target_total ~= nil and ttotal ~= nil and ttotal < op.baseline_target_total then
            return "succeeded", string.format("target_total_reduced:%s->%s",
                tostring(op.baseline_target_total), tostring(ttotal))
        end
    end

    -- [喵喵喵]: 治疗类：血量在基线之后真的涨了(可见资源状态变化)。
    if op.baseline_health ~= nil then
        local hp = get_health(player)
        if hp ~= nil and hp > op.baseline_health + 0.000001 then
            return "succeeded", string.format("healed:%.3f->%.3f", op.baseline_health, hp)
        end
    end

    -- [喵喵喵]: 实体消失(含剔除)本身不是完成证据；持有关系丢了但总量没降同样不算。
    if not is_valid(op.item) or not item_owned_by(op.item, player) then
        return "pending", "consumption_unconfirmed"
    end
    return "pending", "awaiting_confirmation"
end

PIPELINE.inventory = {
    prepare = prepare_inventory,
    dispatch = dispatch_inventory,
    check = check_inventory,
    identify = inventory_key,
}

--============================================================================
-- [喵喵喵]: kind="transfer"：只在“源槽位”与“目标容器/背包”之间搬真实物品，
-- 全程复用原生复制品方法(inventory_replica.lua:584-608 / container_replica.lua:621-643
-- → classified → RPC.MoveInvItemFrom(All|Count)OfSlot / RPC.MoveItemFrom(All|Count)OfSlot)：
--   * 源：本地玩家的 inventory 复制品，或一个客户端可读的容器 container 复制品。
--   * 目标：本地玩家自己(容器→背包)或容器实体(含 equip 在 BODY 上的溢出背包)。
--   * 原生 components/inventory.lua:2513,2613 只认 container.components.container，
--     所以“背包→另一个背包”没有服务端分支；container 源则同时支持 inventory 目标。
-- 绝不动活动光标物品、绝不 DROP 兜底、绝不用“物品消失”当完成证据。
--============================================================================

local function container_replica_of(ent)
    if ent == nil then
        return nil
    end
    local rep = ent.replica
    return rep ~= nil and rep.container or nil
end

-- [喵喵喵]: 溢出背包：replica:GetOverflowContainer() 返回容器复制品(不是实体)，
-- 目标实体取它的 .inst(客户端即 HUD 中那个便携容器)。
local function get_overflow_entity(player)
    local inv = get_inventory_replica(player)
    if inv == nil or inv.GetOverflowContainer == nil then
        return nil
    end
    local ok, cont = pcall(function() return inv:GetOverflowContainer() end)
    if not ok or cont == nil then
        return nil
    end
    return cont.inst
end

local function count_prefab_in_container(cont, prefab)
    if cont == nil or type(prefab) ~= "string" or cont.GetItems == nil then
        return nil
    end
    local ok, items = pcall(function() return cont:GetItems() end)
    if not ok or type(items) ~= "table" then
        return nil
    end
    return count_items_in(items, prefab)
end

-- [喵喵喵]: 玩家侧聚合量：物品槽 + 装备槽(+ 溢出背包)。
-- skip_container 用来排除“本次搬运的源容器就是溢出背包”的情况，否则把背包里的
-- 东西搬回背包时聚合量恒不变，会永远看不出来。
local function player_owned_prefab_count(player, prefab, skip_container)
    if type(prefab) ~= "string" then
        return nil
    end
    local inv = get_inventory_replica(player)
    if inv == nil then
        return nil
    end
    local readable = false
    local total = 0
    if inv.GetItems ~= nil then
        local ok, items = pcall(function() return inv:GetItems() end)
        if ok and type(items) == "table" then
            readable = true
            total = total + count_items_in(items, prefab)
        end
    end
    if inv.GetEquips ~= nil then
        local ok, equips = pcall(function() return inv:GetEquips() end)
        if ok and type(equips) == "table" then
            readable = true
            total = total + count_items_in(equips, prefab)
        end
    end
    if inv.GetOverflowContainer ~= nil then
        local okc, container = pcall(function() return inv:GetOverflowContainer() end)
        if okc and container ~= nil and container.inst ~= skip_container and container.GetItems ~= nil then
            local oki, items = pcall(function() return container:GetItems() end)
            if oki and type(items) == "table" then
                readable = true
                total = total + count_items_in(items, prefab)
            end
        end
    end
    return readable and total or nil
end

-- [喵喵喵]: 槽位读取：主机走 components，客户端走 classified(未由我们打开的容器返回 nil)。
-- 第二个返回值表示“这份清单到底可不可读”，不可读时绝不下成功结论。
local function read_slot_item(replica_owner, slot)
    if replica_owner == nil or replica_owner.GetItemInSlot == nil then
        return nil, false
    end
    local ok, item = pcall(function() return replica_owner:GetItemInSlot(slot) end)
    if not ok then
        return nil, false
    end
    return item, true
end

local function container_replica_busy(cont)
    if cont == nil or cont.IsBusy == nil then
        return false
    end
    local ok, busy = pcall(function() return cont:IsBusy() end)
    return ok and busy == true
end

local function is_positive_integer(v)
    return type(v) == "number" and v == math.floor(v) and v >= 1
end

-- [喵喵喵]: 原生 components/inventory.lua:2514 / container.lua:1335 遇到
-- islockedinslot 的物品直接 return(什么都不搬)；客户端在
-- inventoryitem_replica.lua:127-128 可读到该标记，这里先如实拒绝。
local function item_locked_in_slot(item)
    local rep = item ~= nil and item.replica or nil
    local invitem = rep ~= nil and rep.inventoryitem or nil
    if invitem == nil or invitem.IsLockedInSlot == nil then
        return false
    end
    local ok, locked = pcall(function() return invitem:IsLockedInSlot() end)
    return ok and locked == true
end

local function transfer_destination_replica(player, op)
    if op.destination_mode == "player" then
        return get_inventory_replica(player)
    end
    local dest = op.destination
    if dest == nil or not is_valid(dest) then
        return nil
    end
    return container_replica_of(dest)
end

-- [喵喵喵]: 目标聚合量：容器读它自己的槽位汇总；玩家读物品槽+装备槽(+溢出)。
-- 源容器恰好是溢出背包时排除它自己，避免“自己搬自己”的恒等。
local function destination_prefab_total(player, op, destination_replica)
    if op.destination_mode == "player" then
        local skip = op.source_mode == "container" and op.source or nil
        return player_owned_prefab_count(player, op.prefab, skip)
    end
    return count_prefab_in_container(destination_replica, op.prefab)
end

local function transfer_key(intent)
    if intent.source == nil or intent.destination == nil then
        return nil
    end
    if not is_positive_integer(intent.slot) then
        return nil
    end
    local count_key = "all"
    if intent.count ~= nil then
        if not is_positive_integer(intent.count) then
            return nil
        end
        count_key = tostring(intent.count)
    end
    -- [喵喵喵]: 身份只由意图字段算出(GUID/数字/字符串)，实体失效后仍能算出同一身份。
    return string.format("transfer|%s|%d|%s|%s|%s",
        to_key_ref(intent.source), intent.slot, to_key_ref(intent.destination),
        count_key, tostring(intent.id))
end

local function prepare_transfer(player, intent)
    local source = intent.source
    if source == nil then
        return nil, "transfer_needs_source"
    end
    if not is_valid(source) then
        return nil, "transfer_source_invalid"
    end
    local destination = intent.destination
    if destination == nil then
        return nil, "transfer_needs_destination"
    end
    if not is_valid(destination) then
        return nil, "transfer_destination_invalid"
    end
    if source == destination then
        return nil, "transfer_source_is_destination"
    end
    if not is_positive_integer(intent.slot) then
        return nil, "transfer_bad_slot"
    end
    if intent.count ~= nil and not is_positive_integer(intent.count) then
        return nil, "transfer_bad_count"
    end
    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "transfer_bad_confirm"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "transfer_bad_priority"
    end

    -- [喵喵喵]: 源只能是自己背包或客户端可读容器；别的玩家背包从客户端根本拿不到。
    local source_mode, source_replica
    if source == player then
        source_mode = "inventory"
        source_replica = get_inventory_replica(player)
        if source_replica == nil then
            return nil, "inventory_replica_unavailable"
        end
    else
        source_replica = container_replica_of(source)
        if source_replica ~= nil then
            source_mode = "container"
        elseif source.replica ~= nil and source.replica.inventory ~= nil then
            return nil, "transfer_source_not_local_player"
        else
            return nil, "transfer_source_not_supported"
        end
    end

    -- [喵喵喵]: 目标：自己(容器→背包)或容器实体。非本机玩家的 inventory 目的地在原生
    -- classified 里会被发成 nil(destcontainer 为空 → 服务端塞回发起者)，等于偷偷换目的地。
    local destination_mode, destination_replica
    if destination == player then
        destination_mode = "player"
        destination_replica = get_inventory_replica(player)
        if destination_replica == nil then
            return nil, "inventory_replica_unavailable"
        end
    else
        destination_replica = container_replica_of(destination)
        if destination_replica ~= nil then
            destination_mode = "container"
        elseif destination.replica ~= nil and destination.replica.inventory ~= nil then
            return nil, "transfer_destination_player_not_local"
        else
            return nil, "transfer_destination_not_supported"
        end
    end

    -- [喵喵喵]: 原生只有 container 目标分支(components/inventory.lua:2513,2613 /
    -- networkclientrpc.lua:862-896)，背包→背包没有实现。
    if source_mode == "inventory" and destination_mode == "player" then
        return nil, "transfer_inventory_to_inventory_unsupported"
    end

    -- [喵喵喵]: 世界容器必须此刻就在 GetOpenContainers() 里(客户端 HUD 可见、
    -- 服务端 opencontainers / IsOpenedBy 一致)；当前溢出背包例外(它不一定“打开”)，
    -- 但只豁免“此刻自己那个溢出背包实体”，别的未打开容器照旧拒绝。
    local open = get_open_containers(player)
    if open == nil then
        return nil, "transfer_open_containers_unavailable"
    end
    local overflow_entity = get_overflow_entity(player)
    if source_mode == "container" then
        local source_is_overflow = overflow_entity ~= nil and source == overflow_entity
        if not source_is_overflow and open[source] ~= true then
            return nil, "transfer_source_not_open"
        end
        if container_replica_busy(source_replica) then
            return nil, "transfer_source_busy"
        end
    end
    if destination_mode == "container" then
        local is_overflow = overflow_entity ~= nil and destination == overflow_entity
        if not is_overflow and open[destination] ~= true then
            return nil, "transfer_destination_not_open"
        end
    end

    -- [喵喵喵]: 源槽位必须真的有一个我们认得出的物品；数量以此刻为准。
    local item, readable = read_slot_item(source_replica, intent.slot)
    if not readable then
        return nil, "transfer_source_slots_unreadable"
    end
    if item == nil then
        return nil, "transfer_source_slot_empty"
    end
    if not is_valid(item) then
        return nil, "transfer_source_item_invalid"
    end
    if item_locked_in_slot(item) then
        return nil, "transfer_source_locked"
    end
    local prefab = item.prefab
    if type(prefab) ~= "string" then
        return nil, "transfer_source_item_unidentified"
    end
    local qty = item_stack_size(item) or 1
    if intent.count ~= nil and intent.count > qty then
        -- [喵喵喵]: 原生 MoveItemFromCountOfSlot 会 math.clamp(count,1,fullstacksize)，
        -- 那等于悄悄改搬运量：这里直接拒绝，绝不下发一个“实际数量不同”的请求。
        return nil, string.format("transfer_count_exceeds_source:%d>%s", intent.count, tostring(qty))
    end

    -- [喵喵喵]: 目标满且没有同 prefab 可合并堆叠时，原生 ReceiveItem 会返回 nil 而
    -- 什么都不发(沉默)，这里提前如实拒绝。读不到就不断言“满”，交给完成判定。
    local dest_prefab_count = destination_prefab_total(player, {
        destination_mode = destination_mode,
        source_mode = source_mode,
        source = source,
        prefab = prefab,
    }, destination_replica)
    if destination_replica ~= nil and destination_replica.IsFull ~= nil then
        local okf, full = pcall(function() return destination_replica:IsFull() end)
        if okf and full == true and (dest_prefab_count == nil or dest_prefab_count <= 0) then
            return nil, "transfer_destination_full"
        end
    end

    local key = transfer_key(intent)
    if key == nil then
        return nil, "transfer_bad_intent_key"
    end
    return {
        kind = "transfer",
        key = key,
        id = intent.id,
        intent = intent,
        confirm = intent.confirm,
        priority = priority,
        source = source,
        source_mode = source_mode,
        slot = intent.slot,
        destination = destination,
        destination_mode = destination_mode,
        count = intent.count,
        item = item,
        prefab = prefab,
        -- [喵喵喵]: 与其它 kind 一样必须有有限截止时间。
        deadline = now() + Actions.DEFAULT_TIMEOUT,
        dispatched = false,
        -- [喵喵喵]: 搬运走原生复制品方法发 RPC/改本地副本，那个 BufferedAction 不是我们的，
        -- 本地无处可撤，Cancel 只能清本地记录。
        no_prediction = true,
    }
end

local function dispatch_transfer(player, pc, op)
    -- [喵喵喵]: 下发前把源/目标权限、打开状态、源槽位实体再查一遍：任何一项变了就不发。
    local source_replica
    if op.source_mode == "inventory" then
        source_replica = get_inventory_replica(player)
    elseif op.source ~= nil and is_valid(op.source) then
        source_replica = container_replica_of(op.source)
    end
    if source_replica == nil then
        return false, "transfer_source_gone", true
    end

    local open = get_open_containers(player)
    if open == nil then
        return false, "transfer_open_containers_unavailable", true
    end
    local overflow_entity = get_overflow_entity(player)

    if op.source_mode == "container" then
        -- [喵喵喵]: 与 prepare 一致：源是“此刻自己那个溢出背包实体”时豁免打开状态，
        -- 其余容器源仍必须真的在打开集合里；槽位/实体/数量校验一律保留。
        local source_is_overflow = overflow_entity ~= nil and op.source == overflow_entity
        if not source_is_overflow and open[op.source] ~= true then
            return false, "transfer_source_closed", true
        end
        if container_replica_busy(source_replica) then
            return false, "transfer_source_busy"
        end
    end

    local destination_replica
    if op.destination_mode == "player" then
        destination_replica = get_inventory_replica(player)
        if destination_replica == nil then
            return false, "inventory_replica_unavailable", true
        end
    else
        local dest = op.destination
        if dest == nil or not is_valid(dest) then
            return false, "transfer_destination_gone", true
        end
        destination_replica = container_replica_of(dest)
        if destination_replica == nil then
            return false, "transfer_destination_gone", true
        end
        local is_overflow = overflow_entity ~= nil and dest == overflow_entity
        if not is_overflow and open[dest] ~= true then
            return false, "transfer_destination_closed", true
        end
        if container_replica_busy(destination_replica) then
            return false, "transfer_destination_busy"
        end
    end

    -- [喵喵喵]: 必须是 prepare 时那一个精确实体还在同一个槽位里(被换掉就重新起意图)。
    local item, readable = read_slot_item(source_replica, op.slot)
    if not readable then
        return false, "transfer_source_slots_unreadable", true
    end
    if item ~= op.item or item == nil then
        return false, "transfer_source_changed", true
    end
    if item_locked_in_slot(item) then
        return false, "transfer_source_locked", true
    end
    local qty = item_stack_size(item) or 1
    if op.count ~= nil and op.count > qty then
        return false, string.format("transfer_count_exceeds_source:%d>%s", op.count, tostring(qty)), true
    end

    -- [喵喵喵]: 真基线就在这一刻取：源精确数量 + 目标聚合量(之后只拿这两个数对比)。
    op.dispatch_qty = qty
    local baseline = destination_prefab_total(player, op, destination_replica)
    if baseline == nil then
        return false, "transfer_destination_unreadable", true
    end
    op.baseline_destination_total = baseline

    local method = op.count == nil and "MoveItemFromAllOfSlot" or "MoveItemFromCountOfSlot"
    if source_replica[method] == nil then
        return false, "replica_method_missing:" .. method, true
    end
    local okc, err = pcall(function()
        if op.count == nil then
            source_replica:MoveItemFromAllOfSlot(op.slot, op.destination)
        else
            source_replica:MoveItemFromCountOfSlot(op.slot, op.destination, op.count)
        end
    end)
    if not okc then
        return false, "transfer_dispatch_error:" .. tostring(err), true
    end
    return true
end

local function check_transfer(player, pc, op)
    -- [喵喵喵]: 调用方 confirm 优先(真主机/上层转述的原生回调)。
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    -- [喵喵喵]: 源：只认“同一个精确实体还在同一槽位、堆叠数下降”，或它已经不在那个槽位(空)。
    -- 槽位里换成别的实体一律不算——那是被换掉，不是搬走。
    local source_replica
    if op.source_mode == "inventory" then
        source_replica = get_inventory_replica(player)
    elseif op.source ~= nil and is_valid(op.source) then
        source_replica = container_replica_of(op.source)
    end
    local src_now
    if source_replica ~= nil then
        local item, readable = read_slot_item(source_replica, op.slot)
        if readable then
            if item == nil then
                src_now = 0
            elseif item == op.item then
                src_now = item_stack_size(item) or 1
            else
                return "pending", "source_slot_replaced_unconfirmed"
            end
        end
    end

    local destination_replica = transfer_destination_replica(player, op)
    if op.destination_mode == "container" and destination_replica == nil then
        return "pending", "destination_unavailable_unconfirmed"
    end
    local dest_now = destination_prefab_total(player, op, destination_replica)

    local baseline_src = op.dispatch_qty
    local baseline_dest = op.baseline_destination_total
    local src_drop = (baseline_src ~= nil and src_now ~= nil) and (baseline_src - src_now) or nil
    local dest_gain = (baseline_dest ~= nil and dest_now ~= nil) and (dest_now - baseline_dest) or nil

    if src_drop ~= nil and src_drop > 0 then
        if dest_gain ~= nil and dest_gain > 0 then
            -- [喵喵喵]: 两边都动过才叫搬到了；部分搬运(原生允许)如实标注。
            local partial = src_drop < baseline_src or (op.count ~= nil and src_drop < op.count)
            return "succeeded", string.format("%s:src:%s->%s|dest:%s->%s",
                partial and "transferred_partial" or "transferred",
                tostring(baseline_src), tostring(src_now),
                tostring(baseline_dest), tostring(dest_now))
        end
        -- [喵喵喵]: 源少了但目标没涨：可能被别人拿走/被剔除/部分进别处，绝不当成功。
        if dest_now == nil then
            return "pending", "destination_unreadable_unconfirmed"
        end
        return "pending", "destination_increment_unconfirmed"
    end
    if dest_gain ~= nil and dest_gain > 0 then
        -- [喵喵喵]: 目标涨了但源没降：来源不明(可能是别的来源给的)，不认。
        return "pending", "source_decrement_unconfirmed"
    end
    return "pending", "awaiting_confirmation"
end

PIPELINE.transfer = {
    prepare = prepare_transfer,
    dispatch = dispatch_transfer,
    check = check_transfer,
    identify = transfer_key,
}

--============================================================================
-- [喵喵喵]: kind="craft"：只做一次“玩家在制作栏点这个配方”的原版制作。
--   非放置类：replica.builder:MakeRecipeFromMenu(recipe)
--   放置类  ：replica.builder:MakeRecipeAtPoint(recipe, Vector3(x,0,z), rot)
-- 所有门槛按原版按钮流程(widgets/widgetutil.lua:52-165)重算一遍，不做任何
-- 物品/材料/科技/免费建造的发放；CanBuild 只是过时的 HasIngredients 别名，
-- 不能作为“会做这个配方”的证据，所以一概不用。
-- 服务端真实行为参考：components/builder.lua:1041-1124(MakeRecipeFromMenu/AtPoint，
-- 都要求背包界面 IsOpenedBy(self)、放置类还要求 IsBuildBuffered 与 CanDeployRecipeAtPoint)、
-- 629-839(MakeRecipe/DoBuild，推 builditem/buildstructure 并扣材料)、
-- networkclientrpc.lua:937-988(两个 RPC 的入参校验：rpc_id/数字坐标/rot/64 码内)。
-- 完成判定绝不看材料减少（那是扣材料，不是做成了），只看产品上升/原位新增/主机事件/confirm。
--============================================================================

-- [喵喵喵]: 附近扫描的范围与上限：只做“有界的可见扫描”，超上限就当作没有证据。
local CRAFT_SCAN_RADIUS = 8
local CRAFT_SCAN_MAX = 200
-- [喵喵喵]: 原生 MakeRecipe 在 components/builder.lua:630 会拒掉这些状态标签。
local CRAFT_BLOCKING_STATE_TAGS = {
    "drowning", "falling", "floating", "nointerrupt", "nopredict", "pausepredict",
}

local function get_builder_replica(player)
    local rep = player.replica
    return rep ~= nil and rep.builder or nil
end

local function builder_is_busy(builder)
    if builder == nil or builder.IsBusy == nil then
        return false
    end
    local ok, busy = pcall(function() return builder:IsBusy() end)
    return ok and busy == true
end

local function builder_knows_recipe(builder, recipe)
    if builder == nil or builder.KnowsRecipe == nil then
        return false
    end
    local ok, v = pcall(function() return builder:KnowsRecipe(recipe) end)
    return ok and v == true
end

local function builder_has_ingredients(builder, recipe)
    if builder == nil or builder.HasIngredients == nil then
        return false
    end
    local ok, v = pcall(function() return builder:HasIngredients(recipe) end)
    return ok and v == true
end

local function builder_can_learn(builder, recipename)
    if builder == nil or builder.CanLearn == nil then
        return false
    end
    local ok, v = pcall(function() return builder:CanLearn(recipename) end)
    return ok and v == true
end

local function builder_is_build_buffered(builder, recipename)
    if builder == nil or builder.IsBuildBuffered == nil then
        return false
    end
    local ok, v = pcall(function() return builder:IsBuildBuffered(recipename) end)
    return ok and v == true
end

local function builder_get_tech_trees(builder)
    if builder == nil or builder.GetTechTrees == nil then
        return nil
    end
    local ok, v = pcall(function() return builder:GetTechTrees() end)
    return ok and v or nil
end

local function builder_can_build_at_point(builder, pt, recipe, rot)
    if builder == nil or builder.CanBuildAtPoint == nil then
        return false
    end
    local ok, v = pcall(function() return builder:CanBuildAtPoint(pt, recipe, rot) end)
    return ok and v == true
end

-- [喵喵喵]: 与原生全局 CanPrototypeRecipe(widgets/widgetutil.lua:16-24)同一算法，
-- 自己算是为了不依赖 HUD 模块的全局；客户端 techtrees 是纯数字表
-- (prefabs/player_classified.lua:1525/563-564)，所以可以直接比大小。
local function can_prototype_recipe(recipetree, buildertree)
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

local function get_recipe(name)
    if type(GetValidRecipe) ~= "function" then
        return nil
    end
    local ok, recipe = pcall(GetValidRecipe, name)
    if not ok or type(recipe) ~= "table" then
        return nil
    end
    return recipe
end

-- [喵喵喵]: 产品实际会给多少个：原生 DoBuild 用 override_numtogive_fn or numtogive
-- (components/builder.lua:737)；这只是“期望值”，只用于报告，绝不参与完成判定。
local function expected_product_qty(recipe, player)
    if type(recipe.override_numtogive_fn) == "function" then
        local ok, v = pcall(recipe.override_numtogive_fn, recipe, player)
        if ok and is_finite_number(v) and v >= 1 then
            return math.floor(v)
        end
    end
    if is_finite_number(recipe.numtogive) and recipe.numtogive >= 1 then
        return math.floor(recipe.numtogive)
    end
    return 1
end

local function player_state_blocks_craft(player)
    local sg = player.sg
    if sg == nil or sg.HasStateTag == nil then
        return false
    end
    for _, tag in ipairs(CRAFT_BLOCKING_STATE_TAGS) do
        local ok, v = pcall(function() return sg:HasStateTag(tag) end)
        if ok and v == true then
            return true
        end
    end
    return false
end

-- [喵喵喵]: 同一 prefab 是否已经在槽位清单里(避免与光标物品重复计数)。
local function inventory_lists_contain(inv, ent)
    local function has(list)
        if type(list) ~= "table" then
            return false
        end
        for _, v in pairs(list) do
            if v == ent then
                return true
            end
        end
        return false
    end
    if inv == nil then
        return false
    end
    if inv.GetItems ~= nil then
        local ok, items = pcall(function() return inv:GetItems() end)
        if ok and has(items) then
            return true
        end
    end
    if inv.GetEquips ~= nil then
        local ok, equips = pcall(function() return inv:GetEquips() end)
        if ok and has(equips) then
            return true
        end
    end
    return false
end

-- [喵喵喵]: 产品持有量 = 背包槽 + 装备槽 + 溢出背包(count_owned_prefab)
-- + 光标上正在举着的那一个(inventory_replica.lua:308 GetActiveItem)。
-- 例：可穿戴产品被原生自动穿上、溢出背包里的产品、手上还举着的那一份，都算。
local function craft_owned_total(player, prefab)
    local total = count_owned_prefab(player, prefab)
    if total == nil then
        return nil
    end
    local inv = get_inventory_replica(player)
    if inv ~= nil and inv.GetActiveItem ~= nil then
        local ok, active = pcall(function() return inv:GetActiveItem() end)
        if ok and is_valid(active) and active.prefab == prefab and not inventory_lists_contain(inv, active) then
            total = total + (item_stack_size(active) or 1)
        end
    end
    return total
end

-- [喵喵喵]: 目标点附近这个 prefab 的实体数(有界扫描；读不到/超上限返回 nil，即“无证据”)。
local function count_nearby_prefab(x, z, radius, prefab, cap)
    if not is_finite_number(x) or not is_finite_number(z) or type(prefab) ~= "string" then
        return nil
    end
    if TheSim == nil or TheSim.FindEntities == nil then
        return nil
    end
    local ok, ents = pcall(function() return TheSim:FindEntities(x, 0, z, radius) end)
    if not ok or type(ents) ~= "table" then
        return nil
    end
    local n, scanned = 0, 0
    for _, ent in ipairs(ents) do
        scanned = scanned + 1
        if scanned > cap then
            return nil
        end
        if ent ~= nil and ent.prefab == prefab then
            n = n + 1
        end
    end
    return n
end

-- [喵喵喵]: 主机侧“本次制作的精确原生事件”：DoBuild 在 builder 本人身上推
-- builditem / buildstructure(components/builder.lua:723/783)。客户端不会复制这两个事件，
-- 所以只在主机装监听；每个本地玩家只装一次(弱键)，触发时只认 OWNED 里那条 craft。
-- 门槛不能用 op.dispatched：主机侧 MakeRecipeFromMenu/AtPoint → MakeRecipe →
-- locomotor:PushAction(components/builder.lua:637) 有可能在同一次调用里就把
-- BUILD 动作执行掉(instant/do_not_locomote/已在范围内)，也就是说 builditem 会先于
-- 共享 poll() 打上 dispatched 就发出来。所以改成“我们发出 MakeRecipe* 之前就上膛”
-- 的 op.build_event_armed：窗口只覆盖本操作自己那一次原生调用（含它之后异步完成）。
local CRAFT_HOOKS = setmetatable({}, { __mode = "k" })

local function on_craft_build_event(inst, data)
    local player = inst
    if player == nil then
        return
    end
    local op = OWNED[player]
    if op == nil or op.kind ~= "craft" or op.build_event_armed ~= true then
        return
    end
    -- [喵喵喵]: 仍然只认“这个配方 + 这个产品”：别的配方/产品的建造事件与我们无关。
    local recipe = data ~= nil and data.recipe or nil
    if recipe == nil or recipe.name ~= op.recipe_name then
        return
    end
    local product = data.item ~= nil and data.item.prefab or nil
    if product ~= nil and op.product ~= nil and product ~= op.product then
        return
    end
    if op.host_build_event == nil then
        op.host_build_event = product or op.product
    end
end

local function ensure_craft_hook(player)
    if CRAFT_HOOKS[player] ~= nil or player.ListenForEvent == nil then
        return
    end
    CRAFT_HOOKS[player] = true
    player:ListenForEvent("builditem", on_craft_build_event, player)
    player:ListenForEvent("buildstructure", on_craft_build_event, player)
end

-- [喵喵喵]: 已在事件里拿到本操作的证据后就不再需要监听，拆掉，不留长期回调。
local function release_craft_hook(player)
    if CRAFT_HOOKS[player] == nil then
        return
    end
    CRAFT_HOOKS[player] = nil
    if player.RemoveEventCallback == nil then
        return
    end
    pcall(function() player:RemoveEventCallback("builditem", on_craft_build_event, player) end)
    pcall(function() player:RemoveEventCallback("buildstructure", on_craft_build_event, player) end)
end

local function craft_key(intent)
    if type(intent.recipe) ~= "string" then
        return nil
    end
    local point = "-"
    if is_finite_number(intent.x) and is_finite_number(intent.z) then
        point = string.format("%.3f_%.3f", intent.x, intent.z)
    end
    local rot = is_finite_number(intent.rotation) and string.format("%.2f", intent.rotation) or "-"
    -- [喵喵喵]: 身份只由意图字段算出，配方/位置消失后仍能算出同一身份。
    return string.format("craft|%s|%s|%s|%s", intent.recipe, point, rot, tostring(intent.id))
end

local function prepare_craft(player, intent)
    if type(intent.recipe) ~= "string" then
        return nil, "craft_needs_recipe"
    end
    local recipe = get_recipe(intent.recipe)
    if recipe == nil then
        return nil, "craft_recipe_unknown:" .. intent.recipe
    end
    -- [喵喵喵]: RPC 只带 recipe.rpc_id(networkclientrpc.lua:937-988)，没有 rpc_id 的配方无法下发。
    if not is_finite_number(recipe.rpc_id) then
        return nil, "craft_recipe_not_registered:" .. intent.recipe
    end
    if type(recipe.product) ~= "string" then
        return nil, "craft_recipe_without_product:" .. intent.recipe
    end

    local placer = recipe.placer ~= nil
    local x, z, rotation
    if intent.x ~= nil or intent.z ~= nil then
        if not is_finite_number(intent.x) or not is_finite_number(intent.z) then
            return nil, "craft_bad_point"
        end
        if math.abs(intent.x) > Actions.WORLD_LIMIT or math.abs(intent.z) > Actions.WORLD_LIMIT then
            return nil, "craft_point_out_of_world"
        end
        x, z = intent.x, intent.z
    end
    if placer and (x == nil or z == nil) then
        return nil, "craft_placer_needs_point"
    end
    if intent.rotation ~= nil and not is_finite_number(intent.rotation) then
        return nil, "craft_bad_rotation"
    end
    rotation = intent.rotation or 0

    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "craft_bad_confirm"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "craft_bad_priority"
    end

    local builder = get_builder_replica(player)
    if builder == nil then
        return nil, "builder_replica_unavailable"
    end

    -- [喵喵喵]: 原生客户端拿不到 current_prototyper / petleash 的真实状态，
    -- 这几种配方只能显式拒绝，绝不下发后把“没反应”当完成。
    if recipe.manufactured then
        return nil, "craft_manufactured_needs_station:" .. intent.recipe
    end
    if type(recipe.level) == "table" and is_finite_number(recipe.level.ORPHANAGE)
        and recipe.level.ORPHANAGE > 0 then
        return nil, "craft_orphanage_check_unsupported:" .. intent.recipe
    end
    if recipe.unlocks_from_skin then
        return nil, "craft_skin_unlock_unsupported:" .. intent.recipe
    end

    -- [喵喵喵]: 原版点击流程的四个门槛：缓冲建造 / 已知 / 可试制(科技+CanLearn) / 有材料。
    local buffered = builder_is_build_buffered(builder, intent.recipe)
    if not buffered then
        if not builder_knows_recipe(builder, recipe) then
            if not can_prototype_recipe(recipe.level, builder_get_tech_trees(builder)) then
                return nil, "craft_no_tech:" .. intent.recipe
            end
            if not builder_can_learn(builder, intent.recipe) then
                return nil, "craft_builder_gate:" .. intent.recipe
            end
        end
        if not builder_has_ingredients(builder, recipe) then
            return nil, "craft_missing_ingredients:" .. intent.recipe
        end
    end

    -- [喵喵喵]: 服务端 MakeRecipeAtPoint 走 RPC 时要求点在 64 码内(networkclientrpc.lua:43-45)。
    if placer then
        local px, pz = get_xz(player)
        if px ~= nil then
            local d2 = (px - x) ^ 2 + (pz - z) ^ 2
            if d2 > 64 * 64 then
                return nil, string.format("craft_point_out_of_range:%.2f", math.sqrt(d2))
            end
        end
    end

    local key = craft_key(intent)
    if key == nil then
        return nil, "craft_bad_intent_key"
    end

    local dist = 0
    if placer then
        local px, pz = get_xz(player)
        if px ~= nil then
            dist = math.sqrt((px - x) ^ 2 + (pz - z) ^ 2)
        end
    end
    return {
        kind = "craft",
        key = key,
        id = intent.id,
        recipe = recipe,
        recipe_name = intent.recipe,
        product = recipe.product,
        prefab = recipe.product,
        placer = placer,
        x = x,
        z = z,
        rotation = rotation,
        expected_qty = expected_product_qty(recipe, player),
        intent = intent,
        confirm = intent.confirm,
        priority = priority,
        deadline = now() + math.min(Actions.DEFAULT_TIMEOUT + dist * Actions.TIMEOUT_PER_UNIT, Actions.TIMEOUT_MAX),
        dispatched = false,
        -- [喵喵喵]: 制作走原生 replica 方法(自己造 BufferedAction 或自己发 RPC)，
        -- 那条动作不是我们的，本地无处可撤。
        no_prediction = true,
    }
end

-- [喵喵喵]: 真基线就在下发那一刻取：产品持有量 + 目标点附近该 prefab 的实体数。
local function capture_craft_baseline(player, op)
    op.baseline_owned = craft_owned_total(player, op.product)
    local px, pz
    if op.placer then
        px, pz = op.x, op.z
    else
        px, pz = get_xz(player)
    end
    if is_finite_number(px) and is_finite_number(pz) then
        op.point_x, op.point_z = px, pz
        op.baseline_near = count_nearby_prefab(px, pz, CRAFT_SCAN_RADIUS, op.product, CRAFT_SCAN_MAX)
    end
end

local function dispatch_craft(player, pc, op)
    local builder = get_builder_replica(player)
    if builder == nil then
        return false, "builder_replica_unavailable", true
    end
    -- [喵喵喵]: 原版按钮会先看 owner:HasTag("busy") 与 builder:IsBusy()(widgetutil.lua:58)，
    -- 这两条是“等一下再做”的软条件，不占掉下发次数。
    if builder_is_busy(builder) then
        return false, "craft_builder_busy"
    end
    if player.HasTag ~= nil and player:HasTag("busy") then
        return false, "craft_player_busy"
    end
    if player_state_blocks_craft(player) then
        return false, "craft_player_state_blocked"
    end
    local inv = get_inventory_replica(player)
    if inv == nil then
        return false, "inventory_replica_unavailable", true
    end
    -- [喵喵喵]: 服务端两个 MakeRecipe* 都要求背包界面此刻由自己打开(builder.lua:1042/1114)，
    -- 不满足就是静默 return，这一条必须在下发前挡掉。
    if inv.IsOpenedBy == nil then
        return false, "replica_method_missing:IsOpenedBy", true
    end
    local okopen, opened = pcall(function() return inv:IsOpenedBy(player) end)
    if not okopen then
        return false, "inventory_replica_error", true
    end
    if opened ~= true then
        return false, "craft_inventory_closed"
    end

    local recipe = op.recipe
    if recipe == nil then
        return false, "craft_recipe_lost", true
    end
    local buffered = builder_is_build_buffered(builder, op.recipe_name)
    -- [喵喵喵]: 材料可能在 prepare 之后被吃掉（原件会重新判一次），这里再判一次。
    if not buffered then
        if not builder_has_ingredients(builder, recipe) then
            return false, "craft_missing_ingredients:" .. op.recipe_name, true
        end
        if not (builder_knows_recipe(builder, recipe)
            or (can_prototype_recipe(recipe.level, builder_get_tech_trees(builder))
                and builder_can_learn(builder, op.recipe_name))) then
            return false, "craft_not_known:" .. op.recipe_name, true
        end
    end

    if op.placer then
        local pt = Vector3(op.x, 0, op.z)
        if not builder_can_build_at_point(builder, pt, recipe, op.rotation) then
            -- [喵喵喵]: 材料还没被缓冲吃掉时可以当场判死；已经缓冲过就再等一下，
            -- 那一点可能只是暂时被东西占住了(材料已扣，没必要立刻放弃)。
            if buffered then
                return false, "craft_point_blocked_waiting"
            end
            return false, "craft_cannot_build_at_point", true
        end
        if not buffered then
            -- [喵喵喵]: 服务端 MakeRecipeAtPoint 必须已被缓冲(builder.lua:1117-1121)，
            -- 所以先走原版路径发一次 BufferBuild(原版点按钮就是这么做的)，
            -- 等“已缓冲”可见后再发 MakeRecipeAtPoint；每次操作只发一次 BufferBuild。
            if op.buffer_sent then
                return false, "buffered_build_unconfirmed"
            end
            if builder.BufferBuild == nil then
                return false, "replica_method_missing:BufferBuild", true
            end
            local okb, errb = pcall(function() builder:BufferBuild(op.recipe_name) end)
            if not okb then
                return false, "craft_buffer_error:" .. tostring(errb), true
            end
            op.buffer_sent = true
            return false, "buffered_build_requested"
        end
        capture_craft_baseline(player, op)
        ensure_craft_hook(player)
        if builder.MakeRecipeAtPoint == nil then
            return false, "replica_method_missing:MakeRecipeAtPoint", true
        end
        -- [喵喵喵]: 上膛后才发：同一次调用里就可能同步推出 builditem/buildstructure。
        op.build_event_armed = true
        local okd, errd = pcall(function() builder:MakeRecipeAtPoint(recipe, pt, op.rotation) end)
        if not okd then
            op.build_event_armed = nil
            return false, "craft_dispatch_error:" .. tostring(errd), true
        end
        op.recipe = nil
        return true
    end

    capture_craft_baseline(player, op)
    ensure_craft_hook(player)
    if builder.MakeRecipeFromMenu == nil then
        return false, "replica_method_missing:MakeRecipeFromMenu", true
    end
    -- [喵喵喵]: 同上：先上膛再发，避免丢掉同步事件。
    op.build_event_armed = true
    local okd, errd = pcall(function() builder:MakeRecipeFromMenu(recipe) end)
    if not okd then
        op.build_event_armed = nil
        return false, "craft_dispatch_error:" .. tostring(errd), true
    end
    op.recipe = nil
    return true
end

local function check_craft(player, pc, op)
    -- [喵喵喵]: 调用方 confirm 优先（主机/上层转述原生回调）。
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    -- [喵喵喵]: 主机侧本次操作的精确原生事件（builditem / buildstructure）。
    if op.host_build_event ~= nil then
        local prefab = op.host_build_event
        op.host_build_event = nil
        op.build_event_armed = nil
        release_craft_hook(player)
        return "succeeded", string.format("host_build_event:%s", tostring(prefab))
    end

    -- [喵喵喵]: 产品持有量上升（背包/装备/溢出/光标都算），并按期望数量标注是否足额。
    local owned_now = craft_owned_total(player, op.product)
    if op.baseline_owned ~= nil and owned_now ~= nil and owned_now > op.baseline_owned then
        local gained = owned_now - op.baseline_owned
        local expected = op.expected_qty
        return "succeeded", string.format("%s:%s:%s->%s|expected:%s",
            (expected ~= nil and gained >= expected) and "built_products" or "built_products_partial",
            tostring(op.product), tostring(op.baseline_owned), tostring(owned_now), tostring(expected))
    end

    -- [喵喵喵]: 目标点附近新增了这个 prefab 的实体（结构/掉落在地上、不进背包的产品）。
    if op.baseline_near ~= nil and op.point_x ~= nil then
        local near_now = count_nearby_prefab(op.point_x, op.point_z, CRAFT_SCAN_RADIUS, op.product, CRAFT_SCAN_MAX)
        if near_now ~= nil and near_now > op.baseline_near then
            return "succeeded", string.format("built_near_point:%s:%s->%s",
                tostring(op.product), tostring(op.baseline_near), tostring(near_now))
        end
    end

    -- [喵喵喵]: 材料变少、配方变已知都不是完成证据（上面根本没查它们），继续等。
    if op.placer and op.buffer_sent and not builder_is_build_buffered(get_builder_replica(player), op.recipe_name) then
        return "pending", "buffered_build_unconfirmed"
    end
    return "pending", "build_unconfirmed"
end

PIPELINE.craft = {
    prepare = prepare_craft,
    dispatch = dispatch_craft,
    check = check_craft,
    identify = craft_key,
}

--============================================================================
-- [喵喵喵]: kind="use"：把“自己已持有的某个物品”对场景实体/场景点做一次原版下发。
-- 两条互斥链路(详见文件头 intent(kind="use") 段)：
--   实体 → pc:GetItemUseAction(item, target) 算出原生动作，主机 DoAction，
--          客户端 RemoteControllerUseItemOnSceneFromInvTile(原生 scene-from-invtile 路径)；
--   点    → 原生控制器部署链路(RPC.ControllerActionButtonDeploy / OnRemoteControllerActionButtonDeploy)，
--          按 ACTIONS.DEPLOY / ACTIONS.DEPLOY_FLOATING 原生表同一性判定，且必须真的出现在
--          GetPointActions(pos, item, right=true) 候选里。
-- 不自造执行器、不改光标、不伪造服务端效果；未知/不匹配动作一律拒绝。
--============================================================================

-- [喵喵喵]: 点部署的产物扫描上限：有界，超上限返回 nil=“无证据”。
local USE_POINT_SCAN_RADIUS = 3
local USE_POINT_SCAN_MAX = 200

-- [喵喵喵]: 前置声明：期望产物判定实现在下面(需要“本 kind 只认可核实副作用”的说明集中在一处)。
local use_effect_spec

local function use_key(intent)
    if type(intent.action) ~= "string" then
        return nil
    end
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil
    end
    local where
    if intent.target ~= nil then
        where = "e:" .. to_key_ref(intent.target)
    elseif is_finite_number(intent.x) and is_finite_number(intent.z) then
        -- [喵喵喵]: 点模式的身份按厘米取整，避免浮点抖动让同一意图换 key。
        where = string.format("p:%d:%d",
            math.floor(intent.x * 100 + 0.5), math.floor(intent.z * 100 + 0.5))
    else
        return nil
    end
    return string.format("use|%s|%s|%s|%s",
        tostring(action.id), to_key_ref(intent.item), where, tostring(intent.id))
end

local function prepare_use(player, intent)
    if type(intent.action) ~= "string" then
        return nil, "use_needs_string_id"
    end
    -- [喵喵喵]: 只接受原版 ACTIONS 里的字符串 id，避免造自定义动作。
    local action = ACTIONS[intent.action]
    if action == nil or action.code == nil then
        return nil, "action_unknown:" .. intent.action
    end
    local item = intent.item
    if item == nil then
        return nil, "use_needs_item"
    end
    if not is_valid(item) then
        return nil, "use_item_invalid"
    end
    if intent.confirm ~= nil and type(intent.confirm) ~= "function" then
        return nil, "use_bad_confirm"
    end
    if intent.rotation ~= nil and not is_finite_number(intent.rotation) then
        return nil, "use_bad_rotation"
    end
    local priority = intent.priority == nil and Actions.DEFAULT_PRIORITY or intent.priority
    if not is_finite_number(priority) then
        return nil, "use_bad_priority"
    end
    local target = intent.target
    local mode
    if target ~= nil then
        if not is_valid(target) then
            return nil, "use_target_invalid"
        end
        if target == item then
            return nil, "use_target_is_item"
        end
        mode = "entity"
    else
        mode = "point"
    end
    local has_x = intent.x ~= nil
    if has_x ~= (intent.z ~= nil) then
        return nil, "use_needs_both_x_and_z"
    end
    local x, z = intent.x, intent.z
    if not has_x then
        if mode ~= "entity" then
            return nil, "use_needs_target_or_x_z"
        end
        x, z = get_xz(target)
    end
    if not is_finite_number(x) or not is_finite_number(z) then
        if mode == "point" then
            return nil, "use_needs_finite_x_z"
        end
        -- [喵喵喵]: 实体链路根本不用坐标，目标没有坐标不是错误。
        x, z = nil, nil
    elseif math.abs(x) > Actions.WORLD_LIMIT or math.abs(z) > Actions.WORLD_LIMIT then
        return nil, "use_point_out_of_world"
    end
    -- [喵喵喵]: 点模式只保留原生“控制器部署”能携带显式物品的那两个动作(原生 action 表同一性)。
    -- 其它点动作没有任何原生 RPC 能把物品送到点上，直接拒绝而不是伪造。
    if mode == "point" and action ~= ACTIONS.DEPLOY and action ~= ACTIONS.DEPLOY_FLOATING then
        return nil, "point_use_unsupported:" .. intent.action
    end
    -- [喵喵喵]: 所有权必须在 prepare 与下发前各查一次(物品可能中途被拿走)。
    if not item_owned_by(item, player) then
        return nil, "item_not_owned"
    end
    local key = use_key(intent)
    if key == nil then
        return nil, "use_bad_intent_key"
    end
    local op = {
        kind = "use",
        key = key,
        id = intent.id,
        action_id = intent.action,
        action = action,
        item = item,
        prefab = item.prefab,
        target = target,
        mode = mode,
        x = x,
        z = z,
        rotation = intent.rotation,
        intent = intent,
        confirm = intent.confirm,
        priority = priority,
        -- [喵喵喵]: 与其它 kind 一样必须有有限截止时间。
        deadline = now() + Actions.DEFAULT_TIMEOUT,
        dispatched = false,
    }
    -- [喵喵喵]: 期望产物只在这里一次性确定(只从原生源码映射，不猜字符串)。
    use_effect_spec(op)
    return op
end

-- [喵喵喵]: 期望产物 prefab 只从原生源码取，绝不猜字符串、也绝不把“随便一个新实体”当产物：
--  * 部署类：prefab 函数在客户端与主机都会在 SetPristine 之前写 inst.deploy_product
--    (prefabs/boat.lua:1500-1509 / 1520-1532)，而 ondeploy 就是
--    SpawnPrefab(inst.deploy_product, ...)(prefabs/boat.lua:723-724)，所以两边都读得到。
--  * 烹饪类：产物只存在于服务端 components/cookable.lua 的 product 字段
--    (prefabs/acorn.lua:98-99 在 ismastersim 之后才设)，客户端没有任何 cookable 复制品，
--    所以只有主机能读；客户端读不到就绝不猜，只能等调用方 confirm。
local function use_deploy_product(item)
    if item == nil or not is_valid(item) then
        return nil
    end
    local product = item.deploy_product
    if type(product) == "string" and product ~= "" then
        return product
    end
    return nil
end

local function use_cook_product(item)
    if item == nil or not is_valid(item) then
        return nil
    end
    local comp = item.components ~= nil and item.components.cookable or nil
    if comp == nil then
        return nil
    end
    local product = comp.product
    if type(product) == "string" and product ~= "" then
        return product
    end
    return nil
end

-- [喵喵喵]: 相关副作用种类(只认可核实的那两类)：
--   "near_point_product" 点部署 → 预期产物真的出现在目标点附近；
--   "inventory_product" 火堆烹饪 → 预期熟食真的回到自己背包(ACTIONS.COOK.fn
--   actions.lua:2030-2033 把产物 GiveItem 给 doer)。
-- 读不到预期产物(effect_kind 为 nil)时，本 kind 绝不靠“东西没了”或“多了个东西”认成功，
-- 只等调用方 confirm / 主机侧原生成功，否则到截止时间如实报失败。
-- [喵喵喵]: 赋值给上面前置声明的 local(不能用 local function，否则 prepare_use 看不到)。
use_effect_spec = function(op)
    if op.mode == "point" then
        local product = use_deploy_product(op.item)
        if product ~= nil then
            op.effect_kind = "near_point_product"
            op.product = product
        end
    else
        local product = use_cook_product(op.item)
        if product ~= nil then
            op.effect_kind = "inventory_product"
            op.product = product
        end
    end
end

-- [喵喵喵]: 基线只取客户端可见事实：物品堆叠/持有量 + 预期产物的现有数量。
local function capture_use_baseline(player, op)
    op.baseline_stack = item_stack_size(op.item)
    op.baseline_total = count_owned_prefab(player, op.prefab)
    if op.effect_kind == "near_point_product" and op.product ~= nil then
        op.baseline_product = count_nearby_prefab(op.x, op.z, USE_POINT_SCAN_RADIUS, op.product, USE_POINT_SCAN_MAX)
    elseif op.effect_kind == "inventory_product" and op.product ~= nil then
        op.baseline_product = count_owned_prefab(player, op.product)
    end
end

-- [喵喵喵]: 预期产物的现时数量；读不到(未设基线/扫描不可用)一律返回 nil，即“无证据”。
local function use_product_now(player, op)
    if op.effect_kind == "near_point_product" then
        return count_nearby_prefab(op.x, op.z, USE_POINT_SCAN_RADIUS, op.product, USE_POINT_SCAN_MAX)
    elseif op.effect_kind == "inventory_product" then
        return count_owned_prefab(player, op.product)
    end
    return nil
end

-- [喵喵喵]: 复刻 PlayerController:DoAction 的“重复动作短路”(playercontroller.lua:4590-4605)：
-- 缓冲里已经是同一个 action+target+pos 时原生直接 return，一个字节都不发；
-- 这种情况绝不能当作“已下发”，否则会把用户/别人正在做的动作算成我们的结果。
local function do_action_would_skip(player, act)
    if player.GetBufferedAction == nil then
        return false
    end
    local ok, cur = pcall(function() return player:GetBufferedAction() end)
    if not ok or cur == nil then
        return false
    end
    if cur.action ~= act.action or cur.target ~= act.target then
        return false
    end
    local same_pos = (cur.pos == nil and act.pos == nil) or (cur.pos == act.pos)
    if not same_pos then
        return false
    end
    local previewing_idle = cur.ispreviewing == true
        and player.HasTag ~= nil and player:HasTag("idle")
        and player.sg ~= nil and player.sg.HasStateTag ~= nil and player:HasStateTag("idle")
    return not previewing_idle
end

-- [喵喵喵]: 实体目标：只用原生 GetItemUseAction 算动作，绝不自己拼 BufferedAction。
local function dispatch_use_entity(player, pc, op)
    local target = op.target
    if not is_valid(target) then
        return false, "target_gone", true
    end
    if type(CanEntitySeeTarget) == "function" and not CanEntitySeeTarget(player, target) then
        return false, "target_not_visible", true
    end
    if pc.GetItemUseAction == nil then
        return false, "picker_unavailable", true
    end
    local ok, act = pcall(function() return pc:GetItemUseAction(op.item, target) end)
    if not ok then
        return false, "picker_error", true
    end
    if act == nil or act.action == nil then
        return false, "action_unavailable:" .. op.action_id
    end
    -- [喵喵喵]: 原生此刻选中的动作必须就是请求的那个(精确 code+mod_name)，绝不默默换。
    if not same_action(act.action, op) then
        return false, "action_mismatch:" .. tostring(act.action.id)
    end
    -- [喵喵喵]: 这三类不是“物品用于场景”，不在这条链路的语义里。
    if act.action == ACTIONS.UNEQUIP or act.action == ACTIONS.DROP or act.action == ACTIONS.WALKTO then
        return false, "action_unsupported:" .. tostring(act.action.id), true
    end
    if act.target ~= target then
        return false, "action_target_mismatch", true
    end
    if act.invobject ~= op.item then
        return false, "action_item_mismatch", true
    end
    if map_target_redirect(pc, act) then
        return false, "map_target_redirect", true
    end

    if pc.ismastersim then
        if do_action_would_skip(player, act) then
            return false, "duplicate_action_buffered"
        end
        capture_use_baseline(player, op)
        op.result = nil
        act:AddSuccessAction(function()
            if OWNED[player] == op then op.result = "succeeded" end
        end)
        act:AddFailAction(function()
            if OWNED[player] == op then op.result = "failed" end
        end)
        pc:DoAction(act)
        op.buffaction = act
        return true
    end

    if pc.RemoteControllerUseItemOnSceneFromInvTile == nil then
        return false, "controller_method_missing:RemoteControllerUseItemOnSceneFromInvTile", true
    end
    -- [喵喵喵]: 有预测时才谈 CanLocomote；无预测客户端那条方法会直接发一次 RPC。
    if pc.locomotor ~= nil and pc.CanLocomote ~= nil and not pc:CanLocomote() then
        return false, "cannot_locomote_prediction"
    end
    capture_use_baseline(player, op)
    pc:RemoteControllerUseItemOnSceneFromInvTile(act, op.item)
    if pc.locomotor ~= nil then
        op.buffaction = act
    else
        op.no_prediction = true
    end
    return true
end

-- [喵喵喵]: 点部署：只走原生控制器部署链路(RPC 自己带 item，不动光标)；
-- 下发前必须让原生 GetPointActions 真的给出这个动作，并核对 DEPLOY/DEPLOY_FLOATING 原生选择。
local function dispatch_use_point(player, pc, op)
    if not is_finite_number(op.x) or not is_finite_number(op.z) then
        return false, "use_needs_finite_x_z", true
    end
    -- [喵喵喵]: 原生 RPC 入口在 IsPointInRange(distsq <= 4096，即 64 单位；
    -- networkclientrpc.lua:43-46) 之外会直接丢弃包，什么都不会发生。
    -- 先在客户端可见位置判一次，避免“标记已下发但其实被丢包”卡到截止时间。
    local px, pz = get_xz(player)
    if px ~= nil then
        local dx, dz = op.x - px, op.z - pz
        if dx * dx + dz * dz > 4096 then
            return false, "point_out_of_rpc_range", true
        end
    end
    local picker = player.components ~= nil and player.components.playeractionpicker or nil
    if picker == nil or picker.GetPointActions == nil then
        return false, "picker_unavailable", true
    end
    local pt = Vector3(op.x, 0, op.z)
    -- [喵喵喵]: right=true 是原版部署的语义(componentactions.lua:2072 deployable 收集器要求 right)。
    local okp, cands = pcall(function() return picker:GetPointActions(pt, op.item, true, nil) end)
    if not okp or type(cands) ~= "table" then
        return false, "picker_error", true
    end
    local matched = nil
    for _, cand in ipairs(cands) do
        if cand ~= nil and cand.action ~= nil and same_action(cand.action, op)
            and cand.invobject == op.item then
            matched = cand
            break
        end
    end
    if matched == nil then
        return false, "point_action_unavailable:" .. op.action_id, true
    end
    -- [喵喵喵]: 原生只在“手持漂浮物 + boatbuilder”时选 DEPLOY_FLOATING，否则 DEPLOY
    -- (playercontroller.lua:1051-1059 / placer.lua:215-229)。客户端可读 IsFloaterHeld，
    -- 因此两边都能核对，不会把请求的动作悄悄换成另一个。
    local floating = false
    local inv = get_inventory_replica(player)
    if inv ~= nil and inv.IsFloaterHeld ~= nil then
        local okf, held = pcall(function() return inv:IsFloaterHeld() end)
        floating = okf and held == true
    end
    local derived = (floating and op.item:HasTag("boatbuilder")) and ACTIONS.DEPLOY_FLOATING or ACTIONS.DEPLOY
    if derived ~= op.action then
        return false, "deploy_action_mismatch:" .. tostring(derived.id), true
    end
    if pc.GetPlatformRelativePosition == nil then
        return false, "controller_method_missing:GetPlatformRelativePosition", true
    end
    local platform, rx, rz = pc:GetPlatformRelativePosition(op.x, op.z)
    if not is_finite_number(rx) or not is_finite_number(rz) then
        return false, "no_click_point", true
    end
    local rotation = is_finite_number(op.rotation) and op.rotation or 0

    if pc.ismastersim then
        -- [喵喵喵]: 与 OnRemoteControllerActionButtonDeploy 的构造完全一致(distance=1)。
        local act = BufferedAction(player, nil, derived, op.item, Vector3(op.x, 0, op.z), nil, 1, nil, rotation)
        if do_action_would_skip(player, act) then
            return false, "duplicate_action_buffered"
        end
        capture_use_baseline(player, op)
        op.result = nil
        act:AddSuccessAction(function()
            if OWNED[player] == op then op.result = "succeeded" end
        end)
        act:AddFailAction(function()
            if OWNED[player] == op then op.result = "failed" end
        end)
        pc:DoAction(act)
        op.buffaction = act
        return true
    end

    if pc.locomotor ~= nil and pc.CanLocomote ~= nil and not pc:CanLocomote() then
        return false, "cannot_locomote_prediction"
    end
    if RPC == nil or RPC.ControllerActionButtonDeploy == nil then
        return false, "rpc_missing:ControllerActionButtonDeploy", true
    end
    capture_use_baseline(player, op)
    -- [喵喵喵]: isreleased=true = 一次已松手点击，发完立刻把控件还回 nil。
    local send = function()
        pc.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
        SendRPCToServer(RPC.ControllerActionButtonDeploy, op.item, rx, rz,
            rotation ~= 0 and rotation or nil, true, platform, platform ~= nil)
        pc.remote_controls[CONTROL_CONTROLLER_ACTION] = nil
    end
    if pc.locomotor == nil then
        send()
        op.no_prediction = true
        return true
    end
    local act = BufferedAction(player, nil, derived, op.item, Vector3(op.x, 0, op.z), nil, 1, nil, rotation)
    act.preview_cb = send
    pc.locomotor:PreviewAction(act, true)
    op.buffaction = act
    return true
end

local function dispatch_use(player, pc, op)
    -- [喵喵喵]: 下发前重查物品有效性与所有权(可能已被别人拿走/用掉)。
    if not is_valid(op.item) then
        return false, "item_gone", true
    end
    if not item_owned_by(op.item, player) then
        return false, "item_not_owned", true
    end
    if get_inventory_replica(player) == nil then
        return false, "inventory_replica_unavailable", true
    end
    if inventory_busy(player, pc) then
        return false, "use_busy"
    end
    if op.mode == "point" then
        return dispatch_use_point(player, pc, op)
    end
    return dispatch_use_entity(player, pc, op)
end

local function check_use(player, pc, op)
    -- [喵喵喵]: 主机侧原生成功/失败最权威，优先。
    if op.result == "succeeded" then
        return "succeeded", "host_action_succeeded"
    elseif op.result == "failed" then
        return "failed", "host_action_failed"
    end
    if op.confirm ~= nil then
        local ok, done = pcall(op.confirm, player, op.intent)
        if ok and done == true then
            return "succeeded", "caller_confirmed"
        end
    end

    -- [喵喵喵]: 消耗只是“相关副作用”的必要条件之一，单独绝不算成功
    -- (东西没了可能是别人用掉/被剔除，实体消失/所有权转移从来不是完成证据)。
    local consumed
    local stack = item_stack_size(op.item)
    if op.baseline_stack ~= nil and stack ~= nil and stack < op.baseline_stack then
        consumed = string.format("stack:%s->%s", tostring(op.baseline_stack), tostring(stack))
    else
        local total = count_owned_prefab(player, op.prefab)
        if op.baseline_total ~= nil and total ~= nil and total < op.baseline_total then
            consumed = string.format("total:%s->%s", tostring(op.baseline_total), tostring(total))
        end
    end

    -- [喵喵喵]: 只有“预期产物真的出现”才算动作相关副作用(产物 prefab 来自原生源码：
    -- 部署物品的 inst.deploy_product / 服务端 cookable.product)；不认“随便多了一个实体”。
    local effect
    if op.effect_kind ~= nil and op.product ~= nil and op.baseline_product ~= nil then
        local now_n = use_product_now(player, op)
        if now_n ~= nil and now_n > op.baseline_product then
            effect = string.format("%s:%s:%s->%s", tostring(op.effect_kind), tostring(op.product),
                tostring(op.baseline_product), tostring(now_n))
        end
    end

    if consumed ~= nil and effect ~= nil then
        return "succeeded", string.format("correlated_effect:%s|%s|%s",
            tostring(op.prefab), consumed, effect)
    end
    if effect ~= nil then
        -- [喵喵喵]: 产物出现了但物品没少 → 可能是别人的动作，继续保持 pending 直到 deadline。
        return "pending", "effect_without_consumption:" .. effect
    end
    -- [喵喵喵]: 看不到预期副作用就是未确认；消耗、所有权转移、实体消失一律不当成功。
    if op.effect_kind == nil then
        return "pending", "effect_unconfirmed:no_readable_effect"
    elseif op.baseline_product == nil then
        return "pending", "effect_unconfirmed:no_baseline:" .. tostring(op.product)
    end
    return "pending", "effect_unconfirmed:" .. tostring(op.product)
end

PIPELINE.use = {
    prepare = prepare_use,
    dispatch = dispatch_use,
    check = check_use,
    identify = use_key,
}

-- [喵喵喵]: 释放只针对我们自己那条本地 BufferedAction；别人的动作/控件一律不碰。
local function release_local(player, op)
    op.deadline = nil
    local work_released = release_work_control(player, op)
    local buff = op.buffaction
    op.buffaction = nil
    if buff == nil then
        return work_released, work_released and "released_work_control" or "not_current_action"
    end
    local pc = player.components ~= nil and player.components.playercontroller or nil
    local loco = pc ~= nil and pc.locomotor or nil
    local cleared = false
    if loco ~= nil and loco.bufferedaction == buff then
        loco:Clear()
        cleared = true
    end
    if player.bufferedaction == buff then
        player:ClearBufferedAction()
        cleared = true
    end
    if not cleared then
        return work_released, work_released and "released_work_control" or "not_current_action"
    end
    -- [喵喵喵]: 只给终止原因加一个 kind 标签(use 不用假装是移动/攻击)；旧标签保持不变。
    local label = (op.kind == "attack" and "cleared_local_attack")
        or (op.kind == "use" and "cleared_local_use")
        or "cleared_local_movement"
    return true, label
end

-- [喵喵喵]: 终结清理：成功或失败都要做，否则一旦闩存终态，所有权就丢了，
-- 之后 Cancel() 再也找不到那条还占着 locomotor 的本地动作。
-- 只撤“我们那条”BufferedAction(与 loco.bufferedaction / player.bufferedaction
-- 同一对象才动)，绝不碰用户或别人的动作。
-- 唯一例外：攻击若我们下发的那一次周期此刻还在状态机里跑(还没到判定帧)，
-- 就保留所有权(返回暂留原因)，免得撤缓冲让原生 onexit 把这一刀提前取消。
-- 返回 nil = 现在没有任何仍属我们且需保留的本地动作；返回字符串 = 暂留原因。
local function cleanup_local(player, op)
    if op.buffaction == nil and op.work_controller == nil then
        return nil
    end
    if op.kind == "attack"
        and op.target ~= nil and is_valid(op.target)
        and is_attack_state_for(player, op.target) then
        return "attack_cycle_in_progress"
    end
    release_local(player, op)
    return nil
end

-- [喵喵喵]: 终结结果(状态+原因)闩存在该身份上：同一意图之后只轮询这个结果、绝不重发；
-- 显式换 id / 换意图 / Cancel() 才清除。同时丢掉可能长期占内存的回调与实体引用；
-- 只有当本地清理暂留了自有缓冲(被打的那一刀还在跑)时才留着 op.buffaction/op.target，
-- 以便 Cancel() 还能撤掉它。
local function settle(player, op, status, reason)
    if op.latched == nil then
        local held = cleanup_local(player, op)
        if held ~= nil then
            reason = tostring(reason) .. "|held:" .. tostring(held)
            op.latched = { status = status, reason = reason, holds_local = true }
        else
            op.latched = { status = status, reason = reason }
        end
    end
    op.deadline = nil
    if op.latched.holds_local ~= true then
        op.buffaction = nil
        op.target = nil
    end
    op.confirm = nil
    op.intent = nil
    op.item = nil
    op.target_item = nil
    op.prefab = nil
    return status, reason
end

-- [喵喵喵]: 只清自有记录(闩存或挂起)，绝不动 OWNED 之外的东西。
local function release_owned_record(player, op)
    if op ~= nil and OWNED[player] == op then
        OWNED[player] = nil
    end
end

local function poll(player, op)
    -- [喵喵喵]: 任何 kind 都必须有有限截止时间，杜绝 deadline 与 now() 的 nil 比较。
    if not is_finite_number(op.deadline) then
        op.deadline = now() + Actions.DEFAULT_TIMEOUT
    end
    local pc = player.components.playercontroller
    if pc == nil then
        return settle(player, op, "failed", "controller_unavailable")
    end
    local status, reason
    if op.dispatched then
        status, reason = PIPELINE[op.kind].check(player, pc, op)
    elseif not pc:IsEnabled() then
        status, reason = "pending", "controller_disabled"
    elseif pc:IsBusy() then
        status, reason = "pending", "controller_busy"
    else
        local ok, why, hard = PIPELINE[op.kind].dispatch(player, pc, op)
        if ok then
            op.dispatched = true
            op.dispatch_time = now()
            status, reason = "pending", "dispatched"
        elseif hard then
            -- [喵喵喵]: 确定性拒绝（动作不可用/目标不可见）不等截止时间。
            return settle(player, op, "failed", why or "dispatch_refused")
        else
            status, reason = "pending", why or "dispatch_blocked"
        end
    end
    if status ~= "pending" then
        return settle(player, op, status, reason)
    end
    -- [喵喵喵]: 超时只撤我们自己的本地缓冲，不碰别人的动作；攻击那刀还在跑就先留着。
    if now() >= op.deadline then
        local held = cleanup_local(player, op)
        return settle(player, op, "failed",
            "deadline:" .. tostring(reason) .. (held == nil and "|released" or "|held:" .. tostring(held)))
    end
    return status, reason
end

function Actions.Step(player, intent)
    if not is_valid(player) then
        return "failed", "player_invalid"
    end
    -- [喵喵喵]: 只对本地玩家下发客户端可见的行走/点击路径。
    if ThePlayer ~= nil and player ~= ThePlayer then
        return "failed", "not_local_player"
    end
    if type(intent) ~= "table" then
        return "failed", "intent_not_table"
    end
    local handler = PIPELINE[intent.kind]
    if handler == nil then
        return "failed", "unknown_intent_kind:" .. tostring(intent.kind)
    end

    -- [喵喵喵]: 身份键只由意图字段算出(GUID/数字/字符串，不要求实体此刻有效)，
    -- 因此“目标/物品消失”不会让已持有的同名操作失去身份，也不会被重复下发。
    local identity = handler.identify ~= nil and handler.identify(intent) or nil
    local op = OWNED[player]

    if op ~= nil and op.latched ~= nil then
        if identity ~= nil and op.key == identity then
            -- [喵喵喵]: 已终结的同一身份：只回闩存结果，不重发、也不再 prepare。
            return op.latched.status, op.latched.reason
        end
        -- [喵喵喵]: 终结记录绝不阻塞别的意图/显式新 id，就地让位；若终结时因
        -- “我们那一刀还在跑”而暂留了自有缓冲，这里同样先做一次身份受限的清理
        -- (还在跑时 cleanup_local 会继续保留它，免得把这一刀提前取消)。
        cleanup_local(player, op)
        release_owned_record(player, op)
        op = nil
    elseif op ~= nil and identity ~= nil and op.key == identity then
        -- [喵喵喵]: 已持有的同一意图先 poll(实体已消失也照样轮询到超时)。
        return poll(player, op)
    end

    local params, reason = handler.prepare(player, intent)
    if params == nil then
        -- [喵喵喵]: 无效/无关意图绝不取消挂起的自有操作；只有确实过期的自有记录才让位。
        if op ~= nil and (op.deadline == nil or now() >= op.deadline) then
            release_local(player, op)
            release_owned_record(player, op)
        end
        return "failed", reason or "intent_invalid"
    end

    if op ~= nil then
        -- [喵喵喵]: 等优先级不能靠过期记录硬占；过期(或刚终结，已在上面让位)的
        -- 自有记录不阻塞同优先级新意图。抢占时也只释放自己那条本地操作。
        local expired = op.deadline == nil or now() >= op.deadline
        if params.priority > op.priority or (expired and params.priority >= op.priority) then
            release_local(player, op)
            release_owned_record(player, op)
        else
            return "pending", "held_by_" .. tostring(op.kind)
        end
    end
    OWNED[player] = params
    return poll(player, params)
end

function Actions.Cancel(player)
    if not is_valid(player) then
        return false, "player_invalid"
    end
    local op = OWNED[player]
    if op == nil then
        return false, "not_owned"
    end
    OWNED[player] = nil

    -- [喵喵喵]: 终结记录默认只是闩存结果；但若终结时因“我们那一刀还在跑”而暂留了
    -- 自有缓冲，Cancel() 就是最后能把它撤掉的时机(仍只撤自己的那条)。
    if op.latched ~= nil then
        if op.buffaction ~= nil then
            local ok, why = release_local(player, op)
            op.target = nil
            return true, "cleared_terminal_record" .. (ok and "|released" or "|held:" .. tostring(why))
        end
        return true, "cleared_terminal_record"
    end

    -- [喵喵喵]: 已松手的无预测点击只在本地记账，服务端动作无法从这里撤销；
    -- 上层需用短程路径/后置条件控制并接受这个边界。
    if op.no_prediction then
        release_local(player, op)
        return true, "local_only_no_prediction"
    end

    return release_local(player, op)
end

return Actions
