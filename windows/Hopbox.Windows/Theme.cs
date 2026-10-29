using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Button = System.Windows.Controls.Button;
using Cursors = System.Windows.Input.Cursors;
using Image = System.Windows.Controls.Image;
using MenuItem = System.Windows.Controls.MenuItem;

namespace Hopbox;

/// <summary>색과 자주 쓰는 작은 부품</summary>
static class Theme
{
    public static readonly Brush Pill = Frozen(Color.FromArgb(235, 32, 32, 34));
    public static readonly Brush Card = Frozen(Color.FromArgb(245, 28, 28, 30));
    public static readonly Brush CardLine = Frozen(Color.FromArgb(40, 255, 255, 255));
    public static readonly Brush RowHover = Frozen(Color.FromArgb(30, 255, 255, 255));
    public static readonly Brush Secondary = Frozen(Color.FromArgb(160, 255, 255, 255));
    public static readonly Brush Badge = Frozen(Color.FromRgb(232, 84, 60));
    public static readonly Brush Accent = Frozen(Color.FromRgb(255, 176, 64));
    public static readonly Brush Note = Frozen(Color.FromRgb(255, 236, 150));
    public static readonly Brush NoteText = Frozen(Color.FromRgb(90, 70, 20));
    /// <summary>눈에 안 보이지만 마우스는 받는 바탕. 완전히 투명하면 클릭이 아래 앱으로 지나간다</summary>
    public static readonly Brush HitTarget = Frozen(Color.FromArgb(1, 255, 255, 255));
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static Effect Shadow() => new DropShadowEffect { BlurRadius = 14, ShadowDepth = 3, Opacity = 0.35, Direction = 270 };

    /// <summary>글자만 있는 단추</summary>
    public static Button TextButton(string text, Action onClick)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = text, Foreground = Accent, FontWeight = FontWeights.SemiBold, FontSize = 13 },
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            Cursor = Cursors.Hand, Focusable = false,
            Template = PlainTemplate(),
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>둥근 아이콘 단추 (Segoe 아이콘 글꼴)</summary>
    public static Button IconButton(string glyph, string tooltip, Action onClick, double size = 34)
    {
        var button = new Button
        {
            Content = IconCircle(glyph, size), ToolTip = tooltip, Cursor = Cursors.Hand, Focusable = false, Template = PlainTemplate(),
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>단추 모양의 동그라미. 끌기처럼 단추가 아닌 동작에 쓴다</summary>
    public static Border IconCircle(string glyph, double size = 34) => new()
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = Pill, Effect = Shadow(),
        Child = new TextBlock
        {
            Text = glyph, FontFamily = Icons, FontSize = 14, Foreground = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        },
    };

    /// <summary>모양 없이 내용만 그리는 단추 틀</summary>
    static ControlTemplate PlainTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        template.VisualTree = presenter;
        return template;
    }

    public static Border PillText(string text, Brush? foreground = null) => new()
    {
        Background = Pill, CornerRadius = new CornerRadius(14), Padding = new Thickness(12, 6, 12, 6), Effect = Shadow(),
        Child = new TextBlock { Text = text, Foreground = foreground ?? Brushes.White, FontSize = 13 },
    };

    public static MenuItem Menu(string header, Action onClick)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => onClick();
        return item;
    }

    /// <summary>나타날 때 살짝 밀려 들어온다</summary>
    public static void FadeIn(UIElement element, double offsetY, double delay)
    {
        var begin = TimeSpan.FromSeconds(delay);
        var duration = TimeSpan.FromSeconds(0.18);
        element.Opacity = 0;
        element.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, duration) { BeginTime = begin });
        if (offsetY == 0) return;
        var shift = new TranslateTransform();
        element.RenderTransform = element.RenderTransform is Transform existing && existing != Transform.Identity
            ? new TransformGroup { Children = { existing, shift } }
            : shift;
        shift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(offsetY, 0, duration)
        {
            BeginTime = begin, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        });
    }

    /// <summary>버튼 줄에서 앞 요소와 띄운다</summary>
    public static FrameworkElement Spaced(FrameworkElement element)
    {
        element.Margin = new Thickness(6, 0, 0, 0);
        return element;
    }

    /// <summary>썸네일 한 칸. 그림이 있으면 그림, 텍스트는 노란 메모, 없으면 문서 아이콘</summary>
    public static FrameworkElement Thumbnail(ShelfItem item, double size)
    {
        if (item.Kind == ItemKind.Text)
        {
            return new Border
            {
                Width = size, Height = size, Background = Note, CornerRadius = new CornerRadius(4), Effect = Shadow(),
                Padding = new Thickness(size / 10),
                Child = new TextBlock
                {
                    Text = item.Title, FontSize = Math.Max(6, size / 7), Foreground = NoteText, TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            };
        }
        // 미리보기는 화면을 먼저 그린 뒤 하나씩 채운다. 동영상이 많은 목록을 열 때 멈칫하지 않도록
        var placeholder = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(6), Background = Pill,
            Child = new TextBlock
            {
                Text = item.Exists ? "\uE8A5" : "\uE783", FontFamily = Icons, FontSize = size / 2.2, Foreground = Secondary,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
        var image = new Image { Width = size, Height = size, Stretch = Stretch.Uniform };
        var cell = new Grid { Width = size, Height = size, Children = { placeholder, image } };
        void Show(ImageSource? source)
        {
            if (source is null) return;
            image.Source = source;
            image.Effect = Shadow();
            placeholder.Visibility = Visibility.Collapsed;
        }
        if (Thumbnails.TryCached(item, (int)size, out var cached)) Show(cached);
        else if (item.Exists)
            cell.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => Show(Thumbnails.For(item, (int)size))));
        return cell;
    }
}
