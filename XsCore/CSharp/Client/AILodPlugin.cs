using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;

using HarmonyLib;
using Microsoft.Xna.Framework;

using Barotrauma;

namespace XsAILod
{
    /// <summary>
    /// AI 距离分级调度（不砍人数，按需更新）
    ///
    /// 思路：
    ///   前哨站 AI 多 → 每个都全速跑 Update + 寻路 + 目标扫描 → 卡。
    ///   但玩家根本看不见 6000px 外那些站桩的 NPC。
    ///   所以：看得见的每帧更新，看不见的闲置 AI 降频更新。
    ///
    /// 判定条件（全部满足才降频）：
    ///   1. 不是玩家、不是 Controlled
    ///   2. 有 AIController（是 AI 控制的单位）
    ///   3. AIState == Idle（不在战斗/逃跑/追击）
    ///   4. 距最近玩家 > FarRadius（默认 6000px）
    ///
    /// 安全：
    ///   · 战斗中（非 Idle）永远全速，不影响手感
    ///   · 玩家附近永远全速
    ///   · 任何异常都放行，绝不阻断游戏
    ///   · 提供开关（默认启用）
    /// </summary>
    public class AILodPlugin : IAssemblyPlugin
    {
        public readonly string Name = "XsAILod";
        private static Harmony _harmony;

        private static bool _enabled = true;
        private static float _farRadius = 6000f;
        private static float _idleInterval = 0.25f;   // 闲置 AI 每 0.25 秒更新一次（4Hz）
        private static float _movingSpeed = 0.5f;     // CurrentSpeed 超过这个值算「在移动」，不降频

        private static readonly Dictionary<Character, float> _next = new Dictionary<Character, float>();
        private static readonly Stopwatch _clock = Stopwatch.StartNew();

        private static long _skipped;
        private static long _passed;
        private static int _patched;

        public void Initialize()
        {
            LuaCsLogger.Log("[XsAILod] Initialize 被调用");
            _harmony = new Harmony("xs.ailod");
        }

        public void Dispose()
        {
            try { _harmony?.UnpatchSelf(); } catch { }
        }

        public void PreInitPatching()
        {
        }

        public void OnLoadCompleted()
        {
            PatchAll();
            LuaCsLogger.Log(string.Format(
                "[XsAILod] 已加载 | 远场 {0:F0}px | 闲置 AI 降频至 {1:F2}s | 已 patch {2} 个 Update 重载",
                _farRadius, _idleInterval, _patched));
        }

        // ---------- Patch 全部 Update 重载 ----------
        private static void PatchAll()
        {
            if (_harmony == null) return;
            try
            {
                var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                var prefix = new HarmonyMethod(
                    AccessTools.Method(typeof(AILodPlugin), nameof(Prefix)));

                foreach (var m in typeof(Character).GetMethods(flags))
                {
                    if (m.Name != "Update") continue;
                    try
                    {
                        _harmony.Patch(m, prefix: prefix);
                        _patched++;
                    }
                    catch (Exception e)
                    {
                        LuaCsLogger.LogError("[XsAILod] patch Update 失败: " + e.Message);
                    }
                }
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsAILod] PatchAll 失败: " + e.Message);
            }
        }

        // ---------- 读当前速度（反射，兼容任何数值类型）----------
        private static System.Reflection.PropertyInfo _speedProp;
        private static readonly object _speedLock = new object();

        private static float GetSpeed(Character c)
        {
            try
            {
                if (_speedProp == null)
                {
                    lock (_speedLock)
                    {
                        if (_speedProp == null)
                            _speedProp = typeof(Character).GetProperty("CurrentSpeed");
                    }
                }
                if (_speedProp == null) return 0f;
                object v = _speedProp.GetValue(c);
                if (v == null) return 0f;
                return Convert.ToSingle(v);
            }
            catch { return 0f; }
        }

        // ---------- 到最近玩家的距离 ----------
        private static float NearestPlayerDist(Character c)
        {
            float best = float.MaxValue;
            try
            {
                foreach (var other in Character.CharacterList)
                {
                    if (other == null || other.Removed) continue;
                    if (!(other.IsPlayer || other == Character.Controlled)) continue;
                    float d = Vector2.Distance(other.WorldPosition, c.WorldPosition);
                    if (d < best) best = d;
                }
            }
            catch { }
            return best;
        }

        // ---------- 节流 Prefix ----------
        private static bool Prefix(Character __instance)
        {
            if (!_enabled || __instance == null) return true;

            try
            {
                if (__instance.IsPlayer) return true;
                if (__instance == Character.Controlled) return true;
                if (__instance.IsDead) return true;
                if (__instance.AIController == null) return true;   // 非 AI 控制

                // 非闲置状态（战斗/追击/逃跑）→ 全速（用字符串比较，避免枚举值名不确定）
                try { if (!__instance.AIState.ToString().Contains("Idle")) return true; } catch { }

                // ★ 在移动的单位一律不降频（怪物游动、NPC 走路都不会卡顿）
                //   用反射读 CurrentSpeed，避免类型不确定导致编译失败
                if (Math.Abs(GetSpeed(__instance)) > _movingSpeed) return true;

                // 玩家附近 → 全速
                if (NearestPlayerDist(__instance) <= _farRadius) return true;

                float now = (float)_clock.Elapsed.TotalSeconds;
                float next;
                if (_next.TryGetValue(__instance, out next) && now < next)
                {
                    _skipped++;
                    return false;      // 跳过这次 Update
                }

                _next[__instance] = now + _idleInterval;
                _passed++;

                if (_next.Count > 3000) _next.Clear();
                return true;
            }
            catch
            {
                return true;           // 异常放行
            }
        }

        // ---------- 外部可调 ----------
        public static void SetEnabled(bool v) { _enabled = v; LuaCsLogger.Log("[XsAILod] enabled=" + v); }
        public static void SetFarRadius(float r) { _farRadius = r; LuaCsLogger.Log("[XsAILod] farRadius=" + r); }
        public static void SetIdleInterval(float s)
        {
            if (s < 0.05f) s = 0.05f;
            _idleInterval = s;
            LuaCsLogger.Log("[XsAILod] idleInterval=" + s.ToString("F2"));
        }
        public static string Stats()
        {
            return string.Format("patched={0} passed={1} skipped={2} far={3:F0} interval={4:F2}s enabled={5}",
                _patched, _passed, _skipped, _farRadius, _idleInterval, _enabled);
        }
    }
}
