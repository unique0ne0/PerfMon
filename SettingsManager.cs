using System.IO;
using System.Text.Json;

namespace PerfMonCS;

public record AppSettings(double? X, double? Y, double? W, double? H, double? Opacity, int? Layout = null);

public static class SettingsManager
{
    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "PerfMonCS", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            var json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<AppSettings>(json)
                   ?? new AppSettings(null, null, null, null, null, null);
        }
        catch { return new AppSettings(null, null, null, null, null, null); }
    }

    public static void Save(AppSettings s)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(s));
        }
        catch { }
    }
}
