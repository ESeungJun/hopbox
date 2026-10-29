using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Orientation = System.Windows.Controls.Orientation;

namespace Hopbox;

/// <summary>전체 목록. 부채꼴에 다 안 들어갈 때 쓰고, 한꺼번에 끌어낼 수 있다</summary>
static class ListCard
{
    public const double CardWidth = 340, CardHeight = 420, MinCardHeight = 220;
    const double ThumbSize = 34;

    /// <summary>height: 화면이 낮으면 CardHeight 보다 줄여서 넘긴다</summary>
    public static FrameworkElement Build(ShelfStore store, ItemActions actions, Action close, double height)
    {
        var items = store.Items;

        // 머리: 제목, 전부 끌어내기, 비우기, 닫기
        var header = new DockPanel { Margin = new Thickness(14, 12, 10, 8), LastChildFill = true };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (items.Count > 0)
        {
            var dragAll = Theme.IconCircle("\uE8B3", size: 28);
            dragAll.ToolTip = "끌면 전부 한꺼번에 꺼내요";
            actions.MakeDraggable(dragAll, () => store.Items.ToArray(), onClick: null);
            buttons.Children.Add(dragAll);
            buttons.Children.Add(Theme.Spaced(Theme.IconButton("\uE74D", "모두 비우기 (되돌릴 수 있어요)", store.RemoveAll, size: 28)));
        }
        buttons.Children.Add(Theme.Spaced(Theme.IconButton("\uE711", "닫기 (esc)", close, size: 28)));
        DockPanel.SetDock(buttons, Dock.Right);
        header.Children.Add(buttons);
        header.Children.Add(new TextBlock
        {
            Text = items.Count > 0 ? $"택배상자 · {items.Count}개" : "택배상자",
            Foreground = Brushes.White, FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
        });

        FrameworkElement body;
        if (items.Count == 0)
        {
            body = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    Centered("상자가 비어 있어요", Brushes.White, 15),
                    Centered("파일을 여기로 끌어다 놓거나\n복사한 뒤 Ctrl+V 로 담으세요", Theme.Secondary, 13),
                },
            };
        }
        else
        {
            var list = new StackPanel { Margin = new Thickness(6, 0, 6, 0) };
            foreach (var item in items) list.Children.Add(Row(item, actions));
            body = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        }

        var footer = new TextBlock
        {
            Text = "끌어다 놓기 · Ctrl+V 담기 · 클릭하면 복사 · esc 닫기", Foreground = Theme.Secondary, FontSize = 11,
            Margin = new Thickness(14, 6, 14, 10), TextTrimming = TextTrimming.CharacterEllipsis,
        };

        var layout = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        layout.Children.Add(header);
        layout.Children.Add(footer);
        layout.Children.Add(body);

        return new Border
        {
            Width = CardWidth, Height = height, Background = Theme.Card, CornerRadius = new CornerRadius(14),
            BorderBrush = Theme.CardLine, BorderThickness = new Thickness(1), Effect = Theme.Shadow(), Child = layout,
        };
    }

    static TextBlock Centered(string text, Brush brush, double size) => new()
    {
        Text = text, Foreground = brush, FontSize = size, TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 4),
    };

    static FrameworkElement Row(ShelfItem item, ItemActions actions)
    {
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        texts.Children.Add(new TextBlock
        {
            Text = item.Title, Foreground = item.Exists ? Brushes.White : Theme.Secondary, FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        texts.Children.Add(new TextBlock
        {
            Text = Subtitle(item), Foreground = Theme.Secondary, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var row = new DockPanel { Background = Theme.HitTarget, Margin = new Thickness(0, 1, 0, 1) };
        var thumb = Theme.Thumbnail(item, ThumbSize);
        thumb.Margin = new Thickness(6, 5, 0, 5);
        DockPanel.SetDock(thumb, Dock.Left);
        row.Children.Add(thumb);
        row.Children.Add(texts);
        var frame = new Border { CornerRadius = new CornerRadius(8), Child = row, ToolTip = "끌어서 꺼내기 · 클릭하면 복사 · 우클릭 메뉴" };
        frame.MouseEnter += (_, _) => frame.Background = Theme.RowHover;
        frame.MouseLeave += (_, _) => frame.Background = null;
        actions.Attach(frame, item);
        return frame;
    }

    static string Subtitle(ShelfItem item) => item.Kind switch
    {
        ItemKind.Text => $"텍스트 · {item.TextLength ?? item.Text?.Length ?? 0}자",
        ItemKind.Image => !item.Exists ? "보관한 파일이 없어요" : item.IsPicture ? "상자에 보관한 이미지" : "상자에 보관한 파일",
        _ => item.Exists ? Path.GetDirectoryName(item.Path) ?? "" : "원본 파일을 찾을 수 없어요",
    };
}
