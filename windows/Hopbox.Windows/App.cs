using System;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Application = System.Windows.Application;

namespace Hopbox;

/// <summary>앱 시작점. 알림 영역 아이콘, 전역 단축키, 상자 창, 자동 담기를 이어 붙인다</summary>
static class App
{
    [STAThread]
    static void Main()
    {
        // 이미 켜져 있으면 그 앱에 "상자를 불러 달라" 고만 알리고 끝낸다
        using var instance = new Mutex(true, @"Local\Hopbox-Instance", out var isFirst);
        using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Hopbox-Show");
        if (!isFirst)
        {
            showSignal.Set();
            return;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var dispatcher = app.Dispatcher;
        var settings = Settings.Load();
        var store = new ShelfStore(ShelfStore.DefaultDirectory(), (delay, action) => Schedule(dispatcher, delay, action));
        var box = new BoxWindow(store);
        var messages = new MessageWindow();
        var hotKey = new HotKey(messages);
        var clipboard = new ClipboardWatcher(store, messages, dispatcher) { Enabled = settings.AutoAddCopiedImages };
        var captures = new CaptureWatcher(store, dispatcher) { Enabled = settings.AutoAddCaptures };
        var tray = new Tray(settings);
        ShortcutWindow? recorder = null;

        hotKey.Pressed += box.Toggle;
        tray.ShowShortcut(settings.Shortcut);
        if (!hotKey.Register(settings.Shortcut))
        {
            tray.ShowMessage($"단축키 {settings.Shortcut.DisplayName} 를 등록하지 못했어요",
                "다른 앱이 같은 단축키를 쓰고 있을 수 있어요. 알림 영역의 상자 아이콘에서 단축키를 바꿀 수 있어요.");
        }

        tray.OpenBox += box.Deliver;
        tray.EmptyBox += store.RemoveAll;
        tray.CapturesChanged += enabled =>
        {
            settings.AutoAddCaptures = enabled;
            settings.Save();
            captures.Enabled = enabled;
        };
        tray.CopiedImagesChanged += enabled =>
        {
            settings.AutoAddCopiedImages = enabled;
            settings.Save();
            clipboard.Enabled = enabled;
        };
        tray.ChangeShortcut += () =>
        {
            if (recorder is not null)
            {
                recorder.Activate();
                return;
            }
            // 바꾸는 동안에는 지금 단축키를 풀어 둔다. 누르면 창이 키를 받아야 하므로
            hotKey.Unregister();
            recorder = new ShortcutWindow(settings.Shortcut, shortcut =>
            {
                // 등록이 되는지 시험만 하고 바로 푼다. 창을 닫을 때 저장된 단축키로 다시 등록한다
                if (!hotKey.Register(shortcut)) return false;
                hotKey.Unregister();
                settings.Shortcut = shortcut;
                settings.Save();
                tray.ShowShortcut(shortcut);
                return true;
            });
            recorder.Closed += (_, _) =>
            {
                recorder = null;
                if (!hotKey.Register(settings.Shortcut))
                    tray.ShowMessage($"단축키 {settings.Shortcut.DisplayName} 를 등록하지 못했어요");
            };
            recorder.Show();
            recorder.Activate();
        };
        tray.Quit += () => app.Shutdown();

        // 두 번째로 실행하면 상자를 부른다
        var waiter = new Thread(() =>
        {
            while (showSignal.WaitOne())
                dispatcher.BeginInvoke(new Action(box.Deliver));
        }) { IsBackground = true };
        waiter.Start();

        app.Exit += (_, _) =>
        {
            store.PurgePendingRemoval();
            clipboard.Dispose();
            captures.Dispose();
            hotKey.Dispose();
            messages.Dispose();
            tray.Dispose();
        };
        app.Run();
    }

    /// <summary>화면 스레드에서 delay 뒤에 한 번 실행한다. Dispose 하면 취소된다</summary>
    static IDisposable Schedule(Dispatcher dispatcher, TimeSpan delay, Action action)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher) { Interval = delay };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
        return new Cancel(timer.Stop);
    }

    sealed class Cancel : IDisposable
    {
        readonly Action _cancel;
        public Cancel(Action cancel) => _cancel = cancel;
        public void Dispose() => _cancel();
    }
}
