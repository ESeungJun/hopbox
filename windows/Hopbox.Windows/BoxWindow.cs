using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Clipboard = System.Windows.Clipboard;
using DragDropEffects = System.Windows.DragDropEffects;
using DragEventArgs = System.Windows.DragEventArgs;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Screen = System.Windows.Forms.Screen;

namespace Hopbox;

public enum BoxMode { Icon, Fan, List }

/// <summary>
/// 떠 있는 상자 창. 창 크기는 늘 같고 투명한 부분은 클릭이 아래 앱으로 지나간다.
/// 그래서 상자가 펼쳐지거나 닫혀도 아이콘은 화면의 같은 자리에 그대로 있다.
/// </summary>
sealed class BoxWindow : Window
{
    public const double WindowWidth = 560, WindowHeight = 820;
    const double IconArea = 96, BoxImageSize = 82;
    /// <summary>아이콘 가운데가 화면 끝에서 떨어져 있어야 하는 거리</summary>
    const double EdgeMargin = 56;

    readonly ShelfStore _store;
    readonly ItemActions _actions;
    readonly Canvas _root = new() { Focusable = true };
    readonly Canvas _content = new();
    readonly Grid _icon = new() { Width = IconArea, Height = IconArea };
    readonly Image _boxImage = new() { Width = BoxImageSize, Height = BoxImageSize };
    readonly ScaleTransform _iconScale = new();
    readonly RotateTransform _iconWobble = new();
    readonly TranslateTransform _iconLift = new();
    readonly Border _badge;
    readonly TextBlock _badgeText = new() { Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.SemiBold };
    readonly TextBlock _plus = new() { FontSize = 16, FontWeight = FontWeights.Bold, Foreground = Theme.Accent, Opacity = 0 };
    readonly TranslateTransform _plusLift = new();
    readonly Border _toast;
    readonly TextBlock _toastText = new() { Foreground = Brushes.White, FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxWidth = 220 };
    readonly Button _undo;

    static readonly ImageSource ClosedBox = LoadArt("box-closed.png");
    static readonly ImageSource OpenBox = LoadArt("box-open.png");

    BoxMode _mode = BoxMode.Icon;
    /// <summary>아이콘 가운데의 화면 좌표</summary>
    Point _anchor;
    /// <summary>아이콘에서 펼쳐지는 쪽 화면 끝까지 남은 높이</summary>
    double _room;
    bool _opensUp = true;
    bool _iconOnRight = true;
    bool _dropTargeted;
    DispatcherTimer? _autoOpen;

    public BoxWindow(ShelfStore store)
    {
        _store = store;
        _actions = new ItemActions(store);
        Title = "택배상자";
        Width = WindowWidth;
        Height = WindowHeight;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowDrop = true;
        Content = _root;
        _root.Children.Add(_content);

        // 아이콘
        _icon.Children.Add(new Rectangle { Fill = Theme.HitTarget, RadiusX = 20, RadiusY = 20 });
        _icon.Children.Add(new Ellipse
        {
            Width = 58, Height = 10, Fill = new SolidColorBrush(Color.FromArgb(70, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 2),
            Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 6 },
        });
        _boxImage.Source = ClosedBox;
        _boxImage.RenderTransformOrigin = new Point(0.5, 1);
        _boxImage.RenderTransform = new TransformGroup { Children = { _iconScale, _iconWobble, _iconLift } };
        _icon.Children.Add(_boxImage);
        _badge = new Border
        {
            Background = Theme.Badge, CornerRadius = new CornerRadius(9), MinWidth = 18, Height = 18,
            Padding = new Thickness(5, 0, 5, 0), HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 4, 0),
            Child = _badgeText, Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        };
        _badgeText.HorizontalAlignment = HorizontalAlignment.Center;
        _badgeText.VerticalAlignment = VerticalAlignment.Center;
        _icon.Children.Add(_badge);
        _plus.HorizontalAlignment = HorizontalAlignment.Center;
        _plus.VerticalAlignment = VerticalAlignment.Top;
        _plus.RenderTransform = _plusLift;
        _plus.IsHitTestVisible = false;
        _icon.Children.Add(_plus);
        _icon.ToolTip = "누르면 열고 닫아요 · 끌면 상자를 옮겨요";
        WireIconMouse();
        _root.Children.Add(_icon);

        // 알림
        _undo = Theme.TextButton("되돌리기", () => _store.UndoRemove());
        _undo.Margin = new Thickness(10, 0, 0, 0);
        _toast = new Border
        {
            Background = Theme.Pill, CornerRadius = new CornerRadius(16), Padding = new Thickness(14, 7, 14, 7),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { _toastText, _undo } },
            Visibility = Visibility.Collapsed, Effect = Theme.Shadow(),
        };
        _root.Children.Add(_toast);

        _store.Changed += () => { UpdateBadge(); if (_mode != BoxMode.Icon) Rebuild(animate: false); };
        _store.Added += Received;
        _store.ToastChanged += UpdateToast;
        UpdateBadge();

        SourceInitialized += (_, _) => MakeToolWindow();
        Deactivated += (_, _) => { if (_mode != BoxMode.Icon && !ItemActions.DraggingOut) SetMode(BoxMode.Icon); };
        PreviewKeyDown += OnKey;
        DragEnter += OnDragOver;
        DragOver += OnDragOver;
        DragLeave += (_, _) => SetDropTargeted(false);
        Drop += OnDrop;
    }

    static ImageSource LoadArt(string name)
    {
        var image = new BitmapImage(new Uri($"pack://application:,,,/Assets/{name}"));
        image.Freeze();
        return image;
    }

    /// <summary>작업 표시줄·Alt+Tab 에 나오지 않고, 모든 가상 데스크톱에서 보이는 도구 창으로 만든다</summary>
    void MakeToolWindow()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var style = Native.GetWindowLongPtr(handle, Native.GWL_EXSTYLE).ToInt64();
        style = (style | Native.WS_EX_TOOLWINDOW) & ~(long)Native.WS_EX_APPWINDOW;
        Native.SetWindowLongPtr(handle, Native.GWL_EXSTYLE, new IntPtr(style));
    }

    // 부르기·숨기기

    /// <summary>단축키를 누르면 부른다. 이미 앞에 떠 있으면 숨긴다</summary>
    public void Toggle()
    {
        if (IsVisible && IsActive) HideBox();
        else Deliver();
    }

    /// <summary>마우스 옆으로 상자를 배달한다. 위에서 살짝 내려앉고, 담긴 게 있으면 저절로 열린다</summary>
    public void Deliver()
    {
        Native.GetCursorPos(out var cursor);
        _anchor = new Point(cursor.X / Scale, cursor.Y / Scale);
        _mode = BoxMode.Icon;
        _content.Children.Clear();
        _boxImage.Source = ClosedBox;
        Place();

        Show();
        Activate();
        Native.SetForegroundWindow(new WindowInteropHelper(this).Handle);
        _root.Focus();
        PlayLanding();

        _autoOpen?.Stop();
        if (_store.Items.Count == 0) return;
        _autoOpen = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.45) };
        _autoOpen.Tick += (_, _) => { _autoOpen.Stop(); if (IsVisible && _mode == BoxMode.Icon) SetMode(BoxMode.Fan); };
        _autoOpen.Start();
    }

    /// <summary>알림 영역 메뉴에서 비울 때. 상자를 불러서 되돌리기 알림이 보이게 한다</summary>
    public void EmptyFromTray()
    {
        Deliver();
        _autoOpen?.Stop();
        _store.RemoveAll();
    }

    public void HideBox()
    {
        _autoOpen?.Stop();
        SetMode(BoxMode.Icon);
        Hide();
    }

    /// <summary>
    /// 화면 픽셀과 창 좌표(DIP)의 배율. 앱은 시스템 DPI 기준으로 동작하므로(모니터별 DPI 미사용)
    /// 모든 모니터에 같은 배율을 쓴다
    /// </summary>
    static double Scale => Native.GetDpiForSystem() / 96.0;

    /// <summary>점이 있는 모니터의 작업 영역(작업 표시줄 제외)을 창 좌표로</summary>
    static Rect WorkAreaAt(Point point)
    {
        var scale = Scale;
        var work = Screen.FromPoint(new System.Drawing.Point((int)(point.X * scale), (int)(point.Y * scale))).WorkingArea;
        return new Rect(work.Left / scale, work.Top / scale, work.Width / scale, work.Height / scale);
    }

    /// <summary>
    /// 아이콘을 화면 안으로 당기고, 펼칠 방향과 남은 높이를 정한 뒤, 아이콘이 _anchor 에 오도록 창을 놓는다.
    /// 배달할 때뿐 아니라 끌어 옮긴 뒤, 펼칠 때마다 부른다
    /// </summary>
    void Place()
    {
        var work = WorkAreaAt(_anchor);
        _anchor = new Point(
            Math.Clamp(_anchor.X, work.Left + EdgeMargin, Math.Max(work.Left + EdgeMargin, work.Right - EdgeMargin)),
            Math.Clamp(_anchor.Y, work.Top + EdgeMargin, Math.Max(work.Top + EdgeMargin, work.Bottom - EdgeMargin)));
        var above = _anchor.Y - work.Top;
        var below = work.Bottom - _anchor.Y;
        _opensUp = above >= below;
        _room = Math.Max(above, below);
        _iconOnRight = _anchor.X > work.Left + work.Width / 2;
        var icon = IconCenter;
        Canvas.SetLeft(_icon, icon.X - IconArea / 2);
        Canvas.SetTop(_icon, icon.Y - IconArea / 2);
        Left = _anchor.X - icon.X;
        Top = _anchor.Y - icon.Y;
    }

    /// <summary>창 안에서 아이콘 가운데 자리. 펼쳐질 쪽의 반대편 끝에 둔다</summary>
    Point IconCenter => new(_iconOnRight ? WindowWidth - 80 : 80, _opensUp ? WindowHeight - 110 : 110);

    // 상태

    public void SetMode(BoxMode mode)
    {
        if (mode != BoxMode.Icon) _autoOpen?.Stop();
        var changed = mode != _mode;
        _mode = mode;
        if (mode == BoxMode.Icon)
        {
            _content.Children.Clear();
            _boxImage.Source = _dropTargeted ? OpenBox : ClosedBox;
            return;
        }
        // 펼칠 때마다 방향을 다시 정한다. 아이콘은 화면의 같은 자리에 남는다
        Place();
        _boxImage.Source = OpenBox;
        Rebuild(animate: changed);
    }

    void Rebuild(bool animate)
    {
        _content.Children.Clear();
        var icon = IconCenter;
        if (_mode == BoxMode.Fan)
        {
            var rows = FanView.FitRows(_room);
            foreach (var element in FanView.Build(_store, _actions, OpenList, icon, _opensUp, _iconOnRight, rows, animate))
                _content.Children.Add(element);
        }
        else if (_mode == BoxMode.List)
        {
            // 화면이 낮으면 목록 카드를 줄여서 머리줄(닫기·전부 끌기)이 화면 밖으로 나가지 않게 한다
            const double gap = 56;
            var height = Math.Clamp(_room - gap - 8, ListCard.MinCardHeight, ListCard.CardHeight);
            var card = ListCard.Build(_store, _actions, CloseToIcon, height);
            Canvas.SetTop(card, _opensUp ? icon.Y - gap - height : icon.Y + gap);
            Canvas.SetLeft(card, _iconOnRight ? icon.X + IconArea / 2 - ListCard.CardWidth : icon.X - IconArea / 2);
            _content.Children.Add(card);
            if (animate) Theme.FadeIn(card, offsetY: _opensUp ? 12 : -12, delay: 0);
        }
        UpdateToast();
    }

    void UpdateBadge()
    {
        var count = _store.Items.Count;
        _badge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _badgeText.Text = count > 99 ? "99+" : count.ToString();
    }

    void UpdateToast()
    {
        var toast = _store.Toast;
        if (toast is null || !IsVisible)
        {
            _toast.Visibility = Visibility.Collapsed;
            return;
        }
        _toastText.Text = toast.Message;
        _undo.Visibility = toast.Undoable ? Visibility.Visible : Visibility.Collapsed;
        _toast.Visibility = Visibility.Visible;
        _toast.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = _toast.DesiredSize;
        var icon = IconCenter;
        // 아이콘 옆, 화면 가운데 쪽에 둔다. 아이콘은 화면 안에 있으니 알림도 작업 표시줄에 겹치지 않는다
        Canvas.SetLeft(_toast, _iconOnRight ? icon.X - IconArea / 2 - 6 - size.Width : icon.X + IconArea / 2 + 6);
        Canvas.SetTop(_toast, icon.Y - size.Height / 2);
        Theme.FadeIn(_toast, offsetY: 0, delay: 0);
    }

    // 아이콘: 누르면 열고 닫고, 끌면 창을 옮긴다

    void WireIconMouse()
    {
        Point? down = null;
        var moved = false;
        _icon.MouseLeftButtonDown += (_, e) =>
        {
            down = e.GetPosition(this);
            moved = false;
            _icon.CaptureMouse();
            e.Handled = true;
        };
        _icon.MouseMove += (_, e) =>
        {
            if (down is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            if ((e.GetPosition(this) - start).Length < 4) return;
            moved = true;
            down = null;
            _icon.ReleaseMouseCapture();
            DragMove();
            // 놓은 자리가 화면 밖이면 안으로 당긴다
            var icon = IconCenter;
            _anchor = new Point(Left + icon.X, Top + icon.Y);
            Place();
            if (_mode != BoxMode.Icon) Rebuild(animate: false);
        };
        _icon.MouseLeftButtonUp += (_, e) =>
        {
            _icon.ReleaseMouseCapture();
            if (down is not null && !moved) SetMode(_mode == BoxMode.Icon ? BoxMode.Fan : BoxMode.Icon);
            down = null;
            e.Handled = true;
        };
    }

    // 애니메이션

    void PlayLanding()
    {
        _boxImage.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.2)));
        var fall = new DoubleAnimation(-22, 0, TimeSpan.FromSeconds(0.2)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } };
        fall.Completed += (_, _) => Squash(1.06, 0.92);
        _iconLift.BeginAnimation(TranslateTransform.YProperty, fall);
    }

    /// <summary>살짝 납작해졌다가 돌아온다</summary>
    void Squash(double x, double y)
    {
        _iconScale.BeginAnimation(ScaleTransform.ScaleXProperty, Bounce(x));
        _iconScale.BeginAnimation(ScaleTransform.ScaleYProperty, Bounce(y));
    }

    static DoubleAnimationUsingKeyFrames Bounce(double peak) => new()
    {
        KeyFrames =
        {
            new EasingDoubleKeyFrame(peak, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.08))),
            new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.45)), new ElasticEase { Oscillations = 1, Springiness = 4 }),
        },
    };

    /// <summary>무언가 담기면 통통 튀고 "+N" 이 떠오른다</summary>
    void Received(int count)
    {
        if (!IsVisible) return;
        Squash(1.12, 1.12);
        _plus.Text = $"+{count}";
        _plus.BeginAnimation(OpacityProperty, new DoubleAnimationUsingKeyFrames
        {
            KeyFrames =
            {
                new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.Zero)),
                new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.4))),
                new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.8))),
            },
        });
        _plusLift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, -26, TimeSpan.FromSeconds(0.8)));
    }

    void SetDropTargeted(bool targeted)
    {
        if (targeted == _dropTargeted) return;
        _dropTargeted = targeted;
        if (_mode == BoxMode.Icon) _boxImage.Source = targeted ? OpenBox : ClosedBox;
        if (targeted)
        {
            _iconWobble.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-4, 4, TimeSpan.FromSeconds(0.12))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever,
            });
        }
        else
        {
            _iconWobble.BeginAnimation(RotateTransform.AngleProperty, null);
        }
    }

    // 담기: 끌어다 놓기와 Ctrl+V

    void OnDragOver(object sender, DragEventArgs e)
    {
        var accept = !ItemActions.DraggingOut && Transfer.CanAdd(e.Data);
        e.Effects = accept ? DragDropEffects.Copy : DragDropEffects.None;
        SetDropTargeted(accept);
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        SetDropTargeted(false);
        if (ItemActions.DraggingOut) return;
        _store.Add(Transfer.Read(e.Data));
        e.Handled = true;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        var control = Keyboard.Modifiers == ModifierKeys.Control;
        if (e.Key == Key.Escape)
        {
            if (_mode != BoxMode.Icon) SetMode(BoxMode.Icon);
            else HideBox();
        }
        else if (control && e.Key == Key.V)
        {
            PasteFromClipboard();
        }
        else if (control && e.Key == Key.W)
        {
            HideBox();
        }
        else
        {
            return;
        }
        e.Handled = true;
    }

    void PasteFromClipboard()
    {
        try
        {
            var sequence = Native.GetClipboardSequenceNumber();
            if (Clipboard.GetDataObject() is { } data) _store.Add(Transfer.Read(data, sequence));
        }
        catch (Exception)
        {
            _store.ShowToast("담을 수 있는 내용이 없어요");
        }
    }

    public void OpenList() => SetMode(BoxMode.List);
    public void CloseToIcon() => SetMode(BoxMode.Icon);
}
