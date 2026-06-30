using Microsoft.Win32;

namespace PerfMonCS;

public static class AutoStartHelper
{
    private const string RegKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "PerfMonCS";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RegKey, false);
        return key?.GetValue(AppName) is not null;
    }

    public static void Set(bool enable)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RegKey, true);
        if (key is null) return;
        if (enable)
            key.SetValue(AppName, $"\"{Environment.ProcessPath}\"");
        else
            key.DeleteValue(AppName, throwOnMissingValue: false);
    }
}
