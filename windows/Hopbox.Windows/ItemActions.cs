using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Clipboard = System.Windows.Clipboard;
using DragDropEffects = System.Windows.DragDropEffects;

namespace Hopbox;

/// <summary>항목 꺼내기: 복사, 끌어내기, 탐색기에서 보기, 우클릭 메뉴. 부채꼴과 목록이 같이 쓴다</summary>
sealed class ItemActions
{
    readonly ShelfStore _store;

    /// <summary>상자에서 끌어내는 중. 상자에 다시 떨어뜨려도 받지 않는다</summary>
    public static bool DraggingOut { get; private set; }

    public ItemActions(ShelfStore store) => _store = store;

    public void Copy(ShelfItem item)
    {
        if (!item.Exists)
        {
            ShowMissing(item);
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
            ShowMissing(item);
            return;
        }
        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.Path}\"");
    }

    void ShowMissing(ShelfItem item) =>
        _store.ShowToast(item.Kind == ItemKind.File ? "원본 파일을 찾을 수 없어요" : "보관한 파일이 없어요");

    public ContextMenu MenuFor(ShelfItem item)
    {
        var menu = new ContextMenu();
        menu.Items.Add(Theme.Menu("복사", () => Copy(item)));
        if (item.Kind != ItemKind.Text) menu.Items.Add(Theme.Menu("탐색기에서 보기", () => Reveal(item)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Theme.Menu("상자에서 빼기", () => _store.Remove(item)));
        return menu;
    }

    /// <summary>항목 한 줄에 "끌면 꺼내기, 누르면 복사, 우클릭 메뉴" 를 붙인다</summary>
    public void Attach(FrameworkElement element, ShelfItem item) =>
        MakeDraggable(element, () => new[] { item }, () => Copy(item), () => MenuFor(item));

    /// <summary>끌면 items 를 꺼내고, 누르면 onClick, 우클릭하면 menu 를 띄운다</summary>
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
}
