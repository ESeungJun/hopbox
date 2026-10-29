using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

namespace Hopbox.Tests;

/// <summary>직접 돌리는 타이머. 시험에서 "5초가 지났다" 를 즉시 만든다</summary>
sealed class ManualScheduler
{
    readonly List<(Action Action, bool Cancelled)> _jobs = new();

    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var index = _jobs.Count;
        _jobs.Add((action, false));
        return new Cancel(() => _jobs[index] = (_jobs[index].Action, true));
    }

    public void RunAll()
    {
        for (var i = 0; i < _jobs.Count; i++)
        {
            var job = _jobs[i];
            if (job.Cancelled) continue;
            _jobs[i] = (job.Action, true);
            job.Action();
        }
    }

    sealed class Cancel : IDisposable
    {
        readonly Action _cancel;
        public Cancel(Action cancel) => _cancel = cancel;
        public void Dispose() => _cancel();
    }
}

public sealed class ShelfStoreTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "hopbox-test-" + Guid.NewGuid().ToString("N"));
    readonly string _userDir;
    readonly ManualScheduler _timer = new();
    static readonly byte[] Png = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3 };

    public ShelfStoreTests()
    {
        // 사용자 폴더의 파일은 임시 폴더 밖이어야 하므로 문서 폴더 아래에 만든다
        _userDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "hopbox-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_userDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch (Exception) { }
        try { Directory.Delete(_userDir, true); } catch (Exception) { }
    }

    ShelfStore NewStore() => new(_dir, _timer.Schedule, () => new DateTime(2026, 10, 29, 12, 0, 0));

    string UserFile(string name)
    {
        var path = Path.Combine(_userDir, name);
        File.WriteAllText(path, "내용");
        return path;
    }

    [Fact]
    public void 텍스트를_담고_같은_텍스트는_다시_담지_않는다()
    {
        var store = NewStore();
        Assert.Equal(1, store.Add(new ClipPayload { Text = "안녕  하세요\n반가워요" }));
        Assert.Equal(ItemKind.Text, store.Items[0].Kind);
        Assert.Equal("안녕 하세요 반가워요", store.Items[0].Title);
        Assert.Equal(0, store.Add(new ClipPayload { Text = "안녕  하세요\n반가워요" }));
        Assert.Equal("이미 담겨 있어요", store.Toast?.Message);
    }

    [Fact]
    public void 빈_내용은_담지_않는다()
    {
        var store = NewStore();
        Assert.Equal(0, store.Add(new ClipPayload { Text = "   " }));
        Assert.Equal("담을 수 있는 내용이 없어요", store.Toast?.Message);
    }

    [Fact]
    public void 숨긴_값은_담지_않는다()
    {
        var store = NewStore();
        Assert.Equal(0, store.Add(new ClipPayload { Text = "비밀번호", Concealed = true }));
        Assert.Empty(store.Items);
        Assert.Equal("비밀번호처럼 숨겨진 값은 담지 않아요", store.Toast?.Message);
    }

    [Fact]
    public void 사용자_파일은_원본을_가리키고_중복은_건너뛴다()
    {
        var store = NewStore();
        var file = UserFile("문서.txt");
        Assert.Equal(1, store.Add(new ClipPayload { Files = new[] { file } }));
        Assert.Equal(ItemKind.File, store.Items[0].Kind);
        Assert.Equal(file, store.Items[0].Path);
        Assert.Equal(0, store.Add(new ClipPayload { Files = new[] { file } }));
        Assert.Equal("이미 담겨 있어요", store.Toast?.Message);
    }

    [Fact]
    public void 임시_파일은_상자에_복사해_둔다()
    {
        var store = NewStore();
        var temp = Path.Combine(Path.GetTempPath(), "캡처-" + Guid.NewGuid().ToString("N") + ".png");
        File.WriteAllBytes(temp, Png);
        try
        {
            Assert.Equal(1, store.Add(new ClipPayload { Files = new[] { temp }, HasImage = true }));
            var item = store.Items[0];
            Assert.Equal(ItemKind.Image, item.Kind);
            Assert.NotEqual(temp, item.Path);
            Assert.StartsWith(Path.Combine(_dir, "images"), item.Path);
            Assert.True(File.Exists(item.Path));
        }
        finally
        {
            File.Delete(temp);
        }
    }

    [Fact]
    public void 이미지는_PNG_로_저장하고_서식_있는_텍스트면_텍스트로_담는다()
    {
        var store = NewStore();
        Assert.Equal(1, store.Add(new ClipPayload { HasImage = true, ReadPng = () => Png, Text = "https://example.com/a.png" }));
        Assert.Equal(ItemKind.Image, store.Items[0].Kind);
        Assert.Equal("이미지 2026-10-29 12.00.00.png", store.Items[0].Title);

        Assert.Equal(1, store.Add(new ClipPayload { HasImage = true, ReadPng = () => Png, Text = "A1 셀", HasRichText = true }));
        Assert.Equal(ItemKind.Text, store.Items[0].Kind);
    }

    [Fact]
    public void 가상_파일은_이름_그대로_보관한다()
    {
        var store = NewStore();
        Assert.Equal(1, store.Add(new ClipPayload { VirtualFiles = new[] { new VirtualFile("고양이.png", () => Png) } }));
        Assert.Equal("고양이.png", store.Items[0].Title);
        Assert.Equal(0, store.Add(new ClipPayload { VirtualFiles = new[] { new VirtualFile("빈.png", () => null) } }));
        Assert.Equal("가져오지 못했어요", store.Toast?.Message);
    }

    [Fact]
    public void 이름이_겹치면_꼬리표를_붙인다()
    {
        var store = NewStore();
        store.Add(new ClipPayload { VirtualFiles = new[] { new VirtualFile("a.png", () => Png) } });
        store.Add(new ClipPayload { VirtualFiles = new[] { new VirtualFile("a.png", () => Png) } });
        var names = store.Items.Select(i => i.Title).ToList();
        Assert.Equal(2, names.Distinct().Count());
        Assert.All(names, n => Assert.EndsWith(".png", n));
    }

    [Fact]
    public void 빼기는_되돌릴_수_있고_시간이_지나면_보관_파일만_지운다()
    {
        var store = NewStore();
        var original = UserFile("원본.txt");
        store.Add(new ClipPayload { Files = new[] { original } });
        store.Add(new ClipPayload { HasImage = true, ReadPng = () => Png });
        var image = store.Items[0].Path!;

        store.RemoveAll();
        Assert.Empty(store.Items);
        Assert.True(store.Toast?.Undoable);
        store.UndoRemove();
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("되돌렸어요", store.Toast?.Message);

        store.RemoveAll();
        _timer.RunAll();
        Assert.False(File.Exists(image));
        Assert.True(File.Exists(original));
    }

    [Fact]
    public void 다시_켜도_담긴_것이_남고_목록에_없는_이미지는_정리한다()
    {
        var store = NewStore();
        store.Add(new ClipPayload { Text = "남아 있어야 함" });
        var orphan = Path.Combine(_dir, "images", "고아.png");
        File.WriteAllBytes(orphan, Png);

        var reopened = NewStore();
        Assert.Equal("남아 있어야 함", reopened.Items.Single().Text);
        Assert.False(File.Exists(orphan));
    }

    [Fact]
    public void 자동으로_담은_클립보드는_Ctrl_V_로_또_담지_않는다()
    {
        var store = NewStore();
        var payload = new ClipPayload { HasImage = true, ReadPng = () => Png, ClipboardSequence = 42 };
        store.AddCopiedImage(payload);
        Assert.Single(store.Items);
        Assert.Equal(0, store.Add(payload));
        Assert.Equal("이미 담겨 있어요", store.Toast?.Message);
    }

    [Fact]
    public void 캡처는_한_번만_담는다()
    {
        var store = NewStore();
        var capture = UserFile("스크린샷.png");
        store.AddCapture(capture);
        store.AddCapture(capture);
        Assert.Single(store.Items);
        Assert.Equal("캡처를 담았어요", store.Toast?.Message);
    }
}

public sealed class IntakeTests
{
    [Fact]
    public void 임시_폴더와_브라우저_캐시를_임시_파일로_본다()
    {
        Assert.True(Intake.IsTemporary(Path.Combine(Path.GetTempPath(), "a.png")));
        Assert.True(Intake.IsTemporary(@"C:\Users\me\AppData\Local\Microsoft\Windows\INetCache\IE\b.png"));
        Assert.False(Intake.IsTemporary(@"C:\Users\me\Pictures\c.png"));
    }

    [Fact]
    public void 복사한_이미지만_자동으로_담는다()
    {
        Assert.True(Intake.IsCopiedImage(new ClipPayload { HasImage = true }));
        Assert.False(Intake.IsCopiedImage(new ClipPayload { HasImage = true, HasRichText = true }));
        Assert.False(Intake.IsCopiedImage(new ClipPayload { HasImage = true, Concealed = true }));
        Assert.False(Intake.IsCopiedImage(new ClipPayload { HasImage = true, Files = new[] { @"C:\Users\me\Pictures\c.png" } }));
        Assert.True(Intake.IsCopiedImage(new ClipPayload { HasImage = true, Files = new[] { Path.Combine(Path.GetTempPath(), "slack.png") } }));
        Assert.False(Intake.IsCopiedImage(new ClipPayload { Text = "글" }));
    }
}

public sealed class ShortcutTests
{
    [Fact]
    public void 기본_단축키_이름()
    {
        Assert.Equal("Ctrl+Shift+F", Shortcut.Standard.DisplayName);
        Assert.Equal("Ctrl+Alt+Win+Space", new Shortcut(0x20, Shortcut.Control | Shortcut.Alt | Shortcut.Win).DisplayName);
        Assert.Equal("Alt+F5", new Shortcut(0x74, Shortcut.Alt).DisplayName);
    }

    [Fact]
    public void Ctrl_Alt_Win_중_하나가_있어야_한다()
    {
        Assert.Null(Shortcut.From(0x46, Shortcut.Shift));
        Assert.Null(Shortcut.From(0x11, Shortcut.Control));
        Assert.Equal(new Shortcut(0x42, Shortcut.Control | Shortcut.Shift), Shortcut.From(0x42, Shortcut.Control | Shortcut.Shift));
    }
}

public sealed class TransferTests
{
    [Fact]
    public void 가상_파일_목록에서_이름을_읽는다()
    {
        var names = new[] { "고양이.png", "b.gif" };
        var bytes = new byte[4 + 592 * names.Length];
        BitConverter.GetBytes(names.Length).CopyTo(bytes, 0);
        for (var i = 0; i < names.Length; i++)
            System.Text.Encoding.Unicode.GetBytes(names[i]).CopyTo(bytes, 4 + i * 592 + 72);
        Assert.Equal(names, Transfer.ParseFileNames(bytes));
    }
}
