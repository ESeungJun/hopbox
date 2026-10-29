using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Hopbox;

/// <summary>%APPDATA%\Hopbox\settings.json 에 저장하는 설정</summary>
public sealed class Settings
{
    public int ShortcutKey { get; set; } = Shortcut.Standard.Key;
    public int ShortcutModifiers { get; set; } = Shortcut.Standard.Modifiers;
    /// <summary>스크린샷·화면 녹화 자동 담기</summary>
    public bool AutoAddCaptures { get; set; } = true;
    /// <summary>복사한 이미지 자동 담기</summary>
    public bool AutoAddCopiedImages { get; set; } = true;

    [JsonIgnore]
    public Shortcut Shortcut
    {
        get => new(ShortcutKey, ShortcutModifiers);
        set { ShortcutKey = value.Key; ShortcutModifiers = value.Modifiers; }
    }

    static string FilePath => Path.Combine(ShelfStore.DefaultDirectory(), "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch (Exception) { }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception) { }
    }
}

/// <summary>로그인 시 자동 실행. 사용자 레지스트리의 Run 항목 하나로 켜고 끈다</summary>
public static class LaunchAtLogin
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Hopbox";

    static string Command => $"\"{Environment.ProcessPath}\"";

    /// <summary>지금 실행 중인 이 파일을 가리킬 때만 켜진 것으로 본다. 앱을 옮겼으면 꺼진 것으로 보여서 다시 켤 수 있다</summary>
    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(Name) is string value && string.Equals(value, Command, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    public static bool Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled) key.SetValue(Name, Command);
            else key.DeleteValue(Name, throwOnMissingValue: false);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
