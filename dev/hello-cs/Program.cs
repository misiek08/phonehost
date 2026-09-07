using System.Globalization;
using System.Runtime.InteropServices;

const string PsDir = "/sys/class/power_supply/qcom_qg";

static string? Read(string name)
{
    var p = Path.Combine(PsDir, name);
    return File.Exists(p) ? File.ReadAllText(p).Trim() : null;
}

static double Num(string? s, double scale) =>
    s is null ? double.NaN : double.Parse(s, CultureInfo.InvariantCulture) / scale;

Console.WriteLine($"dotnet {Environment.Version} on {RuntimeInformation.RuntimeIdentifier}, {Environment.ProcessorCount} cores");

var cap = Read("capacity");
if (cap is null)
{
    Console.WriteLine("no battery sysfs found");
    return;
}

Console.WriteLine($"battery: {cap}%  {Num(Read("voltage_now"), 1e6):F3} V  " +
                  $"{Num(Read("current_now"), 1e6):F3} A  {Num(Read("temp"), 10):F1} C");
Console.WriteLine("(negative current = charging on this platform)");
