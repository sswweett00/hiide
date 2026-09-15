pub const AppConfig = struct {
    app_name: []const u8,
    workspace_root: []const u8,
    max_parallel_agents: u16,
    speculative_execution: bool,

    /// Returns the default local-engine configuration.
    /// @example
    /// const cfg = AppConfig.default();
    pub fn default() AppConfig {
        return .{
            .app_name = "hiide",
            .workspace_root = ".",
            .max_parallel_agents = 8,
            .speculative_execution = true,
        };
    }
};
