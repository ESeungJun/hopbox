using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;
using DataObject = System.Windows.DataObject;
using IDataObject = System.Windows.IDataObject;

namespace Hopbox;

/// <summary>클립보드·끌어다 놓기 데이터와 상자 항목 사이를 옮긴다</summary>
static class Transfer
{
    const string FileGroupDescriptor = "FileGroupDescriptorW";
    const string FileContents = "FileContents";
    const string Png = "PNG";
    /// <summary>비밀번호 관리자 등이 "기록하지 말 것" 으로 표시할 때 쓰는 형식</summary>
    static readonly string[] ConcealedFormats = { "ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore" };
    const string HistoryFormat = "CanIncludeInClipboardHistory";

    const string DibV5 = "DeviceIndependentBitmapV5";
    static readonly string[] ImageFormats = { Png, "image/png", DataFormats.Bitmap, DataFormats.Dib, DibV5 };
    /// <summary>가상 파일 하나를 받을 수 있는 최대 크기. 이보다 크면 메모리에 다 올리지 않고 포기한다</summary>
    const long MaxVirtualFileBytes = 512L * 1024 * 1024;

    /// <summary>담을 만한 내용이 있는지. 끌어다 놓을 때 상자가 반응할지 정한다</summary>
    public static bool CanAdd(IDataObject data)
    {
        var formats = SafeFormats(data);
        return formats.Contains(DataFormats.FileDrop) || formats.Contains(FileGroupDescriptor)
            || formats.Any(ImageFormats.Contains) || formats.Contains(DataFormats.UnicodeText);
    }

    /// <summary>
    /// 들어온 내용을 형식별로 정리한다.
    /// 클립보드 자동 담기는 이미지만 보므로 readText 를 끄고 부른다. 복사할 때마다 긴 글 전체를 읽지 않도록
    /// </summary>
    public static ClipPayload Read(IDataObject data, uint? clipboardSequence = null, bool readText = true)
    {
        var formats = SafeFormats(data);
        var hasText = formats.Contains(DataFormats.UnicodeText);
        var text = readText && hasText ? Get(data, DataFormats.UnicodeText) as string : null;
        return new ClipPayload
        {
            Concealed = formats.Any(ConcealedFormats.Contains) || HistoryForbidden(data, formats),
            Files = formats.Contains(DataFormats.FileDrop) ? Get(data, DataFormats.FileDrop) as string[] ?? Array.Empty<string>() : Array.Empty<string>(),
            VirtualFiles = formats.Contains(FileGroupDescriptor) ? ReadVirtualFiles(data) : Array.Empty<VirtualFile>(),
            HasImage = formats.Any(ImageFormats.Contains),
            ReadPng = () => ReadPng(data, formats),
            Text = text,
            HasRichText = formats.Contains(DataFormats.Rtf)
                || (formats.Contains(DataFormats.Html) && (readText ? !string.IsNullOrWhiteSpace(text) : hasText)),
            ClipboardSequence = clipboardSequence,
        };
    }

    static HashSet<string> SafeFormats(IDataObject data)
    {
        try { return data.GetFormats(false).ToHashSet(); }
        catch (Exception) { return new HashSet<string>(); }
    }

    static object? Get(IDataObject data, string format)
    {
        try { return data.GetData(format, false); }
        catch (Exception) { return null; }
    }

    static bool HistoryForbidden(IDataObject data, HashSet<string> formats)
    {
        if (!formats.Contains(HistoryFormat) || Get(data, HistoryFormat) is not MemoryStream stream) return false;
        var bytes = stream.ToArray();
        return bytes.Length >= 4 && BitConverter.ToInt32(bytes, 0) == 0;
    }

    /// <summary>
    /// PNG 형식이 있으면 그대로(투명도 유지), 없으면 비트맵을 PNG 로 바꾼다.
    /// 끌어다 놓기는 클립보드와 달리 윈도우가 DIB 를 비트맵으로 바꿔 주지 않아서 DIB 도 직접 읽는다
    /// </summary>
    static byte[]? ReadPng(IDataObject data, HashSet<string> formats)
    {
        try
        {
            foreach (var format in new[] { Png, "image/png" })
            {
                if (formats.Contains(format) && Get(data, format) is MemoryStream stream && stream.Length > 0)
                    return stream.ToArray();
            }
            var bitmap = Get(data, DataFormats.Bitmap) as BitmapSource;
            foreach (var format in new[] { DibV5, DataFormats.Dib })
            {
                if (bitmap is not null) break;
                if (formats.Contains(format) && Get(data, format) is MemoryStream dib) bitmap = DecodeDib(dib.ToArray());
            }
            if (bitmap is null) return null;
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = new MemoryStream();
            encoder.Save(output);
            return output.ToArray();
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>DIB(머리 + 색표 + 픽셀) 앞에 14바이트 BMP 파일 머리를 붙여 BMP 로 읽는다</summary>
    static BitmapSource? DecodeDib(byte[] dib)
    {
        if (dib.Length < 40) return null;
        var headerSize = BitConverter.ToInt32(dib, 0);
        var bitCount = BitConverter.ToInt16(dib, 14);
        var compression = BitConverter.ToInt32(dib, 16);
        var colorsUsed = BitConverter.ToInt32(dib, 32);
        // BI_BITFIELDS(3)·BI_ALPHABITFIELDS(6) 이고 머리가 기본 크기면 색 마스크가 머리 뒤에 따로 붙는다
        var masks = headerSize == 40 && compression is 3 or 6 ? (compression == 3 ? 12 : 16) : 0;
        var colors = colorsUsed != 0 ? colorsUsed : bitCount <= 8 ? 1 << bitCount : 0;
        var pixelOffset = 14 + headerSize + masks + colors * 4;
        var file = new byte[14 + dib.Length];
        file[0] = (byte)'B';
        file[1] = (byte)'M';
        BitConverter.GetBytes(file.Length).CopyTo(file, 2);
        BitConverter.GetBytes(pixelOffset).CopyTo(file, 10);
        dib.CopyTo(file, 14);
        var decoder = new BmpBitmapDecoder(new MemoryStream(file), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return decoder.Frames[0];
    }

    // 가상 파일: 브라우저·메신저가 실제 파일 대신 "이름 목록 + 내용" 으로 넘기는 것

    static VirtualFile[] ReadVirtualFiles(IDataObject data)
    {
        if (Get(data, FileGroupDescriptor) is not MemoryStream stream || data is not ComDataObject com) return Array.Empty<VirtualFile>();
        var files = ParseFileDescriptors(stream.ToArray());
        return files.Select((file, index) => new VirtualFile(file.Name, () => ReadFileContents(com, index, file.Size))).ToArray();
    }

    /// <summary>
    /// FILEGROUPDESCRIPTORW: 개수(4바이트) 뒤에 592바이트짜리 FILEDESCRIPTORW 가 이어진다.
    /// 각 항목의 0바이트에 플래그, 64·68바이트에 크기(상위·하위), 72바이트에 이름이 있다. 크기는 FD_FILESIZE 플래그가 있을 때만 믿는다
    /// </summary>
    public static List<(string Name, long? Size)> ParseFileDescriptors(byte[] descriptor)
    {
        const int Size = 592, FlagsOffset = 0, SizeOffset = 64, NameOffset = 72, NameBytes = 520, FileSizeFlag = 0x40;
        var files = new List<(string, long?)>();
        if (descriptor.Length < 4) return files;
        var count = BitConverter.ToInt32(descriptor, 0);
        for (var i = 0; i < count; i++)
        {
            var start = 4 + i * Size;
            if (start + NameOffset + NameBytes > descriptor.Length) break;
            var name = Encoding.Unicode.GetString(descriptor, start + NameOffset, NameBytes);
            var end = name.IndexOf('\0');
            var flags = BitConverter.ToInt32(descriptor, start + FlagsOffset);
            long? size = (flags & FileSizeFlag) != 0
                ? ((long)BitConverter.ToUInt32(descriptor, start + SizeOffset) << 32) | BitConverter.ToUInt32(descriptor, start + SizeOffset + 4)
                : null;
            files.Add((end >= 0 ? name[..end] : name, size));
        }
        return files;
    }

    static byte[]? ReadFileContents(ComDataObject com, int index, long? size)
    {
        if (size > MaxVirtualFileBytes) return null;
        var format = new FORMATETC
        {
            cfFormat = unchecked((short)Native.RegisterClipboardFormat(FileContents)),
            dwAspect = DVASPECT.DVASPECT_CONTENT,
            lindex = index,
            ptd = IntPtr.Zero,
            tymed = TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL,
        };
        try
        {
            com.GetData(ref format, out var medium);
            try
            {
                return medium.tymed switch
                {
                    TYMED.TYMED_HGLOBAL => ReadGlobal(medium.unionmember, size),
                    TYMED.TYMED_ISTREAM => ReadStream(medium.unionmember),
                    _ => null,
                };
            }
            finally
            {
                Native.ReleaseStgMedium(ref medium);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>메모리 덩어리는 실제 파일보다 크게 잡혀 있을 수 있어 알려 준 크기만큼만 읽는다</summary>
    static byte[]? ReadGlobal(IntPtr handle, long? size)
    {
        var allocated = (long)Native.GlobalSize(handle).ToUInt64();
        var length = Math.Min(allocated, size ?? allocated);
        if (length > MaxVirtualFileBytes) return null;
        var pointer = Native.GlobalLock(handle);
        try
        {
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            Native.GlobalUnlock(handle);
        }
    }

    static byte[]? ReadStream(IntPtr unknown)
    {
        var stream = (IStream)Marshal.GetObjectForIUnknown(unknown);
        var countPointer = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            using var output = new MemoryStream();
            var buffer = new byte[64 * 1024];
            while (true)
            {
                stream.Read(buffer, buffer.Length, countPointer);
                var count = Marshal.ReadInt32(countPointer);
                if (count <= 0) break;
                output.Write(buffer, 0, count);
                if (output.Length > MaxVirtualFileBytes) return null;
            }
            return output.ToArray();
        }
        finally
        {
            Marshal.FreeHGlobal(countPointer);
            Marshal.ReleaseComObject(stream);
        }
    }

    // 꺼내기

    /// <summary>
    /// 클릭해서 복사할 때 클립보드에 올릴 내용.
    /// 파일은 탐색기가 가져가도록 경로를 올리고, 상자가 보관한 그림은 메신저·문서가 쓰도록 그림도 함께 올린다
    /// </summary>
    public static DataObject ForClipboard(ShelfItem item)
    {
        var data = new DataObject();
        if (item.Kind == ItemKind.Text)
        {
            data.SetText(item.Text ?? "", TextDataFormat.UnicodeText);
            return data;
        }
        data.SetFileDropList(new StringCollection { item.Path! });
        if (item.Kind == ItemKind.Image && item.IsPicture) AddPicture(data, item.Path!);
        return data;
    }

    /// <summary>그림을 읽지 못하면(깨진 파일 등) 파일 경로만 올린 채로 둔다</summary>
    static void AddPicture(DataObject data, string path)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            var decoder = BitmapDecoder.Create(new MemoryStream(bytes), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            var frame = decoder.Frames[0];
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(frame));
            var png = new MemoryStream();
            encoder.Save(png);
            data.SetData(Png, png);
            data.SetImage(frame);
        }
        catch (Exception) { }
    }

    /// <summary>끌어낼 때 넘길 내용. 파일은 늘 복사로 나간다</summary>
    public static DataObject ForDrag(IEnumerable<ShelfItem> items)
    {
        var list = items.ToList();
        var data = new DataObject();
        var files = list.Where(i => i.Kind != ItemKind.Text && i.Exists).Select(i => i.Path!).ToArray();
        if (files.Length > 0)
        {
            var collection = new StringCollection();
            collection.AddRange(files);
            data.SetFileDropList(collection);
        }
        var texts = list.Where(i => i.Kind == ItemKind.Text).Select(i => i.Text ?? "").ToArray();
        if (texts.Length > 0) data.SetText(string.Join(Environment.NewLine, texts), TextDataFormat.UnicodeText);
        return data;
    }
}
