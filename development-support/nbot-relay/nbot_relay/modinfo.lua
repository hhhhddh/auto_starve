name = "NBot Relay"
description = "连接本机 NBot HTTP 中转，执行 Lua 和常用指令；专服同样可显式加载。"
author = "NBot"
version = "0.1.0"
api_version = 10
dst_compatible = true
client_only_mod = true
all_clients_require_mod = false

configuration_options = {
    {
        name = "enabled",
        label = "启用中转",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        -- [喵喵喵] 本目录是 WilsonExpedition 的本地开发档位副本，不是分发物；
        -- 默认关闭，避免误入正式游戏会话或任何专服分片。启用前须先从 private/ 同步真实 token。
        default = false,
    },
}
