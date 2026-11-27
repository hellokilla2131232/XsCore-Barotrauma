using System;
using System.Collections.Generic;
using System.Reflection;
using Barotrauma;
using Barotrauma.LuaCs;
using HarmonyLib;

namespace XsCore
{
    /// <summary>
    /// Submarine.GetItems 缓存
    ///
    /// 背景：
    ///   AIObjectiveGetItem.FindTargetItem() 每扫完一轮物品，就调用一次
    ///   character.Submarine.GetItems(alsoFromConnectedSubs: true)。
    ///   该方法内部是 Item.ItemList.FindAll(...)，遍历全部物品并新建 List。
    ///   33 个 AI 各自独立调用 → 33 份重复全量遍历 + 33 次 List 分配。
    ///
    /// 做法：
    ///   按 Submarine 实例缓存结果，TTL 0.5 秒。缓存期内返回同一份 List。
    ///   只缓存 alsoFromConnectedSubs == true（AI 用的就是这条），false 走原逻辑。
    ///
    /// 作用范围：
    ///   所有 AI（船员 / 海盗 / NPC），不限模组。
    /// </summary>
    public class GetItemsCachePlugin : IAssemblyPlugin
    {
        private const float CacheTTL = 0.5f;
        private const float SweepInterval = 10f;

        private static readonly Dictionary<Submarine, (List<Item> items, float stamp)> Cache
            = new Dictionary<Submarine, (List<Item>, float)>();

        private static long _hits;
        private static long _misses;
        private static float _nextReport;
        private static float _nextSweep;

        private Harmony _harmony;

        public void Initialize()
        {
            _harmony = new Harmony("xs.getitems.cache");
            _harmony.PatchAll(typeof(GetItemsCachePlugin).Assembly);

            LuaCsLogger.Log(
                $"[XsGetItemsCache] 初始化 | TTL={CacheTTL:F2}s | " +
                "缓存 Submarine.GetItems，所有 AI 共享");
        }

        public void OnLoadCompleted()
        {
            LuaCsLogger.Log("[XsGetItemsCache] 已加载");
        }

        public void PreInitPatching() { }

        public void Dispose()
        {
            try { _harmony?.UnpatchSelf(); } catch { }
            Cache.Clear();
            LuaCsLogger.Log($"[XsGetItemsCache] 已卸载 | 命中={_hits} 未命中={_misses}");
        }

        // ── 命中/未命中记录（顺带做统计与清理）──
        internal static void RecordHit()
        {
            _hits++;
            TickHousekeeping();
        }

        internal static void RecordMiss()
        {
            _misses++;
            TickHousekeeping();
        }

        private static void TickHousekeeping()
        {
            float now = (float)Timing.TotalTime;

            if (now >= _nextSweep)
            {
                _nextSweep = now + SweepInterval;
                SweepDeadEntries(now);
            }

            if (now >= _nextReport)
            {
                _nextReport = now + 30f;
                long total = _hits + _misses;
                if (total <= 0) return;

                LuaCsLogger.Log(
                    $"[XsGetItemsCache] 命中 {_hits}/{total} " +
                    $"({_hits * 100.0 / total:F1}%) | 缓存条目 {Cache.Count}");
            }
        }

        private static void SweepDeadEntries(float now)
        {
            if (Cache.Count == 0) return;

            List<Submarine> dead = null;
            foreach (var kv in Cache)
            {
                bool expired = now - kv.Value.stamp > 60f;
                bool gone = kv.Key == null || kv.Key.Removed;
                if (expired || gone)
                {
                    if (dead == null) dead = new List<Submarine>();
                    dead.Add(kv.Key);
                }
            }

            if (dead == null) return;
            foreach (var s in dead) Cache.Remove(s);
        }

        internal static bool TryGet(Submarine sub, out List<Item> items)
        {
            items = null;
            if (sub == null) return false;
            if (!Cache.TryGetValue(sub, out var entry)) return false;
            if ((float)Timing.TotalTime - entry.stamp > CacheTTL) return false;

            items = entry.items;
            return items != null;
        }

        internal static void Store(Submarine sub, List<Item> items)
        {
            if (sub == null || items == null) return;
            Cache[sub] = (items, (float)Timing.TotalTime);
        }
    }

    [HarmonyPatch]
    internal static class GetItemsCachePatch
    {
        [HarmonyTargetMethod]
        static MethodBase TargetMethod()
        {
            foreach (var m in typeof(Submarine).GetMethods(BindingFlags.Public | BindingFlags.Instance))
            {
                if (m.Name == "GetItems") return m;
            }
            return null;
        }

        /// <summary>
        /// 只缓存 alsoFromConnectedSubs == true 的调用。
        /// false 的调用一律走原方法，避免影响无关逻辑。
        /// </summary>
        [HarmonyPrefix]
        static bool Prefix(Submarine __instance, bool alsoFromConnectedSubs, ref List<Item> __result)
        {
            if (!alsoFromConnectedSubs) return true;

            if (GetItemsCachePlugin.TryGet(__instance, out var cached))
            {
                __result = cached;
                GetItemsCachePlugin.RecordHit();
                return false;
            }

            GetItemsCachePlugin.RecordMiss();
            return true;
        }

        [HarmonyPostfix]
        static void Postfix(Submarine __instance, bool alsoFromConnectedSubs, List<Item> __result)
        {
            if (!alsoFromConnectedSubs) return;
            GetItemsCachePlugin.Store(__instance, __result);
        }
    }
}
