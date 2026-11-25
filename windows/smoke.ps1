# 설치본을 진짜 윈도우에서 한 바퀴 돌려 본다 (CI 의 windows 러너).
#   깔기 → 앱이 뜨는가 → 창을 하나 띄우면 방울이 달리는가 → 초록·노랑·빨강을 누르면
#   그 창이 커지고·접히고·닫히는가 → 트리를 끌면 옮겨지는가 → 제거하면 깨끗한가
#
# 이 맥에서는 윈도우 셸을 컴파일만 할 수 있다. 「돌아간다」는 말은 이 스크립트가 한다.
# 결과는 dist/smoke/ 에 남는다(로그·화면).
param([string]$Setup = "dist\DesktopTree-win-Setup.exe")

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Mouse2 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  static void Nudge() { mouse_event(1, 0, 0, 0, UIntPtr.Zero); }
  public static void Click(int x, int y) {
    SetCursorPos(x, y); Nudge(); System.Threading.Thread.Sleep(500);
    mouse_event(2, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(80); mouse_event(4, 0, 0, 0, UIntPtr.Zero);
  }
  public static void Drag(int x, int y, int x2, int y2) {
    SetCursorPos(x, y); Nudge(); System.Threading.Thread.Sleep(500);
    mouse_event(2, 0, 0, 0, UIntPtr.Zero);
    for (int i = 1; i <= 20; i++) {
      System.Threading.Thread.Sleep(30);
      SetCursorPos(x + (x2 - x) * i / 20, y + (y2 - y) * i / 20); Nudge();
    }
    System.Threading.Thread.Sleep(200);
    mouse_event(4, 0, 0, 0, UIntPtr.Zero);
  }
}
"@
# 앱은 실제 픽셀로 말한다. 이 스크립트도 그래야 좌표가 맞는다.
[Mouse2]::SetProcessDPIAware() | Out-Null

$out = "dist\smoke"
New-Item -ItemType Directory -Force $out | Out-Null
$data = Join-Path $env:APPDATA "DesktopTree"
$app = Join-Path $env:LOCALAPPDATA "Programs\Desktop Tree"
$failed = @()
function Check($name, $ok) {
  if ($ok) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:failed += $name }
}
function Shot($name) {
  try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out "$name.png"))
  } catch { Write-Host "  (화면을 못 찍음: $_)" }
}

Write-Host "› 깔기"
$env:TREE_DEBUG = "1"   # 설치본이 띄우는 앱이 물려받는다
# -Wait 는 쓰지 않는다 — 자손까지 기다려서, 설치본이 띄운 앱이 꺼질 때까지 안 돌아온다.
$setupProcess = Start-Process $Setup -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -PassThru
$setupProcess.WaitForExit()
Check "앱 폴더가 생겼다" (Test-Path (Join-Path $app "DesktopTree.exe"))
Check "제거 프로그램이 있다" (Test-Path (Join-Path $app "unins000.exe"))
Check "시작 프로그램에 들어갔다" (Test-Path (Join-Path ([Environment]::GetFolderPath("Startup")) "Desktop Tree.lnk"))

Write-Host "› 뜨는가"
Start-Sleep 12
Check "설치가 끝나고 앱이 스스로 떴다" ($null -ne (Get-Process DesktopTree -ErrorAction SilentlyContinue))
$log = Join-Path $data "debug.log"
function LogText { if (Test-Path $log) { Get-Content $log -Raw -Encoding UTF8 } else { "" } }
function LastMatch($pattern) {
  $all = [regex]::Matches((LogText), $pattern)
  if ($all.Count -gt 0) { $all[$all.Count - 1] } else { $null }
}
Check "마우스 훅이 걸렸다" ((LogText) -match "마우스 훅 걸림")
Check "렌더러가 창의 목록을 받았다 (다리가 살아 있다)" ((LogText) -match "누를 자리 \d+개")
Shot "1-tree"

# 방울이 화면의 어디에 있는지는 앱이 적어 준다: 「방울 <창번호>:<색> x,y」.
function Ball($hwnd, $kind) {
  $m = LastMatch "방울 ${hwnd}:$kind (-?\d+),(-?\d+)"
  if ($null -eq $m) { return $null }
  @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}
function Press($hwnd, $kind) {
  $at = Ball $hwnd $kind
  if ($null -eq $at) { Write-Host "  ($kind 방울의 자리를 모름)"; return }
  Write-Host "  $kind 방울 $($at[0]),$($at[1])"
  [Mouse2]::Click($at[0], $at[1])
}

Write-Host "› 방울이 창을 움직이는가"
# 과녁: 빈 창 하나. 타이머가 차례로 방울을 누르고, 누른 다음 걸음에서 창이 어떻게 됐는지 본다.
$form = New-Object System.Windows.Forms.Form
$form.Text = "target"; $form.Width = 520; $form.Height = 320
$form.StartPosition = "Manual"; $form.Left = 80; $form.Top = 80
$script:closed = $false
$form.Add_FormClosed({ $script:closed = $true })
$script:step = 0
$script:seen = @{}
$script:hwnd = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  $script:step += 1
  $state = "$($form.WindowState)"
  switch ($script:step) {
    1 { $script:hwnd = $form.Handle.ToInt64(); $script:seen.hung = ($null -ne (Ball $script:hwnd "red")); Shot "2-hung"; Press $script:hwnd "green" }
    2 { $script:seen.grown = $state; Shot "3-grown"; Press $script:hwnd "green" }
    3 { $script:seen.back = $state; Press $script:hwnd "yellow" }
    4 { $script:seen.folded = $state; Shot "4-folded"; Press $script:hwnd "yellow" }
    5 {
      $script:seen.unfolded = $state
      $m = LastMatch "기둥 (-?\d+),(-?\d+)"
      if ($null -ne $m) {
        $x = [int]$m.Groups[1].Value; $y = [int]$m.Groups[2].Value
        Write-Host "  기둥 $x,$y → 왼쪽 위로 끈다"
        [Mouse2]::Drag($x, $y, $x - 400, $y - 150)
      }
    }
    6 { $script:seen.moved = ((LogText) -match "옮김 "); Shot "5-moved"; Press $script:hwnd "red" }
    7 { $timer.Stop(); if (-not $script:closed) { $form.Close() } }
  }
})
$form.Add_Shown({ $timer.Start() })
[System.Windows.Forms.Application]::Run($form)
# 빨강을 눌러 닫혔으면 7번째 걸음 전에 창이 닫혀 여기로 온다.
$closedByBall = $script:step -lt 7
Start-Sleep 2
Shot "6-dropped"

Check "창을 띄우니 방울 셋이 달렸다" $script:seen.hung
Check "초록 방울 → 창이 커졌다" ($script:seen.grown -eq "Maximized")
Check "초록 방울을 다시 → 되돌아갔다" ($script:seen.back -eq "Normal")
Check "노랑 방울 → 창이 접혔다" ($script:seen.folded -eq "Minimized")
Check "노랑 방울을 다시 → 펴졌다" ($script:seen.unfolded -eq "Normal")
Check "기둥을 잡고 끄니 트리가 옮겨졌다" $script:seen.moved
Check "빨강 방울 → 창이 닫혔다" $closedByBall
Check "누른 것이 전부 통했다 (말 안 듣는 창 없음)" (-not ((LogText) -match "누름 \S+ → fail"))

Copy-Item $log (Join-Path $out "debug.log") -ErrorAction SilentlyContinue

Write-Host "› 제거"
$un = Start-Process (Join-Path $app "unins000.exe") -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -PassThru
$un.WaitForExit()
Start-Sleep 5
Check "앱이 꺼졌다" ($null -eq (Get-Process DesktopTree -ErrorAction SilentlyContinue))
Check "앱 폴더가 없어졌다" (-not (Test-Path (Join-Path $app "DesktopTree.exe")))
Check "설정이 없어졌다" (-not (Test-Path $data))
Check "시작 프로그램에서 빠졌다" (-not (Test-Path (Join-Path ([Environment]::GetFolderPath("Startup")) "Desktop Tree.lnk")))

if ($failed.Count -gt 0) {
  Write-Host "`n실패 $($failed.Count)개:"; $failed | ForEach-Object { Write-Host "  - $_" }
  $failed | Set-Content (Join-Path $out "failed.txt") -Encoding UTF8
  exit 1
}
Write-Host "`n전부 통과"
