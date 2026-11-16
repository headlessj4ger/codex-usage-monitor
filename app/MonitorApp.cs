using System;
using System.Collections.Generic;
using System.Data;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Path = System.IO.Path;
using System.Xml;
using Forms = System.Windows.Forms;
using static CodexUsageMonitor.ViewData;

namespace CodexUsageMonitor;

sealed partial class MonitorApp : IDisposable
{
    readonly Application app;
    readonly Storage storage;
    readonly CollectorClient backend;
    readonly Window main;
    readonly DispatcherTimer poll;
    readonly Forms.NotifyIcon? tray;
    readonly Forms.ContextMenuStrip? trayMenu;
    readonly Dictionary<string, StateTable> tables = new();
    readonly HashSet<string> expanded = new();
    readonly bool demoMode;
    bool closing, syncing, details = true;
    string page = "Live", selectedSession = "", detailTarget = "";
    JsonElement snapshot, speed, processData, chartRow;
    Dictionary<string, JsonElement> sessions = new(), speedRows = new(), processes = new();
    Dictionary<string, string> parents = new();
    readonly int[] refreshValues = [5,10,30,60,300,0];
    readonly int[] miniRefreshValues = [5,10,30,60,0];
    readonly string[] navButtons = ["NavLive","NavSessions","NavModels","NavProcesses"];
    readonly string[] pages = ["Live","Session","Model","Process"];
    int refresh, miniRefresh;
    public Dispatcher Dispatcher => app.Dispatcher;
    static string IdOf(JsonElement row) => row.S("id");
    int Interval => mini?.IsVisible == true ? miniRefresh : refresh;

    public MonitorApp(Application app, Storage storage, string command)
    {
        this.app = app;
        this.storage = storage;
        demoMode = command is "demo" or "self-test";
        backend = new(storage);
        main = Load("window.xaml");
        main.Icon = new BitmapImage(new Uri(Path.Combine(Program.Base, "assets/app.ico")));
        U<Image>("AppLogo").Source = new BitmapImage(new Uri(Path.Combine(Program.Base, "assets/logo.png")));
        var area = SystemParameters.WorkArea;
        main.Width = Math.Min(1440, area.Width - 60);
        main.Height = Math.Min(900, area.Height - 60);
        refresh = storage.Get("refreshSeconds", 30);
        miniRefresh = storage.Get("miniRefreshSeconds", 5);
        if (!refreshValues.Contains(refresh)) refresh = 30;
        if (!miniRefreshValues.Contains(miniRefresh)) miniRefresh = 5;

        var schemas = new Dictionary<string, string> {
            ["Live"]="Title Subtitle Tooltip State Tone Rate Elapsed", ["Session"]="Title Subtitle Tooltip Indent Chevron Week Estimate",
            ["Model"]="Title Subtitle Week Estimate Samples", ["Process"]="Title Subtitle Tooltip Indent Pid Memory",
            ["DetailFacts"]="Label Value", ["SessionFacts"]="Label Value", ["Commands"]="Title Subtitle Tooltip State Duration",
            ["SessionModels"]="Title Subtitle Tooltip Total", ["Daily"]="Day Total", ["Relations"]="Title Subtitle Tooltip Other"
        };
        foreach (var (key, schema) in schemas) {
            var table = tables[key] = new(schema);
            U<ItemsControl>(key.EndsWith("Facts") ? key : key + "Grid").ItemsSource = table.View;
        }
        ConfigureMain();
        poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        poll.Tick += (_, _) => Safe(Tick);
        app.DispatcherUnhandledException += (_, e) => { Error(e.Exception); e.Handled = true; };
        if (!demoMode)
        {
            trayMenu = new Forms.ContextMenuStrip();
            trayMenu.Items.Add("打开用量透视", null, (_, _) => Safe(() => Show("main")));
            trayMenu.Items.Add("悬浮小窗", null, (_, _) => Safe(() => Show("mini")));
            trayMenu.Items.Add("立即刷新", null, (_, _) => Safe(Refresh));
            trayMenu.Items.Add("退出程序", null, (_, _) => Exit());
            tray = new Forms.NotifyIcon { Icon = new System.Drawing.Icon(Path.Combine(Program.Base,"assets/app.ico")),
                Text = "Codex 用量透视 " + Program.Version, Visible = true, ContextMenuStrip = trayMenu };
            tray.DoubleClick += (_, _) => Safe(() => Show("main"));
        }
        Dispatcher.BeginInvoke(() => {
            if (demoMode) { Safe(() => StartDemo(command == "self-test")); return; }
            Safe(() => {
                try { Show(command); backend.Start(Interval); }
                catch (Exception error) {
                    Error(error);
                    if (!main.IsVisible && mini?.IsVisible != true)
                        tray?.ShowBalloonTip(5000, "Codex 用量透视", "采集启动失败，可从托盘重试。详情见数据目录中的 ui-errors.log。", Forms.ToolTipIcon.Error);
                }
            });
        });
        poll.Start();
    }

    internal static Window Load(string name)
    {
        var file = Path.Combine(Program.Base, name);
        using var reader = XmlReader.Create(file, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
        return (Window)XamlReader.Load(reader);
    }
    T U<T>(string name) where T : class => (T)(main.FindName(name) ?? throw new InvalidOperationException(name));
    void Text(string name, string value) { var text = U<TextBlock>(name); if (text.Text != value) text.Text = value; }
    void Visible(string name, bool visible) => U<UIElement>(name).Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    Brush BrushFor(string name) => (Brush)main.FindResource(name);
    string Color(string name) => BrushFor(name).ToString();
    ComboBox Combo(string name) => U<ComboBox>(name);
    bool Checked(string name) => U<ToggleButton>(name).IsChecked == true;
    DataGrid GridFor(string name) => U<DataGrid>(name + "Grid");
    void Click(string name, Action action) => U<ButtonBase>(name).Click += (_, _) => Safe(action);
    void Safe(Action action) { try { action(); } catch (Exception error) { Error(error); } }
    public void Error(Exception error)
    {
        try { File.AppendAllText(Path.Combine(storage.Data, "ui-errors.log"), $"{DateTimeOffset.Now:O} {error}\n"); } catch (IOException) { }
        Text("StatusText", "操作未完成：" + error.Message);
        if (demoMode && demo != null) ((TextBlock)demo.FindName("DemoHint")).Text = error.Message;
        if (selfTest) { Console.Error.WriteLine(error); Exit(1); }
    }

    void ConfigureMain()
    {
        Combo("RefreshChoice").SelectedIndex = Array.IndexOf(refreshValues, refresh);
        Combo("RefreshChoice").ToolTip = "完整统计的采样间隔。状态随本地记录变化更新；仅手动会暂停全部自动采集。";
        Combo("SessionOrder").SelectedIndex = 0;
        Combo("RefreshChoice").SelectionChanged += (_, _) => Safe(() => {
            var index = Combo("RefreshChoice").SelectedIndex;
            if (index < 0) return;
            refresh = refreshValues[index]; storage.Set("refreshSeconds", refresh); Send("configure");
        });
        Combo("SessionOrder").SelectionChanged += (_, _) => { if (!syncing) Safe(RenderPage); };
        Click("MiniModeButton", () => Show("mini"));
        Click("RefreshButton", Refresh);
        Click("DetailsButton", () => SetDetails(!details));
        Click("CloseDetails", () => SetDetails(false));
        foreach (var name in new[] {"Minimize","CloseWindow"}) Click(name, HideMain);
        Click("Maximize", ToggleMaximize);
        foreach (var name in new[] {"MoreButton","SettingsButton"})
        {
            var button = U<ButtonBase>(name);
            button.ContextMenu = AppMenu();
            Click(name, () => { button.ContextMenu.PlacementTarget = button; button.ContextMenu.Placement = PlacementMode.Bottom; button.ContextMenu.IsOpen = true; });
        }
        for (int i = 0; i < pages.Length; i++) {
            var target = pages[i];
            U<ToggleButton>(navButtons[i]).Checked += (_, _) => { if (!syncing) Safe(() => ShowPage(target)); };
            GridFor(target).SelectionChanged += (_, _) => { if (!syncing) Safe(RenderSelection); };
        }
        Click("HelpButton", () => {
            foreach (var key in navButtons) U<ToggleButton>(key).IsChecked = false;
            ShowPage("Help");
        });
        foreach (var name in new[] {"RecentFilter","GuardianFilter","StaleFilter","SessionGuardians","ArchivedFilter"}) Click(name, RenderPage);
        var search = U<TextBox>("Search");
        var searchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        searchTimer.Tick += (_, _) => {
            searchTimer.Stop();
            Safe(() => { if (search.Text.Length > 0 && page != "Session") U<ToggleButton>("NavSessions").IsChecked = true; else RenderPage(); });
        };
        search.TextChanged += (_, _) => { Visible("SearchHint", search.Text.Length == 0); if (!syncing) { searchTimer.Stop(); searchTimer.Start(); } };
        GridFor("Session").AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((_, e) => {
            if (e.OriginalSource is Button { Tag: string id, Content: string { Length: > 0 } }) {
                if (!expanded.Add(id)) expanded.Remove(id);
                e.Handled = true; Safe(RenderPage);
            }
        }));
        GridFor("Session").PreviewKeyDown += (_, e) => Safe(() => {
            if (Combo("SessionOrder").SelectedIndex != 0 || GridFor("Session").SelectedItem is not DataRowView row) return;
            var id = row.Id();
            if (e.Key == Key.Right && (string)row["Chevron"] != "") { expanded.Add(id); RenderPage(); e.Handled = true; }
            if (e.Key == Key.Left) { if (expanded.Remove(id)) RenderPage(); else SelectRow("Session", parents.GetValueOrDefault(id, "")); e.Handled = true; }
        });
        Click("OpenSession", () => SelectSession(detailTarget));
        GridFor("Live").MouseDoubleClick += (_, _) => Safe(() => SelectSession(GridFor("Live").SelectedItem.Id()));
        GridFor("Relations").MouseDoubleClick += (_, _) => Safe(() => { if (GridFor("Relations").SelectedItem is DataRowView row) SelectSession((string)row["Other"]); });
        U<FrameworkElement>("CaptionBar").MouseLeftButtonDown += (_, e) => Safe(() => {
            if (InsideButton(e.OriginalSource as DependencyObject)) return;
            if (e.ClickCount == 2) ToggleMaximize(); else main.DragMove();
        });
        main.StateChanged += (_, _) => {
            if (main.WindowState == WindowState.Minimized) HideMain();
            U<Button>("Maximize").Content = main.WindowState == WindowState.Maximized ? "❐" : "□";
        };
        main.SizeChanged += (_, _) => Safe(UpdateSize);
        U<Canvas>("TrendCanvas").SizeChanged += (_, _) => { if (chartRow.Valid()) Safe(() => RenderTrend(chartRow)); };
        main.PreviewKeyDown += (_, e) => Safe(() => {
            var mods = Keyboard.Modifiers;
            if (e.Key == Key.M && mods.HasFlag(ModifierKeys.Control | ModifierKeys.Shift)) Show("mini");
            else if (e.Key == Key.F5) Refresh();
            else if (e.Key == Key.F && mods.HasFlag(ModifierKeys.Control)) { search.Focus(); search.SelectAll(); }
            else if (e.Key == Key.Escape && !Combo("RefreshChoice").IsDropDownOpen && !Combo("SessionOrder").IsDropDownOpen &&
                     !U<Button>("MoreButton").ContextMenu.IsOpen && !U<Button>("SettingsButton").ContextMenu.IsOpen) SetDetails(false);
            else return;
            e.Handled = true;
        });
        main.Closing += (_, e) => { if (!closing) { e.Cancel = true; HideMain(); } };
        Text("MethodText", MethodText);
        InitChart();
        ShowPage("Live");
    }

    static bool InsideButton(DependencyObject? node)
    {
        while (node != null) {
            if (node is ButtonBase) return true;
            node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) :
                node is FrameworkContentElement content ? content.Parent : null;
        }
        return false;
    }

    ContextMenu AppMenu()
    {
        var menu = new ContextMenu { Style = (Style)main.FindResource(typeof(ContextMenu)) };
        var autostart = Add("登录 Windows 后启动", () => {}, check: true);
        autostart.Click += (_, _) => Safe(() => storage.SetAutostart(autostart.IsChecked));
        menu.Opened += (_, _) => Safe(() => autostart.IsChecked = storage.Autostart);
        menu.Items.Insert(0, Item("导出全部会话 CSV", Export));
        menu.Items.Insert(1, Item("打开数据目录", () => Process.Start(new ProcessStartInfo(storage.Data) { UseShellExecute = true })));
        Add("悬浮小窗", () => Show("mini"));
        Add("收起到托盘", HideMain);
        Add("退出程序", () => Exit());
        return menu;
        MenuItem Item(string title, Action action, bool check = false) {
            var item = new MenuItem { Header = title, IsCheckable = check, Style = (Style)main.FindResource(typeof(MenuItem)) };
            item.Click += (_, _) => Safe(action);
            return item;
        }
        MenuItem Add(string title, Action action, bool check = false) { var item = Item(title, action, check); menu.Items.Add(item); return item; }
    }

    void ToggleMaximize() => main.WindowState = main.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    void HideMain() { main.Hide(); main.ShowInTaskbar = false; }
    public void Show(string command)
    {
        if (demoMode) { demo?.Activate(); return; }
        if (command == "start") command = storage.Get("lastView", "Main") == "Mini" ? "mini" : "main";
        if (command == "mini") { ShowMini(); return; }
        HideMini();
        if (command == "tray") { HideMain(); return; }
        storage.Set("lastView", "Main");
        main.ShowInTaskbar = true;
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }
    void Exit(int code = 0) { if (closing) return; closing = true; poll.Stop(); app.Shutdown(code); }
    void Send(string action, string id = "", string turn = "") => backend.Send(action, Interval, id, turn);
    void Refresh()
    {
        if (demoMode) return;
        if (!backend.Running) backend.Start(Interval); else Send("refresh");
        Text("ConnectionText", "正在采集…");
    }
    void Tick()
    {
        if (demoMode) { TickDemo(); return; }
        for (var i = 0; i < 8 && backend.Messages.TryDequeue(out var message); i++)
        {
            if (string.IsNullOrEmpty(message.Line)) continue;
            if (message.Error) { Text("StatusText", message.Line); continue; }
            using var json = JsonDocument.Parse(message.Line);
            var data = json.RootElement.Clone();
            switch (data.S("type"))
            {
                case "snapshot": ApplySnapshot(data); break;
                case "activity": ApplySpeed(data); if (page == "Live" && main.IsVisible) RenderPage(); RenderMini(); break;
                case "processes": processData = data; if (page == "Process" && main.IsVisible) RenderPage(); break;
                case "detail": ApplyDetail(data); break;
                case "error": Text("StatusText", "采集异常：" + data.S("message")); break;
            }
        }
        if (!backend.Running) { Text("ConnectionText", "采集器已停止 · 可点击刷新重试"); U<Shape>("ConnectionDot").Fill = BrushFor("Error"); }
        TickMini();
    }
    void SetDetails(bool show)
    {
        details = show;
        Visible("DetailPane", show && page != "Help");
        U<ColumnDefinition>("DetailColumn").Width = new(show && page != "Help" ? (main.ActualWidth < 1220 ? 310 : 350) : 0);
    }
    void UpdateSize()
    {
        U<ColumnDefinition>("SidebarColumn").Width = new(main.ActualWidth < 1220 ? 184 : 208);
        SetDetails(details);
        U<FrameworkElement>("QuotaFill").Width = U<FrameworkElement>("QuotaTrack").ActualWidth * Math.Clamp(snapshot.J("quota").N("used_percent"), 0, 100) / 100;
        if (chartRow.Valid()) RenderTrend(chartRow);
    }
    void ShowPage(string name)
    {
        page = name;
        foreach (var key in pages) Visible(key + "Grid", key == name);
        Visible("HelpView", name == "Help"); Visible("LiveFilters", name == "Live"); Visible("SessionFilters", name == "Session");
        Visible("ContextNote", name is "Model" or "Process");
        Text("PageTitle", name switch { "Live" => "进行中", "Session" => "全部会话", "Model" => "模型与校准", "Process" => "进程关联", _ => "统计口径" });
        if (name == "Help") Text("PageSubtitle", "数据来源、边界与计算方式");
        SetDetails(details);
        RenderPage();
    }
    void ApplySnapshot(JsonElement data)
    {
        snapshot = data;
        processData = data;
        sessions = data.A("sessions").ToDictionary(IdOf);
        parents = new();
        foreach (var edge in data.A("edges"))
        {
            var child = edge.S("child_id"); var parent = edge.S("parent_id");
            if (edge.S("kind") == "interaction" || !sessions.ContainsKey(child) || !sessions.ContainsKey(parent) || parents.ContainsKey(child)) continue;
            if (child == parent || Ancestors(parent).Contains(child)) continue;
            parents[child] = parent;
        }
        ApplySpeed(data);
        var q = data.J("quota"); var c = data.J("coverage");
        Text("QuotaValue", q.J("used_percent").Number() is double n ? $"{n:0}% 已用" : "未知");
        Text("QuotaStamp", q.B("expired") ? "快照已过期" : q.N("at_ms") > 0 ? "快照 " + q.Stamp("at_ms") : "尚无账户快照");
        U<TextBlock>("QuotaStamp").ToolTip = "账户配额快照；重置：" + Date(q.N("reset_at") * 1000);
        var total = data.N("week_total");
        Text("WeekUsage", "本机周期 " + (total >= 1e6 ? $"{total / 1e6:0.00} M" : total >= 1e3 ? $"{total / 1e3:0.0} K" : data.Count("week_total")) + " token");
        U<TextBlock>("WeekUsage").ToolTip = $"周期 {data.J("period").Stamp("start")} — {data.J("period").Stamp("end")}（北京时间）";
        Text("ConnectionText", "本地采集 · " + data.Stamp("last_scan"));
        U<Shape>("ConnectionDot").Fill = BrushFor("Accent");
        Text("StatusText", $"{c.Count("sessions")} 个会话 · {c.Count("with_logs")} 个有日志 · {c.Count("metadata_only")} 个仅累计快照");
        U<TextBlock>("StatusText").ToolTip = string.Join("\n", data.A("warnings").Select(x => x.Text()));
        UpdateSize();
        RenderPage();
        RenderMini();
    }
    double lastSpeedAt;
    void ApplySpeed(JsonElement data) {
        speed = data.J("speed");
        lastSpeedAt = data.N("at");
        speedRows = speed.A("rows").ToDictionary(IdOf);
        foreach (var row in speed.A("activity")) speedRows[IdOf(row)] = row;
        Text("LiveCount", speed.A("rows").Count(s => s.B("is_open") && !s.B("long_stale") && s.S("source") != "guardian_review").ToString());
    }
    IEnumerable<string> Ancestors(string id) {
        while (parents.TryGetValue(id, out var parent)) { yield return parent; id = parent; }
    }
    void SelectRow(string grid, string id)
    {
        if (tables[grid].Table.Rows.Find(id) == null) return;
        var g = GridFor(grid);
        var row = tables[grid].View.Cast<DataRowView>().First(x => x.Id() == id);
        g.SelectedItem = row;
        g.ScrollIntoView(row);
    }
    void SelectSession(string id)
    {
        if (!sessions.ContainsKey(id)) return;
        syncing = true;
        try {
            U<TextBox>("Search").Clear();
            U<ToggleButton>("SessionGuardians").IsChecked = true; U<ToggleButton>("ArchivedFilter").IsChecked = true;
            Combo("SessionOrder").SelectedIndex = 0;
            expanded.UnionWith(Ancestors(id));
            U<ToggleButton>("NavSessions").IsChecked = true;
        } finally { syncing = false; }
        ShowPage("Session"); SetDetails(true); SelectRow("Session", id);
    }
    void Export()
    {
        if (!snapshot.Valid()) return;
        var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV 文件 (*.csv)|*.csv", FileName = $"Codex用量-{DateTime.Now:yyyyMMdd}.csv" };
        if (dialog.ShowDialog(main) != true) return;
        using var writer = new StreamWriter(dialog.FileName, false, new UTF8Encoding(true));
        writer.WriteLine("会话ID,标题,类型,累计token,逐条累计token,周期token,缓存输入token,输出token,本机周期占比,周配额校准占比,校准状态,token分摊参考,完整性,周期开始北京时间,周期结束北京时间,配额快照北京时间");
        foreach (var s in sessions.Values)
        {
            string title = s.S("title");
            if (title.Length > 0 && "=+@-\t\r".Contains(title[0])) title = "'" + title;
            var fields = new[] { IdOf(s),title,Kind(s.S("source")),s.S("total"),s.S("recorded"),s.B("week_known") ? s.S("week_total") : "未知",
                s.S("cached"),s.S("output"),s.S("local_share"),s.S("quota_estimate"),snapshot.J("calibration").S("reason"),s.S("quota_allocation"),Coverage(s),
                snapshot.J("period").Stamp("start"),snapshot.J("period").Stamp("end"),snapshot.J("quota").Stamp("at_ms") };
            writer.WriteLine(string.Join(",", fields.Select(x => "\"" + x.Replace("\"", "\"\"") + "\"")));
        }
        Text("StatusText", $"已导出 {sessions.Count} 个会话：{dialog.FileName}");
    }
    public void Dispose()
    {
        closing = true;
        poll.Stop();
        if (tray != null) { tray.Visible = false; tray.Icon?.Dispose(); tray.Dispose(); }
        trayMenu?.Dispose();
        backend.Dispose();
    }
}
