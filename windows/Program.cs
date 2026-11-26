// 바탕화면 트리 — Windows 셸.
//
// 규칙은 전부 web\ 안의 JS 다. 이 파일은 mac/Sources/main.swift 와 같은 일을 하고,
// 다리(window.sneaky)도 같은 모양이다. 한쪽만 고치면 두 플랫폼이 다른 물건이 된다.
//
//   · 트리만 한 크기의 투명 창 (레이어드 + DWM 픽셀 알파 — 붙여넣기 총 셸과 같은 방식)
//   · 지금 떠 있는 창의 목록 — EnumWindows
//   · 방울을 누르면 그 창을 닫고(WM_CLOSE) · 접고 · 키우기(ShowWindow)
//   · 트리를 끌어서 옮기기
//
// **창은 언제나 클릭이 통과한다. 방울과 몸통 위의 클릭만 저수준 마우스 훅이 삼킨다.**
// 붙여넣기 총은 마우스를 받을 때마다 창과 웹뷰 자식 창들의 스타일을 떼었다 붙였고, 그 길에서
// 「커서를 올리면 오버레이가 사라지는」 버그가 났다. 여기서는 어느 방울인지를 셸이 이미 알고
// 있어서 웹뷰가 마우스를 받을 일이 없다 — 그래서 스타일을 아예 건드리지 않는다.
//
// 맥과 달리 권한이 필요 없다. 다만 **관리자 권한으로 뜬 창은 못 움직인다**(UIPI).
// 실제 윈도우에서는 CI 러너가 돌려 본다(windows/smoke.ps1).

using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace DesktopTree;

static class Program
{
    [STAThread]
    static void Main()
    {
        // 둘이 뜨면 트리가 두 그루 겹쳐 서고, 방울 하나에 창이 두 번 닫힌다.
        using var mutex = new Mutex(true, "DesktopTree.SingleInstance", out var first);
        if (!first) return;

        ApplicationConfiguration.Initialize();
        Application.Run(new OverlayContext());
    }
}

/// <summary>창을 띄우지 않는 트레이 앱.</summary>
sealed class OverlayContext : ApplicationContext
{
    private readonly Overlay overlay = new();
    private readonly NotifyIcon tray = new();

    public OverlayContext()
    {
        overlay.Show();
        tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        tray.Text = "바탕화면 트리";
        tray.Visible = true;
        Refresh();
        overlay.SettingsChanged += Refresh;
    }

    private void Refresh()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem($"창 {overlay.WindowCount}개의 방울이 달려 있습니다") { Enabled = false });
        menu.Items.Add(new ToolStripMenuItem("빨강 닫기 · 노랑 접기 · 초록 키우기") { Enabled = false });
        menu.Items.Add(new ToolStripMenuItem("트리를 끌면 옮겨지고, 별을 끌면 크기가 바뀝니다") { Enabled = false });
        // 새 버전이 있을 때만 낸다. 없으면 메뉴에 아무 흔적도 없다.
        if (overlay.UpdateVersion is not null)
        {
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem(
                overlay.UpdateNote ?? $"새 버전 {overlay.UpdateVersion} 설치",
                null, (_, _) => overlay.InstallUpdate())
            {
                Enabled = !overlay.Updating,
            });
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("숨기기", null, (_, _) => overlay.Toggle("hidden")) { Checked = overlay.Flag("hidden") });
        menu.Items.Add(new ToolStripMenuItem("꼬마전구 반짝임", null, (_, _) => overlay.Toggle("twinkle")) { Checked = overlay.Flag("twinkle") });
        menu.Items.Add(Choices("자리 (끌어서도 옮깁니다)", "spot", "right", [("왼쪽 구석", "left"), ("오른쪽 구석", "right")]));
        var sizes = new ToolStripMenuItem("크기 (별을 끌어서도 바꿉니다)");
        foreach (var (label, value) in Overlay.ScalePresets)
        {
            sizes.DropDownItems.Add(new ToolStripMenuItem(label, null, (_, _) => overlay.Choose("scale", value))
            {
                Checked = Math.Abs(overlay.CurrentScale - value) < 0.02,
            });
        }
        menu.Items.Add(sizes);
        menu.Items.Add(new ToolStripSeparator());
        if (Overlay.Uninstaller is not null)
        {
            menu.Items.Add(new ToolStripMenuItem("바탕화면 트리 제거…", null, (_, _) =>
            {
                // 설치본이 만든 제거 프로그램에 넘긴다. 물어보는 것도, 설정을 지우는 것도 거기서 한다.
                if (!Overlay.StartUninstaller()) return;
                Quit();
            }));
            menu.Items.Add(new ToolStripSeparator());
        }
        menu.Items.Add(new ToolStripMenuItem($"버전 {Overlay.CurrentVersion}") { Enabled = false });
        menu.Items.Add(new ToolStripMenuItem("종료", null, (_, _) => Quit()));
        tray.ContextMenuStrip = menu;
    }

    private ToolStripMenuItem Choices(string title, string key, string fallback, (string Label, string Value)[] options)
    {
        var parent = new ToolStripMenuItem(title);
        var now = overlay.Choice(key) ?? fallback;
        foreach (var (label, value) in options)
        {
            parent.DropDownItems.Add(new ToolStripMenuItem(label, null, (_, _) => overlay.Choose(key, value))
            {
                Checked = now == value,
            });
        }
        return parent;
    }

    private void Quit()
    {
        tray.Visible = false;
        overlay.Close();
        ExitThread();
    }
}

sealed class Overlay : Form
{
    // 창 스타일 — 마우스 통과 + 작업 표시줄에 안 뜸 + 포커스 안 가져감.
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_LAYERED = 0x00080000;
    private const uint LWA_COLORKEY = 0x00000001;
    private const uint LWA_ALPHA = 0x00000002;

    private const int WH_MOUSE_LL = 14;
    private const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    private const uint WM_CLOSE = 0x0010;
    private const int SW_MAXIMIZE = 3, SW_MINIMIZE = 6, SW_RESTORE = 9;
    private const uint GW_OWNER = 4;
    private const int DWMWA_CLOAKED = 14;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    /// <summary>기준 판의 크기. src/game/tree.js 의 BOARD 와 같아야 한다.</summary>
    private const double BoardW = 460, BoardH = 560;
    /// <summary>이보다 작은 창은 창으로 안 친다(도구 막대·말풍선 같은 것).</summary>
    private const int SmallestW = 160, SmallestH = 100;

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr param);
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc proc, IntPtr param);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint relation);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hWnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);
    [DllImport("dwmapi.dll")] private static extern int DwmEnableBlurBehindWindow(IntPtr hWnd, ref DWM_BLURBEHIND bb);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public Point pt;
        public uint mouseData, flags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DWM_BLURBEHIND
    {
        public int dwFlags;
        public bool fEnable;
        public IntPtr hRgnBlur;
        public bool fTransitionOnMaximized;
    }

    private const int DWM_BB_ENABLE = 0x1;
    private const int DWM_BB_BLURREGION = 0x2;

    private static readonly string DataDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DesktopTree");
    private static readonly string StatePath = Path.Combine(DataDir, "state.json");
    /// <summary>끌어다 놓은 자리(트리 밑동의 가운데, 화면 픽셀). 없으면 메뉴에서 고른 구석이다.</summary>
    private static readonly string AnchorPath = Path.Combine(DataDir, "anchor.json");
    private static readonly bool Debugging = Environment.GetEnvironmentVariable("TREE_DEBUG") is not null;

    /// <summary>WinExe 라 콘솔이 없다. TREE_DEBUG 가 켜져 있을 때만 debug.log 로 흘린다.</summary>
    private static void DebugLog(string text)
    {
        if (!Debugging) return;
        try
        {
            Directory.CreateDirectory(DataDir);
            File.AppendAllText(Path.Combine(DataDir, "debug.log"),
                $"[tree] {DateTime.Now:HH:mm:ss.fff} {text}{Environment.NewLine}");
        }
        catch
        {
            // 로그 쓰기 실패로 앱이 죽으면 안 된다.
        }
    }

    /// <summary>값을 JS 리터럴로 만든다. 손으로 따옴표를 붙이지 않는다.</summary>
    private static string Js(object? value) => JsonSerializer.Serialize(value);

    private readonly WebView2 web = new();
    private readonly System.Windows.Forms.Timer pointerTimer = new() { Interval = 33 };
    private readonly System.Windows.Forms.Timer watchTimer = new() { Interval = 1000 };
    private bool ready;

    /// <summary>렌더러가 알려 준 설정. 셸은 이걸 메뉴에 적고, 창의 자리와 크기를 맞춘다.</summary>
    private Dictionary<string, JsonElement> settings = [];
    public int WindowCount { get; private set; }
    public event Action? SettingsChanged;

    /// <summary>누를 수 있는 동그라미들과 잡고 끌 수 있는 네모들. **창의 왼쪽 위에서 잰 실제 픽셀**이다.</summary>
    private List<(string Key, double X, double Y, double R)> hits = [];
    private List<RectangleF> body = [];
    private string? hovered;
    /// <summary>끄는 중이면: 잡은 순간의 마우스 자리와 창의 자리.</summary>
    private (Point Mouse, Point Origin)? drag;
    /// <summary>누른 것을 삼켰으면 떼는 것도 삼킨다 — 밑의 앱이 「뗀 것만」 받으면 안 된다.</summary>
    private bool swallowRelease;
    private Point? anchor;
    /// <summary>크기를 정하는 손잡이 — 꼭대기 별(창의 왼쪽 위에서 잰 실제 픽셀). 잡고 끌면 밑동은 그대로 있고 별이 마우스를 따라온다.</summary>
    private (double X, double Y, double R)? grip;
    /// <summary>별이 밑동에서 얼마나 높이 있나(창 높이에 대한 비율). 판의 모양이 정하는 값이라 크기가 바뀌어도 같다.</summary>
    private double gripRatio = 0.886;
    private bool overGrip;
    /// <summary>크기를 바꾸는 중이면: 별과 마우스의 높이 차, 밑동의 가운데(화면 픽셀).</summary>
    private (int Offset, Point Base)? resize;
    /// <summary>끌어서 정한 크기. 렌더러가 설정으로 되돌려 줄 때까지 이 값을 쓴다.</summary>
    private double? liveScale;

    private IntPtr hook;
    private readonly HookProc hookProc; // 지워지면 안 된다. 훅이 이 대리자를 부른다.

    public Overlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        anchor = LoadAnchor();
        Bounds = TreeBounds();

        // DWM 합성에 맡길 때는 폼이 스스로 배경을 칠하면 안 된다. 검정은 「아무것도 없음」이다.
        BackColor = Color.Black;

        web.Dock = DockStyle.Fill;
        web.DefaultBackgroundColor = Color.Transparent;
        Controls.Add(web);

        hookProc = OnMouseHook;
        pointerTimer.Tick += (_, _) => CheckPointer();
        watchTimer.Tick += (_, _) => Watch();
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

        // 켠 지 20초 뒤에 한 번, 그 뒤로는 하루 한 번.
        var firstCheck = new System.Windows.Forms.Timer { Interval = 20_000 };
        firstCheck.Tick += (_, _) => { firstCheck.Stop(); _ = CheckForUpdateAsync(); };
        firstCheck.Start();
        updateTimer.Tick += (_, _) => _ = CheckForUpdateAsync();
        updateTimer.Start();

        _ = InitWebAsync();
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Place();

    // MARK: 자리와 크기

    /// <summary>트리의 크기(기준 판에 곱하는 배율)의 범위. src/game/tree.js 의 SCALE 과 같아야 한다.</summary>
    private const double ScaleMin = 0.3, ScaleMax = 1.6;
    /// <summary>메뉴에서 고르는 크기. 그 사이는 별을 끌어서 정한다.</summary>
    public static readonly (string Label, double Value)[] ScalePresets =
        [("아주 작게", 0.3), ("작게", 0.55), ("조금 작게", 0.8), ("보통", 1.0), ("크게", 1.3)];

    public double CurrentScale
    {
        get
        {
            var saved = settings.TryGetValue("scale", out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : 1.0;
            return Math.Clamp(liveScale ?? saved, ScaleMin, ScaleMax);
        }
    }

    /// <summary>트리가 설 자리: 끌어다 놓은 데가 있으면 거기, 없으면 작업 표시줄 위 화면의 오른쪽(또는 왼쪽) 구석.</summary>
    private Rectangle TreeBounds()
    {
        var dpi = DeviceDpi / 96.0;
        var width = (int)Math.Round(BoardW * CurrentScale * dpi);
        var height = (int)Math.Round(BoardH * CurrentScale * dpi);
        if (anchor is { } at) return KeptOnScreen(new Rectangle(at.X - width / 2, at.Y - height, width, height));
        var room = Screen.PrimaryScreen!.WorkingArea;
        var x = Choice("spot") == "left" ? room.Left + 8 : room.Right - width - 8;
        return new Rectangle(x, room.Bottom - height, width, height);
    }

    /// <summary>트리가 화면 밖으로 사라지지 않게 한다 — 가장 많이 걸친 화면 안으로 밀어 넣는다.</summary>
    private static Rectangle KeptOnScreen(Rectangle frame)
    {
        var room = Screen.FromRectangle(frame).WorkingArea;
        var x = Math.Min(Math.Max(frame.Left, room.Left), Math.Max(room.Left, room.Right - frame.Width));
        var y = Math.Min(Math.Max(frame.Top, room.Top), Math.Max(room.Top, room.Bottom - frame.Height));
        return new Rectangle(x, y, frame.Width, frame.Height);
    }

    private void Place()
    {
        if (drag is not null || resize is not null) return; // 끄는 동안에는 손이 자리와 크기를 정한다
        var frame = TreeBounds();
        if (Bounds != frame) Bounds = frame;
        var hide = Flag("hidden");
        if (hide == Visible) Visible = !hide;
        if (hide) SetHovered(null);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        BeginInvoke(Place);
    }

    private static Point? LoadAnchor()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(AnchorPath));
            return new Point(doc.RootElement[0].GetInt32(), doc.RootElement[1].GetInt32());
        }
        catch
        {
            return null;
        }
    }

    private void SaveAnchor()
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            if (anchor is { } at) File.WriteAllText(AnchorPath, Js(new[] { at.X, at.Y }));
            else File.Delete(AnchorPath);
        }
        catch
        {
            // 자리를 못 적어도 트리는 서 있어야 한다.
        }
    }

    // MARK: 설정 — 렌더러가 쥐고 있다. 셸은 「이걸 이렇게 바꿔 달라」고만 한다.

    public bool Flag(string key) => settings.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.True;

    public string? Choice(string key) =>
        settings.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public void Toggle(string key) => Call("__treeSet", key, !Flag(key));

    public void Choose(string key, object value)
    {
        if (key == "spot")
        {
            // 구석을 고르면 끌어다 놓은 자리는 잊는다.
            anchor = null;
            SaveAnchor();
        }
        Call("__treeSet", key, value);
        if (key == "spot") BeginInvoke(Place); // 같은 구석을 또 골라도 돌아가게
    }

    // MARK: 업데이트와 제거
    //
    // <b>두 단계다.</b> 1단계는 「새 버전이 있다」고 메뉴에 알리는 것뿐이고, 2단계는 눌렀을 때
    // 설치본을 받아 조용히 다시 까는 것이다. 설정은 %AppData%\DesktopTree 에 있어서 다시 깔아도 그대로다.

    private const string ReleaseApi = "https://api.github.com/repos/joowon-dev/desktop-tree/releases/latest";
    private const string ReleasePage = "https://joowonkoh.com/playground/desktop-tree";
    /// <summary>자동 업데이트가 받아 가는 것은 설치본이다 — zip 은 사람이 직접 풀 때 쓴다.</summary>
    private const string WinAssetSuffix = "-win-Setup.exe";

    private static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 24 * 60 * 60 * 1000 };

    public string? UpdateVersion { get; private set; }
    public string? UpdateNote { get; private set; }
    public bool Updating { get; private set; }
    private string? updateAsset;

    public static string CurrentVersion =>
        System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";

    /// <summary>"v1.10.0" 이 "1.9.0" 보다 높다. 문자열로 비교하면 거꾸로 나온다.</summary>
    public static bool IsNewerVersion(string candidate, string current)
    {
        static int[] Parts(string text) => text.TrimStart('v', 'V', ' ')
            .Split('.')
            .Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0)
            .ToArray();

        var a = Parts(candidate);
        var b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i += 1)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>하루 한 번 물어본다. 실패는 조용히 삼킨다.</summary>
    private async Task CheckForUpdateAsync()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ReleaseApi);
            request.Headers.Add("Accept", "application/vnd.github+json");
            // GitHub 은 User-Agent 없는 요청을 거절한다.
            request.Headers.Add("User-Agent", "DesktopTree");

            using var response = await http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;

            var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
            var tag = json.GetProperty("tag_name").GetString();
            DebugLog($"릴리스 {tag} · 지금 {CurrentVersion}");
            if (tag is null || !IsNewerVersion(tag, CurrentVersion)) return;

            string? asset = null;
            if (json.TryGetProperty("assets", out var assets))
            {
                foreach (var a in assets.EnumerateArray())
                {
                    var name = a.TryGetProperty("name", out var n) ? n.GetString() : null;
                    if (name is not null && name.EndsWith(WinAssetSuffix, StringComparison.OrdinalIgnoreCase))
                    {
                        asset = a.GetProperty("browser_download_url").GetString();
                        break;
                    }
                }
            }

            BeginInvoke(() =>
            {
                UpdateVersion = tag;
                updateAsset = asset;
                SettingsChanged?.Invoke();
            });
        }
        catch
        {
            // 조용히.
        }
    }

    /// <summary>받아서 조용히 다시 깐다. 한 걸음이라도 어긋나면 받는 곳을 연다.</summary>
    public async void InstallUpdate()
    {
        if (Updating) return;
        if (updateAsset is null)
        {
            OpenReleasePage();
            return;
        }

        Updating = true;
        UpdateNote = "내려받는 중…";
        SettingsChanged?.Invoke();

        var path = Path.Combine(Path.GetTempPath(), $"DesktopTree-{Guid.NewGuid():N}.exe");
        try
        {
            using (var request = new HttpRequestMessage(HttpMethod.Get, updateAsset))
            {
                request.Headers.Add("User-Agent", "DesktopTree");
                using var response = await http.SendAsync(request);
                response.EnsureSuccessStatusCode();
                await using var file = File.Create(path);
                await response.Content.CopyToAsync(file);
            }

            UpdateNote = "설치하는 중…";
            SettingsChanged?.Invoke();

            Process.Start(new ProcessStartInfo(path)
            {
                Arguments = "/SILENT /NORESTART",
                UseShellExecute = true,
            });
            // 물러난다. 설치본이 끝나면 새 것을 다시 띄운다(installer.iss 의 [Run]).
            Application.Exit();
        }
        catch
        {
            Updating = false;
            UpdateNote = "직접 받기";
            SettingsChanged?.Invoke();
            OpenReleasePage();
        }
    }

    private static void OpenReleasePage()
    {
        try { Process.Start(new ProcessStartInfo(ReleasePage) { UseShellExecute = true }); }
        catch { /* 브라우저가 없으면 할 수 있는 것이 없다. */ }
    }

    /// <summary>설치본으로 깔았을 때만 있다. zip 을 풀어 쓰는 사람은 폴더를 지우면 끝이다.</summary>
    public static string? Uninstaller
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "unins000.exe");
            return File.Exists(path) ? path : null;
        }
    }

    public static bool StartUninstaller()
    {
        if (Uninstaller is not { } path) return false;
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            return true;
        }
        catch
        {
            return false;
        }
    }

    // MARK: 투명과 클릭 통과 — 붙여넣기 총 셸에서 러너로 확인된 방식 그대로다.

    protected override CreateParams CreateParams
    {
        get
        {
            var p = base.CreateParams;
            // WS_EX_TRANSPARENT 는 WS_EX_LAYERED 와 같이 있어야만 클릭을 통과시킨다.
            p.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return p;
        }
    }

    /// <summary>뜰 때 포커스를 가져가지 않는다.</summary>
    protected override bool ShowWithoutActivation => true;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);

        // 레이어드 창은 알파를 정해 주지 않으면 아예 안 그려진다. 검정 컬러 키는 DWM 이
        // 픽셀 알파를 무시하는 기계에서도 빈 곳을 뚫는 안전장치다.
        SetLayeredWindowAttributes(Handle, 0, 255, LWA_COLORKEY | LWA_ALPHA);
        EnablePerPixelAlpha();

        // 방울과 몸통 위의 클릭을 삼키는 훅. 이 스레드의 메시지 루프에서 불린다.
        hook = SetWindowsHookEx(WH_MOUSE_LL, hookProc, GetModuleHandle(null), 0);
        DebugLog($"마우스 훅 {(hook != IntPtr.Zero ? "걸림" : $"실패 {Marshal.GetLastWin32Error()}")}");
    }

    /// <summary>빈 영역으로 블러를 켠다 — 흐림은 없고 픽셀 단위 알파만 얻는다.</summary>
    private void EnablePerPixelAlpha()
    {
        var region = CreateRectRgn(0, 0, -1, -1);
        try
        {
            var bb = new DWM_BLURBEHIND { dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION, fEnable = true, hRgnBlur = region };
            DebugLog($"DwmEnableBlurBehindWindow hr={DwmEnableBlurBehindWindow(Handle, ref bb)}");
        }
        finally
        {
            DeleteObject(region);
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        base.OnFormClosed(e);
    }

    // MARK: 마우스

    /// <summary>화면의 한 점 밑에 있는 방울. 숨겼으면 없다.</summary>
    private string? HitAt(Point screen)
    {
        if (!Visible || !Bounds.Contains(screen)) return null;
        double x = screen.X - Bounds.Left, y = screen.Y - Bounds.Top;
        // 트리가 작으면 누를 수 있는 동그라미끼리 겹친다. 그중 가장 가까운 것이다.
        string? best = null;
        var nearest = double.MaxValue;
        foreach (var hit in hits)
        {
            var far = Math.Sqrt((hit.X - x) * (hit.X - x) + (hit.Y - y) * (hit.Y - y));
            if (far > hit.R || far >= nearest) continue;
            nearest = far;
            best = hit.Key;
        }
        return best;
    }

    private bool OnGrip(Point screen)
    {
        if (!Visible || grip is not { } star || !Bounds.Contains(screen)) return false;
        double dx = star.X - (screen.X - Bounds.Left), dy = star.Y - (screen.Y - Bounds.Top);
        return dx * dx + dy * dy <= star.R * star.R;
    }

    private bool OverBody(Point screen)
    {
        if (!Visible || !Bounds.Contains(screen)) return false;
        var at = new PointF(screen.X - Bounds.Left, screen.Y - Bounds.Top);
        return body.Any(band => band.Contains(at));
    }

    /// <summary>마우스가 올라온 방울이 바뀔 때만 렌더러를 깨운다. 자리만 묻는다.</summary>
    private void CheckPointer()
    {
        if (drag is not null || resize is not null) return;
        var key = HitAt(Cursor.Position);
        SetHovered(key);
        var star = key is null && OnGrip(Cursor.Position);
        if (star == overGrip) return;
        overGrip = star;
        Call("__treeGrip", star);
    }

    private void SetHovered(string? key)
    {
        if (key == hovered) return;
        hovered = key;
        Call("__treeHover", key);
    }

    /// <summary>
    /// 모든 마우스 이벤트가 여기를 먼저 지난다. <b>빨리 돌아가야 한다</b> — 늦으면 윈도우가 훅을 떼어 버린다.
    /// 방울을 눌렀으면 그 창에 일을 시키고, 몸통을 눌렀으면 끌기 시작한다. 그 밖의 것은 손대지 않고 넘긴다.
    /// </summary>
    private IntPtr OnMouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var point = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam).pt;
            switch ((int)wParam)
            {
                case WM_LBUTTONDOWN:
                    if (HitAt(point) is { } key)
                    {
                        swallowRelease = true;
                        BeginInvoke(() => Press(key));
                        return 1;
                    }
                    if (OnGrip(point) && grip is { } star)
                    {
                        swallowRelease = true;
                        resize = (Bounds.Top + (int)Math.Round(star.Y) - point.Y, new Point(Bounds.Left + Bounds.Width / 2, Bounds.Bottom));
                        DebugLog($"별 잡음 {point.X},{point.Y}");
                        return 1;
                    }
                    if (OverBody(point))
                    {
                        swallowRelease = true;
                        drag = (point, Location);
                        DebugLog($"잡음 {point.X},{point.Y}");
                        return 1;
                    }
                    break;

                case WM_MOUSEMOVE:
                    if (resize is { } sizing)
                    {
                        var next = Resized(sizing, point);
                        BeginInvoke(() => { if (resize is not null) Bounds = next; });
                    }
                    else if (drag is { } held)
                    {
                        var to = new Point(held.Origin.X + point.X - held.Mouse.X, held.Origin.Y + point.Y - held.Mouse.Y);
                        BeginInvoke(() => { if (drag is not null) Location = to; });
                    }
                    break;

                case WM_LBUTTONUP:
                    if (swallowRelease)
                    {
                        swallowRelease = false;
                        if (resize is { } sized)
                        {
                            var last = Resized(sized, point);
                            resize = null;
                            BeginInvoke(() => { Bounds = last; ResizeDone(); });
                        }
                        else if (drag is { } began)
                        {
                            // 뗀 자리로 한 번 더 옮긴다 — 움직임이 하나도 안 왔어도(빠르게 끌었을 때) 놓은 자리가 맞게.
                            var last = new Point(began.Origin.X + point.X - began.Mouse.X, began.Origin.Y + point.Y - began.Mouse.Y);
                            drag = null;
                            BeginInvoke(() => { Location = last; Released(began.Origin); });
                        }
                        return 1;
                    }
                    break;
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    /// <summary>밑동은 그대로 있고 별이 마우스의 높이를 따라온다. 그때의 크기와 창의 자리.</summary>
    private Rectangle Resized((int Offset, Point Base) sizing, Point mouse)
    {
        var dpi = DeviceDpi / 96.0;
        var tall = (sizing.Base.Y - (mouse.Y + sizing.Offset)) / gripRatio;
        var scale = Math.Clamp(tall / (BoardH * dpi), ScaleMin, ScaleMax);
        liveScale = scale;
        var width = (int)Math.Round(BoardW * scale * dpi);
        var height = (int)Math.Round(BoardH * scale * dpi);
        return new Rectangle(sizing.Base.X - width / 2, sizing.Base.Y - height, width, height);
    }

    private void ResizeDone()
    {
        // 줄이고 키운 자리에 그대로 서 있게, 밑동의 자리를 기억한다.
        var frame = KeptOnScreen(Bounds);
        anchor = new Point(frame.Left + frame.Width / 2, frame.Bottom);
        SaveAnchor();
        var scale = Math.Round(liveScale ?? 1, 2);
        Call("__treeSet", "scale", scale);
        Call("__treeMoved");
        DebugLog($"크기 {scale.ToString(System.Globalization.CultureInfo.InvariantCulture)}");
    }

    /// <summary>내려놓은 자리를 기억한다. 화면 밖에 걸쳤으면 안으로 밀어 넣는다.</summary>
    private void Released(Point origin)
    {
        if (Location == origin) return; // 누르기만 하고 안 끌었다
        var frame = KeptOnScreen(Bounds);
        anchor = new Point(frame.Left + frame.Width / 2, frame.Bottom);
        SaveAnchor();
        Place();
        Call("__treeMoved");
        LogHits();
        DebugLog($"옮김 {frame.Left},{frame.Top}");
    }

    // MARK: 떠 있는 창들

    private readonly Dictionary<uint, string> appNames = [];
    private readonly Dictionary<uint, string?> appPaths = [];
    private string lastSent = "";

    private static string ClassName(IntPtr hWnd)
    {
        var text = new StringBuilder(128);
        GetClassName(hWnd, text, text.Capacity);
        return text.ToString();
    }

    private string? PathOf(uint pid)
    {
        if (appPaths.TryGetValue(pid, out var known)) return known;
        string? path = null;
        var process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process != IntPtr.Zero)
        {
            var text = new StringBuilder(1024);
            var size = (uint)text.Capacity;
            if (QueryFullProcessImageName(process, 0, text, ref size)) path = text.ToString();
            CloseHandle(process);
        }
        appPaths[pid] = path;
        return path;
    }

    /// <summary>이름표에 적을 앱의 이름. 실행 파일에 적힌 설명(「메모장」)이 있으면 그것, 없으면 파일 이름.</summary>
    private string NameOf(uint pid)
    {
        if (appNames.TryGetValue(pid, out var known)) return known;
        var name = "";
        try
        {
            if (PathOf(pid) is { } path)
            {
                name = FileVersionInfo.GetVersionInfo(path).FileDescription?.Trim() ?? "";
                if (name.Length == 0) name = Path.GetFileNameWithoutExtension(path);
            }
        }
        catch
        {
            // 못 읽는 프로세스(관리자 권한)는 이름 없이 간다.
        }
        appNames[pid] = name;
        return name;
    }

    /// <summary>
    /// 작업 표시줄에 보이는 그 창들. 접힌 창도 들어 있다(불이 꺼진 방울로 남는다).
    /// 다른 가상 데스크톱의 창은 「가려진」(cloaked) 것이라 빠진다.
    /// </summary>
    private List<Dictionary<string, object>> ListWindows()
    {
        var list = new List<Dictionary<string, object>>();
        var own = (uint)Environment.ProcessId;
        EnumWindows((hWnd, _) =>
        {
            if (!IsWindowVisible(hWnd) || GetWindow(hWnd, GW_OWNER) != IntPtr.Zero) return true;
            if ((GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0 || GetWindowTextLength(hWnd) == 0) return true;
            if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out var cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            GetWindowThreadProcessId(hWnd, out var pid);
            if (pid == own) return true;
            if (ClassName(hWnd) is "Progman" or "WorkerW" or "Shell_TrayWnd") return true;
            var folded = IsIconic(hWnd);
            if (!folded && GetWindowRect(hWnd, out var rect)
                && (rect.right - rect.left < SmallestW || rect.bottom - rect.top < SmallestH)) return true;
            list.Add(new Dictionary<string, object>
            {
                ["id"] = hWnd.ToInt64(), ["pid"] = (long)pid, ["app"] = NameOf(pid),
                ["min"] = folded, ["big"] = !folded && IsZoomed(hWnd),
            });
            return true;
        }, IntPtr.Zero);
        list.Sort((a, b) => ((long)a["id"]).CompareTo((long)b["id"]));
        return list;
    }

    private void Watch()
    {
        if (!ready) return;
        var list = ListWindows();
        var text = Js(list);
        if (text == lastSent) return;
        lastSent = text;
        WindowCount = list.Count;
        DebugLog($"창 {list.Count}개 — {string.Join(", ", list.Select(w => $"{w["app"]}#{w["id"]}"))}");
        Call("__treeWindows", list, false);
        SettingsChanged?.Invoke();
    }

    /// <summary>방울이 눌렸다. 그 창에 일을 시키고 결과를 렌더러에 알린다: "ok" · "fail"(그 창이 말을 안 듣는다).</summary>
    private void Press(string key)
    {
        var parts = key.Split(':');
        var result = parts.Length == 2 && long.TryParse(parts[0], out var id) && Act(new IntPtr(id), parts[1]) ? "ok" : "fail";
        DebugLog($"누름 {key} → {result}");
        Call("__treePressed", key, result);
        if (result != "ok") return;
        // 닫히고 접히는 데는 시간이 걸린다. 1초를 기다리지 않고 바로바로 다시 본다.
        foreach (var delay in new[] { 120, 350, 700 })
        {
            var once = new System.Windows.Forms.Timer { Interval = delay };
            once.Tick += (_, _) => { once.Stop(); once.Dispose(); Watch(); };
            once.Start();
        }
    }

    private static bool Act(IntPtr hWnd, string kind)
    {
        if (!IsWindow(hWnd)) return false;
        switch (kind)
        {
            case "red":
                // 「닫아 달라」고 부탁한다. 저장 안 한 문서면 그 앱이 평소처럼 묻는다 — 우리는 강제로 닫지 않는다.
                return PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            case "yellow":
                if (!IsIconic(hWnd))
                {
                    ShowWindowAsync(hWnd, SW_MINIMIZE);
                    return true;
                }
                ShowWindowAsync(hWnd, SW_RESTORE);
                SetForegroundWindow(hWnd);
                return true;
            case "green":
                // 접혀 있었으면 펴면서 키운다. 이미 커져 있으면 되돌린다.
                ShowWindowAsync(hWnd, !IsIconic(hWnd) && IsZoomed(hWnd) ? SW_RESTORE : SW_MAXIMIZE);
                SetForegroundWindow(hWnd);
                return true;
            default:
                return false;
        }
    }

    // MARK: 웹뷰

    private async Task InitWebAsync()
    {
        // 사용자 데이터 폴더를 AppData 에 둔다 — Program Files 에 설치되면 앱 폴더에 쓸 수 없다.
        var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DataDir, "webview"));
        await web.EnsureCoreWebView2Async(env);

        web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        web.CoreWebView2.Settings.AreDevToolsEnabled = false;
        web.CoreWebView2.Settings.IsStatusBarEnabled = false;
        web.CoreWebView2.WebMessageReceived += OnWebMessage;

        // 맥 셸의 커스텀 스킴에 해당하는 것. file:// 로 열면 ES 모듈 import 가 막힌다.
        web.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "tree.local", Path.Combine(AppContext.BaseDirectory, "web"),
            CoreWebView2HostResourceAccessKind.Allow);
        // /icon/<pid> 는 그 앱의 아이콘이다(이름표에 붙는다). 못 주면 렌더러가 그림 없이 이름만 적는다.
        web.CoreWebView2.AddWebResourceRequestedFilter("https://tree.local/icon/*", CoreWebView2WebResourceContext.All);
        web.CoreWebView2.WebResourceRequested += OnIconRequested;

        await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(BridgeScript());
        web.CoreWebView2.Navigate("https://tree.local/renderer/index.html");

        ready = true;
        pointerTimer.Start();
        watchTimer.Start();
    }

    private void OnIconRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        try
        {
            var last = new Uri(e.Request.Uri).Segments[^1];
            if (!uint.TryParse(last, out var pid) || PathOf(pid) is not { } path) return;
            using var icon = Icon.ExtractAssociatedIcon(path);
            if (icon is null) return;
            using var bitmap = icon.ToBitmap();
            var stream = new MemoryStream();
            bitmap.Save(stream, ImageFormat.Png);
            stream.Position = 0;
            e.Response = web.CoreWebView2.Environment.CreateWebResourceResponse(stream, 200, "OK", "Content-Type: image/png");
        }
        catch
        {
            // 아이콘이 없어도 이름표는 뜬다.
        }
    }

    /// <summary>
    /// 저장해 둔 것. 렌더러가 준 JSON 을 그대로 들고 있다가 그대로 돌려준다 — 셸은 그 안을
    /// 모른다. 한 번 읽었다 다시 써서, 깨진 파일이 스크립트에 섞이지 않게 한다.
    /// </summary>
    private static string SavedStateLiteral()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(StatePath));
            return JsonSerializer.Serialize(doc.RootElement);
        }
        catch
        {
            return "null";
        }
    }

    /// <summary>맥 셸과 <b>같은 모양</b>의 다리.</summary>
    private static string BridgeScript() => $$"""
        (() => {
          const post = (m) => window.chrome.webview.postMessage(m)
          const hook = (name) => (handler) => { window[name] = handler }
          // 렌더러는 CSS 픽셀로 말하고 커서는 실제 픽셀로 온다. 배율이 150% 면 그대로 견줄 때
          // 방울 자리가 1.5 배 어긋난다. 여기서 실제 픽셀로 바꿔 보낸다.
          const real = () => window.devicePixelRatio || 1
          window.sneaky = {
            platform: 'win',
            getState: () => Promise.resolve({{SavedStateLiteral()}}),
            saveState: (s) => post({ type: 'state', json: JSON.stringify(s) }),
            setSettings: (s) => post({ type: 'settings', settings: s }),
            setHits: (list) => { const k = real(); post({ type: 'hits', list: list.map((h) => ({ key: String(h.key), x: h.x * k, y: h.y * k, r: h.r * k })) }) },
            setGrip: (g) => { const k = real(); post({ type: 'grip', x: g.x * k, y: g.y * k, r: g.r * k }) },
            setBody: (list) => { const k = real(); post({ type: 'body', list: list.map((b) => ({ x: b.x * k, y: b.y * k, w: b.w * k, h: b.h * k })) }) },
            ready: () => post({ type: 'ready' }),
            onSet: hook('__treeSet'),
            onWindows: hook('__treeWindows'),
            onHover: hook('__treeHover'),
            onPressed: hook('__treePressed'),
            onMoved: hook('__treeMoved'),
            onGrip: hook('__treeGrip'),
          }
          window.addEventListener('error', (e) => post({ type: 'log', text: `${e.message} (${e.filename}:${e.lineno})` }))
          window.addEventListener('unhandledrejection', (e) => post({ type: 'log', text: `reject ${e.reason}` }))
          console.error = (...args) => post({ type: 'log', text: args.join(' ') })
        })()
        """;

    private void Call(string name, params object?[] arguments)
    {
        if (!ready) return;
        var list = string.Join(", ", arguments.Select(Js));
        _ = web.ExecuteScriptAsync($"window.{name} && window.{name}({list})");
    }

    /// <summary>시험용 기록. 방울이 화면의 어디에 있는지 — smoke.ps1 이 이걸 읽고 거기를 누른다.</summary>
    private void LogHits()
    {
        if (!Debugging) return;
        foreach (var hit in hits)
            DebugLog($"방울 {hit.Key} {(int)Math.Round(Bounds.Left + hit.X)},{(int)Math.Round(Bounds.Top + hit.Y)}");
        if (grip is { } star) DebugLog($"별 {(int)Math.Round(Bounds.Left + star.X)},{(int)Math.Round(Bounds.Top + star.Y)}");
        if (body.Count > 0)
        {
            var trunk = body[^1];
            DebugLog($"기둥 {(int)(Bounds.Left + trunk.Left + trunk.Width / 2)},{(int)(Bounds.Top + trunk.Top + trunk.Height / 2)}");
        }
    }

    // MARK: 렌더러에서 오는 것

    private static string? Str(JsonElement body, string name) =>
        body.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    private static double Num(JsonElement body, string name) =>
        body.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble() : 0;

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            var message = JsonDocument.Parse(e.WebMessageAsJson).RootElement;
            switch (Str(message, "type"))
            {
                case "log":
                    DebugLog($"[web] {Str(message, "text")}");
                    break;

                case "state":
                    if (Str(message, "json") is { } json)
                    {
                        Directory.CreateDirectory(DataDir);
                        File.WriteAllText(StatePath, json);
                    }
                    break;

                case "settings":
                    if (message.TryGetProperty("settings", out var given) && given.ValueKind == JsonValueKind.Object)
                        settings = given.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
                    if (resize is null) liveScale = null; // 끌어서 정한 크기가 설정으로 돌아왔다
                    Place();
                    SettingsChanged?.Invoke();
                    break;

                case "ready":
                    lastSent = "";
                    Watch();
                    break;

                case "hits":
                    hits = message.GetProperty("list").EnumerateArray()
                        .Select(h => (Str(h, "key") ?? "", Num(h, "x"), Num(h, "y"), Num(h, "r")))
                        .Where(h => h.Item1.Length > 0).ToList();
                    DebugLog($"누를 자리 {hits.Count}개");
                    LogHits();
                    break;

                case "grip":
                    grip = (Num(message, "x"), Num(message, "y"), Num(message, "r"));
                    if (resize is null && Height > 0 && Num(message, "y") > 0) gripRatio = (Height - Num(message, "y")) / Height;
                    break;

                case "body":
                    body = message.GetProperty("list").EnumerateArray()
                        .Select(b => new RectangleF((float)Num(b, "x"), (float)Num(b, "y"), (float)Num(b, "w"), (float)Num(b, "h")))
                        .ToList();
                    break;
            }
        }
        catch (Exception error)
        {
            DebugLog($"메시지 처리 실패 {error.Message}");
        }
    }
}
