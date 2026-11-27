using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;

using HarmonyLib;

using Barotrauma;

namespace XsStatusThrottle
{
    /// <summary>
    /// 通用状态效果节流器（C# 层）
    ///
    /// 解决的问题：
    ///   任何内容包里 &lt;StatusEffect type="Always"&gt; 若未写 interval，
    ///   引擎会每帧执行它（Explosion / SpawnItem / ParticleEmitter / Affliction）。
    ///   BT 里有 194 处这样写，其它模组也有。Lua 侧访问不到 StatusEffect 内部字段，
    ///   所以只能在这一层拦。
    ///
    /// 做法：
    ///   反射找出 StatusEffect 的 interval / type 字段；
    ///   Patch 所有名为 Apply 的重载，在 Prefix 里做节流：
    ///     仅当 type 含 "Always" 且 interval &lt;= 0 时，
    ///     同一实例 throttleSeconds 内重复调用直接 return false（跳过原逻辑）。
    ///
    /// 不改任何 XML、不改粒子/音效/贴图，只降低执行频率。
    /// </summary>
    public class StatusThrottlePlugin : IAssemblyPlugin
    {
        private static Harmony _harmony;
        private static FieldInfo _intervalField;
        // 1.15 起 StatusEffect.Type 从字段变成了属性，所以两样都要探测
        private static FieldInfo _typeField;
        private static PropertyInfo _typeProp;

        private static bool _enabled = true;
        private static float _throttle = 1.0f;

        private static readonly Dictionary<StatusEffect, float> _lastRun = new Dictionary<StatusEffect, float>();
        private static readonly Stopwatch _clock = Stopwatch.StartNew();

        private static int _patchedCount;
        private static long _calls;
        private static long _blocked;

        public void Initialize()
        {
            _harmony = new Harmony("xs.statusthrottle");
            ProbeFields();
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
                "[XsStatusThrottle] 已加载 | interval字段={0} | type字段={1} | 已 patch {2} 个 Apply 重载 | 节流 {3:F2}s",
                _intervalField != null ? _intervalField.Name : "NULL",
                _typeField != null ? _typeField.Name : (_typeProp != null ? _typeProp.Name + "(属性)" : "NULL"),
                _patchedCount, _throttle));
        }

        // ---------- 反射探测字段 ----------
        private static void ProbeFields()
        {
            try
            {
                var type = typeof(StatusEffect);
                var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                var fields = type.GetFields(flags);
                LuaCsLogger.Log(string.Format("[XsStatusThrottle] StatusEffect 共 {0} 个字段：", fields.Length));
                foreach (var f in fields)
                {
                    LuaCsLogger.Log(string.Format("    {0} {1}", f.FieldType.Name, f.Name));
                }

                _intervalField = fields.FirstOrDefault(f =>
                    f.Name.Equals("interval", StringComparison.OrdinalIgnoreCase));
                if (_intervalField == null)
                {
                    _intervalField = fields.FirstOrDefault(f =>
                        f.Name.IndexOf("interval", StringComparison.OrdinalIgnoreCase) >= 0);
                }
                _typeField = fields.FirstOrDefault(f =>
                    f.Name.Equals("type", StringComparison.OrdinalIgnoreCase));

                // 1.15 起 Type 是属性（public ActionType Type { get; }），字段里找不到
                if (_typeField == null)
                {
                    _typeProp = type.GetProperty("Type", flags);
                }
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsStatusThrottle] 探测字段失败: " + e.Message);
            }
        }

        // ---------- Patch 所有 Apply 重载 ----------
        private static void PatchAll()
        {
            if (_harmony == null) return;
            try
            {
                var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                var prefix = new HarmonyMethod(
                    AccessTools.Method(typeof(StatusThrottlePlugin), nameof(Prefix)));

                foreach (var m in typeof(StatusEffect).GetMethods(flags))
                {
                    if (m.Name != "Apply") continue;
                    try
                    {
                        _harmony.Patch(m, prefix: prefix);
                        _patchedCount++;
                    }
                    catch (Exception e)
                    {
                        LuaCsLogger.LogError(string.Format(
                            "[XsStatusThrottle] patch Apply 重载失败 ({0}): {1}",
                            m.GetParameters().Length, e.Message));
                    }
                }
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsStatusThrottle] PatchAll 失败: " + e.Message);
            }
        }

        // ---------- 节流 Prefix ----------
        private static bool Prefix(StatusEffect __instance)
        {
            if (!_enabled || __instance == null) return true;
            if (_intervalField == null) return true;

            try
            {
                _calls++;

                object rawIv = _intervalField.GetValue(__instance);
                if (!(rawIv is float iv)) return true;
                if (iv > 0f) return true;           // 已有 interval，交给引擎自己控频

                if (_typeField != null || _typeProp != null)
                {
                    object tv = _typeField != null
                        ? _typeField.GetValue(__instance)
                        : _typeProp.GetValue(__instance);
                    if (tv != null)
                    {
                        string ts = tv.ToString();
                        if (ts.IndexOf("Always", StringComparison.Ordinal) < 0) return true;
                    }
                }

                float now = (float)_clock.Elapsed.TotalSeconds;
                float last;
                if (_lastRun.TryGetValue(__instance, out last) && (now - last) < _throttle)
                {
                    _blocked++;                      // 只计数，不打印
                    return false;                    // 跳过原逻辑
                }

                _lastRun[__instance] = now;

                // 字典过大时清理一次，避免长期挂机无限增长
                if (_lastRun.Count > 5000)
                {
                    _lastRun.Clear();
                    LuaCsLogger.Log("[XsStatusThrottle] 节流表已清空重建");
                }

                return true;
            }
            catch
            {
                return true;    // 任何异常都放行，绝不阻断游戏
            }
        }

        // ---------- 供外部调用 ----------
        public static void SetEnabled(bool value)
        {
            _enabled = value;
            LuaCsLogger.Log("[XsStatusThrottle] enabled=" + value);
        }

        public static void SetThrottle(float seconds)
        {
            if (seconds < 0.1f) seconds = 0.1f;
            _throttle = seconds;
            LuaCsLogger.Log("[XsStatusThrottle] throttle=" + seconds.ToString("F2") + "s");
        }

        public static string Stats()
        {
            return string.Format("patched={0} calls={1} blocked={2} throttle={3:F2}s enabled={4}",
                _patchedCount, _calls, _blocked, _throttle, _enabled);
        }
    }
}
