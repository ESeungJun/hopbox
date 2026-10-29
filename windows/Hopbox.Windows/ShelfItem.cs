using System;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;

namespace Hopbox;

public enum ItemKind
{
    /// <summary>원본 파일을 가리키기만 한다 (복사하지 않음)</summary>
    File,
    /// <summary>상자가 보관하는 파일. 붙여넣은 이미지, 곧 지워질 임시 파일을 상자 폴더에 복사해 둔다</summary>
    Image,
    Text,
}

public sealed record ShelfItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ItemKind Kind { get; init; }
    public string? Path { get; init; }
    public string? Text { get; init; }
    /// <summary>텍스트 미리보기. 긴 텍스트를 그릴 때마다 다듬지 않도록 담을 때 한 번 만든다</summary>
    public string? Preview { get; init; }
    public int? TextLength { get; init; }
    public DateTime AddedAt { get; init; } = DateTime.Now;

    [JsonIgnore]
    public bool Exists => Path is null ? Kind == ItemKind.Text : System.IO.File.Exists(Path);

    /// <summary>목록·부채꼴에 보이는 이름</summary>
    [JsonIgnore]
    public string Title => Kind == ItemKind.Text
        ? Preview ?? MakePreview(Text ?? "")
        : System.IO.Path.GetFileName(Path ?? "");

    public static ShelfItem FromFile(string path) => new() { Kind = ItemKind.File, Path = path };

    public static ShelfItem FromImage(string path) => new() { Kind = ItemKind.Image, Path = path };

    public static ShelfItem FromText(string text) => new()
    {
        Kind = ItemKind.Text, Text = text, Preview = MakePreview(text), TextLength = text.Length,
    };

    public static string MakePreview(string text) =>
        string.Join(' ', text[..Math.Min(text.Length, 300)]
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}

public sealed record Toast(string Message, bool Undoable = false)
{
    public Guid Id { get; } = Guid.NewGuid();
}

/// <summary>다른 앱이 넘겨준 가상 파일(브라우저·메신저에서 끌어온 이미지 등). 이름과 내용을 읽는 방법</summary>
public sealed record VirtualFile(string Name, Func<byte[]?> Read);

/// <summary>
/// 끌어다 놓기·붙여넣기로 들어온 내용을 형식별로 정리한 것.
/// 실제 클립보드에서 읽는 일은 Transfer 가 하고, 무엇을 담을지는 ShelfStore 가 이것만 보고 정한다.
/// </summary>
public sealed record ClipPayload
{
    public string[] Files { get; init; } = Array.Empty<string>();
    public VirtualFile[] VirtualFiles { get; init; } = Array.Empty<VirtualFile>();
    public bool HasImage { get; init; }
    /// <summary>이미지를 PNG 로 읽는다. 필요할 때만 부른다</summary>
    public Func<byte[]?> ReadPng { get; init; } = () => null;
    public string? Text { get; init; }
    /// <summary>서식 있는 텍스트(엑셀·워드 등). 이때는 그림이 같이 실려도 텍스트로 본다</summary>
    public bool HasRichText { get; init; }
    /// <summary>비밀번호 관리자처럼 기록에 남기지 말라고 표시한 값</summary>
    public bool Concealed { get; init; }
    /// <summary>클립보드에서 읽었으면 그 순번. 끌어다 놓기면 null</summary>
    public uint? ClipboardSequence { get; init; }

    public string? TrimmedText => string.IsNullOrWhiteSpace(Text) ? null : Text;
}

public static class Intake
{
    /// <summary>시스템 임시 폴더·브라우저 캐시에 있는 파일인지. 곧 지워지므로 상자에 복사해 둔다</summary>
    public static bool IsTemporary(string path)
    {
        string full;
        try { full = System.IO.Path.GetFullPath(path); }
        catch (Exception) { return false; }
        var temp = System.IO.Path.GetFullPath(System.IO.Path.GetTempPath());
        return full.StartsWith(temp, StringComparison.OrdinalIgnoreCase)
            || full.Contains(@"\INetCache\", StringComparison.OrdinalIgnoreCase)
            || full.Contains(@"\Temporary Internet Files\", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// 자동 담기 대상인 "복사한 이미지" 인지.
    /// 탐색기에서 파일을 복사한 경우(사용자 폴더의 파일), 엑셀처럼 글과 그림을 함께 싣는 경우, 숨긴 값은 제외한다.
    /// </summary>
    public static bool IsCopiedImage(ClipPayload payload) =>
        payload.HasImage
        && !payload.HasRichText
        && !payload.Concealed
        && payload.Files.All(IsTemporary);
}
