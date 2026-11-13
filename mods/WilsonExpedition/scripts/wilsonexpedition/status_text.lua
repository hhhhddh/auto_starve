-- [喵喵喵]: 只翻译显示文案，原始任务和错误标识继续保留在日志、轨迹与协议中。
local TASKS = {
    ["escape:threat"] = "远离威胁", ["escape:hounds"] = "躲避猎犬",
    ["escape:fire"] = "远离火焰", ["escape:drown"] = "寻找落脚点",
    ["escape:wait"] = "等待安全退路",
    ["light:hold"] = "保持安全照明", ["light:unequip"] = "收起光源",
    ["env:hold"] = "等待体温恢复", ["base:return"] = "返回营地",
    explore = "探索周边", idle = "等待可执行目标",
}
local DETAILS = {
    ["moving:moving"] = "行走中", ["moving:dispatched"] = "开始移动",
    search_submitted = "规划路线", search_running = "正在寻路",
    path_ready = "路线就绪", waypoint_reached = "继续前往下一路段",
    awaiting_confirmation = "等待动作确认", dispatched = "动作已发出",
    working = "持续工作中", completed = "已完成", succeeded = "已完成",
    cancelled = "已取消", preempted = "优先处理紧急情况",
    no_light_source = "缺少可用光源", plan_timeout = "采购等待超时",
    threat_blocked = "路线有危险", no_path = "暂时无法通行",
    los_blocked = "前方有阻挡", los_unsupported = "等待通路信息",
    no_safe_point = "未找到安全退路", stale_snapshot = "等待观察更新",
}

local function item_name(prefab)
    return STRINGS ~= nil and STRINGS.NAMES ~= nil
        and STRINGS.NAMES[string.upper(prefab)] or "所需物资"
end

local function task_text(task)
    if TASKS[task] ~= nil then return TASKS[task] end
    local kind, target = task:match("^([^:]+):(.+)$")
    if kind == "escape" then return "紧急避险" end
    if kind == "light" then
        if target:match("^equip:") then return "装备光源" end
        if target:match("unequip") then return "收起光源" end
        return "准备照明物资"
    end
    if kind == "vital" then
        if target:match("^search:food") then return "寻找救急食物" end
        if target:match("^sanity") then return "恢复理智" end
        if target:match("^heal") then return "治疗伤势" end
        if target:match("^eat") then return "补充食物" end
        if target:match("^equip") then return "调整装备" end
        return "补充生存物资"
    end
    if kind == "env" then
        if target:match("^addfuel") then return "添加燃料" end
        if target:match("^smother") then return "处理闷烧" end
        return "应对环境变化"
    end
    if kind == "explore" and (target == "frontier" or target == "resource") then return "探索周边" end
    local verbs = {
        request = "获取", acquire = "采集", approach = "靠近", work = "采集",
        craft = "制作", cook = "烹饪", explore = "寻找", landmark = "前往资源点：",
        station = "寻找科技站：", transfer = "整理物资：",
    }
    if verbs[kind] ~= nil then
        local prefab = target:match("^([%w_]+)")
        if prefab ~= nil then return verbs[kind] .. item_name(prefab) end
    end
    return "任务待识别，请查看日志"
end

local function detail_text(detail)
    if DETAILS[detail] ~= nil then return DETAILS[detail] end
    local code = detail:match("^([%w_]+)")
    if DETAILS[code] ~= nil then return DETAILS[code] end
    local distance = tonumber(detail:match("^arrived:([%d.]+)"))
    if distance ~= nil then return string.format("已到达（距离 %.1f 米）", distance) end
    if code == "moving" then return "行走中" end
    if code == "waypoint_skipped" then return "绕开危险路段" end
    if code == "waypoint_failed_retry" or code == "replanning" then return "重新规划路线" end
    if code == "action_unavailable" then return "当前动作不可用" end
    if code == "not_ready" then return "等待角色就绪" end
    if code == "temperature_recovering" then return "等待体温恢复" end
    if code ~= nil and code:find("timeout", 1, true) then return "等待超时" end
    if code ~= nil and code:find("failed", 1, true) then return "执行失败，请查看日志" end
    if code ~= nil and code:find("blocked", 1, true) then return "当前条件受限" end
    return "状态待识别，请查看日志"
end

return function(reason)
    if reason == nil or reason == "" then return "等待可执行目标" end
    local task, detail = reason:match("^(.-): (.+)$")
    if task ~= nil then return task_text(task) .. " · " .. detail_text(detail) end
    if reason:find("[\128-\255]") then return reason end
    return DETAILS[reason] or detail_text(reason)
end
