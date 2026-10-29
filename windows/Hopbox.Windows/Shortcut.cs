using System;
using System.Collections.Generic;

namespace Hopbox;

/// <summary>상자를 부르는 단축키. 가상 키 코드와 RegisterHotKey 수정키 조합을 저장한다</summary>
public readonly record struct Shortcut(int Key, int Modifiers)
{
    public const int Alt = 0x1, Control = 0x2, Shift = 0x4, Win = 0x8;
    const int VkF = 0x46;

    /// <summary>Ctrl+Shift+F</summary>
    public static readonly Shortcut Standard = new(VkF, Control | Shift);

    /// <summary>키 입력에서 단축키를 만든다. Ctrl·Alt·Win 중 하나는 있어야 한다 (Shift 만으로는 글자 입력과 겹친다)</summary>
    public static Shortcut? From(int key, int modifiers)
    {
        if ((modifiers & (Control | Alt | Win)) == 0) return null;
        if (IsModifierKey(key)) return null;
        return new Shortcut(key, modifiers);
    }

    static bool IsModifierKey(int key) => key is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    /// <summary>"Ctrl+Shift+F" 처럼 보이는 이름</summary>
    public string DisplayName
    {
        get
        {
            var parts = new List<string>();
            if ((Modifiers & Control) != 0) parts.Add("Ctrl");
            if ((Modifiers & Alt) != 0) parts.Add("Alt");
            if ((Modifiers & Shift) != 0) parts.Add("Shift");
            if ((Modifiers & Win) != 0) parts.Add("Win");
            parts.Add(KeyName(Key));
            return string.Join("+", parts);
        }
    }

    static readonly Dictionary<int, string> SpecialKeys = new()
    {
        [0x20] = "Space", [0x0D] = "Enter", [0x09] = "Tab", [0x08] = "Backspace", [0x2E] = "Delete",
        [0x2D] = "Insert", [0x24] = "Home", [0x23] = "End", [0x21] = "PageUp", [0x22] = "PageDown",
        [0x25] = "←", [0x26] = "↑", [0x27] = "→", [0x28] = "↓",
        [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".", [0xBF] = "/",
        [0xC0] = "`", [0xDB] = "[", [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'",
    };

    /// <summary>키 이름. 한글 입력 상태와 상관없이 영문 자판 기준으로 보여 준다</summary>
    public static string KeyName(int key)
    {
        if (key is >= 0x41 and <= 0x5A or >= 0x30 and <= 0x39) return ((char)key).ToString();
        if (key is >= 0x70 and <= 0x87) return $"F{key - 0x6F}";
        if (key is >= 0x60 and <= 0x69) return $"Num{key - 0x60}";
        return SpecialKeys.TryGetValue(key, out var name) ? name : $"키{key}";
    }
}
