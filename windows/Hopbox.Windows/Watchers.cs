using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Hopbox;

/// <summary>다른 앱에서 이미지를 복사하면 상자에 담는다 (클립보드 캡처 Win+Shift+S 포함)</summary>
sealed class ClipboardWatcher : IDisposable
{
    readonly ShelfStore _store;
    readonly MessageWindow _window;
    readonly Dispatcher _dispatcher;
    bool _listening;

    public ClipboardWatcher(ShelfStore store, MessageWindow window, Dispatcher dispatcher)
    {
        _store = store;
        _window = window;
        _dispatcher = dispatcher;
        _window.Message += (msg, _, _) =>
        {
            // 클립보드를 연 앱이 아직 쓰는 중일 수 있어 잠깐 뒤에 읽는다
            if (msg == Native.WM_CLIPBOARDUPDATE)
                _dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => Check(attempt: 0)));
        };
    }

    public bool Enabled
    {
        get => _listening;
        set
        {
            if (value == _listening) return;
            if (value)
            {
                _listening = Native.AddClipboardFormatListener(_window.Handle);
            }
            else
            {
                Native.RemoveClipboardFormatListener(_window.Handle);
                _listening = false;
            }
        }
    }

    void Check(int attempt)
    {
        if (!_listening) return;
        try
        {
            var sequence = Native.GetClipboardSequenceNumber();
            // WPF 의 Clipboard.GetDataObject 는 클립보드가 잠겨 있으면 화면 스레드에서 잠들며 다시 시도한다.
            // 직접 열고, 잠겨 있으면 아래 타이머로 조금 뒤에 다시 본다
            var result = Native.OleGetClipboard(out var com);
            if (result != 0) Marshal.ThrowExceptionForHR(result);
            var payload = Transfer.Read(new System.Windows.DataObject(com), sequence, readText: false);
            if (Intake.IsCopiedImage(payload)) _store.AddCopiedImage(payload);
        }
        catch (COMException) when (attempt < 3)
        {
            // 다른 앱이 클립보드를 잡고 있으면 조금 뒤에 다시 본다
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            timer.Tick += (_, _) => { timer.Stop(); Check(attempt + 1); };
            timer.Start();
        }
        catch (Exception) { }
    }

    public void Dispose() => Enabled = false;
}

/// <summary>
/// 새로 저장된 스크린샷·화면 녹화를 상자에 담는다.
/// 캡처 도구(Win+Shift+S 자동 저장, Win+PrtScn)는 사진\스크린샷, 녹화는 동영상\화면 녹화·캡처에 저장한다.
/// </summary>
sealed class CaptureWatcher : IDisposable
{
    static readonly Guid ScreenshotsFolder = new("b7bede81-df94-4682-a7d8-57a52620b86f");
    static readonly string[] Extensions = { ".png", ".jpg", ".jpeg", ".gif", ".mp4", ".mkv", ".webm" };
    static readonly TimeSpan MaxWait = TimeSpan.FromHours(6);

    readonly ShelfStore _store;
    readonly Dispatcher _dispatcher;
    readonly List<FileSystemWatcher> _watchers = new();
    readonly DispatcherTimer _folderCheck;
    readonly HashSet<string> _watchedFolders = new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> _pending = new(StringComparer.OrdinalIgnoreCase);
    bool _enabled;

    public CaptureWatcher(ShelfStore store, Dispatcher dispatcher)
    {
        _store = store;
        _dispatcher = dispatcher;
        // 폴더는 처음 캡처할 때 만들어지기도 하므로 가끔 다시 찾는다
        _folderCheck = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromSeconds(10) };
        _folderCheck.Tick += (_, _) => WatchFolders();
    }

    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (value == _enabled) return;
            _enabled = value;
            if (value)
            {
                WatchFolders();
                _folderCheck.Start();
            }
            else
            {
                _folderCheck.Stop();
                foreach (var watcher in _watchers) watcher.Dispose();
                _watchers.Clear();
                _watchedFolders.Clear();
            }
        }
    }

    static IEnumerable<string> Folders()
    {
        var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return new[]
        {
            Native.KnownFolder(ScreenshotsFolder) ?? Path.Combine(pictures, "Screenshots"),
            Path.Combine(videos, "Screen Recordings"),
            Path.Combine(videos, "Captures"),
        }.Distinct(StringComparer.OrdinalIgnoreCase);
    }

    void WatchFolders()
    {
        foreach (var folder in Folders())
        {
            if (_watchedFolders.Contains(folder) || !Directory.Exists(folder)) continue;
            var watcher = new FileSystemWatcher(folder) { IncludeSubdirectories = false, EnableRaisingEvents = true };
            watcher.Created += (_, e) => Found(e.FullPath);
            watcher.Renamed += (_, e) => Found(e.FullPath);
            // 폴더가 지워지거나 알림이 넘치면 감시가 멈춘다. 놓아 두면 다음 폴더 찾기 때 다시 붙는다
            watcher.Error += (_, _) => _dispatcher.BeginInvoke(new Action(() => Forget(watcher, folder)));
            _watchers.Add(watcher);
            _watchedFolders.Add(folder);
        }
    }

    void Forget(FileSystemWatcher watcher, string folder)
    {
        if (!_watchers.Remove(watcher)) return;
        watcher.Dispose();
        _watchedFolders.Remove(folder);
    }

    void Found(string path)
    {
        if (!Extensions.Contains(Path.GetExtension(path).ToLowerInvariant())) return;
        _dispatcher.BeginInvoke(new Action(() =>
        {
            if (!_enabled || !_pending.Add(path)) return;
            AddWhenWritten(path, previousSize: -1, DateTime.Now);
        }));
    }

    /// <summary>
    /// 녹화처럼 오래 쓰는 파일은 크기가 멈출 때까지 기다렸다가 담는다.
    /// 녹화 중인 파일은 크기가 계속 바뀌므로 몇 시간짜리 녹화까지 기다린다
    /// </summary>
    void AddWhenWritten(string path, long previousSize, DateTime started)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher) { Interval = TimeSpan.FromMilliseconds(700) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            var size = SizeOf(path);
            if (size is null || DateTime.Now - started > MaxWait)
            {
                _pending.Remove(path);
                return;
            }
            if (size > 0 && size == previousSize && CanOpen(path))
            {
                _pending.Remove(path);
                if (_enabled) _store.AddCapture(path);
                return;
            }
            AddWhenWritten(path, size.Value, started);
        };
        timer.Start();
    }

    /// <summary>파일 크기. 그사이 지워졌거나 읽을 수 없으면 null</summary>
    static long? SizeOf(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? info.Length : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    static bool CanOpen(string path)
    {
        try
        {
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
    }

    public void Dispose() => Enabled = false;
}
