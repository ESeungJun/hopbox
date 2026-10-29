using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Hopbox;

/// <summary>
/// 상자에 담긴 것들. 앱을 다시 켜도 남도록 %APPDATA%\Hopbox 에 저장한다.
/// 화면과 클립보드는 모르고, 들어온 내용(ClipPayload)만 보고 담을지 정한다.
/// </summary>
public sealed class ShelfStore
{
    public static readonly TimeSpan UndoTime = TimeSpan.FromSeconds(5);
    static readonly TimeSpan ToastTime = TimeSpan.FromSeconds(1.6);
    /// <summary>캡처 도구는 클립보드에 올리면서 파일로도 저장한다. 이 시간 안에 둘 다 들어오면 같은 캡처로 본다</summary>
    static readonly TimeSpan SameCaptureTime = TimeSpan.FromSeconds(10);

    readonly string _directory;
    readonly string _imagesDirectory;
    /// <summary>시간이 지난 뒤 할 일을 맡긴다. 앱에서는 화면 타이머, 시험에서는 직접 돌리는 가짜 타이머</summary>
    readonly Func<TimeSpan, Action, IDisposable> _schedule;
    readonly Func<DateTime> _now;

    List<ShelfItem> _items = new();
    /// <summary>방금 뺀 항목. 되돌리기 시간이 지나야 이미지 파일을 실제로 지운다</summary>
    List<ShelfItem> _pendingRemoval = new();
    IDisposable? _purgeTimer;
    IDisposable? _toastTimer;
    /// <summary>자동으로 담은 클립보드 이미지의 클립보드 순번</summary>
    uint? _capturedSequence;
    /// <summary>방금 클립보드에서 담은 이미지. 같은 캡처가 파일로도 저장되면 이 항목을 그 파일로 바꾼다</summary>
    (Guid Id, DateTime At)? _lastCopiedImage;
    /// <summary>방금 폴더에서 담은 그림 캡처. 같은 캡처가 클립보드로 뒤늦게 들어오면 건너뛴다</summary>
    (string Path, DateTime At)? _lastPictureCapture;
    /// <summary>목록 파일을 읽지 못했으면 보관 파일을 정리하지 않는다 (목록에 있던 파일을 지우지 않도록)</summary>
    bool _loadFailed;

    public IReadOnlyList<ShelfItem> Items => _items;
    public Toast? Toast { get; private set; }

    /// <summary>목록이 바뀔 때</summary>
    public event Action? Changed;
    /// <summary>무언가 담겼을 때. 상자 아이콘이 이걸 보고 통통 튄다 (인자는 담긴 개수)</summary>
    public event Action<int>? Added;
    public event Action? ToastChanged;

    public ShelfStore(string directory, Func<TimeSpan, Action, IDisposable> schedule, Func<DateTime>? now = null)
    {
        _directory = directory;
        _imagesDirectory = System.IO.Path.Combine(directory, "images");
        _schedule = schedule;
        _now = now ?? (() => DateTime.Now);
        Directory.CreateDirectory(_imagesDirectory);
        Load();
        if (!_loadFailed) RemoveOrphanImages();
    }

    public static string DefaultDirectory() =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Hopbox");

    string ListFile => System.IO.Path.Combine(_directory, "items.json");

    // 담기

    /// <summary>
    /// 끌어다 놓기와 Ctrl+V 가 같은 경로로 들어온다. 파일 → 가상 파일 → 이미지 → 텍스트 순으로 본다.
    /// 브라우저에서 이미지를 복사하면 주소 글자가 같이 실리므로 이미지를 텍스트보다 먼저 본다.
    /// 다만 서식 있는 텍스트가 함께 있으면 엑셀·워드처럼 글을 복사한 경우라 텍스트로 담는다.
    /// </summary>
    public int Add(ClipPayload payload)
    {
        if (payload.Concealed)
        {
            ShowToast("비밀번호처럼 숨겨진 값은 담지 않아요");
            return 0;
        }
        if (payload.ClipboardSequence is { } sequence && sequence == _capturedSequence)
        {
            ShowToast("이미 담겨 있어요");
            return 0;
        }

        var text = payload.TrimmedText;
        var newItems = new List<ShelfItem>();
        var isDuplicate = false;

        if (payload.Files.Length > 0)
        {
            var existing = _items.Where(i => i.Kind == ItemKind.File).Select(i => i.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var path in payload.Files)
            {
                // 캡처 도구·메신저가 넘겨주는 임시 파일은 곧 지워지므로 상자에 복사해 둔다
                if (Intake.IsTemporary(path))
                {
                    if (KeepCopy(path) is { } copy) newItems.Add(ShelfItem.FromImage(copy));
                }
                else if (!existing.Contains(path))
                {
                    newItems.Add(ShelfItem.FromFile(path));
                }
            }
            isDuplicate = newItems.Count == 0;
        }
        else if (payload.VirtualFiles.Length > 0)
        {
            foreach (var file in payload.VirtualFiles)
            {
                if (SaveVirtualFile(file) is { } saved) newItems.Add(ShelfItem.FromImage(saved));
            }
            if (newItems.Count == 0)
            {
                ShowToast("가져오지 못했어요");
                return 0;
            }
        }
        else if (payload.HasImage && (!payload.HasRichText || text is null) && SaveImage(payload.ReadPng()) is { } imagePath)
        {
            newItems.Add(ShelfItem.FromImage(imagePath));
        }
        else if (text is not null)
        {
            if (_items.FirstOrDefault()?.Text == text) isDuplicate = true;
            else newItems.Add(ShelfItem.FromText(text));
        }

        if (newItems.Count == 0)
        {
            ShowToast(isDuplicate ? "이미 담겨 있어요" : "담을 수 있는 내용이 없어요");
            return 0;
        }
        Insert(newItems, $"{newItems.Count}개 담았어요");
        return newItems.Count;
    }

    /// <summary>스크린샷·화면 녹화 파일이 새로 저장됐을 때</summary>
    public void AddCapture(string path)
    {
        if (_items.Any(i => string.Equals(i.Path, path, StringComparison.OrdinalIgnoreCase))) return;
        var item = ShelfItem.FromFile(path);
        if (item.IsPicture && _lastCopiedImage is { } copied && IsSameCapture(copied.At, copied.Id, path)
            && _items.FindIndex(i => i.Id == copied.Id) is var index and >= 0)
        {
            // 클립보드로 먼저 담은 사본을 저장된 원본 파일로 바꾼다. 상자에는 하나만 남는다
            var copy = _items[index];
            _items[index] = item;
            _lastCopiedImage = null;
            DeleteOwnedFile(copy);
            Save();
            Changed?.Invoke();
            return;
        }
        if (item.IsPicture) _lastPictureCapture = (path, _now());
        Insert(new() { item }, "캡처를 담았어요");
    }

    /// <summary>클립보드로 찍은 스크린샷이나 다른 앱에서 복사한 이미지. 같은 클립보드를 Ctrl+V 로 또 담지 않도록 기억해 둔다</summary>
    public void AddCopiedImage(ClipPayload payload)
    {
        // 앱이 이미지를 임시 파일로 함께 올렸으면 원래 이름과 화질 그대로 보관한다
        var saved = payload.Files.Where(Intake.IsTemporary).Select(KeepCopy).FirstOrDefault(p => p is not null)
            ?? SaveImage(payload.ReadPng());
        if (saved is null) return;
        _capturedSequence = payload.ClipboardSequence;
        if (_lastPictureCapture is { } capture && IsSameCapture(capture.At, null, capture.Path, saved))
        {
            // 방금 폴더에서 담은 캡처와 같은 것. 원본 파일이 이미 담겨 있으니 사본은 버린다
            _lastPictureCapture = null;
            try { System.IO.File.Delete(saved); }
            catch (Exception) { }
            return;
        }
        var item = ShelfItem.FromImage(saved);
        _lastCopiedImage = (item.Id, _now());
        Insert(new() { item }, "복사한 이미지를 담았어요");
    }

    /// <summary>
    /// 클립보드 사본과 저장된 캡처 파일이 같은 캡처인지. 짧은 시간 안에 들어왔고, 둘 다 PNG 면 크기도 같아야 한다.
    /// copiedId 가 있으면 그 항목의 파일을, 없으면 copiedPath 를 사본으로 본다
    /// </summary>
    bool IsSameCapture(DateTime at, Guid? copiedId, string capturePath, string? copiedPath = null)
    {
        if (_now() - at > SameCaptureTime) return false;
        copiedPath ??= _items.FirstOrDefault(i => i.Id == copiedId)?.Path;
        if (copiedPath is null) return false;
        var copiedSize = Intake.PngSize(copiedPath);
        var captureSize = Intake.PngSize(capturePath);
        return copiedSize is null || captureSize is null || copiedSize == captureSize;
    }

    void Insert(List<ShelfItem> newItems, string message)
    {
        _items.InsertRange(0, newItems);
        Save();
        Changed?.Invoke();
        Added?.Invoke(newItems.Count);
        ShowToast(message);
    }

    /// <summary>파일을 상자 보관 폴더로 복사한다. 이름이 겹치면 뒤에 짧은 꼬리표를 붙인다</summary>
    string? KeepCopy(string path)
    {
        try
        {
            var destination = UniquePath(System.IO.Path.GetFileName(path));
            System.IO.File.Copy(path, destination);
            return destination;
        }
        catch (Exception)
        {
            return null;
        }
    }

    string? SaveVirtualFile(VirtualFile file)
    {
        try
        {
            if (file.Read() is not { Length: > 0 } data) return null;
            var destination = UniquePath(Intake.SafeFileName(System.IO.Path.GetFileName(file.Name)));
            System.IO.File.WriteAllBytes(destination, data);
            MarkFromInternet(destination);
            return destination;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// 다른 앱이 넘겨준 내용으로 만든 파일에 "인터넷에서 받은 파일" 표시를 붙인다.
    /// 그래야 상자에서 꺼내 열 때 윈도우가 실행 파일·매크로 문서를 경고한다
    /// </summary>
    static void MarkFromInternet(string path)
    {
        try { System.IO.File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n"); }
        catch (Exception) { }
    }

    string? SaveImage(byte[]? png)
    {
        if (png is not { Length: > 0 }) return null;
        try
        {
            var path = UniquePath($"이미지 {_now():yyyy-MM-dd HH.mm.ss}.png");
            System.IO.File.WriteAllBytes(path, png);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    string UniquePath(string name)
    {
        var path = System.IO.Path.Combine(_imagesDirectory, name);
        if (!System.IO.File.Exists(path)) return path;
        var tag = Guid.NewGuid().ToString("N")[..4];
        var ext = System.IO.Path.GetExtension(name);
        return System.IO.Path.Combine(_imagesDirectory, $"{System.IO.Path.GetFileNameWithoutExtension(name)} {tag}{ext}");
    }

    // 빼기 (되돌리기 가능)

    public void Remove(ShelfItem item) => Remove(new List<ShelfItem> { item });

    public void RemoveAll() => Remove(_items.ToList());

    void Remove(List<ShelfItem> removed)
    {
        if (removed.Count == 0) return;
        // 이전에 빼 둔 것은 이제 되돌릴 수 없으니 정리한다
        PurgePendingRemoval();
        var ids = removed.Select(i => i.Id).ToHashSet();
        _items.RemoveAll(i => ids.Contains(i.Id));
        _pendingRemoval = removed;
        Save();
        Changed?.Invoke();
        ShowToast(removed.Count == 1 ? "상자에서 뺐어요" : $"{removed.Count}개를 비웠어요", undoable: true);
        _purgeTimer = _schedule(UndoTime, PurgePendingRemoval);
    }

    public void UndoRemove()
    {
        if (_pendingRemoval.Count == 0) return;
        _purgeTimer?.Dispose();
        _purgeTimer = null;
        // 원래 순서대로 되돌리되 그사이 새로 담은 것은 위에 둔다
        _items = _items.Concat(_pendingRemoval).OrderByDescending(i => i.AddedAt).ToList();
        _pendingRemoval = new();
        Save();
        Changed?.Invoke();
        ShowToast("되돌렸어요");
    }

    /// <summary>되돌리기 시간이 끝났거나 앱을 끌 때 부른다</summary>
    public void PurgePendingRemoval()
    {
        _purgeTimer?.Dispose();
        _purgeTimer = null;
        foreach (var item in _pendingRemoval) DeleteOwnedFile(item);
        _pendingRemoval = new();
    }

    /// <summary>상자 보관 폴더 안의 파일만 지운다. 원본 파일은 절대 건드리지 않는다</summary>
    void DeleteOwnedFile(ShelfItem item)
    {
        if (item.Kind != ItemKind.Image || item.Path is null || !IsOwned(item.Path)) return;
        try { System.IO.File.Delete(item.Path); }
        catch (Exception) { }
    }

    bool IsOwned(string path)
    {
        var folder = System.IO.Path.GetFullPath(_imagesDirectory) + System.IO.Path.DirectorySeparatorChar;
        return System.IO.Path.GetFullPath(path).StartsWith(folder, StringComparison.OrdinalIgnoreCase);
    }

    // 저장

    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    void Save()
    {
        try
        {
            var tempFile = ListFile + ".tmp";
            System.IO.File.WriteAllText(tempFile, JsonSerializer.Serialize(_items, JsonOptions));
            System.IO.File.Move(tempFile, ListFile, overwrite: true);
        }
        catch (Exception) { }
    }

    void Load()
    {
        if (!System.IO.File.Exists(ListFile)) return;
        try
        {
            _items = JsonSerializer.Deserialize<List<ShelfItem>>(System.IO.File.ReadAllText(ListFile), JsonOptions) ?? new();
        }
        catch (Exception)
        {
            // 망가진 목록은 덮어쓰기 전에 옆에 남겨 둔다. 보관 파일도 이번에는 정리하지 않는다
            _items = new();
            _loadFailed = true;
            try { System.IO.File.Copy(ListFile, ListFile + $".{_now():yyyyMMdd-HHmmss}.bak", overwrite: true); }
            catch (Exception) { }
        }
    }

    /// <summary>앱이 되돌리기 시간 중에 꺼지면 이미지 파일이 남는다. 켤 때 목록에 없는 이미지를 정리한다</summary>
    void RemoveOrphanImages()
    {
        var kept = _items.Where(i => i.Path is not null).Select(i => System.IO.Path.GetFullPath(i.Path!))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var file in Directory.EnumerateFiles(_imagesDirectory))
        {
            if (kept.Contains(System.IO.Path.GetFullPath(file))) continue;
            try { System.IO.File.Delete(file); }
            catch (Exception) { }
        }
    }

    // 알림

    public void ShowToast(string message, bool undoable = false)
    {
        _toastTimer?.Dispose();
        var toast = new Toast(message, undoable);
        Toast = toast;
        ToastChanged?.Invoke();
        _toastTimer = _schedule(undoable ? UndoTime : ToastTime, () =>
        {
            if (Toast != toast) return;
            Toast = null;
            ToastChanged?.Invoke();
        });
    }
}
