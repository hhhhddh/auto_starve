-- [喵喵喵] 开发档位占位配置：此处故意不含真实 token，真实 token 只存在于本地 private/relay_config.lua，
-- 启用前由部署步骤覆盖本文件（见 integration-manifest.json 的 stagedPrerequisites）。
-- 占位 token 不是 relay 的公开默认值，也不是任何真实凭据；未同步时会因 token 不符而被中转拒绝。
return {
    port = 20502,
    token = "staged-placeholder-not-a-credential",
    -- cluster_id = "another-cluster", -- 省略即为 default
}
