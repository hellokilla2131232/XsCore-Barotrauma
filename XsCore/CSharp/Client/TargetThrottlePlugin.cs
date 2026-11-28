using System;
using Barotrauma.LuaCs;

namespace XsCore
{
    /// <summary>
    /// 最简版：只验证能否被 LuaCs 加载。
    /// 如果这个版本能出现日志，再逐步加回 PatchAll / Prefix。
    /// </summary>
    public class TargetThrottlePlugin : IAssemblyPlugin
    {
        public void Initialize()
        {
            LuaCsLogger.Log("[XsTargetThrottle] Initialize 被调用（最简版）");
        }

        public void OnLoadCompleted()
        {
            LuaCsLogger.Log("[XsTargetThrottle] 已加载（最简版，无 patch）");
        }

        public void PreInitPatching() { }

        public void Dispose() { }
    }
}
