using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Data;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using static CodexUsageMonitor.ViewData;

namespace CodexUsageMonitor;

sealed partial class MonitorApp
{
    Window? demo;
    bool selfTest, paused, demoUpdating, miniActivated, realFocusChange, movedWithBackdrop;
    int stage, tick, lastDemoPhase;
    double elapsed, rate = 1;
    readonly Stopwatch demoClock = Stopwatch.StartNew();
    double lastDemoTick;
    readonly Dictionary<string,JsonElement> demoRows = new();
    readonly HashSet<int> visited = new();
    static readonly (string Name, string Hint)[] stages = [
        ("新会话","行高展开，名称与速率淡入"),("正常输出","数字与柱形原位更新，行的位置保持稳定"),
        ("子会话加入","子会话跟在父会话下方，显示分支"),("子会话输出","父子会话分别显示各自的速率"),
        ("等待回答","琥珀色点轻亮两次，右侧出现 ?；可点击模拟回答"),("回答后继续","问号消失，恢复薄荷色点和速率"),
        ("会话出错","珊瑚色点和 ! 提醒；可点击模拟查看"),("错误行收起","模拟点击查看：淡出并收起行高"),
        ("新任务加入","新的子会话展开进入"),("任务完成","✓ 淡入，完成行保留；可点击模拟查看"),
        ("完成行收起","模拟点击查看：完成行平滑退出"),("主会话完成","主会话也显示 ✓，等待查看"),
        ("全部收起","最后一行退出，显示空状态"),("所有状态同屏","新建、进行中、待回答、错误、完成和中断同时展示"),
        ("被中断后置灰","标题、模型、柱形和标记一起置灰；点击后沿用退出动画")];
    T D<T>(string name) where T : class => (T)demo!.FindName(name);

    void StartDemo(bool test)
    {
        selfTest = test;
        EnsureMini();
        demo = Load("demo.xaml"); demo.Resources = main.Resources; demo.Icon = main.Icon;
        mini!.Title = "Codex 动效演示 · 模拟数据";
        foreach (var name in new[] {"DemoPause","DemoNext","DemoReplay"}) D<Button>(name).Style = (Style)mini.FindResource("MiniButton");
        var scenes = D<ComboBox>("DemoScene"); scenes.ItemsSource = stages.Select(x => x.Name).ToArray();
        scenes.SelectionChanged += (_,_) => { if (!demoUpdating && scenes.SelectedIndex >= 0) Safe(() => AdvanceDemo(scenes.SelectedIndex)); };
        var speed = D<ComboBox>("DemoSpeed");speed.ItemsSource = new[] {"慢速","正常","快速"};speed.SelectedIndex=1;
        speed.SelectionChanged += (_,_) => rate = speed.SelectedIndex switch { 0=>.5, 2=>2, _=>1 };
        var pause=D<Button>("DemoPause");
        pause.Click+=(_,_)=>{paused=!paused;pause.Content=paused?"继续":"暂停";};
        D<Button>("DemoNext").Click+=(_,_)=>Safe(()=>AdvanceDemo(stage+1));
        D<Button>("DemoReplay").Click+=(_,_)=>Safe(()=>{paused=false;pause.Content="暂停";AdvanceDemo(0);});
        demo.Closed+=(_,_)=>Exit();
        var area=SystemParameters.WorkArea;
        mini.Left=area.Left+(area.Width-400)/2;mini.Top=Math.Max(area.Top+16,area.Top+(area.Height-620)/2);
        demo.Left=mini.Left;demo.Top=mini.Top+400;demo.Show();mini.Owner=demo;mini.Show();
        AdvanceDemo(0);
        if(test) { TestTree(); TestMainViews(); miniActivated=mini.Activate(); }
    }

    static JsonElement DemoRow(string id,string title,string state="running",string parent="",int order=0,double output=44.8)
    {
        var now=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return JsonSerializer.SerializeToElement(new { id,title,parent_id=parent,source=parent==""?"user":"subagent",model="GPT-6.1",effort="high",state,display_state=state,
            available=true,started_ms=now-order*1000,one=new { output_tps=output },
            trend=new double[] {8,12,10,18,23,22,28,35,31,output}.Select((v,i)=>new { at=now-(9-i)*30000,output_tps=state=="starting"?0:v }) });
    }

    void AdvanceDemo(int index)
    {
        stage=index%stages.Length;elapsed=0;demoUpdating=true;
        try {D<ComboBox>("DemoScene").SelectedIndex=stage;} finally {demoUpdating=false;}
        D<TextBlock>("DemoStep").Text=stages[stage].Name;D<TextBlock>("DemoHint").Text=stages[stage].Hint;
        D<TextBlock>("DemoIndex").Text=$"{stage+1} / {stages.Length}";
        visited.Add(stage);demoRows.Clear();
        if(stage!=12) demoRows["main"]=DemoRow("main","小窗动效演示",stage==0?"starting":stage==11?"completed":"running");
        if(stage is >=2 and <=6) demoRows["child"]=DemoRow("child","子会话测试",stage switch {2=>"starting",4=>"waiting",6=>"failed",_=>"running"},"main",output:18.6);
        if(stage is 8 or 9) demoRows["next-child"]=DemoRow("next-child","结果校验",stage==8?"starting":"completed","main");
        if(stage==13) {
            demoRows.Clear();
            var states=new[] {"starting","running","waiting","failed","completed","interrupted"};
            var titles=new[] {"小窗动效实现","告警规则重构","部署脚本检查","接口测试修复","单元测试补齐","被中断的任务"};
            for(int i=0;i<states.Length;i++) {var id=$"all-{i}";demoRows[id]=DemoRow(id,titles[i],states[i],order:i);}
        }
        if(stage==14)demoRows["stopped"]=DemoRow("stopped","被中断的任务","interrupted","main");
        RenderMini();
        if(selfTest && stage is 7 or 10 or 12 && Motion && leaving.Count==0) throw new InvalidOperationException("Exit animation was not scheduled.");
    }
    void DemoClick(string id)
    {
        if(!demoRows.TryGetValue(id,out var row))return;
        switch(row.S("display_state")){
            case "waiting":
                demoRows[id]=DemoRow(id,row.Title(),"running",row.S("parent_id"),output:18.6);
                D<TextBlock>("DemoHint").Text="已模拟回答，恢复速率显示";break;
            case "failed":case "interrupted":case "completed":
                demoRows.Remove(id);D<TextBlock>("DemoHint").Text="已模拟查看，正在收起这一行";break;
            default:D<TextBlock>("DemoHint").Text="正式版点击此处会打开对应 Codex 会话";break;
        }
        RenderMini();
    }
    void TickDemo()
    {
        if(demo==null)return;
        TickMini();
        demo.Left=mini!.Left;
        demo.Top=Math.Min(mini.Top+Math.Max(220,mini.ActualHeight)+10,SystemParameters.WorkArea.Bottom-demo.Height);
        var now=demoClock.Elapsed.TotalMilliseconds;var delta=Math.Clamp(now-lastDemoTick,0,500);lastDemoTick=now;
        if(!paused)elapsed+=delta*rate;
        if(elapsed>=(selfTest?470:3500))
        {
            if(selfTest){
                VerifyDemoStage();
                if(stage==0){miniActivated|=mini.IsActive;main.Show();main.UpdateLayout();main.Activate();}
                if(stage==1){
                    if(acrylic) {
                        var handle=new WindowInteropHelper(mini).Handle;
                        realFocusChange=miniActivated&&!mini.IsActive&&CodexMiniGlass.InactiveAppearanceMessages>0;
                        bool handled=false;
                        CodexMiniGlass.FilterBackdropActivation(handle,0x0086,IntPtr.Zero,IntPtr.Zero,ref handled);
                        var backdrop=CodexMiniGlass.ReadBackdrop(handle);
                        if(!handled||backdrop!=3||CodexMiniGlass.HasSystemCaptionButtons(handle))
                            throw new InvalidOperationException($"Acrylic frame validation failed: hook={handled}; backdrop={backdrop}.");
                    }
                    main.Hide();
                }
                if(stage==2 && acrylic) {
                    var x=mini.Left;
                    mini.Left=x+60;
                    mini.UpdateLayout();
                    var handle=new WindowInteropHelper(mini).Handle;
                    FixCaption();
                    movedWithBackdrop=Math.Abs(mini.Left-x)>20 && CodexMiniGlass.ReadBackdrop(handle)==3 && !CodexMiniGlass.HasSystemCaptionButtons(handle);
                    if(!movedWithBackdrop)throw new InvalidOperationException("Repositioning lost the Acrylic window frame.");
                }
                if(stage==14){
                    if(visited.Count!=stages.Length || lastDemoPhase!=6)throw new InvalidOperationException("Missing stage coverage.");
                    File.WriteAllText(Path.Combine(storage.Data,"ui-checks.json"),JsonSerializer.Serialize(new { passed=true,stages=visited.Count,acrylic, realFocusChange, movedWithBackdrop,inactiveMessages=CodexMiniGlass.InactiveAppearanceMessages,tree=true,mainViews=true }));
                    Exit();return;
                }
            }
            AdvanceDemo(stage+1);
        }
        if(++tick%20==0 && !paused && !selfTest)
        {
            foreach(var (id,row) in demoRows.ToArray().Where(x=>x.Value.S("state")=="running")){
                var output=Math.Round(26+15*Math.Sin(tick/23.0)+(row.S("parent_id")==""?0:-12),1);
                var json=JsonNode.Parse(row.GetRawText())!.AsObject();
                json["one"]!["output_tps"]=output;
                var trend=json["trend"]!.AsArray();trend.RemoveAt(0);
                trend.Add(JsonSerializer.SerializeToNode(new { at=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),output_tps=output }));
                demoRows[id]=JsonSerializer.SerializeToElement(json);
            }
            RenderMini();
        }
    }
    void VerifyDemoStage()
    {
        var table=miniTable!.Table;
        if(table.Rows.Count!=demoRows.Count || leaving.Count!=0)throw new InvalidOperationException("Animation did not settle.");
        if(stage==13){
            var actual=table.Rows.Cast<DataRow>().Select(r=>((string)r["State"],(string)r["Mark"])).ToArray();
            var expected=new[] {("starting",""),("running",""),("waiting","?"),("failed","!"),("completed","✓"),("interrupted","!")};
            if(!actual.SequenceEqual(expected))throw new InvalidOperationException("Wrong state marks.");
            lastDemoPhase=actual.Length;
            CaptureMini();
        }
        if(stage==14 && table.Rows.Find("stopped") is DataRow stopped && (string)stopped["TitleTone"]!="#929BAA")
            throw new InvalidOperationException("Interrupted row did not gray out.");
    }
    void CaptureMini()
    {
        mini!.UpdateLayout();
        var view=M<Border>("MiniSurface");
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(view.ActualWidth),(int)Math.Ceiling(view.ActualHeight),96,96,PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream=File.Create(Path.Combine(storage.Data,"mini-content.png"));encoder.Save(stream);
    }
    void TestTree()
    {
        var parent=DemoRow("parent","真实父会话");
        var unrelated=DemoRow("unrelated","无关活跃会话");
        var child=DemoRow("child","活跃子会话",parent:"parent");
        var tail=DemoRow("tail","下级子会话",parent:"child");
        var isolated=Tree(new[]{unrelated,child,tail},IdOf,r=>r.S("parent_id")).ToArray();
        if(isolated[1].Depth!=0 || isolated[2].Depth!=1 || MiniRow(child,0,true,50)["Branch"]!="" ||
           !MiniRow(child,0,true,50)["Accessible"].Contains("父会话：parent（当前未显示）"))throw new InvalidOperationException("Hidden parent was rendered as a visible branch.");
        var restored=Tree(new[]{unrelated,child,parent,tail},IdOf,r=>r.S("parent_id")).ToArray();
        if(restored[1].Item.S("id")!="parent" || restored[2].Depth!=1 || restored[3].Depth!=2)throw new InvalidOperationException("Restored parent did not regroup its subtree.");
        var cycle=Tree(new[]{DemoRow("a","A",parent:"b"),DemoRow("b","B",parent:"a")},IdOf,r=>r.S("parent_id")).ToArray();
        if(cycle.Length!=2 || cycle.Select(x=>IdOf(x.Item)).Distinct().Count()!=2)throw new InvalidOperationException("Cycle lost a row.");
    }
    void TestMainViews()
    {
        var now=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var fixture=JsonSerializer.SerializeToElement(new {
            at=now,last_scan=now,week_total=175,quota=new {used_percent=29.0,reset_at=now/1000+86400},coverage=new {sessions=2,with_logs=2,metadata_only=0},
            sessions=new [] {
                new {id="parent",title="合成主会话",source="user",model="test",week_total=100,total=100,week_known=true,updated=now},
                new {id="child",title="合成子会话",source="subagent",model="test",week_total=75,total=75,week_known=true,updated=now}
            },
            edges=new[]{new {parent_id="parent",child_id="child",kind="subagent"}},
            speed=new {rows=new[]{DemoRow("parent","合成主会话")}},
            combinations=new[]{new {key="test/high/default",model="test",effort="high",tier="default",week_total=175,calibration_samples=1}},
            calibration=new {reason="待校准"},
            processes=new[]{new {pid=101,ppid=1,name="codex.exe",created="2026-11-16T07:00:00Z",memory=10485760, cpu=1.5,thread_id="child",association="explicit"}}
        });
        ApplySnapshot(fixture);
        var row=tables["Live"].Table.Rows.Find("parent") ?? throw new InvalidOperationException("Live row missing.");
        ApplySnapshot(fixture);
        if(!ReferenceEquals(row,tables["Live"].Table.Rows.Find("parent")))throw new InvalidOperationException("Refresh replaced an existing row.");
        ShowPage("Session");expanded.Add("parent");RenderPage();SelectRow("Session","parent");
        if(tables["Session"].Table.Rows.Find("child") is not DataRow child || (string)child["Indent"]!="16,0,0,0" ||
           tables["SessionFacts"].Table.Rows.Find("自身 + 子树累计") is not DataRow family || !((string)family["Value"]).StartsWith("175"))
            throw new InvalidOperationException("Main session tree or subtree usage does not match.");
        U<TextBox>("Search").Text="合成子会话";RenderPage();
        if(tables["Session"].Table.Rows.Count!=2)throw new InvalidOperationException("Search omitted the parent context.");
        U<TextBox>("Search").Clear();
        ShowPage("Model");
        if(tables["Model"].Table.Rows.Count!=1)throw new InvalidOperationException("Model row missing.");
        ShowPage("Process");
        if(tables["Process"].Table.Rows.Count!=1 || !((string)tables["Process"].Table.Rows[0]["Subtitle"]).Contains("合成子会话"))
            throw new InvalidOperationException("Process attribution lost.");
        ShowPage("Live");
    }
}
