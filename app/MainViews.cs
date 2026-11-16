using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Windows.Controls;
using System.Windows.Shapes;
using static CodexUsageMonitor.ViewData;

namespace CodexUsageMonitor;

using Cells = Dictionary<string,string>;

sealed partial class MonitorApp
{
    void RenderPage()
    {
        if (!snapshot.Valid()) return;
        var grid = page == "Help" ? null : GridFor(page);
        if (grid == null) { Visible("EmptyView", false); return; }
        var id = grid.SelectedItem.Id();
        syncing = true;
        try {
            switch (page) {
                case "Live":
                    var live = speed.A("rows").Where(s => (Checked("RecentFilter") || s.B("is_open")) &&
                        (Checked("GuardianFilter") || s.S("source") != "guardian_review") && (Checked("StaleFilter") || !s.B("long_stale"))).ToArray();
                    tables[page].Sync(live.Select(s => Row(IdOf(s), ("Title", s.Title()), ("Subtitle", $"{Kind(s.S("source"))} · {s.S("model")} / {s.Effort()}"),
                        ("Tooltip", s.S("title") + "\n" + IdOf(s)), ("State", State(s.S("state"))), ("Tone", Color(s.S("state") switch {
                            "running" => "Accent", "quiet" => "Warning", "failed" => "Error", _ => "TextMuted" })),
                        ("Rate", s.J("one").Rate("output_tps")), ("Elapsed", s.J("turn").Duration("elapsed_ms")))));
                    Text("PageSubtitle", $"{live.Length} 个会话 · 输出含推理 token");
                    break;
                case "Session":
                    tables[page].Sync(SessionRows());
                    Text("PageSubtitle", $"{tables[page].Table.Rows.Count} 行 · {(Combo("SessionOrder").SelectedIndex == 0 ? "按会话关联展开" : "所有会话用量排名")}");
                    break;
                case "Model":
                    var combinations = snapshot.A("combinations");
                    var cal = snapshot.J("calibration");
                    tables[page].Sync(combinations.Select(g => Row(g.S("key"), ("Title", g.S("model")), ("Subtitle", $"{g.Effort()} 思考 · {g.Tier()}"),
                        ("Week", g.Count("week_total")), ("Estimate", g.Estimate()), ("Samples", g.Count("calibration_samples")))));
                    Text("PageSubtitle", $"{combinations.Length} 个模型组合 · {cal.S("reason")}");
                    Text("ContextNote", Progress(cal)); U<TextBlock>("ContextNote").ToolTip = Progress(cal) + "\n" + Filters(cal);
                    break;
                case "Process":
                    tables[page].Sync(ProcessRows());
                    Text("PageSubtitle", $"{processes.Count} 个相关进程 · 保留系统父子关系");
                    Text("ContextNote", $"采样 {processData.Stamp("process_at")} · {(processData.S("process_error") is {Length: >0} error ? error : "会话归属按明确标识匹配")}");
                    U<TextBlock>("ContextNote").ToolTip = "自动采样至少间隔 15 秒；Codex 执行编号不是 Windows PID。";
                    break;
            }
            if (grid.SelectedItem.Id() != id && id != "")
                grid.SelectedItem = tables[page].View.Cast<System.Data.DataRowView>().FirstOrDefault(x => x.Id() == id);
            if (grid.SelectedItem == null && grid.Items.Count > 0) grid.SelectedIndex = 0;
            Visible("EmptyView", grid.Items.Count == 0);
        } finally { syncing = false; }
        RenderSelection();
    }

    IEnumerable<Cells> SessionRows()
    {
        var query = U<TextBox>("Search").Text.Trim();
        var order = Math.Clamp(Combo("SessionOrder").SelectedIndex,0,2);
        var allowed = sessions.Values.Where(s => (Checked("SessionGuardians") || s.S("source") != "guardian_review") &&
            (Checked("ArchivedFilter") || !s.B("archived")) && (query.Length == 0 ||
            $"{s.S("title")} {IdOf(s)} {s.S("cwd")} {s.S("agent_path")}".Contains(query, StringComparison.OrdinalIgnoreCase))).Select(IdOf).ToHashSet();
        if (query.Length > 0 && order == 0)
            foreach (var id in allowed.ToArray()) allowed.UnionWith(Ancestors(id));
        var key = new[] {"updated","week_total","total"}[order];
        var sorted = allowed.Select(id => sessions[id]).OrderByDescending(s => s.N(key)).ThenBy(IdOf).ToArray();
        string Parent(JsonElement s) => order == 0 ? parents.GetValueOrDefault(IdOf(s), "") : "";
        var childCounts = sorted.Where(s => allowed.Contains(Parent(s))).ToLookup(Parent);
        foreach (var (s, depth) in Tree(sorted, IdOf, Parent, id => query.Length > 0 || expanded.Contains(id))) {
            var id = IdOf(s); var count = childCounts[id].Count();
            yield return Row(id, ("Title", s.Title()), ("Subtitle", $"{Kind(s.S("source"))} · {s.S("model")}" +
                (count > 0 ? $" · {count} 个子会话" : "") + (s.B("archived") ? " · 已归档" : "")),
                ("Tooltip", $"{s.S("title")}\n{id}\n{s.S("cwd")}"), ("Indent", $"{Math.Min(depth,10)*16},0,0,0"),
                ("Chevron", count == 0 ? "" : query.Length > 0 || expanded.Contains(id) ? "⌄" : "›"),
                ("Week", s.B("week_known") ? s.Count("week_total") : "未知"), ("Estimate", s.Estimate()));
        }
    }

    IEnumerable<Cells> ProcessRows()
    {
        var list = processData.A("processes").OrderBy(p => p.N("pid")).ToArray();
        string ProcessId(JsonElement p) => p.S("pid") + "|" + p.S("created");
        var byPid = list.ToDictionary(p => p.S("pid"));
        processes = list.ToDictionary(ProcessId);
        string Parent(JsonElement p) =>
            byPid.TryGetValue(p.S("ppid"), out var parent) &&
            DateTimeOffset.TryParse(parent.S("created"), out var x) && DateTimeOffset.TryParse(p.S("created"), out var y) && x <= y ? ProcessId(parent) : "";
        foreach (var (p, depth) in Tree(list, ProcessId, Parent))
            yield return Row(ProcessId(p), ("Title", p.S("name")), ("Subtitle", sessions.TryGetValue(p.S("thread_id"), out var s) ? s.Title() : "会话归属未知 / 共享进程"),
                ("Indent", $"{Math.Min(depth,10)*16},0,0,0"), ("Pid", p.S("pid")), ("Memory", $"{p.N("memory")/1048576:N1}"),
                ("Tooltip", $"PPID {p.S("ppid")}\n创建于 {p.S("created")}\n关联依据：{p.S("association")}"));
    }

    void DetailHeader(string type, string title, string subtitle, string tip = "")
    {
        Text("DetailEyebrow", type); Text("DetailTitle", Clean(title)); U<TextBlock>("DetailTitle").ToolTip = title;
        Text("DetailSubtitle", subtitle); U<TextBlock>("DetailSubtitle").ToolTip = tip;
    }

    void RenderSelection()
    {
        if (syncing || !snapshot.Valid() || page == "Help") return;
        var id = GridFor(page).SelectedItem.Id();
        Visible("SessionDetailTabs", page == "Session" && id != "");
        Visible("LiveDetails", page != "Session" || id == "");
        Visible("SpeedMetrics", page == "Live" && id != ""); Visible("TrendSection", page == "Live" && id != "");
        Visible("OpenSession", false); detailTarget = "";
        if (id == "") {
            DetailHeader("详情", "选择一条记录", "选择会话、模型或进程以查看详情");
            tables["DetailFacts"].Sync([]); return;
        }
        switch (page) {
            case "Live":
                if (speedRows.TryGetValue(id, out var live)) RenderLive(live);
                break;
            case "Session":
                if (sessions.TryGetValue(id, out var session)) {
                    RenderSession(session);
                    if (selectedSession != id) {
                        selectedSession = id;
                        foreach (var key in new[] {"Commands","SessionModels","Daily","Relations"}) tables[key].Sync([]);
                        Send("detail", id);
                    }
                }
                break;
            case "Model": RenderModel(snapshot.A("combinations").FirstOrDefault(g => g.S("key") == id)); break;
            case "Process": if (processes.TryGetValue(id, out var p)) RenderProcess(p); break;
        }
    }

    void Facts(string key, params (string Label,string Value)[] facts) =>
        tables[key].Sync(facts.Select(x => Fact(x.Label, x.Label, x.Value)));

    void RenderLive(JsonElement s)
    {
        detailTarget = IdOf(s); Visible("OpenSession", true);
        var one = s.J("one"); var turn = s.J("turn");
        DetailHeader("会话 / 实时", s.S("title"), $"{State(s.S("state"))} · {s.S("model")} / {s.Effort()}");
        Text("RateOne", one.Rate("output_tps")); Text("RateFive", s.J("five").Rate("output_tps")); RenderTrend(s);
        var parent = s.S("parent_id");
        Facts("DetailFacts",
            ("统计范围", Kind(s.S("source")) + "自身"), ("父会话", sessions.TryGetValue(parent, out var p) ? p.Title() : parent == "" ? "无已知父会话" : parent),
            ("服务档位", s.Tier()), ("本轮平均输出", turn.Rate("average_output_tps") + " tok/s"), ("本轮 token", turn.Count("total")),
            ("其中输出", turn.Count("output")), ("其中推理输出", turn.Count("reasoning")),
            ("近 1 分钟非缓存", one.Rate("uncached_tpm") + " token/min"), ("近 1 分钟总用量", one.Rate("total_tpm") + " token/min"),
            ("近 1 分钟响应", one.Rate("responses_per_minute") + " 次/min"), ("缓存输入占比", one.Pct("cache_percent")),
            ("首响应入账等待", turn.J("first_record_wait_ms").Valid() ? turn.Duration("first_record_wait_ms") : s.B("is_open") ? "已等待 " + turn.Duration("elapsed_ms") : "未记录"),
            ("响应间隔中位数", turn.Duration("median_response_gap_ms")), ("命令执行用时", turn.Duration("command_ms") + " / " + turn.Pct("command_percent")),
            ("最后响应", turn.Stamp("last_record_at")), ("距上次响应", turn.N("last_record_at") > 0 ? Duration(speed.N("as_of") - turn.N("last_record_at")) : "尚无记录"),
            ("最后日志活动", s.Stamp("last_activity_at")), ("数据说明", !s.B("available") ? "日志缺失，速度未知。" : one.N("legacy_records") > 0 ?
                "含旧日志累计差值；响应频率未知。" : "按响应结束时记账；账面为 0 时会话仍可能运行。首响应等待不是首 token 延迟。命令耗时按区间并集计算，不含全部工具。"));
    }

    void RenderSession(JsonElement s)
    {
        var id = IdOf(s);
        DetailHeader("会话 / 用量", s.S("title"), Kind(s.S("source")) + " · " + id, s.S("cwd"));
        var children = parents.ToLookup(x => x.Value, x => x.Key);
        var family = new List<JsonElement>(); var stack = new Stack<string>(); stack.Push(id);
        while (stack.TryPop(out var next)) { family.Add(sessions[next]); foreach (var child in children[next]) stack.Push(child); }
        var c = snapshot.J("calibration");
        Facts("SessionFacts", ("自身累计 token",s.Count("total")), ("数据完整性", Coverage(s)),
            ("逐条累计 token", s.Count("recorded")), ("自身周期 token", s.B("week_known") ? s.Count("week_total") : "未知：缺少带时间戳日志"),
            ("本机周期占比", s.B("week_known") ? s.Pct("local_share") : "—"), ("周配额校准占比", s.Estimate()),
            ("校准状态", (!s.J("quota_estimate").Valid() && c.S("mode") == "learned" ? "含尚未校准的组合" : c.S("reason")) + "；截至 " + c.Stamp("as_of")),
            ("token 分摊参考", s.Pct("quota_allocation") + "；原始比例，未考虑模型差异"), ("输入 token",s.Count("input")), ("其中缓存输入",s.Count("cached")),
            ("输出 token",s.Count("output")), ("其中推理输出",s.Count("reasoning")), ("自身 + 子树累计", $"{family.Sum(x=>x.N("total")):N0} / {family.Count} 个会话"),
            ("自身 + 子树周期",$"{family.Sum(x=>x.N("week_total")):N0}（已记录部分）"), ("最近模型",s.S("model")), ("已记录响应",s.Count("requests")),
            ("已索引命令",s.Count("commands")), ("最后活动",s.Stamp("updated")), ("工作目录",s.S("cwd")));
    }
    static string Coverage(JsonElement s) => s.S("coverage") switch { "records" => "逐条用量", "metadata" => "仅累计快照", _ => "部分日志 + 累计快照" };

    void ApplyDetail(JsonElement d)
    {
        if (d.S("id") != selectedSession) return;
        if (d.S("error") is {Length: >0} error) { Text("StatusText",error); return; }
        tables["Commands"].Sync(d.A("commands").Select(c => Row(IdOf(c), ("Title",c.S("executable")), ("Subtitle",c.Stamp("start_ms")),
            ("State",c.S("status")), ("Duration",$"{c.N("duration_ms")/1000:0.00}"), ("Tooltip",$"执行编号 {c.S("process_ref")} · 退出码 {c.S("exit_code")}\n{c.S("cwd")}"))));
        tables["SessionModels"].Sync(d.A("models").Select(m => Row(m.S("key"), ("Title",m.S("model")), ("Subtitle",m.Effort() + " · " + m.Tier()), ("Total",m.Count("total")),
            ("Tooltip",$"未缓存输入 {m.Count("uncached")}\n缓存输入 {m.Count("cached")}\n输出 {m.Count("output")}\n其中推理 {m.Count("reasoning")}\n响应 {m.Count("requests")}"))));
        tables["Daily"].Sync(d.A("daily").Select(x => Row(x.S("day"), ("Day", x.S("day")), ("Total", x.Count("total")))));
        tables["Relations"].Sync(d.A("edges").Select(e => {
            var p = e.S("parent_id"); var c = e.S("child_id"); var kind = e.S("kind"); var outgoing = p == selectedSession;
            var other = outgoing ? c : p;
            return Row($"{p}|{c}|{kind}", ("Other",other), ("Title",sessions.TryGetValue(other,out var t) ? t.Title() : other),
                ("Subtitle",(outgoing ? "关联到 · " : "来自 · ") + Kind(kind)), ("Tooltip",e.S("evidence")+"\n"+other));
        }));
    }

    static string Progress(JsonElement c) => $"本周验证 {c.Count("current_cycle_holdout")} / 3 · 下一区间 {c.J("progress").N("interval_accumulated_pp"):0.#} / 3 百分点 · 有效 {c.Count("observations")} 区间";
    static string Filters(JsonElement c) {
        var s = c.J("skipped");
        return $"缺日志区间 {s.Count("missing")}；上下文不全区间 {s.Count("unknown")}；间隔过长 {s.Count("gap")} 次；快照回退 {s.Count("backwards")} 次";
    }
    void RenderModel(JsonElement g)
    {
        if (!g.Valid()) return;
        var c = snapshot.J("calibration");
        DetailHeader("模型 / 自动校准",g.S("model"),$"{g.Effort()} 思考 · {g.Tier()}");
        var current = g.J("rate").Valid();
        var rate = current ? g.J("rate") : g.J("historical_rate");
        var state = current ? "当前周期验证通过" : g.S("calibration_warning") is {Length: >0} warn ? warn : rate.Valid() ? "历史系数已保留；当前周期验证中" :
            g.S("effort") == "unknown" || g.S("model") == "unknown" ? "历史上下文缺失，无法回填" :
            g.N("calibration_samples") == 0 ? "尚无符合条件的区间" : c.S("mode") == "learned" ? "此组合样本不足，继续积累" : c.S("reason");
        string ErrorOf(string key) => c.J(key).Valid() ? $"{c.N(key):0.00} 个百分点" : "等待本周期验证";
        var history = c.J("historical");
        Facts("DetailFacts", ("本周期 token",g.Count("week_total")), ("周配额校准占比",g.Estimate()), ("组合校准状态",state), ("当前学习进度",Progress(c)),
            ("组合有效区间",g.Count("calibration_samples")), ("本周校准区间",$"已收集 {c.J("progress").Count("current_cycle_observations")}；可用于验证 {c.Count("current_cycle_holdout")}"),
            ("少见组合混用",c.Count("excluded_sparse") + " 个区间暂不用于拟合"),
            (!current && rate.Valid() ? "历史系数（参考）" : "当前采用系数",rate.Valid() ? string.Join(" / ",rate.A("rates").Select(r=>$"{r.Number():0.0000}"))+" 配额百分点 / 百万 token" : "尚无可靠系数"),
            ("换算口径",!rate.Valid() ? "等待可识别的模型组合" : rate.B("channel_model") ? "未缓存 / 缓存 / 输出" : "组合总 token"),
            ("全局训练 / 验证",$"{c.Count("train")} / {c.Count("holdout")} 个区间；近 {c.S("history_days")} 天"), ("本次验证误差", ErrorOf("mae")), ("统一换算误差",ErrorOf("baseline_mae")),
            ("历史验证时间",history.Stamp("as_of")), ("历史验证误差",history.Valid()? history.Rate("mae")+" 个百分点；仅供参考":"—"),
            ("数据过滤记录",Filters(c)), ("已校准 token 覆盖",c.N("eligible_tokens")>0?$"{100*c.N("covered_tokens")/c.N("eligible_tokens"):0.00}%":"—"),
            ("配额快照时间",c.Stamp("as_of")), ("历史累计 token",g.Count("total")), ("周期未缓存输入",g.Count("week_uncached")),
            ("周期缓存输入",g.Count("week_cached")), ("周期输出",g.Count("week_output")), ("其中推理输出",g.Count("week_reasoning")),
            ("周期 / 累计响应",$"{g.Count("week_requests")} / {g.Count("requests")}"), ("账户快照差值",ErrorOf("unexplained_quota")),
            ("套餐上下文",c.B("plan_unknown")?"日志未记录套餐；变更后需重新验证":"已记录"),
            ("估算说明","每个有效区间至少累计 3 个配额百分点。新周期需 3 个验证区间，并通过误差检查。历史系数保留作参考；新模型独立积累样本。"));
    }
    void RenderProcess(JsonElement p)
    {
        DetailHeader("进程 / 系统关联",p.S("name"),$"PID {p.S("pid")} · PPID {p.S("ppid")}");
        var owner = "未知 / 共享进程";
        if (sessions.TryGetValue(p.S("thread_id"),out var s)) { detailTarget = IdOf(s); owner = s.Title(); Visible("OpenSession",true); }
        Facts("DetailFacts",("PID",p.S("pid")),("父进程 PID",p.S("ppid")),
            ("创建时间",DateTimeOffset.TryParse(p.S("created"),out var time)?time.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss"):"未知"),
            ("工作集内存",$"{p.N("memory")/1048576:0.0} MB"),("累计 CPU 时间",$"{p.N("cpu"):0.00} 秒"),("关联会话",owner),
            ("关联依据",p.S("association") switch {"explicit"=>"命令中的明确会话标识","ancestor"=>"祖先进程的明确会话标识",_=>"未发现可靠会话标识"}),
            ("最近采样",processData.Stamp("process_at")), ("匹配说明","仅使用可核实的会话标识匹配。执行编号不是 Windows PID；共享进程可能无法归属单一会话。"));
    }

    readonly Line[] chartLines = new Line[3];
    readonly TextBlock[] chartLabels = new TextBlock[3];
    readonly Rectangle[] bars = new Rectangle[10];
    void InitChart()
    {
        var canvas = U<Canvas>("TrendCanvas");
        for (var i=0;i<3;i++) {
            canvas.Children.Add(chartLines[i] = new Line { Stroke=BrushFor("ChartGrid"), StrokeThickness=1 });
            canvas.Children.Add(chartLabels[i] = new TextBlock { FontSize=9, Foreground=BrushFor("TextMuted") });
        }
        for (var i=0;i<10;i++) canvas.Children.Add(bars[i] = new Rectangle { Fill=BrushFor("Chart"), RadiusX=2,RadiusY=2 });
    }
    void RenderTrend(JsonElement row)
    {
        chartRow = row;
        var width = Math.Max(200,U<Canvas>("TrendCanvas").ActualWidth)-32;
        const double height=112;
        var trend=row.A("trend");var scale=Scale(trend.Select(x=>x.N("output_tps")));
        for (var i=0;i<3;i++) {
            double y=10+i*height/2;
            chartLines[i].X2=width;chartLines[i].Y1=chartLines[i].Y2=y;
            chartLabels[i].Text=$"{scale*(1-i/2.0):0.#}";Canvas.SetLeft(chartLabels[i],width+6);Canvas.SetTop(chartLabels[i],y-6);
        }
        for (var i=0;i<10;i++) {
            var p=i<trend.Length?trend[i]:default;var b=bars[i];
            b.Width=width/10-6;b.Height=Math.Max(0,p.N("output_tps")/scale*height);
            Canvas.SetLeft(b,3+i*width/10); Canvas.SetTop(b,122-b.Height);
            b.ToolTip=$"{p.Stamp("at")} · {p.Rate("output_tps")} tok/s";
            b.Visibility=row.B("available")?System.Windows.Visibility.Visible:System.Windows.Visibility.Collapsed;
        }
        Text("TrendEmpty",row.B("available")?"本窗口尚无响应入账":"日志缺失，无法计算速度");
        Visible("TrendEmpty",!row.B("available")||!trend.Any(p=>p.N("output_tps")>0));
        Text("TrendStart",trend.Length==0?"":trend[0].Stamp("at"));Text("TrendEnd",trend.Length==0?"":trend[^1].Stamp("at"));
    }
}
