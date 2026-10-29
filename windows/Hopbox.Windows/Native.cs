using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Hopbox;

/// <summary>윈도우 API 선언</summary>
static class Native
{
    public const int WM_HOTKEY = 0x0312;
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public const int MOD_NOREPEAT = 0x4000;

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_APPWINDOW = 0x00040000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, int modifiers, int vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint RegisterClipboardFormat(string format);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalLock(IntPtr handle);

    [DllImport("kernel32.dll")]
    public static extern bool GlobalUnlock(IntPtr handle);

    [DllImport("kernel32.dll")]
    public static extern UIntPtr GlobalSize(IntPtr handle);

    [DllImport("ole32.dll")]
    public static extern void ReleaseStgMedium(ref System.Runtime.InteropServices.ComTypes.STGMEDIUM medium);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr handle);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void SHCreateItemFromParsingName(
        string path, IntPtr bindContext, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern IntPtr SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, int flags, IntPtr token);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE
    {
        public int Width;
        public int Height;
    }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(SIZE size, int flags, out IntPtr bitmap);
    }

    /// <summary>알려진 폴더 경로. 사용자가 옮겼어도 실제 위치를 돌려준다</summary>
    public static string? KnownFolder(Guid id)
    {
        try
        {
            var pointer = SHGetKnownFolderPath(id, 0, IntPtr.Zero);
            var path = Marshal.PtrToStringUni(pointer);
            Marshal.FreeCoTaskMem(pointer);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }
}

/// <summary>
/// 화면에 보이지 않는 메시지 전용 창. 전역 단축키와 클립보드 변경 알림을 받는다
/// </summary>
sealed class MessageWindow : IDisposable
{
    readonly HwndSource _source;

    public event Action<int, IntPtr, IntPtr>? Message;

    public MessageWindow()
    {
        var parameters = new HwndSourceParameters("HopboxMessages") { ParentWindow = new IntPtr(-3), WindowStyle = 0 };
        _source = new HwndSource(parameters);
        _source.AddHook(Hook);
    }

    public IntPtr Handle => _source.Handle;

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg is Native.WM_HOTKEY or Native.WM_CLIPBOARDUPDATE)
        {
            Message?.Invoke(msg, wParam, lParam);
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose() => _source.Dispose();
}
