name = "威尔逊远征诊断 / Wilson Expedition Diagnostics"
description = "记录四季生存测试的伤害、死亡、动作与制作事件；提供角色身份和存活时间回执。"
author = "Wilson Expedition"
version = "0.1.0"
api_version = 10
dst_compatible = true
client_only_mod = false
all_clients_require_mod = true
configuration_options = {
    {
        name = "auto_iteration",
        label = "项目测试世界自动迭代",
        hover = "仅由项目测试配置启用：世界重建后自动选择威尔逊。",
        options = {
            { description = "关闭", data = false },
            { description = "开启", data = true },
        },
        default = false,
    },
}
