using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Orientation = System.Windows.Controls.Orientation;

namespace Hopbox;

/// <summary>
/// Dock 스택처럼 상자에서 위(또는 아래)로 호를 그리며 펼쳐지는 항목들.
/// 아이콘에서 멀어질수록 화면 가운데 쪽으로 휘고 살짝 기운다.
/// </summary>
static class FanView
{
    public const int MaxRows = 10;
    const double RowHeight = 58, ThumbSize = 50, SideMargin = 36, LabelMaxWidth = 300;

    public static IEnumerable<UIElement> Build(ShelfStore store, BoxWindow box, Point icon, bool opensUp, bool iconOnRight, bool animate)
    {
        var items = store.Items;
        var shown = items.Take(MaxRows).ToList();
        var elements = new List<UIElement>();

        for (var i = 0; i < shown.Count; i++)
        {
            var item = shown[i];
            var row = Row(item, iconOnRight);
            box.MakeDraggable(row, () => new[] { item }, () => box.Copy(item), () => box.MenuFor(item));
            row.ToolTip = "끌어서 꺼내기 · 클릭하면 복사 · 우클릭 메뉴";
            Place(row, i, icon, opensUp, iconOnRight, thumbAligned: true);
            row.RenderTransformOrigin = new Point(iconOnRight ? 1 : 0, 0.5);
            row.RenderTransform = new RotateTransform(Math.Pow(i, 1.35) * 0.9 * (iconOnRight ? 1 : -1) * (opensUp ? 1 : -1));
            if (animate) Theme.FadeIn(row, offsetY: opensUp ? 18 : -18, delay: i * 0.02);
            elements.Add(row);
        }

        // 맨 끝 줄: 상자가 비었으면 안내, 아니면 "그 외 N개"·목록·비우기
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        if (items.Count == 0)
        {
            controls.Children.Add(Theme.PillText("상자가 비어 있어요 · 끌어다 놓거나 Ctrl+V", Theme.Secondary));
        }
        else
        {
            var hidden = items.Count - shown.Count;
            if (hidden > 0)
            {
                var more = Theme.PillText($"그 외 {hidden}개");
                more.Cursor = System.Windows.Input.Cursors.Hand;
                more.MouseLeftButtonUp += (_, e) => { box.OpenList(); e.Handled = true; };
                controls.Children.Add(more);
            }
            controls.Children.Add(Spaced(Theme.IconButton("\uE8FD", "전체 목록", box.OpenList)));
            controls.Children.Add(Spaced(Theme.IconButton("\uE74D", "모두 비우기 (되돌릴 수 있어요)", store.RemoveAll)));
        }
        Place(controls, shown.Count, icon, opensUp, iconOnRight, thumbAligned: false);
        if (animate) Theme.FadeIn(controls, offsetY: opensUp ? 18 : -18, delay: shown.Count * 0.02);
        elements.Add(controls);
        return elements;
    }

    static FrameworkElement Spaced(FrameworkElement element)
    {
        element.Margin = new Thickness(6, 0, 0, 0);
        return element;
    }

    /// <summary>한 줄: 이름표 + 썸네일. 썸네일이 아이콘 쪽에 온다</summary>
    static FrameworkElement Row(ShelfItem item, bool iconOnRight)
    {
        var label = new Border
        {
            Background = Theme.Pill, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 5, 10, 5),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0), Effect = Theme.Shadow(),
            Child = new TextBlock
            {
                Text = item.Title, Foreground = item.Exists ? Brushes.White : Theme.Secondary, FontSize = 13,
                MaxWidth = LabelMaxWidth, TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
        var thumb = Theme.Thumbnail(item, ThumbSize);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Background = Theme.HitTarget };
        if (iconOnRight)
        {
            row.Children.Add(label);
            row.Children.Add(thumb);
        }
        else
        {
            row.Children.Add(thumb);
            row.Children.Add(label);
        }
        return row;
    }

    /// <summary>
    /// i 번째 칸에 놓는다. 아이콘에서 멀어질수록 화면 가운데 쪽으로 휜다(최대 SideMargin).
    /// 썸네일 줄은 썸네일 가운데를, 버튼 줄은 끝을 아이콘 쪽 가장자리에 맞춘다.
    /// </summary>
    static void Place(FrameworkElement element, int index, Point icon, bool opensUp, bool iconOnRight, bool thumbAligned)
    {
        element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = element.DesiredSize;
        var bend = Math.Min(index * index * 0.4, SideMargin);
        var centerY = opensUp ? icon.Y - 62 - index * RowHeight : icon.Y + 62 + index * RowHeight;
        var edge = thumbAligned ? ThumbSize / 2 : 18;
        var left = iconOnRight
            ? icon.X - bend + edge - size.Width
            : icon.X + bend - edge;
        Canvas.SetLeft(element, left);
        Canvas.SetTop(element, centerY - size.Height / 2);
    }
}
