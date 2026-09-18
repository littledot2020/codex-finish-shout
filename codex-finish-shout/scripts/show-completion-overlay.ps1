# Codex Finish Shout detached completion overlay.
# Displays a short, non-activating, click-through WPF celebration and exits.

[CmdletBinding()]
param(
    [string] $ProjectName = '',

    [int] $DurationMilliseconds = 2000,

    [switch] $Diagnostic,

    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$overlayMutex = $null
$ownsOverlayMutex = $false

function New-CodexFinishOverlayBrush {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Color
    )

    $parsedColor = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    $brush = New-Object System.Windows.Media.SolidColorBrush($parsedColor)
    $brush.Freeze()
    return $brush
}

function Start-CodexFinishOverlayAnimation {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Media.Animation.Animatable] $Target,

        [Parameter(Mandatory = $true)]
        [System.Windows.DependencyProperty] $Property,

        [double] $From,
        [double] $To,
        [ValidateRange(0, 10000)]
        [int] $BeginMilliseconds = 0,
        [ValidateRange(1, 10000)]
        [int] $AnimationMilliseconds,
        [System.Windows.Media.Animation.IEasingFunction] $EasingFunction
    )

    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $From
    $animation.To = $To
    $animation.BeginTime = [TimeSpan]::FromMilliseconds($BeginMilliseconds)
    $animation.Duration = New-Object System.Windows.Duration(
        [TimeSpan]::FromMilliseconds($AnimationMilliseconds)
    )
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    if ($null -ne $EasingFunction) {
        $animation.EasingFunction = $EasingFunction
    }
    $Target.BeginAnimation($Property, $animation)
}

function Add-CodexFinishFirework {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.Canvas] $Canvas,

        [double] $CenterX,
        [double] $CenterY,
        [Parameter(Mandatory = $true)]
        [System.Windows.Media.Brush[]] $Palette,
        [ValidateRange(0, 1000)]
        [int] $BeginMilliseconds,
        [double] $Phase = 0,
        [bool] $Animate = $true
    )

    $particleCount = 18
    $easeOut = New-Object System.Windows.Media.Animation.CubicEase
    $easeOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $easeOut.Freeze()

    for ($index = 0; $index -lt $particleCount; $index++) {
        $angle = ((2 * [Math]::PI * $index) / $particleCount) + $Phase
        $distance = 66 + (($index * 17) % 31)
        $gravity = 8 + (($index % 4) * 2)
        $offsetX = [Math]::Cos($angle) * $distance
        $offsetY = ([Math]::Sin($angle) * $distance) + $gravity
        $particleSize = 3.2 + (($index % 3) * 1.15)

        $particle = New-Object System.Windows.Shapes.Ellipse
        $particle.Width = $particleSize
        $particle.Height = $particleSize
        $particle.Fill = $Palette[$index % $Palette.Count]
        $particle.Opacity = 0.94
        $particle.IsHitTestVisible = $false

        if ($Animate) {
            [System.Windows.Controls.Canvas]::SetLeft($particle, $CenterX - ($particleSize / 2))
            [System.Windows.Controls.Canvas]::SetTop($particle, $CenterY - ($particleSize / 2))
            $translation = New-Object System.Windows.Media.TranslateTransform
            $particle.RenderTransform = $translation
        }
        else {
            [System.Windows.Controls.Canvas]::SetLeft(
                $particle,
                $CenterX + $offsetX - ($particleSize / 2)
            )
            [System.Windows.Controls.Canvas]::SetTop(
                $particle,
                $CenterY + $offsetY - ($particleSize / 2)
            )
            $particle.Opacity = 0.82
        }

        $null = $Canvas.Children.Add($particle)

        if ($Animate) {
            $particleDelay = $BeginMilliseconds + (($index % 3) * 12)
            $travelMilliseconds = 650 + (($index % 4) * 45)
            Start-CodexFinishOverlayAnimation `
                -Target $translation `
                -Property ([System.Windows.Media.TranslateTransform]::XProperty) `
                -From 0 `
                -To $offsetX `
                -BeginMilliseconds $particleDelay `
                -AnimationMilliseconds $travelMilliseconds `
                -EasingFunction $easeOut
            Start-CodexFinishOverlayAnimation `
                -Target $translation `
                -Property ([System.Windows.Media.TranslateTransform]::YProperty) `
                -From 0 `
                -To $offsetY `
                -BeginMilliseconds $particleDelay `
                -AnimationMilliseconds $travelMilliseconds `
                -EasingFunction $easeOut
            Start-CodexFinishOverlayAnimation `
                -Target $particle `
                -Property ([System.Windows.UIElement]::OpacityProperty) `
                -From 0.94 `
                -To 0 `
                -BeginMilliseconds ($particleDelay + 330) `
                -AnimationMilliseconds ([Math]::Max(260, $travelMilliseconds - 300))
        }
    }

    $ring = New-Object System.Windows.Shapes.Ellipse
    $ring.Width = if ($Animate) { 18 } else { 52 }
    $ring.Height = $ring.Width
    $ring.Stroke = $Palette[0]
    $ring.StrokeThickness = 1.6
    $ring.Fill = [System.Windows.Media.Brushes]::Transparent
    $ring.Opacity = if ($Animate) { 0.9 } else { 0.42 }
    $ring.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    [System.Windows.Controls.Canvas]::SetLeft($ring, $CenterX - ($ring.Width / 2))
    [System.Windows.Controls.Canvas]::SetTop($ring, $CenterY - ($ring.Height / 2))
    $null = $Canvas.Children.Add($ring)

    $flash = New-Object System.Windows.Shapes.Ellipse
    $flash.Width = 12
    $flash.Height = 12
    $flash.Fill = $Palette[[Math]::Min(1, $Palette.Count - 1)]
    $flash.Opacity = if ($Animate) { 0.95 } else { 0.72 }
    $flash.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    [System.Windows.Controls.Canvas]::SetLeft($flash, $CenterX - 6)
    [System.Windows.Controls.Canvas]::SetTop($flash, $CenterY - 6)
    $null = $Canvas.Children.Add($flash)

    if ($Animate) {
        $ringScale = New-Object System.Windows.Media.ScaleTransform(0.35, 0.35)
        $ring.RenderTransform = $ringScale
        Start-CodexFinishOverlayAnimation `
            -Target $ringScale `
            -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
            -From 0.35 `
            -To 3.6 `
            -BeginMilliseconds $BeginMilliseconds `
            -AnimationMilliseconds 430 `
            -EasingFunction $easeOut
        Start-CodexFinishOverlayAnimation `
            -Target $ringScale `
            -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) `
            -From 0.35 `
            -To 3.6 `
            -BeginMilliseconds $BeginMilliseconds `
            -AnimationMilliseconds 430 `
            -EasingFunction $easeOut
        Start-CodexFinishOverlayAnimation `
            -Target $ring `
            -Property ([System.Windows.UIElement]::OpacityProperty) `
            -From 0.9 `
            -To 0 `
            -BeginMilliseconds $BeginMilliseconds `
            -AnimationMilliseconds 430

        $flashScale = New-Object System.Windows.Media.ScaleTransform(0.4, 0.4)
        $flash.RenderTransform = $flashScale
        Start-CodexFinishOverlayAnimation `
            -Target $flashScale `
            -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
            -From 0.4 `
            -To 2.5 `
            -BeginMilliseconds $BeginMilliseconds `
            -AnimationMilliseconds 300 `
            -EasingFunction $easeOut
        Start-CodexFinishOverlayAnimation `
            -Target $flashScale `
            -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) `
            -From 0.4 `
            -To 2.5 `
            -BeginMilliseconds $BeginMilliseconds `
            -AnimationMilliseconds 300 `
            -EasingFunction $easeOut
        Start-CodexFinishOverlayAnimation `
            -Target $flash `
            -Property ([System.Windows.UIElement]::OpacityProperty) `
            -From 0.95 `
            -To 0 `
            -BeginMilliseconds ($BeginMilliseconds + 100) `
            -AnimationMilliseconds 300
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return
    }

    $duration = [Math]::Max(1000, [Math]::Min(2000, $DurationMilliseconds))
    $defaultProjectName = -join @(
        [char] 0x5F53,
        [char] 0x524D,
        [char] 0x9879,
        [char] 0x76EE
    )
    $displayProjectName = if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        $defaultProjectName
    }
    else {
        [Text.RegularExpressions.Regex]::Replace(
            $ProjectName.Trim(),
            '[\x00-\x1F\x7F]+',
            ' '
        )
    }

    foreach ($assemblyName in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
        $null = Add-Type -AssemblyName $assemblyName -ErrorAction Stop
    }

    if ($null -eq ('CodexFinishOverlay.NativeWindow' -as [type])) {
        $nativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace CodexFinishOverlay
{
    public static class NativeWindow
    {
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TRANSPARENT = 0x00000020L;
        private const long WS_EX_TOOLWINDOW = 0x00000080L;
        private const long WS_EX_NOACTIVATE = 0x08000000L;
        private const int WM_MOUSEACTIVATE = 0x0021;
        private const int WM_NCHITTEST = 0x0084;
        private const int MA_NOACTIVATE = 3;
        private const int HTTRANSPARENT = -1;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOZORDER = 0x0004;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_FRAMECHANGED = 0x0020;

        [DllImport("user32.dll", EntryPoint = "GetWindowLong", SetLastError = true)]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
        private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int value);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr value);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags
        );

        private static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
        {
            return IntPtr.Size == 8
                ? GetWindowLongPtr64(hWnd, nIndex)
                : new IntPtr(GetWindowLong32(hWnd, nIndex));
        }

        private static void SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr value)
        {
            if (IntPtr.Size == 8)
            {
                SetWindowLongPtr64(hWnd, nIndex, value);
            }
            else
            {
                SetWindowLong32(hWnd, nIndex, value.ToInt32());
            }
        }

        public static void Configure(HwndSource source)
        {
            if (source == null)
            {
                return;
            }

            IntPtr hWnd = source.Handle;
            long style = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
            style |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(style));
            SetWindowPos(
                hWnd,
                IntPtr.Zero,
                0,
                0,
                0,
                0,
                SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
            );
            source.AddHook(WindowProcedure);
        }

        private static IntPtr WindowProcedure(
            IntPtr hWnd,
            int message,
            IntPtr wParam,
            IntPtr lParam,
            ref bool handled
        )
        {
            if (message == WM_NCHITTEST)
            {
                handled = true;
                return new IntPtr(HTTRANSPARENT);
            }

            if (message == WM_MOUSEACTIVATE)
            {
                handled = true;
                return new IntPtr(MA_NOACTIVATE);
            }

            return IntPtr.Zero;
        }
    }
}
'@
        $nativeReferences = @(
            [System.Windows.Interop.HwndSource].Assembly.Location,
            [System.Windows.DependencyObject].Assembly.Location
        )
        $null = Add-Type `
            -TypeDefinition $nativeSource `
            -ReferencedAssemblies $nativeReferences `
            -Language CSharp `
            -ErrorAction Stop
    }

    # A local mutex keeps simultaneous project completions from drawing on top
    # of one another. A short wait allows two near-simultaneous overlays to be
    # shown sequentially without holding up the Codex notification process.
    $overlayMutex = New-Object System.Threading.Mutex(
        $false,
        'Local\CodexFinishShout.CompletionOverlay.v1'
    )
    try {
        $ownsOverlayMutex = $overlayMutex.WaitOne($duration + 500)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsOverlayMutex = $true
    }
    if (-not $ownsOverlayMutex) {
        return
    }

    $tokens = [ordered] @{
        Surface   = '#EE141A25'
        Border    = '#55FFFFFF'
        Ink       = '#FFFFF7E8'
        Gold      = '#FFFFD66B'
        GoldSoft  = '#FFFFF1AE'
        Cyan      = '#FF43E7F4'
        CyanSoft  = '#FFB9FAFF'
    }
    $brushes = [ordered] @{
        Surface   = New-CodexFinishOverlayBrush -Color $tokens.Surface
        Border    = New-CodexFinishOverlayBrush -Color $tokens.Border
        Ink       = New-CodexFinishOverlayBrush -Color $tokens.Ink
        Gold      = New-CodexFinishOverlayBrush -Color $tokens.Gold
        GoldSoft  = New-CodexFinishOverlayBrush -Color $tokens.GoldSoft
        Cyan      = New-CodexFinishOverlayBrush -Color $tokens.Cyan
        CyanSoft  = New-CodexFinishOverlayBrush -Color $tokens.CyanSoft
    }

    $motionAllowed = $false
    try {
        # ClientAreaAnimation reflects the Windows "Show animations" setting.
        $motionAllowed = [bool] [System.Windows.SystemParameters]::ClientAreaAnimation
    }
    catch {
        # If the accessibility preference cannot be read, prefer the static UI.
        $motionAllowed = $false
    }

    $window = New-Object System.Windows.Window
    $window.Title = 'Codex Finish Shout Completion Overlay'
    $window.Width = 780
    $window.Height = 360
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.Focusable = $false
    $window.IsHitTestVisible = $false
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $window.SnapsToDevicePixels = $true
    $window.UseLayoutRounding = $true

    $root = New-Object System.Windows.Controls.Canvas
    $root.Width = 780
    $root.Height = 360
    $root.Background = [System.Windows.Media.Brushes]::Transparent
    $root.IsHitTestVisible = $false
    $window.Content = $root

    $fireworksLayer = New-Object System.Windows.Controls.Canvas
    $fireworksLayer.Width = 780
    $fireworksLayer.Height = 360
    $fireworksLayer.Background = [System.Windows.Media.Brushes]::Transparent
    $fireworksLayer.IsHitTestVisible = $false
    $null = $root.Children.Add($fireworksLayer)

    $card = New-Object System.Windows.Controls.Border
    $card.Width = 640
    $card.Height = 142
    $card.Background = $brushes.Surface
    $card.BorderBrush = $brushes.Border
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(25)
    $card.Padding = New-Object System.Windows.Thickness(30, 18, 30, 18)
    $card.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($card, 70)
    [System.Windows.Controls.Canvas]::SetTop($card, 109)

    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#FF000000')
    $shadow.BlurRadius = 28
    $shadow.ShadowDepth = 0
    $shadow.Opacity = 0.68
    $card.Effect = $shadow

    $cardScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $card.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $card.RenderTransform = $cardScale

    $message = New-Object System.Windows.Controls.TextBlock
    $message.Text = 'Codex' + [char] 0x300C + $displayProjectName + [char] 0x300D +
        [Environment]::NewLine +
        [char] 0x9879 + [char] 0x76EE + [char] 0x5B8C + [char] 0x6210
    $message.Foreground = $brushes.Ink
    $message.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    $message.FontSize = 31
    $message.FontWeight = [System.Windows.FontWeights]::SemiBold
    $message.LineHeight = 43
    $message.TextAlignment = [System.Windows.TextAlignment]::Center
    $message.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $message.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $message.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $message.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $message.MaxWidth = 570
    $message.IsHitTestVisible = $false
    $card.Child = $message
    $null = $root.Children.Add($card)

    $goldRule = New-Object System.Windows.Shapes.Rectangle
    $goldRule.Width = 210
    $goldRule.Height = 2
    $goldRule.RadiusX = 1
    $goldRule.RadiusY = 1
    $goldRule.Fill = $brushes.Gold
    $goldRule.Opacity = 0.88
    [System.Windows.Controls.Canvas]::SetLeft($goldRule, 176)
    [System.Windows.Controls.Canvas]::SetTop($goldRule, 108)
    $null = $root.Children.Add($goldRule)

    $cyanRule = New-Object System.Windows.Shapes.Rectangle
    $cyanRule.Width = 210
    $cyanRule.Height = 2
    $cyanRule.RadiusX = 1
    $cyanRule.RadiusY = 1
    $cyanRule.Fill = $brushes.Cyan
    $cyanRule.Opacity = 0.88
    [System.Windows.Controls.Canvas]::SetLeft($cyanRule, 394)
    [System.Windows.Controls.Canvas]::SetTop($cyanRule, 108)
    $null = $root.Children.Add($cyanRule)

    $window.Add_SourceInitialized({
        try {
            $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper($window)
            $source = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
            [CodexFinishOverlay.NativeWindow]::Configure($source)
        }
        catch {
            # Managed ShowActivated/IsHitTestVisible settings remain as fallback.
            if ($Diagnostic) {
                [Console]::Error.WriteLine($_.Exception.ToString())
            }
        }
    })

    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds($duration)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $window.Close()
    })

    $window.Add_ContentRendered({
        try {
            Add-CodexFinishFirework `
                -Canvas $fireworksLayer `
                -CenterX 166 `
                -CenterY 91 `
                -Palette @($brushes.Gold, $brushes.GoldSoft) `
                -BeginMilliseconds 90 `
                -Phase 0.04 `
                -Animate $motionAllowed
            Add-CodexFinishFirework `
                -Canvas $fireworksLayer `
                -CenterX 614 `
                -CenterY 91 `
                -Palette @($brushes.Cyan, $brushes.CyanSoft) `
                -BeginMilliseconds 175 `
                -Phase 0.19 `
                -Animate $motionAllowed

            if ($motionAllowed) {
                $message.Opacity = 0
                Start-CodexFinishOverlayAnimation `
                    -Target $message `
                    -Property ([System.Windows.UIElement]::OpacityProperty) `
                    -From 0 `
                    -To 1 `
                    -BeginMilliseconds 55 `
                    -AnimationMilliseconds 190

                Start-CodexFinishOverlayAnimation `
                    -Target $cardScale `
                    -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
                    -From 0.94 `
                    -To 1 `
                    -AnimationMilliseconds 260
                Start-CodexFinishOverlayAnimation `
                    -Target $cardScale `
                    -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) `
                    -From 0.94 `
                    -To 1 `
                    -AnimationMilliseconds 260

                Start-CodexFinishOverlayAnimation `
                    -Target $root `
                    -Property ([System.Windows.UIElement]::OpacityProperty) `
                    -From 1 `
                    -To 0 `
                    -BeginMilliseconds ([Math]::Max(700, $duration - 220)) `
                    -AnimationMilliseconds 200
            }

            $closeTimer.Start()
        }
        catch {
            if ($Diagnostic) {
                [Console]::Error.WriteLine($_.Exception.ToString())
            }
            $window.Close()
        }
    })

    $window.Add_Closed({
        $closeTimer.Stop()
    })

    if ($ValidateOnly) {
        return
    }

    $application = New-Object System.Windows.Application
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
    $null = $application.Run($window)
}
catch {
    # Completion effects are best effort and must never affect Codex.
    if ($Diagnostic) {
        [Console]::Error.WriteLine($_.Exception.ToString())
        [Console]::Error.WriteLine($_.ScriptStackTrace)
        exit 1
    }
}
finally {
    if ($ownsOverlayMutex -and $null -ne $overlayMutex) {
        try {
            $overlayMutex.ReleaseMutex()
        }
        catch {
            # Best-effort cleanup only.
        }
    }
    if ($null -ne $overlayMutex) {
        $overlayMutex.Dispose()
    }
}
