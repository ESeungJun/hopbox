using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Hopbox;

/// <summary>탐색기처럼 내용이 보이는 미리보기. 한 번 만든 것은 기억해 둔다</summary>
static class Thumbnails
{
    static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? For(ShelfItem item, int size)
    {
        if (item.Path is null || !item.Exists) return null;
        var key = $"{item.Path}|{size}";
        if (Cache.TryGetValue(key, out var cached)) return cached;
        var image = Load(item.Path, size);
        Cache[key] = image;
        return image;
    }

    static ImageSource? Load(string path, int size)
    {
        // 작은 그림 파일은 직접 읽는 편이 빠르고 투명도도 그대로다
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" && new FileInfo(path).Length < 30_000_000)
        {
            try
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
                var source = Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
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

    public static void Forget(string path)
    {
        foreach (var key in new List<string>(Cache.Keys))
            if (key.StartsWith(path + "|", StringComparison.OrdinalIgnoreCase)) Cache.Remove(key);
    }
}
