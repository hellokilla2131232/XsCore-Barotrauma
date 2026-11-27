using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

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

        // ---- 配置文件（AILod.cfg，游戏根目录）----
        private const string ConfigFileName = "AILod.cfg";
        private static readonly TimeSpan ConfigCheckInterval = TimeSpan.FromSeconds(5);
        private static float _nextConfigCheck = 0f;
        private static DateTime _lastConfigWrite = DateTime.MinValue;

        private static string ConfigPath =>
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ConfigFileName);

        private static readonly Dictionary<Character, float> _next = new Dictionary<Character, float>();
        private static readonly Stopwatch _clock = Stopwatch.StartNew();

        private static long _skipped;
        private static long _passed;
        private static int _patched;
        private static float _nextStatsLog = 0f;   // 统计日志节流

        // 受伤唤醒：血量下降 → 立刻退出降频
        private static readonly Dictionary<Character, float> _lastHealth
            = new Dictionary<Character, float>();
        private static long _damagedWake;
        private static System.Reflection.PropertyInfo _hpProp;

        // 漏斗计数：看五个条件各自淘汰了多少
        private static long _entered;    // 进入 Prefix 的总次数
        private static long _notPlayer;  // 通过「非玩家」检查
        private static long _hasAI;      // 通过「有 AIController」
        private static long _alive;      // 通过「活着」
        private static long _idleOk;     // 通过「AIState = Idle」
        private static long _speedOk;    // 通过「速度 <= 阈值」
        private static long _distOk;     // 通过「距离 > 远场半径」

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
            EnsureDefaultConfig();

            PatchAll();
            LuaCsLogger.Log(string.Format(
                "[XsAILod] 已加载 | 远场 {0:F0}px | 闲置 AI 降频至 {1:F2}s | 已 patch {2} 个 Update 重载",
                _farRadius, _idleInterval, _patched));
        }

        // ---------- 首次启动时创建默认配置文件 ----------
        private static void EnsureDefaultConfig()
        {
            try
            {
                string path = ConfigPath;
                if (File.Exists(path)) return;

                string content =
                    "# XsAILod 配置文件\n" +
                    "# 改完保存，游戏内 5 秒内自动重载，不用重启\n" +
                    "#\n" +
                    "# farRadius   : 远场半径（px），超出此距离的站桩 AI 才降频\n" +
                    "#                范围 1000 ~ 12000，建议 6000 ~ 8000\n" +
                    "# idleInterval: 降频后的更新间隔（秒）\n" +
                    "#                范围 0.10 ~ 2.00，建议 0.25 ~ 0.50\n" +
                    "# enabled     : 总开关\n" +
                    "\n" +
                    "farRadius=6000\n" +
                    "idleInterval=0.25\n" +
                    "enabled=true\n";

                File.WriteAllText(path, content, new UTF8Encoding(false));
                _lastConfigWrite = File.GetLastWriteTimeUtc(path);

                LuaCsLogger.Log($"[XsAILod] 已创建默认配置: {path}");
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsAILod] 创建默认配置失败: " + e.Message);
            }
        }

        // ---------- 配置热重载（每 5 秒检查 AILod.cfg 的修改时间）----------
        private static void CheckConfigReload()
        {
            float now = (float)_clock.Elapsed.TotalSeconds;
            if (now < _nextConfigCheck) return;
            _nextConfigCheck = now + (float)ConfigCheckInterval.TotalSeconds;

            try
            {
                string path = ConfigPath;
                if (!File.Exists(path)) return;

                DateTime mtime = File.GetLastWriteTimeUtc(path);
                if (mtime <= _lastConfigWrite) return;
                _lastConfigWrite = mtime;

                bool changed = false;
                foreach (string raw in File.ReadAllLines(path))
                {
                    string s = raw.Trim();
                    if (s.Length == 0 || s.StartsWith("#")) continue;

                    int eq = s.IndexOf('=');
                    if (eq <= 0) continue;

                    string key = s.Substring(0, eq).Trim();
                    string val = s.Substring(eq + 1).Trim();

                    switch (key)
                    {
                        case "enabled":
                            _enabled = (val == "true" || val == "1");
                            changed = true;
                            break;
                        case "farRadius":
                            if (float.TryParse(val, out float fr) && fr > 0f) { _farRadius = fr; changed = true; }
                            break;
                        case "idleInterval":
                            if (float.TryParse(val, out float ii) && ii > 0f) { _idleInterval = ii; changed = true; }
                            break;
                        case "movingSpeed":
                            if (float.TryParse(val, out float ms) && ms >= 0f) { _movingSpeed = ms; changed = true; }
                            break;
                    }
                }

                if (changed)
                {
                    _next.Clear();  // 参数变了，清空计时表让新值立刻生效
                    LuaCsLogger.Log(
                        $"[XsAILod] 配置已重载 | enabled={_enabled} | " +
                        $"farRadius={_farRadius:F0} | idleInterval={_idleInterval:F2}s");
                }
            }
            catch (Exception e)
            {
                LuaCsLogger.LogError("[XsAILod] 配置文件读取失败: " + e.Message);
            }
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

        // ---------- 反射读血量（0~1） ----------
        private static float GetHealth(Character c)
        {
            try
            {
                if (_hpProp == null)
                    _hpProp = typeof(Character).GetProperty("HealthPercentage");
                if (_hpProp == null) return 1f;
                object v = _hpProp.GetValue(c);
                return v == null ? 1f : Convert.ToSingle(v);
            }
            catch { return 1f; }
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
            CheckConfigReload();
            if (!_enabled || __instance == null) return true;

            try
            {
                if (_entered == 0)
                {
                    LuaCsLogger.Log("[XsAILod] Prefix 首次被调用 —— Harmony patch 已生效");
                }
                _entered++;

                if (__instance.IsPlayer) return true;
                if (__instance == Character.Controlled) return true;
                _notPlayer++;

                if (__instance.IsDead) return true;
                _alive++;

                if (__instance.AIController == null) return true;   // 非 AI 控制
                _hasAI++;

                // 非闲置状态（战斗/追击/逃跑）→ 全速（用字符串比较，避免枚举值名不确定）
                try { if (!__instance.AIState.ToString().Contains("Idle")) return true; } catch { }
                _idleOk++;

                // ★ 在移动的单位一律不降频（怪物游动、NPC 走路都不会卡顿）
                //   用反射读 CurrentSpeed，避免类型不确定导致编译失败
                if (Math.Abs(GetSpeed(__instance)) > _movingSpeed) return true;
                _speedOk++;

                // 玩家附近 → 全速
                if (NearestPlayerDist(__instance) <= _farRadius) return true;
                _distOk++;

                // 受伤检测：血量下降 → 立刻退出降频
                float hp = GetHealth(__instance);
                float lastHp;
                if (_lastHealth.TryGetValue(__instance, out lastHp))
                {
                    if (hp < lastHp - 0.0001f)
                    {
                        _next.Remove(__instance);   // 清掉降频计时
                        _lastHealth[__instance] = hp;
                        _damagedWake++;
                        return true;                // 立刻完整执行一次
                    }
                }
                _lastHealth[__instance] = hp;

                float now = (float)_clock.Elapsed.TotalSeconds;

                // 每 30 秒打一次统计，方便确认降频是否真的在生效
                if (now >= _nextStatsLog)
                {
                    _nextStatsLog = now + 30f;

                    // 无条件打印漏斗（哪怕全 0，也能看出 patch 到底有没有在跑）
                    LuaCsLogger.Log(
                        $"[XsAILod] 漏斗 | 进入 {_entered} → 非玩家 {_notPlayer} → " +
                        $"活着 {_alive} → 有AI {_hasAI} → Idle {_idleOk} → " +
                        $"静止 {_speedOk} → 远距 {_distOk}");

                    long totalCalls = _skipped + _passed;
                    if (totalCalls > 0)
                    {
                        LuaCsLogger.Log(
                            $"[XsAILod] 结果 | 跳过 {_skipped} | 通过 {_passed} | " +
                            $"跳过率 {(_skipped * 100.0 / totalCalls):F1}% | " +
                            $"受伤唤醒 {_damagedWake} | 计时表 {_next.Count} 个");
                    }
                    else
                    {
                        LuaCsLogger.Log(
                            "[XsAILod] 结果 | 还没有 AI 走到降频判定（看漏斗断在哪一步）");
                    }

                    // 顺带报告配置文件路径，方便确认 C# 到底在读哪
                    LuaCsLogger.Log(
                        $"[XsAILod] 配置路径 | {ConfigPath} | 存在={File.Exists(ConfigPath)}");
                }

                float next;
                if (_next.TryGetValue(__instance, out next) && now < next)
                {
                    _skipped++;
                    return false;      // 跳过这次 Update
                }

                _next[__instance] = now + _idleInterval;
                _passed++;

                if (_next.Count > 3000) _next.Clear();
                if (_lastHealth.Count > 3000) _lastHealth.Clear();
                return true;
            }
            catch
            {
                return true;           // 异常放行
            }
        }

        // ---------- 外部可调 ----------
        public static void SetEnabled(bool v) { _enabled = v; LuaCsLogger.Log("[XsAILod] enabled=" + v); }
        public static void SetFarRadius(float r)
        {
            if (r < 100f) r = 100f;
            if (r > 100000f) r = 100000f;
            _farRadius = r;
            LuaCsLogger.Log("[XsAILod] farRadius=" + r.ToString("F0"));
        }
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
