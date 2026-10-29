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

    readonly ShelfStore _store;
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
    bool _opensUp = true;
    bool _iconOnRight = true;
    bool _dropTargeted;
    DispatcherTimer? _autoOpen;

    /// <summary>상자에서 끌어내는 중. 상자에 다시 떨어뜨려도 받지 않는다</summary>
    internal static bool DraggingOut;

    public BoxWindow(ShelfStore store)
    {
        _store = store;
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
        Deactivated += (_, _) => { if (_mode != BoxMode.Icon && !DraggingOut) SetMode(BoxMode.Icon); };
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
        var scale = Native.GetDpiForSystem() / 96.0;
        Native.GetCursorPos(out var cursor);
        var work = Screen.FromPoint(new System.Drawing.Point(cursor.X, cursor.Y)).WorkingArea;
        const double margin = 56;
        _anchor = new Point(
            Math.Clamp(cursor.X / scale, work.Left / scale + margin, work.Right / scale - margin),
            Math.Clamp(cursor.Y / scale, work.Top / scale + margin, work.Bottom / scale - margin));
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

    public void HideBox()
    {
        _autoOpen?.Stop();
        SetMode(BoxMode.Icon);
        Hide();
    }

    /// <summary>펼칠 방향을 정하고, 아이콘이 _anchor 에 오도록 창을 놓는다</summary>
    void Place()
    {
        var scale = Native.GetDpiForSystem() / 96.0;
        var work = Screen.FromPoint(new System.Drawing.Point((int)(_anchor.X * scale), (int)(_anchor.Y * scale))).WorkingArea;
        var top = work.Top / scale;
        var bottom = work.Bottom / scale;
        _opensUp = _anchor.Y - top >= bottom - _anchor.Y;
        _iconOnRight = _anchor.X > (work.Left + work.Right) / 2.0 / scale;
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
            foreach (var element in FanView.Build(_store, this, icon, _opensUp, _iconOnRight, animate))
                _content.Children.Add(element);
        }
        else if (_mode == BoxMode.List)
        {
            var card = ListCard.Build(_store, this);
            Canvas.SetTop(card, _opensUp ? icon.Y - 56 - ListCard.CardHeight : icon.Y + 56);
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
        // 펼쳐지는 쪽의 반대편, 창 밖으로 나가지 않게
        Canvas.SetLeft(_toast, Math.Clamp(icon.X - size.Width / 2, 8, WindowWidth - size.Width - 8));
        Canvas.SetTop(_toast, _opensUp ? icon.Y + IconArea / 2 + 4 : icon.Y - IconArea / 2 - 4 - size.Height);
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
            var icon = IconCenter;
            _anchor = new Point(Left + icon.X, Top + icon.Y);
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
        var accept = !DraggingOut && Transfer.CanAdd(e.Data);
        e.Effects = accept ? DragDropEffects.Copy : DragDropEffects.None;
        SetDropTargeted(accept);
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        SetDropTargeted(false);
        if (DraggingOut) return;
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

    // 항목 꺼내기 (부채꼴·목록이 같이 쓴다)

    public void Copy(ShelfItem item)
    {
        if (!item.Exists)
        {
            _store.ShowToast(item.Kind == ItemKind.File ? "원본 파일을 찾을 수 없어요" : "보관한 파일이 없어요");
            return;
        }
        try
        {
            Clipboard.SetDataObject(Transfer.ForClipboard(item), copy: true);
            _store.ShowToast("복사했어요 · Ctrl+V 로 붙여넣기");
        }
        catch (Exception)
        {
            _store.ShowToast("복사하지 못했어요");
        }
    }

    public void DragOut(DependencyObject source, ShelfItem[] items)
    {
        DraggingOut = true;
        try
        {
            System.Windows.DragDrop.DoDragDrop(source, Transfer.ForDrag(items), DragDropEffects.Copy);
        }
        finally
        {
            DraggingOut = false;
        }
    }

    public void Reveal(ShelfItem item)
    {
        if (item.Path is null || !item.Exists)
        {
            _store.ShowToast(item.Kind == ItemKind.File ? "원본 파일을 찾을 수 없어요" : "보관한 파일이 없어요");
            return;
        }
        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.Path}\"");
    }

    public ContextMenu MenuFor(ShelfItem item)
    {
        var menu = new ContextMenu();
        menu.Items.Add(Theme.Menu("복사", () => Copy(item)));
        if (item.Kind != ItemKind.Text) menu.Items.Add(Theme.Menu("탐색기에서 보기", () => Reveal(item)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Theme.Menu("상자에서 빼기", () => _store.Remove(item)));
        return menu;
    }

    /// <summary>항목 하나에 "끌면 꺼내기, 누르면 복사, 우클릭 메뉴" 를 붙인다</summary>
    public void MakeDraggable(FrameworkElement element, Func<ShelfItem[]> items, Action? onClick, Func<ContextMenu?>? menu = null)
    {
        Point? down = null;
        element.Cursor = Cursors.Hand;
        element.MouseLeftButtonDown += (_, e) => { down = e.GetPosition(element); e.Handled = true; };
        element.MouseMove += (_, e) =>
        {
            if (down is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            if ((e.GetPosition(element) - start).Length < 4) return;
            down = null;
            DragOut(element, items());
        };
        element.MouseLeftButtonUp += (_, e) =>
        {
            if (down is not null) onClick?.Invoke();
            down = null;
            e.Handled = true;
        };
        element.MouseLeave += (_, e) => { if (e.LeftButton != MouseButtonState.Pressed) down = null; };
        if (menu is not null)
            element.MouseRightButtonUp += (_, e) =>
            {
                if (menu() is { } contextMenu)
                {
                    contextMenu.PlacementTarget = element;
                    contextMenu.IsOpen = true;
                }
                e.Handled = true;
            };
    }

    public void OpenList() => SetMode(BoxMode.List);
    public void CloseToIcon() => SetMode(BoxMode.Icon);
}
