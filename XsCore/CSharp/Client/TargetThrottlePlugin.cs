using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using HarmonyLib;
using Barotrauma;
using Barotrauma.LuaCs;

namespace XsCore
{
    /// <summary>
    /// EnemyAIController.UpdateTargets 节流。
    ///
    /// 问题：UpdateTargets 每帧调用，671 行里有几处 O(目标数 × 角色数) 的嵌套遍历：
    ///         行 3553  foreach (AITarget in AITarget.List)          ← 外层主循环
    ///         行 3752    foreach (Character in CharacterList)       ← 嵌套 1
    ///         行 3933    foreach (Character in CharacterList)       ← 嵌套 2
    ///       20 个怪物同时跑，每帧上万次判断，战斗时的「一次性大量计算」主要来自这里。
    ///
    /// 做法：每个怪物每 N 帧才真正算一次目标，其他帧直接跳过。
    ///       N=3 时省 66% 开销，目标切换延迟最多 50ms（人类反应约 200ms，感知不到）。
    /// </summary>
    public class TargetThrottlePlugin : IAssemblyPlugin
    {
        private static Harmony _harmony;
        private static int _patched;

        private static bool _enabled = true;
        private static int _interval = 3;

        private static readonly Dictionary<EnemyAIController, int> _frames
            = new Dictionary<EnemyAIController, int>();

        private static long _skipped;
        private static long _passed;
        private static float _nextStatsLog;
        private static readonly Stopwatch _clock = Stopwatch.StartNew();

        // ---------- 生命周期 ----------
        public void Initialize()
        {
            LuaCsLogger.Log("[XsTargetThrottle] Initialize 被调用");
            _harmony = new Harmony("xs.targetthrottle");
        }

        public void OnLoadCompleted()
        {
            PatchAll();
            LuaCsLogger.Log(
                $"[XsTargetThrottle] 已加载 | 每 {_interval} 帧算一次目标 | 已 patch {_patched} 个方法");
        }

        public void PreInitPatching() { }

        public void Dispose()
        {
            try { _harmony?.UnpatchSelf(); } catch { }
        }

        // ---------- Patch ----------
        private static void PatchAll()
        {
            if (_harmony == null) return;
            try
            {
                MethodInfo prefix = AccessTools.Method(typeof(TargetThrottlePlugin), "Prefix");
                if (prefix == null)
                {
                    LuaCsLogger.LogError("[XsTargetThrottle] 找不到 Prefix 方法");
                    return;
                }
                var harmonyMethod = new HarmonyMethod(prefix);

                var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                foreach (var m in typeof(EnemyAIController).GetMethods(flags))
                {
                    if (m.Name != "UpdateTargets") continue;
                    try
                    {
                        _harmony.Patch(m, prefix: harmonyMethod);
                        _patched++;
                    }
                    catch (Exception e)
                    {
                        LuaCsLogger.LogError("[XsTargetThrottle] patch UpdateTargets 失败: " + e.Message);
                    }
                }
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsTargetThrottle] PatchAll 失败: " + e.Message);
            }
        }

        // ---------- Prefix ----------
        private static bool Prefix(EnemyAIController __instance)
        {
            if (!_enabled || _interval <= 1 || __instance == null) return true;

            try
            {
                float now = (float)_clock.Elapsed.TotalSeconds;

                // 统计：第一次只计时，之后每 30 秒打一次
                if (_nextStatsLog <= 0f)
                {
                    _nextStatsLog = now + 30f;
                }
                else if (now >= _nextStatsLog)
                {
                    _nextStatsLog = now + 30f;
                    long total = _skipped + _passed;
                    if (total > 0)
                    {
                        LuaCsLogger.Log(
                            $"[XsTargetThrottle] 统计 | 跳过 {_skipped} | 通过 {_passed} | " +
                            $"跳过率 {(_skipped * 100.0 / total):F1}% | 计时表 {_frames.Count} 个");
                    }
                }

                _frames.TryGetValue(__instance, out int f);
                f++;

                if (f < _interval)
                {
                    _frames[__instance] = f;
                    _skipped++;
                    return false;
                }

                _frames[__instance] = 0;
                _passed++;

                if (_frames.Count > 3000) _frames.Clear();
                return true;
            }
            catch
            {
                return true;
            }
        }

        // ---------- 供 Lua 调用 ----------
        public static bool GetEnabled() { return _enabled; }
        public static int  GetInterval() { return _interval; }
        public static long GetSkipped() { return _skipped; }
        public static long GetPassed() { return _passed; }

        public static void SetEnabled(bool v)
        {
            _enabled = v;
            LuaCsLogger.Log("[XsTargetThrottle] enabled=" + v);
        }

        public static void SetInterval(int n)
        {
            if (n < 1) n = 1;
            if (n > 10) n = 10;
            _interval = n;
            _frames.Clear();
            LuaCsLogger.Log("[XsTargetThrottle] interval=" + n);
        }
    }
}
