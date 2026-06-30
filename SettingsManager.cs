using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PerfMonCS;

public enum Arrangement { Vertical = 0, Grid2x2 = 1, Horizontal = 2 }
public enum GraphKind   { Line = 0, Bar = 1 }

public sealed class SectionSettings
{
    public bool      Visible    { get; set; } = true;
    public bool      ShowLabel  { get; set; } = true;
    public bool      ShowValues { get; set; } = true;
    public bool      Overlay    { get; set; } = true;   // true=텍스트가 그래프 위 겹침, false=분리
    public GraphKind Graph      { get; set; } = GraphKind.Line;
    public double    SizeRatio  { get; set; } = 1.0;    // 배치 내 상대 크기(가중치)

    public SectionSettings Clone() => (SectionSettings)MemberwiseClone();
}

public sealed class AppSettings
{
    // 창 상태
    public double? X { get; set; }
    public double? Y { get; set; }
    public double? W { get; set; }
    public double? H { get; set; }

    // 공통
    public double      Opacity     { get; set; } = 0.85;
    public bool        AlwaysOnTop { get; set; } = true;
    public bool        ScaleText   { get; set; } = true;   // Viewbox 글자 스케일
    public int         UpdateMs    { get; set; } = 1000;
    public Arrangement Arrange     { get; set; } = Arrangement.Vertical;

    // 섹션
    public SectionSettings Cpu  { get; set; } = new();
    public SectionSettings Mem  { get; set; } = new();
    public SectionSettings Disk { get; set; } = new();
    public SectionSettings Net  { get; set; } = new();

    [JsonIgnore]
    public SectionSettings[] Sections => new[] { Cpu, Mem, Disk, Net };

    public AppSettings Clone() => new()
    {
        X = X, Y = Y, W = W, H = H,
        Opacity = Opacity, AlwaysOnTop = AlwaysOnTop, ScaleText = ScaleText,
        UpdateMs = UpdateMs, Arrange = Arrange,
        Cpu = Cpu.Clone(), Mem = Mem.Clone(), Disk = Disk.Clone(), Net = Net.Clone(),
    };
}

public static class SettingsManager
{
    private static readonly JsonSerializerOptions Opts = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "PerfMonCS", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            var json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<AppSettings>(json, Opts) ?? new AppSettings();
        }
        catch { return new AppSettings(); }
    }

    public static void Save(AppSettings s)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(s, Opts));
        }
        catch { }
    }
}
