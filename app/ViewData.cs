using System;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexUsageMonitor;

using Cells = Dictionary<string, string>;

static class ViewData
{
    public static JsonElement J(this JsonElement json, string key) =>
        json.ValueKind == JsonValueKind.Object && json.TryGetProperty(key, out var value) ? value : default;
    public static string S(this JsonElement json, string key) => json.J(key).Text();
    public static string Text(this JsonElement json) => json.Valid() ? json.ToString() : "";
    public static bool Valid(this JsonElement json) => json.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined);
    public static double? Number(this JsonElement json) => json.ValueKind == JsonValueKind.Number && json.TryGetDouble(out var n) ? n : null;
    public static double N(this JsonElement json, string key) => json.J(key).Number() ?? 0;
    public static bool B(this JsonElement json, string key) => json.J(key).ValueKind == JsonValueKind.True;
    public static JsonElement[] A(this JsonElement json, string key) => json.J(key).ValueKind == JsonValueKind.Array ? json.J(key).EnumerateArray().ToArray() : [];
    public static string Count(this JsonElement json, string key) => json.J(key).Number()?.ToString("N0", CultureInfo.InvariantCulture) ?? "未知";
    public static string Rate(this JsonElement json, string key) => json.J(key).Number()?.ToString("N2", CultureInfo.InvariantCulture) ?? "未知";
    public static string Pct(this JsonElement json, string key) => json.J(key).Number() is double n ? $"{n:0.00}%" : "—";
    public static string Estimate(this JsonElement json) => FormatEstimate(json.N("week_total"),
        json.J("quota_estimate").Number(), json.S("quota_estimate_status"));
    public static string CycleShare(this JsonElement json, string key)
    {
        var share = json.J("cycle_share");
        return FormatEstimate(json.N("week_total"), share.J(key).Number(), share.S("basis"));
    }
    static string FormatEstimate(double tokens, double? amountValue, string basis)
    {
        if (tokens <= 0) return "—";
        if (amountValue is not double value) return "待数据";
        var amount = value is > 0 and < 0.01 ? "<0.01%" : value.ToString("0.##", CultureInfo.InvariantCulture) + "%";
        return basis is "provisional" or "weighted" ? $"≈ {amount}" : amount;
    }
    public static string EstimateStatus(this JsonElement json, string key = "quota_estimate_status") => json.S(key) switch {
        "validated" => "已验证",
        "provisional" => "暂估",
        "weighted" => "本机计费权重分摊",
        _ => "等待可用记录"
    };
    public static string Stamp(this JsonElement json, string key) => Date(json.N(key));
    public static string Date(double ms) => ms > 0 && ms < 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms).ToOffset(TimeSpan.FromHours(8)).ToString("MM-dd HH:mm:ss") : "—";
    public static string Duration(this JsonElement json, string key) => json.J(key).Number() is double ms ? Duration(ms) : "—";
    public static string Duration(double ms) {
        var t = TimeSpan.FromMilliseconds(Math.Clamp(ms, 0, 1e14));
        return ms < 60000 ? $"{ms/1000:0.0} 秒" : t.TotalHours >= 1 ? $"{Math.Floor(t.TotalHours)} 时 {t.Minutes} 分" : $"{t.Minutes} 分 {t.Seconds} 秒";
    }
    public static string Title(this JsonElement json) => Clean(json.S("title"));
    public static string Clean(string value) => Regex.Replace(value, "[\r\n]+", " ").Trim();
    public static string Known(string value) => value is "" or "unknown" ? "未记录" : value;
    public static string Tier(this JsonElement json) => json.S("tier") switch { "default" => "标准", "priority" => "优先", var value => Known(value) };
    public static string Effort(this JsonElement json) => Known(json.S("effort"));
    public static string Kind(string source) => source switch {
        "subagent" => "子代理", "guardian_review" or "guardian" => "审批子会话", "fork" => "分叉", "attached" => "附属会话",
        "interaction" => "会话交互", "agent_created_thread" => "代理创建", _ => "主会话"
    };
    public static string State(string state) => state switch {
        "running" => "进行中", "quiet" => "较久无更新", "completed" => "已完成", "interrupted" => "已中断", "failed" => "失败",
        "starting" => "会话已开始", "waiting" => "等待回答", _ => "状态未知"
    };
    public static Cells Row(string id, params (string Key, string Value)[] columns) {
        var row = new Cells { ["Id"] = id };
        foreach (var (key, value) in columns) row[key] = value;
        return row;
    }
    public static Cells Fact(string id, string label, string value) => Row(id, ("Label", label), ("Value", value.Length == 0 ? "—" : value));
    public static string Id(this object? item) => item is DataRowView row ? (string)row["Id"] : "";

    public static IEnumerable<(T Item, int Depth)> Tree<T>(IEnumerable<T> ordered, Func<T,string> id,
        Func<T,string> parent, Func<string,bool>? expanded = null)
    {
        var items = ordered.ToArray();
        var ids = items.Select(id).ToHashSet();
        var children = items.Where(x => parent(x) != id(x) && ids.Contains(parent(x))).ToLookup(parent);
        var roots = items.Where(x => parent(x) == id(x) || !ids.Contains(parent(x)));
        var seen = new HashSet<string>();
        foreach (var root in expanded == null ? roots.Concat(items) : roots)
        {
            var stack = new Stack<(T Item, int Depth)>();
            stack.Push((root, 0));
            while (stack.TryPop(out var entry))
            {
                var key = id(entry.Item);
                if (!seen.Add(key)) continue;
                yield return entry;
                if (expanded == null || expanded(key))
                    foreach (var child in children[key].Reverse()) stack.Push((child, entry.Depth + 1));
            }
        }
    }
    public static double Scale(IEnumerable<double> values) {
        var max = values.Where(double.IsFinite).Append(0).Max();
        if (max <= 0) return 1;
        var step = Math.Pow(10, Math.Floor(Math.Log10(max)));
        return Math.Ceiling(max / step) * step;
    }
}

sealed class StateTable
{
    public DataTable Table { get; } = new();
    public DataView View => Table.DefaultView;
    public StateTable(string fields) {
        Table.PrimaryKey = [Table.Columns.Add("Id", typeof(string))];
        Table.Columns.Add("SortIndex", typeof(int));
        foreach (var field in fields.Split(' ', StringSplitOptions.RemoveEmptyEntries)) Table.Columns.Add(field, typeof(string));
        View.Sort = "SortIndex ASC";
    }
    public void Sync(IEnumerable<Cells> items)
    {
        var seen = new HashSet<string>();
        int index = 0;
        foreach (var cells in items)
        {
            var id = cells["Id"];
            if (id.Length == 0 || !seen.Add(id)) continue;
            var old = Table.Rows.Find(id);
            var row = old ?? Table.NewRow();
            if (old == null) row["Id"] = id;
            if (old == null || (int)row["SortIndex"] != index) row["SortIndex"] = index;
            foreach (DataColumn col in Table.Columns)
            {
                if (col.ColumnName is "Id" or "SortIndex") continue;
                var value = cells.GetValueOrDefault(col.ColumnName, "");
                if (old == null || (string)row[col] != value) row[col] = value;
            }
            if (old == null) Table.Rows.Add(row);
            index++;
        }
        for (var i = Table.Rows.Count - 1; i >= 0; i--)
            if (!seen.Contains((string)Table.Rows[i]["Id"])) Table.Rows.RemoveAt(i);
    }
}
