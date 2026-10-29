using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace Hopbox;

/// <summary>
/// 새 버전 알림과 설치.
/// 켤 때와 하루에 한 번 GitHub 최신 릴리스를 보고, 새 버전이 있으면 알림 풍선을 띄운다. 풍선이나 메뉴를 누르면
/// 설치 파일을 받아 GitHub 가 알려 준 SHA-256 과 맞는지 확인한 뒤 조용히 설치하고, 설치 파일이 앱을 다시 켠다.
/// </summary>
sealed class Updater
{
    public enum Phase { Idle, Available, Installing }

    public sealed record Release(Version Version, string Download, string Sha256);

    const string LatestUrl = "https://api.github.com/repos/ESeungJun/hopbox/releases/latest";
    const string DownloadPrefix = "https://github.com/ESeungJun/hopbox/releases/download/";
    static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);
    static readonly HttpClient Http = CreateClient();

    public static readonly Version Current = Normalize(Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0));
    public static string CurrentText => Text(Current);

    readonly Settings _settings;
    readonly DispatcherTimer _timer;
    Release? _release;

    public Phase State { get; private set; } = Phase.Idle;
    public string? AvailableVersion => _release is null ? null : Text(_release.Version);

    public event Action? Changed;
    /// <summary>새 버전을 알려야 할 때 (인자는 버전)</summary>
    public event Action<string>? Found;
    /// <summary>확인·설치 결과를 알릴 때 (제목, 내용)</summary>
    public event Action<string, string?>? Message;
    /// <summary>설치 파일을 실행했으니 앱을 끝내야 할 때</summary>
    public event Action? Restarting;

    public Updater(Settings settings, Dispatcher dispatcher)
    {
        _settings = settings;
        _timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromSeconds(10) };
        _timer.Tick += async (_, _) =>
        {
            _timer.Interval = CheckInterval;
            await Check(manual: false);
        };
    }

    static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Hopbox-Windows");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    static Version Normalize(Version version) => new(version.Major, version.Minor, Math.Max(version.Build, 0));

    static string Text(Version version) => $"{version.Major}.{version.Minor}.{version.Build}";

    /// <summary>CI 의 시험 빌드(0.0.0)는 확인하지 않는다</summary>
    public void Start()
    {
        if (Current > new Version(0, 0, 0)) _timer.Start();
    }

    /// <summary>메뉴를 누르면: 새 버전을 알고 있으면 설치하고, 아니면 확인한다</summary>
    public async void MenuAction()
    {
        if (State == Phase.Available) await Install();
        else await Check(manual: true);
    }

    public async Task Check(bool manual)
    {
        if (State == Phase.Installing) return;
        try
        {
            var latest = await FetchLatest();
            if (latest is null || latest.Version <= Current)
            {
                _release = null;
                SetState(Phase.Idle);
                if (manual) Message?.Invoke("최신 버전을 쓰고 있어요", $"택배상자 {CurrentText}");
                return;
            }
            _release = latest;
            SetState(Phase.Available);
            var version = Text(latest.Version);
            // 같은 버전은 저절로 한 번만 알린다. 그 뒤로는 메뉴에서 설치할 수 있다
            if (manual || _settings.NotifiedUpdateVersion != version)
            {
                _settings.NotifiedUpdateVersion = version;
                _settings.Save();
                Found?.Invoke(version);
            }
        }
        catch (Exception error)
        {
            if (manual) Message?.Invoke("업데이트를 확인하지 못했어요", error.Message);
        }
    }

    public async Task Install()
    {
        if (_release is not { } release || State == Phase.Installing) return;
        SetState(Phase.Installing);
        try
        {
            var setup = await Download(release);
            Process.Start(new ProcessStartInfo(setup, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART") { UseShellExecute = false });
            Restarting?.Invoke();
        }
        catch (Exception error)
        {
            SetState(Phase.Available);
            Message?.Invoke("업데이트하지 못했어요", $"{error.Message}\ngithub.com/ESeungJun/hopbox/releases 에서 직접 받을 수 있어요.");
        }
    }

    void SetState(Phase state)
    {
        State = state;
        Changed?.Invoke();
    }

    static string AssetName => RuntimeInformation.ProcessArchitecture == Architecture.Arm64
        ? "Hopbox-Windows-arm64-Setup.exe"
        : "Hopbox-Windows-x64-Setup.exe";

    static async Task<Release?> FetchLatest() => Parse(await Http.GetStringAsync(LatestUrl), AssetName);

    /// <summary>GitHub 최신 릴리스 응답에서 이 PC 에 맞는 설치 파일을 고른다</summary>
    internal static Release? Parse(string json, string assetName)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v'), out var version)) return null;
        var asset = root.GetProperty("assets").EnumerateArray()
            .FirstOrDefault(a => a.GetProperty("name").GetString() == assetName);
        if (asset.ValueKind != JsonValueKind.Object) return null;
        var download = asset.GetProperty("browser_download_url").GetString() ?? "";
        // 이 저장소의 릴리스 파일이고, GitHub 가 내용 해시를 알려 줄 때만 받는다 (설치 파일은 코드 서명이 없다)
        var digest = asset.TryGetProperty("digest", out var value) ? value.GetString() : null;
        if (!download.StartsWith(DownloadPrefix, StringComparison.Ordinal) || digest is null || !digest.StartsWith("sha256:")) return null;
        return new Release(Normalize(version), download, digest["sha256:".Length..]);
    }

    /// <summary>설치 파일을 임시 폴더에 받고 SHA-256 이 맞는지 확인한다</summary>
    static async Task<string> Download(Release release)
    {
        var folder = Path.Combine(Path.GetTempPath(), "hopbox-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, AssetName);
        var bytes = await Http.GetByteArrayAsync(release.Download);
        var hash = Convert.ToHexString(SHA256.HashData(bytes));
        if (!string.Equals(hash, release.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("받은 설치 파일이 릴리스와 달라요");
        await File.WriteAllBytesAsync(path, bytes);
        return path;
    }
}
