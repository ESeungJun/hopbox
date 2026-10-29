using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Button = System.Windows.Controls.Button;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace Hopbox;

/// <summary>새 단축키를 눌러 지정하는 작은 창</summary>
sealed class ShortcutWindow : Window
{
    readonly TextBlock _current = new()
    {
        FontSize = 24, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
    };
    readonly TextBlock _message = new()
    {
        Text = "새 단축키를 누르세요 · esc 로 닫기", Foreground = Brushes.Gray, HorizontalAlignment = HorizontalAlignment.Center,
        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
    };
    readonly Button _reset;
    readonly Func<Shortcut, bool> _onRecord;
    Shortcut _shortcut;

    /// <summary>onRecord 는 등록에 성공하면 true 를 돌려준다</summary>
    public ShortcutWindow(Shortcut current, Func<Shortcut, bool> onRecord)
    {
        _onRecord = onRecord;
        _shortcut = current;
        Title = "단축키 바꾸기";
        Width = 340;
        Height = 220;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;

        _reset = new Button
        {
            Content = $"기본값({Shortcut.Standard.DisplayName})으로", Padding = new Thickness(12, 4, 12, 4),
            HorizontalAlignment = HorizontalAlignment.Center, Focusable = false,
        };
        _reset.Click += (_, _) => Apply(Shortcut.Standard);

        Content = new StackPanel
        {
            Margin = new Thickness(20),
            Children =
            {
                new TextBlock { Text = "상자를 부르는 단축키", FontSize = 15, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                new Border
                {
                    Margin = new Thickness(0, 12, 0, 12), Padding = new Thickness(18, 6, 18, 6), CornerRadius = new CornerRadius(10),
                    Background = new SolidColorBrush(Color.FromArgb(18, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Center,
                    Child = _current,
                },
                _message,
                new Border { Height = 12 },
                _reset,
            },
        };
        Refresh();
        PreviewKeyDown += OnKey;
    }

    void Refresh()
    {
        _current.Text = _shortcut.DisplayName;
        _reset.IsEnabled = _shortcut != Shortcut.Standard;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        // Alt 를 같이 누르면 키가 SystemKey 로 들어온다
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape)
        {
            Close();
            return;
        }
        var modifiers = 0;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= Shortcut.Control;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= Shortcut.Alt;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= Shortcut.Shift;
        if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) modifiers |= Shortcut.Win;
        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        if (Shortcut.From(virtualKey, modifiers) is { } shortcut) Apply(shortcut);
        else if (key is not (Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin))
            _message.Text = "Ctrl · Alt · Win 중 하나와 함께 눌러 주세요";
    }

    void Apply(Shortcut shortcut)
    {
        if (_onRecord(shortcut))
        {
            _shortcut = shortcut;
            _message.Text = $"{shortcut.DisplayName} 로 바꿨어요";
        }
        else
        {
            _message.Text = $"{shortcut.DisplayName} 는 다른 앱이 쓰고 있어요";
        }
        Refresh();
    }
}
