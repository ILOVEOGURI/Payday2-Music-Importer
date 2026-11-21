using System.IO.Compression;
using System.Reflection;

var tempRoot = Path.Combine(Path.GetTempPath(), $"PD2MI-installer-tests-{Guid.NewGuid():N}");
Directory.CreateDirectory(tempRoot);
try
{
    var gameRoot = Path.Combine(tempRoot, "PAYDAY 2");
    Directory.CreateDirectory(Path.Combine(gameRoot, "assets"));
    var zip = Path.Combine(tempRoot, "package.zip");
    CreatePackage(zip, includeTraversal: false, payload: "new-install");

    var first = Install(zip, gameRoot);
    var installPath = GetProperty(first, "InstallPath")!;
    Assert(File.Exists(Path.Combine(installPath, "mod.txt")), "Successful install should contain mod.txt.");
    Assert(File.ReadAllText(Path.Combine(installPath, "main.lua")) == "new-install", "Successful install should extract the new package.");

    File.WriteAllText(Path.Combine(installPath, "local-marker.txt"), "previous-install");
    CreatePackage(zip, includeTraversal: false, payload: "updated-install");
    var second = Install(zip, gameRoot);
    var backupPath = GetProperty(second, "BackupPath") as string;
    Assert(backupPath is not null && File.Exists(Path.Combine(backupPath, "local-marker.txt")), "Updating should preserve the previous install as a backup.");
    Assert(File.ReadAllText(Path.Combine(installPath, "main.lua")) == "updated-install", "Update should replace the installed package.");

    CreatePackage(zip, includeTraversal: false, payload: "", omitRequiredFile: true);
    AssertThrows<InvalidDataException>(() => Install(zip, gameRoot), "Incomplete package should be rejected.");
    Assert(File.ReadAllText(Path.Combine(installPath, "main.lua")) == "updated-install", "Invalid package must leave the installed mod unchanged.");

    CreatePackage(zip, includeTraversal: true, payload: "", omitRequiredFile: false);
    AssertThrows<InvalidDataException>(() => Install(zip, Path.Combine(tempRoot, "Unsafe game")), "Path traversal should be rejected.");
    Assert(!File.Exists(Path.Combine(tempRoot, "escape.txt")), "Unsafe package must not write outside its staging directory.");

    Console.WriteLine("Installer package tests passed: install, backup/update, invalid ZIP, and unsafe path.");
}
finally
{
    if (Directory.Exists(tempRoot))
        Directory.Delete(tempRoot, recursive: true);
}

static object Install(string zipPath, string gameRoot)
{
    var assembly = Assembly.Load("PD2MusicImporterInstaller");
    var formType = assembly.GetType("PD2MusicImporterInstaller.InstallerForm", throwOnError: true)!;
    var method = formType.GetMethod("InstallPackage", BindingFlags.Static | BindingFlags.NonPublic)!;
    try
    {
        return method.Invoke(null, new object[] { zipPath, gameRoot })!;
    }
    catch (TargetInvocationException ex) when (ex.InnerException is not null)
    {
        throw ex.InnerException;
    }
}

static string? GetProperty(object value, string name) => value.GetType().GetProperty(name)!.GetValue(value)?.ToString();

static void CreatePackage(string zipPath, bool includeTraversal, string payload, bool omitRequiredFile = false)
{
    if (File.Exists(zipPath))
        File.Delete(zipPath);
    using var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create);
    Add("PaydayMusicImporter/mod.txt", "{}");
    Add("PaydayMusicImporter/main.lua", payload);
    if (!omitRequiredFile)
        Add("PaydayMusicImporter/Importer.ps1", "# helper");
    Add("PaydayMusicImporter/Start-Helper.cmd", "@echo off");
    if (includeTraversal)
        Add("PaydayMusicImporter/../escape.txt", "unsafe");

    void Add(string path, string contents)
    {
        var entry = archive.CreateEntry(path);
        using var writer = new StreamWriter(entry.Open());
        writer.Write(contents);
    }
}

static void Assert(bool condition, string message)
{
    if (!condition)
        throw new InvalidOperationException(message);
}

static void AssertThrows<T>(Action action, string message) where T : Exception
{
    try
    {
        action();
    }
    catch (T)
    {
        return;
    }
    throw new InvalidOperationException(message);
}
