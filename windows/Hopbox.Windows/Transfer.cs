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

    static readonly string[] ImageFormats = { Png, "image/png", DataFormats.Bitmap, DataFormats.Dib, "DeviceIndependentBitmapV5" };

    /// <summary>담을 만한 내용이 있는지. 끌어다 놓을 때 상자가 반응할지 정한다</summary>
    public static bool CanAdd(IDataObject data)
    {
        var formats = SafeFormats(data);
        return formats.Contains(DataFormats.FileDrop) || formats.Contains(FileGroupDescriptor)
            || formats.Any(ImageFormats.Contains) || formats.Contains(DataFormats.UnicodeText);
    }

    public static ClipPayload Read(IDataObject data, uint? clipboardSequence = null)
    {
        var formats = SafeFormats(data);
        var text = formats.Contains(DataFormats.UnicodeText) ? Get(data, DataFormats.UnicodeText) as string : null;
        return new ClipPayload
        {
            Concealed = formats.Any(ConcealedFormats.Contains) || HistoryForbidden(data, formats),
            Files = formats.Contains(DataFormats.FileDrop) ? Get(data, DataFormats.FileDrop) as string[] ?? Array.Empty<string>() : Array.Empty<string>(),
            VirtualFiles = formats.Contains(FileGroupDescriptor) ? ReadVirtualFiles(data) : Array.Empty<VirtualFile>(),
            HasImage = formats.Any(ImageFormats.Contains),
            ReadPng = () => ReadPng(data, formats),
            Text = text,
            HasRichText = formats.Contains(DataFormats.Rtf) || (formats.Contains(DataFormats.Html) && !string.IsNullOrWhiteSpace(text)),
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

    /// <summary>PNG 형식이 있으면 그대로(투명도 유지), 없으면 비트맵을 PNG 로 바꾼다</summary>
    static byte[]? ReadPng(IDataObject data, HashSet<string> formats)
    {
        foreach (var format in new[] { Png, "image/png" })
        {
            if (formats.Contains(format) && Get(data, format) is MemoryStream stream && stream.Length > 0)
                return stream.ToArray();
        }
        if (Get(data, DataFormats.Bitmap) is not BitmapSource bitmap) return null;
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    // 가상 파일: 브라우저·메신저가 실제 파일 대신 "이름 목록 + 내용" 으로 넘기는 것

    static VirtualFile[] ReadVirtualFiles(IDataObject data)
    {
        if (Get(data, FileGroupDescriptor) is not MemoryStream stream || data is not ComDataObject com) return Array.Empty<VirtualFile>();
        var names = ParseFileNames(stream.ToArray());
        return names.Select((name, index) => new VirtualFile(name, () => ReadFileContents(com, index))).ToArray();
    }

    /// <summary>FILEGROUPDESCRIPTORW: 개수(4바이트) 뒤에 592바이트짜리 FILEDESCRIPTORW 가 이어진다. 이름은 각 항목의 72바이트 위치</summary>
    public static List<string> ParseFileNames(byte[] descriptor)
    {
        const int Size = 592, NameOffset = 72, NameBytes = 520;
        var names = new List<string>();
        if (descriptor.Length < 4) return names;
        var count = BitConverter.ToInt32(descriptor, 0);
        for (var i = 0; i < count; i++)
        {
            var start = 4 + i * Size + NameOffset;
            if (start + NameBytes > descriptor.Length) break;
            var name = Encoding.Unicode.GetString(descriptor, start, NameBytes);
            var end = name.IndexOf('\0');
            names.Add(end >= 0 ? name[..end] : name);
        }
        return names;
    }

    static byte[]? ReadFileContents(ComDataObject com, int index)
    {
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
                    TYMED.TYMED_HGLOBAL => ReadGlobal(medium.unionmember),
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

    static byte[] ReadGlobal(IntPtr handle)
    {
        var pointer = Native.GlobalLock(handle);
        try
        {
            var bytes = new byte[(int)Native.GlobalSize(handle).ToUInt64()];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            Native.GlobalUnlock(handle);
        }
    }

    static byte[] ReadStream(IntPtr unknown)
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
    /// 이미지는 메신저·문서가 그림을, 탐색기가 파일을 가져가도록 둘 다 올린다
    /// </summary>
    public static DataObject? ForClipboard(ShelfItem item)
    {
        var data = new DataObject();
        switch (item.Kind)
        {
            case ItemKind.Text:
                data.SetText(item.Text ?? "", TextDataFormat.UnicodeText);
                break;
            case ItemKind.File:
                data.SetFileDropList(new StringCollection { item.Path! });
                break;
            case ItemKind.Image:
                var bytes = File.ReadAllBytes(item.Path!);
                var decoder = BitmapDecoder.Create(new MemoryStream(bytes), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                var frame = decoder.Frames[0];
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(frame));
                var png = new MemoryStream();
                encoder.Save(png);
                data.SetData(Png, png);
                data.SetImage(frame);
                data.SetFileDropList(new StringCollection { item.Path! });
                break;
        }
        return data;
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
