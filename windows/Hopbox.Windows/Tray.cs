using System;
using System.Drawing;
using System.Windows.Forms;

namespace Hopbox;

/// <summary>작업 표시줄 알림 영역의 상자 아이콘과 메뉴. 누르면 상자를 부르고, 우클릭하면 설정 메뉴가 뜬다</summary>
sealed class Tray : IDisposable
{
    readonly NotifyIcon _icon;
    readonly ToolStripMenuItem _open = new("상자 열기");
    readonly ToolStripMenuItem _captures = new("스크린샷·화면 녹화 자동 담기") { CheckOnClick = true };
    readonly ToolStripMenuItem _copiedImages = new("복사한 이미지 자동 담기") { CheckOnClick = true };
    readonly ToolStripMenuItem _launchAtLogin = new("로그인 시 자동 실행") { CheckOnClick = true };

    public event Action? OpenBox;
    public event Action? EmptyBox;
    public event Action<bool>? CapturesChanged;
    public event Action<bool>? CopiedImagesChanged;
    public event Action? ChangeShortcut;
    public event Action? Quit;

    public Tray(Settings settings)
    {
        using var stream = typeof(Tray).Assembly.GetManifestResourceStream("app.ico");
        _icon = new NotifyIcon
        {
            Icon = stream is null ? SystemIcons.Application : new Icon(stream, SystemInformation.SmallIconSize),
            Text = "택배상자",
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };

        _captures.Checked = settings.AutoAddCaptures;
        _copiedImages.Checked = settings.AutoAddCopiedImages;
        _open.Click += (_, _) => OpenBox?.Invoke();
        _captures.CheckedChanged += (_, _) => CapturesChanged?.Invoke(_captures.Checked);
        _copiedImages.CheckedChanged += (_, _) => CopiedImagesChanged?.Invoke(_copiedImages.Checked);
        _launchAtLogin.Click += (_, _) =>
        {
            if (!LaunchAtLogin.Set(_launchAtLogin.Checked))
            {
                _launchAtLogin.Checked = LaunchAtLogin.IsEnabled;
                ShowMessage("자동 실행 설정을 바꾸지 못했어요");
            }
        };

        var menu = _icon.ContextMenuStrip;
        menu.Items.Add(_open);
        menu.Items.Add("모두 비우기", null, (_, _) => EmptyBox?.Invoke());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_captures);
        menu.Items.Add(_copiedImages);
        menu.Items.Add(_launchAtLogin);
        menu.Items.Add("단축키 바꾸기…", null, (_, _) => ChangeShortcut?.Invoke());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("종료", null, (_, _) => Quit?.Invoke());
        menu.Opening += (_, _) => _launchAtLogin.Checked = LaunchAtLogin.IsEnabled;

        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) OpenBox?.Invoke();
        };
    }

    /// <summary>메뉴의 "상자 열기" 옆에 지금 단축키를 보여 준다</summary>
    public void ShowShortcut(Shortcut shortcut) => _open.ShortcutKeyDisplayString = shortcut.DisplayName;

    public void ShowMessage(string message, string? detail = null) =>
        _icon.ShowBalloonTip(5000, "택배상자", detail is null ? message : $"{message}\n{detail}", ToolTipIcon.Info);

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
