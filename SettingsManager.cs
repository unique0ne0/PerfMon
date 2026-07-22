using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PerfMonCS;

public enum Arrangement { Vertical = 0, Grid2x2 = 1, Horizontal = 2, Compact = 3, Mini = 4 }
public enum GraphKind   { Line = 0, Bar = 1 }

public sealed class SectionSettings
{
    public bool      Visible    { get; set; } = true;
    public bool      ShowLabel  { get; set; } = true;
    public bool      ShowValues { get; set; } = true;
    public bool      ShowGraph  { get; set; } = true;
    public bool      Overlay     { get; set; } = true;   // true=텍스트가 그래프 위 겹침, false=분리
    public GraphKind Graph       { get; set; } = GraphKind.Line;
    public int       WidthRatio  { get; set; } = 1;     // 가로 비율 1-3
    public int       HeightRatio { get; set; } = 1;     // 세로 비율 1-3

    // 색상 (#AARRGGBB / #RRGGBB). null이면 AppSettings.ApplyColorDefaults()가 섹션 기본색으로 채움.
    // Value2/Graph2는 이중 계열 섹션(DISK R/W, NET D/U)에서만 사용.
    // 기본적으로 그래프는 수치(Value) 색을 그대로 사용한다. SeparateGraphColor=true일 때만
    // Graph1/Graph2를 별도 색으로 적용.
    public bool    SeparateGraphColor { get; set; } = false;
    public string? LabelColor  { get; set; }
    public string? Value1Color { get; set; }
    public string? Value2Color { get; set; }
    public string? Graph1Color { get; set; }
    public string? Graph2Color { get; set; }

    public SectionSettings Clone() => (SectionSettings)MemberwiseClone();
}

public sealed class AppSettings
{
    // 창 상태
    public double? X { get; set; }
    public double? Y { get; set; }
    public double? W { get; set; }
    public double? H { get; set; }
    public double? SavedX { get; set; }
    public double? SavedY { get; set; }

    // 공통
    public double      Opacity        { get; set; } = 0.85;
    public bool        AlwaysOnTop    { get; set; } = true;
    public bool        ScaleText      { get; set; } = true;
    public int         UpdateMs       { get; set; } = 1000;
    public Arrangement Arrange        { get; set; } = Arrangement.Vertical;
    public double      LabelFontSize     { get; set; } = 10;
    public double      ValueFontSize     { get; set; } = 10;
    public bool        UseCommonDisplay  { get; set; } = false;
    public bool        MemShowPercent    { get; set; } = true;
    public bool        MemShowUsage      { get; set; } = true;

    // 섹션
    public SectionSettings Cpu  { get; set; } = new();
    public SectionSettings Mem  { get; set; } = new();
    public SectionSettings Disk { get; set; } = new();
    public SectionSettings Net  { get; set; } = new();

    [JsonIgnore]
    public SectionSettings[] Sections => new[] { Cpu, Mem, Disk, Net };

    public AppSettings() => ApplyColorDefaults();

    // null/빈 색상 필드에만 섹션별 기본색을 채운다(명시 지정된 값은 보존).
    // 신규 인스턴스·기존 settings.json(색상 필드 없음) 모두 여기서 정규화된다.
    public void ApplyColorDefaults()
    {
        Fill(Cpu,  "#FF00C3FF", "#FF00C3FF", "#FF00C3FF", "#FF00C3FF", "#FF00C3FF");
        Fill(Mem,  "#FFA855F7", "#FFA855F7", "#FFA855F7", "#FFA855F7", "#FFA855F7");
        Fill(Disk, "#FFFDE047", "#FFFDE047", "#FFF97316", "#FFFDE047", "#FFF97316");
        Fill(Net,  "#FFFFFFFF", "#FFFFFFFF", "#FF38BDF8", "#FFFFFFFF", "#FF38BDF8");

        static void Fill(SectionSettings s, string label, string v1, string v2, string g1, string g2)
        {
            s.LabelColor  = Def(s.LabelColor,  label);
            s.Value1Color = Def(s.Value1Color, v1);
            s.Value2Color = Def(s.Value2Color, v2);
            s.Graph1Color = Def(s.Graph1Color, g1);
            s.Graph2Color = Def(s.Graph2Color, g2);
        }
        static string Def(string? cur, string d) => string.IsNullOrEmpty(cur) ? d : cur;
    }

    public AppSettings Clone() => new()
    {
        X = X, Y = Y, W = W, H = H, SavedX = SavedX, SavedY = SavedY,
        Opacity = Opacity, AlwaysOnTop = AlwaysOnTop, ScaleText = ScaleText,
        UpdateMs = UpdateMs, Arrange = Arrange,
        LabelFontSize = LabelFontSize, ValueFontSize = ValueFontSize,
        UseCommonDisplay = UseCommonDisplay,
        MemShowPercent = MemShowPercent, MemShowUsage = MemShowUsage,
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

    private static string AppDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "PerfMonCS");

    private static string FilePath => Path.Combine(AppDir, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new AppSettings();
            var json = File.ReadAllText(FilePath);
            var s = JsonSerializer.Deserialize<AppSettings>(json, Opts) ?? new AppSettings();
            s.ApplyColorDefaults();   // 구버전 파일에 없던 색상 필드를 기본색으로 보충
            return s;
        }
        catch (Exception ex)
        {
            LogError("Load settings", ex);
            return new AppSettings();
        }
    }

    public static void Save(AppSettings s)
    {
        string tmp = FilePath + ".tmp";
        try
        {
            Directory.CreateDirectory(AppDir);
            File.WriteAllText(tmp, JsonSerializer.Serialize(s, Opts));
            if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null);
            else File.Move(tmp, FilePath);
        }
        catch (Exception ex)
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            LogError("Save settings", ex);
        }
    }

    public static void LogError(string context, Exception ex)
    {
        try
        {
            Directory.CreateDirectory(AppDir);
            var log = Path.Combine(AppDir, "error.log");
            File.AppendAllText(log, $"[{DateTime.Now}] {context}: {ex.Message}\n");
        }
        catch { }
    }
}
