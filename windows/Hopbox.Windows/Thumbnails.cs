using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Hopbox;

/// <summary>탐색기처럼 내용이 보이는 미리보기. 한 번 만든 것은 기억해 둔다</summary>
static class Thumbnails
{
    static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// 기억해 둔 미리보기가 있으면 돌려준다. 파일 내용이 바뀌면(같은 이름으로 다시 저장 등) 새로 만들도록
    /// 수정 시각과 크기를 열쇠에 넣는다
    /// </summary>
    public static bool TryCached(ShelfItem item, int size, out ImageSource? image)
    {
        image = null;
        return Key(item, size) is { } key && Cache.TryGetValue(key, out image);
    }

    public static ImageSource? For(ShelfItem item, int size)
    {
        if (item.Path is null || Key(item, size) is not { } key) return null;
        if (Cache.TryGetValue(key, out var cached)) return cached;
        var image = Load(item.Path, size);
        Cache[key] = image;
        return image;
    }

    static string? Key(ShelfItem item, int size)
    {
        if (item.Path is null) return null;
        try
        {
            var info = new FileInfo(item.Path);
            if (info.Exists) return $"{item.Path}|{size}|{info.LastWriteTimeUtc.Ticks}|{info.Length}";
            return Directory.Exists(item.Path) ? $"{item.Path}|{size}" : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    static ImageSource? Load(string path, int size)
    {
        // 작은 그림 파일은 직접 읽는 편이 빠르고 투명도도 그대로다
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp")
        {
            try
            {
                if (new FileInfo(path).Length < 30_000_000)
                {
                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.DecodePixelWidth = size * 2;
                    bitmap.UriSource = new Uri(path);
                    bitmap.EndInit();
                    bitmap.Freeze();
                    return bitmap;
                }
            }
            catch (Exception) { }
        }
        return ShellThumbnail(path, size * 2);
    }

    /// <summary>윈도우 셸이 만드는 미리보기(동영상 첫 장면, 문서 첫 쪽, 없으면 파일 아이콘)</summary>
    static ImageSource? ShellThumbnail(string path, int pixels)
    {
        try
        {
            Native.SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(Native.IShellItemImageFactory).GUID, out var factory);
            if (factory.GetImage(new Native.SIZE { Width = pixels, Height = pixels }, 0, out var handle) != 0) return null;
            try
            {
                var source = WithAlpha(handle)
                    ?? Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                return source;
            }
            finally
            {
                Native.DeleteObject(handle);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// 셸이 주는 32비트 그림은 투명도를 담고 있는데, CreateBitmapSourceFromHBitmap 은 이를 버려 바탕이 검게 나온다.
    /// 픽셀을 직접 읽어 투명도를 살린다. 32비트 DIB 가 아니거나 투명도 값이 비어 있으면 null
    /// </summary>
    static BitmapSource? WithAlpha(IntPtr handle)
    {
        var size = Marshal.SizeOf<Native.DIBSECTION>();
        if (Native.GetObject(handle, size, out var section) != size) return null;
        var info = section.dsBm;
        if (info.bmBitsPixel != 32 || info.bmBits == IntPtr.Zero || info.bmHeight <= 0) return null;
        var stride = info.bmWidthBytes;
        var pixels = new byte[stride * info.bmHeight];
        Marshal.Copy(info.bmBits, pixels, 0, pixels.Length);
        var hasAlpha = false;
        for (var i = 3; i < pixels.Length && !hasAlpha; i += 4) hasAlpha = pixels[i] != 0;
        if (!hasAlpha) return null;
        // 머리의 높이가 양수면 아래 줄부터 저장돼 있다
        if (section.dsBmih.biHeight > 0)
        {
            var flipped = new byte[pixels.Length];
            for (var y = 0; y < info.bmHeight; y++)
                Array.Copy(pixels, y * stride, flipped, (info.bmHeight - 1 - y) * stride, stride);
            pixels = flipped;
        }
        return BitmapSource.Create(info.bmWidth, info.bmHeight, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
    }
}
