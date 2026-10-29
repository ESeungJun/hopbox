using System;

namespace Hopbox;

/// <summary>전역 단축키. 어느 앱 위에서든 눌리면 알려 준다 (관리자 권한 필요 없음)</summary>
sealed class HotKey : IDisposable
{
    const int Id = 0x4850; // 'HP'
    readonly MessageWindow _window;
    bool _registered;

    public event Action? Pressed;

    public HotKey(MessageWindow window)
    {
        _window = window;
        _window.Message += (msg, wParam, _) =>
        {
            if (msg == Native.WM_HOTKEY && wParam.ToInt32() == Id) Pressed?.Invoke();
        };
    }

    /// <summary>등록에 실패하면(다른 앱이 쓰는 중) false</summary>
    public bool Register(Shortcut shortcut)
    {
        Unregister();
        _registered = Native.RegisterHotKey(_window.Handle, Id, shortcut.Modifiers | Native.MOD_NOREPEAT, shortcut.Key);
        return _registered;
    }

    public void Unregister()
    {
        if (!_registered) return;
        Native.UnregisterHotKey(_window.Handle, Id);
        _registered = false;
    }

    public void Dispose() => Unregister();
}
