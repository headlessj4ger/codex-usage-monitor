using System;
using System.Collections.Generic;
using System.Data;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using static CodexUsageMonitor.ViewData;

namespace CodexUsageMonitor;

using Cells = Dictionary<string,string>;

sealed partial class MonitorApp
{
    Window? mini;
    StateTable? miniTable;
    ContextMenu? miniMenu;
    readonly Dictionary<string,DateTime> entering=new(), leaving=new();
    readonly Dictionary<int,MenuItem> miniIntervals=new();
    string[] miniOrder=[];
    bool? miniFresh;
    DateTime lastClock;
    bool acrylic;
    bool Motion => !storage.Get("reduceMotion",false) && SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
    T M<T>(string name) where T:class => (T)(mini!.FindName(name) ?? throw new InvalidOperationException(name));
    void MiniText(string name,string value) { var label=M<TextBlock>(name);if(label.Text!=value)label.Text=value; }
    void MiniVisible(string name,bool show) => M<UIElement>(name).Visibility=show?Visibility.Visible:Visibility.Collapsed;

    void EnsureMini()
    {
        if(mini!=null) return;
        mini=Load("mini.xaml"); mini.Icon=main.Icon;
        mini.Topmost=storage.Get("miniTopmost",true);
        var pin=M<ToggleButton>("MiniTopmost");pin.IsChecked=mini.Topmost;
        miniTable=new("Title Subtitle TitleTone SubtitleTone Rate RateTone Tone Branch Indent Tooltip Accessible ChartOpacity ChartLabel ChartTone ChartLastTone SeparatorVisibility State Mark RowFill MarkVisibility RateVisibility RingVisibility Phase Motion " +
            string.Join(" ",Enumerable.Range(0,10).SelectMany(i=>new[]{"H"+i,"T"+i})));
        var list=M<ListBox>("MiniList");list.ItemsSource=miniTable.View;
        var button=M<Button>("MiniRefresh");
        miniMenu=new ContextMenu{Style=(Style)mini.FindResource(typeof(ContextMenu))};
        foreach(var interval in miniRefreshValues)
        {
            var item=new MenuItem{Header=IntervalLabel(interval),Style=(Style)mini.FindResource(typeof(MenuItem)),IsCheckable=true};
            miniMenu.Items.Add(item);miniIntervals[interval]=item;
            item.Click+=(_,_)=>Safe(()=>{miniRefresh=interval;SaveMiniSetting("miniRefreshSeconds",interval);UpdateIntervals();Send("configure");TickMini(force:true);});
        }
        miniMenu.Items.Add(new Separator());
        var reduce=new MenuItem{Header="减少动画",Style=(Style)mini.FindResource(typeof(MenuItem)),IsCheckable=true,IsChecked=storage.Get("reduceMotion",false)};
        miniMenu.Items.Add(reduce);
        reduce.Click+=(_,_)=>Safe(()=>{if(demoMode)storage.Settings["reduceMotion"]=reduce.IsChecked;else storage.Set("reduceMotion",reduce.IsChecked);ClearMotion();RenderMini();});
        button.ContextMenu=miniMenu;
        button.Click+=(_,_)=>{miniMenu.PlacementTarget=button;miniMenu.Placement=PlacementMode.Top;miniMenu.IsOpen=true;};
        miniMenu.Closed+=(_,_)=>{if(mini.IsVisible)button.Focus();};
        M<Button>("MiniClose").Click+=(_,_)=>Safe(()=>{if(demoMode)Exit();else HideMini();});
        M<Button>("MiniExpand").Click+=(_,_)=>Safe(()=>{
            if(demoMode){demo?.Activate();return;}
            var id=list.SelectedItem.Id();Show("main");U<ToggleButton>("NavLive").IsChecked=true;SelectRow("Live",id);
        });
        pin.Click+=(_,_)=>Safe(()=>{mini.Topmost=pin.IsChecked==true;SaveMiniSetting("miniTopmost",mini.Topmost);});
        list.PreviewMouseLeftButtonUp+=(_,e)=>Safe(()=>{
            if(e.OriginalSource is DependencyObject origin && ItemsControl.ContainerFromElement(list,origin) is ListBoxItem { IsSelected:true }) OpenMiniSession();
        });
        mini.PreviewKeyDown+=(_,e)=>Safe(()=>{
            if(e.Key==Key.F5){Refresh();e.Handled=true;}
            if(e.Key==Key.Enter && list.IsKeyboardFocusWithin){OpenMiniSession();e.Handled=true;}
            if(e.Key==Key.Escape && !miniMenu.IsOpen){if(demoMode)Exit();else HideMini();e.Handled=true;}
        });
        M<FrameworkElement>("MiniCaption").MouseLeftButtonDown+=(_,e)=>Safe(()=>{
            if(InsideButton(e.OriginalSource as DependencyObject))return;
            mini.DragMove();SaveMiniPosition();
        });
        mini.Closing+=(_,e)=>{if(!closing){e.Cancel=true;Safe(()=>{if(demoMode)Exit();else HideMini();});}};
        mini.SourceInitialized+=(_,_)=>InitGlass();
        mini.Loaded+=(_,_)=>Safe(FixCaption);
        mini.Activated+=(_,_)=>Safe(FixCaption);
        mini.IsVisibleChanged+=(_,_)=>{if(mini.IsVisible)Safe(FixCaption);};
        UpdateIntervals();
    }

    void InitGlass()
    {
        var handle=new WindowInteropHelper(mini!).Handle;
        var source=HwndSource.FromHwnd(handle);
        if(source?.CompositionTarget==null)return;
        try {
            if(SystemParameters.HighContrast || CodexMiniGlass.Enable(handle) < 0) throw new InvalidOperationException("Desktop Acrylic unavailable.");
            source.CompositionTarget.BackgroundColor=Colors.Transparent;
            source.AddHook(CodexMiniGlass.FilterBackdropActivation);
            CodexMiniGlass.RefreshBackdropAppearance(handle);
            mini!.Background=Brushes.Transparent;
            M<Border>("MiniSurface").Background=BrushFor("GlassTint");
            acrylic=true;
        } catch {
            mini!.Background=BrushFor("WindowSurface");
            M<Border>("MiniSurface").Background=BrushFor("WindowSurface");
        }
    }
    void FixCaption() { var handle=new WindowInteropHelper(mini!).Handle;if(handle!=IntPtr.Zero)CodexMiniGlass.HideSystemCaptionButtons(handle); }
    void SaveMiniSetting<T>(string key,T value) { if(!demoMode)storage.Set(key,value); }
    void SaveMiniPosition() {
        if(demoMode || mini==null)return;
        storage.Set("miniLeft",mini.Left);storage.Set("miniTop",mini.Top);
    }
    static string IntervalLabel(int interval)=>interval>0?$"{interval} 秒刷新":"手动刷新";
    void UpdateIntervals() { foreach(var (value,item) in miniIntervals)item.IsChecked=miniRefresh==value;MiniText("MiniRefreshLabel",IntervalLabel(miniRefresh)); }
    void ShowMini()
    {
        EnsureMini();
        storage.Set("lastView","Mini");
        var w=mini!;var area=SystemParameters.WorkArea;
        SetMiniBounds(speed.A("activity").Length);
        w.Left=Math.Clamp(storage.Get("miniLeft",area.Right-w.Width-24),area.Left,Math.Max(area.Left,area.Right-w.Width));
        w.Top=Math.Clamp(storage.Get("miniTop",area.Bottom-w.Height-24),area.Top,Math.Max(area.Top,area.Bottom-w.Height));
        w.Show();HideMain();RenderMini();w.Activate();Send("configure");Refresh();
    }
    void HideMini()
    {
        if(mini?.IsVisible!=true)return;
        miniMenu!.IsOpen=false;SaveMiniPosition();mini.Hide();ClearMotion();Send("configure");
    }
    void SetMiniBounds(int count)
    {
        var w=mini!;var area=SystemParameters.WorkArea;
        double target=Math.Min(area.Height-32,count==0?208:118+52*Math.Min(6,Math.Max(1,count)));
        if(Math.Abs(w.Height-target)>.5)
        {
            double before=w.ActualHeight;
            w.BeginAnimation(FrameworkElement.HeightProperty,null);w.Height=target;
            if(w.IsVisible && before>0 && Motion) w.BeginAnimation(FrameworkElement.HeightProperty,new DoubleAnimation(before,target,TimeSpan.FromMilliseconds(220)) {
                FillBehavior=FillBehavior.Stop,EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}
            });
        }
        if(double.IsFinite(w.Top))w.Top=Math.Clamp(w.Top,area.Top,Math.Max(area.Top,area.Bottom-target));
    }
    void OpenMiniSession()
    {
        var id=M<ListBox>("MiniList").SelectedItem.Id(); if(id=="")return;
        if(demoMode){DemoClick(id);return;}
        if(!Guid.TryParseExact(id,"D",out _))throw new InvalidOperationException("此会话没有可打开的 Codex 会话 ID");
        try {
            Process.Start(new ProcessStartInfo("codex://threads/"+id){UseShellExecute=true});
            if(speedRows.TryGetValue(id,out var row) && !row.B("is_open") && !row.B("requires_input"))
                Send("acknowledge",id,row.S("turn_id"));
        } catch(Exception error) { MiniText("MiniStatus","打开失败 · 点击重试");MiniText("MiniFreshness",error.Message);throw; }
    }

    static string MiniRate(double? value)=>value is not double n || !double.IsFinite(n) || n<0?"—":
        n is >0 and <.1?"<0.1":n>=1000?(n/1000).ToString("0.0",CultureInfo.InvariantCulture)+"k":n.ToString("0.0",CultureInfo.InvariantCulture);
    double Age=>Math.Max(0,DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()-lastSpeedAt);
    bool Stale=>miniRefresh>0 && Age>1000*Math.Max(15,miniRefresh*2+5);
    bool Fresh=>demoMode || (snapshot.Valid() && backend.Running && !Stale);
    Cells MiniRow(JsonElement row,int depth,bool fresh,double scale)
    {
        var id=IdOf(row);var parent=row.S("parent_id");bool child=parent!="" || row.S("source")=="subagent";
        var title=row.Title() is {Length:>0} t?t:id;
        var model=Known(row.S("model"));var subtitle=(child?"子会话 · ":"")+(model=="未记录"?"模型未记录":model)+" · "+row.Effort();
        var state=row.S("display_state") is {Length:>0} s?s:row.S("state");
        var rate=fresh&&row.B("available")&&state!="starting"?MiniRate(row.J("one").J("output_tps").Number()):"—";
        var tone=Color(state switch {"waiting"=>"Warning","failed"=>"Error","interrupted" or "quiet"=>"TextMuted",_=>"Accent"});
        if(state=="completed")tone="#9CBEB1";
        var mark=state switch {"waiting"=>"?","failed" or "interrupted"=>"!","completed"=>"✓",_=>""};
        if(mark!="")rate="";
        var description=state switch {"failed"=>"会话出错，点击查看","interrupted"=>"会话已中断，点击查看","completed"=>"已完成，点击查看并收起","quiet"=>"暂无新用量记录",_=>State(state)};
        if(!fresh)description+=" · 数据待更新";
        var parentTitle=(sessions.TryGetValue(parent,out var parentRow)||speedRows.TryGetValue(parent,out parentRow))?parentRow.Title():"";
        var parentInList=(demoMode?demoRows.ContainsKey(parent):speed.A("activity").Any(x=>IdOf(x)==parent));
        var parentNote=parent==""?"":"父会话："+(parentTitle==""?parent:parentTitle)+(depth==0&&!parentInList?"（当前未显示）":"");
        var tooltip=$"{title}\n{subtitle}\n{description}"+(mark==""?$" · 近 1 分钟 {rate} tok/s":"")+"\n每行仅计自身输出，包含推理 token；响应结束后入账。"+(parentNote==""?"":"\n"+parentNote);
        bool idle=state=="interrupted"; if(idle)tone="#929BAA";
        var item=Row(id,("Title",title),("Subtitle",subtitle),("Rate",rate),("RateTone",idle?"#929BAA":Color(fresh?"TextPrimary":"TextMuted")),
            ("Tone",tone),("Branch",depth>0?"└":""),("Indent",$"{8+20*Math.Min(2,depth)},0,0,0"),("Tooltip",tooltip),
            ("Accessible",title+"，"+description+(mark==""?"，"+rate+" token 每秒":"")+(parentNote==""?"":"，"+parentNote)),
            ("ChartOpacity",fresh&&row.B("available")?"1":"0.3"),("ChartLabel",$"近 5 分钟输出速率，每柱 30 秒，共用刻度 0 至 {scale:0.###} token 每秒"),
            ("State",state),("Mark",mark),("RowFill",state=="waiting"?"#09DEBF83":state=="failed"?"#09F2949A":"Transparent"),
            ("ChartTone",idle?"#608994A3":state=="failed"?"#9BF2949A":state=="waiting"?"#807E919B":Color("Chart")),
            ("ChartLastTone",idle?"#908994A3":state=="waiting"?"#B07E919B":tone),
            ("TitleTone",idle?"#929BAA":Color("TextPrimary")),("SubtitleTone",idle?"#7E8999":Color("TextMuted")),
            ("MarkVisibility",mark!=""?"Visible":"Collapsed"),("RateVisibility",mark!=""?"Collapsed":"Visible"),
            ("RingVisibility",mark is "?" or "!"?"Visible":"Collapsed"),("SeparatorVisibility","Visible"));
        var trend=row.A("trend");
        for(int i=0;i<10;i++)
        {
            var point=i<trend.Length?trend[i]:default;
            item["H"+i]=Math.Clamp(row.B("available")?32*point.N("output_tps")/Math.Max(.000001,scale):0,0,32).ToString("0.###",CultureInfo.InvariantCulture);
            item["T"+i]=point.Valid()&&row.B("available")?$"{Date(point.N("at")-30000)} — {point.Stamp("at")}\n{MiniRate(point.J("output_tps").Number())} tok/s"+(fresh?"":"\n快照待更新"):"尚无用量记录";
        }
        return item;
    }

    void RenderMini()
    {
        if(mini?.IsVisible!=true)return;
        var rank=miniOrder.Select((id,i)=>(id,i)).ToDictionary(x=>x.id,x=>x.i);
        var ordered=(demoMode?demoRows.Values.ToArray():speed.A("activity")).OrderBy(row=>rank.GetValueOrDefault(IdOf(row),int.MaxValue)).ThenByDescending(row=>row.N("started_ms")).ThenBy(IdOf);
        var entries=Tree(ordered,IdOf,row=>row.S("parent_id")).ToArray();
        miniOrder=entries.Select(e=>IdOf(e.Item)).ToArray();
        var fresh=Fresh;var scale=Scale(entries.Where(e=>e.Item.B("available")).SelectMany(e=>e.Item.A("trend")).Select(x=>x.N("output_tps")));
        var rows=entries.Select(e=>MiniRow(e.Item,e.Depth,fresh,scale)).ToList();
        if(rows.Count>0)rows[^1]["SeparatorVisibility"]="Collapsed";
        var count=rows.Count;
        SyncMotion(rows);
        MiniText("MiniCount",count.ToString());
        var empty=miniTable!.Table.Rows.Count==0;
        MiniVisible("MiniEmpty",empty);MiniVisible("MiniList",!empty);
        MiniText("MiniEmptyTitle",snapshot.Valid()||demoMode?"暂无活跃会话":"正在读取会话");
        MiniText("MiniEmptyHint",snapshot.Valid()||demoMode?"新任务开始后会自动出现":"首次采集完成后自动显示");
        M<TextBlock>("MiniTrendHeader").ToolTip=$"每柱 30 秒 · 所有会话共用刻度 0–{scale:0.###} tok/s";
        SetMiniBounds(miniTable.Table.Rows.Count);
        miniFresh=fresh;TickMini(force:true,updateMotion:false);
    }
    void SyncMotion(List<Cells> rows)
    {
        var table=miniTable!.Table;var now=DateTime.UtcNow;var motion=Motion;
        var desired=rows.Select(r=>r["Id"]).ToHashSet();
        var selection=M<ListBox>("MiniList").SelectedItem.Id();
        foreach(var row in rows){
            var id=row["Id"];
            var returning=leaving.Remove(id);
            if(motion && (returning || table.Rows.Find(id)==null)) entering[id]=now.AddMilliseconds(240);
            row["Phase"]=motion && entering.ContainsKey(id)?"enter":"stable";row["Motion"]=motion?"yes":"no";
        }
        foreach(DataRow old in table.Rows) {
            var id=(string)old["Id"];if(desired.Contains(id))continue;
            entering.Remove(id);
            if(!motion){leaving.Remove(id);continue;}
            if(!leaving.TryGetValue(id,out var end))leaving[id]=end=now.AddMilliseconds(200);
            if(now>=end){leaving.Remove(id);continue;}
            var copy=table.Columns.Cast<DataColumn>().Where(c=>c.DataType==typeof(string)).ToDictionary(c=>c.ColumnName,c=>(string)old[c]);
            copy["Phase"]="exit";copy["Motion"]="yes";rows.Insert(Math.Min((int)old["SortIndex"],rows.Count),copy);
        }
        miniTable.Sync(rows);
        if(selection!="" && M<ListBox>("MiniList").SelectedItem.Id()!=selection)
            M<ListBox>("MiniList").SelectedItem=miniTable.View.Cast<DataRowView>().FirstOrDefault(x=>x.Id()==selection);
    }
    void ClearMotion()
    {
        entering.Clear();leaving.Clear();
        if(miniTable!=null)foreach(DataRow row in miniTable.Table.Rows)row["Phase"]="stable";
    }
    void TickMini(bool force=false,bool updateMotion=true)
    {
        if(mini?.IsVisible!=true)return;
        var now=DateTime.UtcNow;
        if(updateMotion)
        {
            foreach(var id in entering.Where(x=>x.Value<=now).Select(x=>x.Key).ToArray()){
                entering.Remove(id);if(miniTable!.Table.Rows.Find(id) is DataRow row)row["Phase"]="stable";
            }
            if(leaving.Values.Any(end=>end<=now)){RenderMini();return;}
        }
        if(!force && now-lastClock<TimeSpan.FromSeconds(1))return;
        lastClock=now;
        if(miniFresh.HasValue && miniFresh.Value!=Fresh){RenderMini();return;}
        var status=demoMode?"演示数据":!snapshot.Valid()?"等待采集":!backend.Running?"采集已停止 · F5 重试":Stale?"数据已过期 · F5 重试":
            miniRefresh==0?$"快照 · {(long)(Age/1000)} 秒前":"近 1 分钟均值";
        MiniText("MiniStatus",status);
        MiniText("MiniFreshness",demoMode?"模拟状态与速率。点击问号模拟回答，点击错误或完成行模拟查看并收起。":
            $"{status}\n最近更新 {(long)(Age/1000)} 秒前 · {Date(lastSpeedAt)}\n输出含推理；按响应入账，近 60 秒均值。\n点击打开 Codex 会话；完成和错误可点击收起。\n问号表示待回答问题；权限审批状态尚未接入。");
        M<Shape>("MiniStatusDot").Fill=BrushFor(Fresh?"Accent":"Warning");
    }
}
