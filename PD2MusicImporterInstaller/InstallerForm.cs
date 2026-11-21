using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace PD2MusicImporterInstaller;

internal sealed class InstallerForm : Form
{
    private const string RepoOwner = "ILOVEOGURI";
    private const string Repository = "Payday2-Music-Importer";
    private const string ModFolder = "PaydayMusicImporter";
    private const string PackageAsset = "PaydayMusicImporter.zip";
    private static readonly HttpClient Http = CreateHttpClient();
    private readonly TextBox _exePath = new() { Dock = DockStyle.Fill, ReadOnly = true };
    private readonly Label _status = new() { AutoSize = true, Text = "Choose your PAYDAY 2 installation." };
    private readonly ProgressBar _progress = new() { Dock = DockStyle.Fill, Style = ProgressBarStyle.Continuous };
    private readonly Button _detect = new() { Text = "Auto Detect", AutoSize = true };
    private readonly Button _browse = new() { Text = "Browse for PAYDAY2.exe", AutoSize = true };
    private readonly Button _install = new() { Text = "Install PAYDAY 2 Music Importer", AutoSize = true, Enabled = false };

    public InstallerForm()
    {
        Text = "PAYDAY 2 Music Importer Installer";
        Size = new Size(720, 300);
        MinimumSize = new Size(620, 270);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10F);

        var title = new Label { Text = "Install PAYDAY 2 Music Importer", AutoSize = true, Font = new Font("Segoe UI Semibold", 16F) };
        var intro = new Label { Text = "Select your PAYDAY 2 game. The installer downloads the latest stable version from GitHub.", AutoSize = true };
        var chooseButtons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 8, 0, 8) };
        chooseButtons.Controls.Add(_detect);
        chooseButtons.Controls.Add(_browse);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 2, RowCount = 6 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(title, 0, 0);
        layout.SetColumnSpan(title, 2);
        layout.Controls.Add(intro, 0, 1);
        layout.SetColumnSpan(intro, 2);
        layout.Controls.Add(new Label { Text = "PAYDAY2.exe", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
        layout.Controls.Add(_exePath, 1, 2);
        layout.Controls.Add(chooseButtons, 0, 3);
        layout.SetColumnSpan(chooseButtons, 2);
        layout.Controls.Add(_status, 0, 4);
        layout.SetColumnSpan(_status, 2);
        layout.Controls.Add(_progress, 0, 5);
        layout.Controls.Add(_install, 1, 5);
        Controls.Add(layout);

        _detect.Click += (_, _) => DetectGame(showMessage: true);
        _browse.Click += (_, _) => BrowseGame();
        _install.Click += InstallClickedAsync;
        Shown += (_, _) => DetectGame(showMessage: false);
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("PD2MusicImporterInstaller", "1.0"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private void DetectGame(bool showMessage)
    {
        var found = FindGameExecutable();
        SetGameExecutable(found);
        if (found is not null)
            _status.Text = "PAYDAY 2 was found. You can install the mod.";
        else
        {
            _status.Text = "Could not find PAYDAY 2. Use Browse for PAYDAY2.exe.";
            if (showMessage)
                MessageBox.Show(this, "PAYDAY 2 was not found in the Steam libraries we checked. Select Browse for PAYDAY2.exe to choose it manually.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    private void BrowseGame()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Select PAYDAY2.exe",
            Filter = "PAYDAY 2 executable (PAYDAY2.exe)|PAYDAY2.exe|Executable files (*.exe)|*.exe",
            CheckFileExists = true,
            Multiselect = false
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
            return;
        if (!IsValidGameExecutable(dialog.FileName))
        {
            MessageBox.Show(this, "Select PAYDAY2.exe from the PAYDAY 2 game folder.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        SetGameExecutable(Path.GetFullPath(dialog.FileName));
        _status.Text = "Game selected. You can install the mod.";
    }

    private void SetGameExecutable(string? path)
    {
        _exePath.Text = path ?? string.Empty;
        _install.Enabled = path is not null && IsValidGameExecutable(path);
    }

    private async void InstallClickedAsync(object? sender, EventArgs e)
    {
        if (!IsValidGameExecutable(_exePath.Text))
        {
            MessageBox.Show(this, "Choose a valid PAYDAY2.exe first.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (Process.GetProcessesByName("PAYDAY2").Any())
        {
            MessageBox.Show(this, "Close PAYDAY 2 before installing or updating the mod, then try again.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        var gameRoot = Path.GetDirectoryName(Path.GetFullPath(_exePath.Text))!;
        string? downloadPath = null;
        SetBusy(true);
        try
        {
            _status.Text = "Checking the latest GitHub release…";
            var packageUrl = await GetLatestPackageUrlAsync();
            downloadPath = Path.Combine(Path.GetTempPath(), $"PD2MusicImporter-{Guid.NewGuid():N}.zip");
            _status.Text = "Downloading the mod package…";
            await DownloadAsync(packageUrl, downloadPath);
            _status.Text = "Installing the mod…";
            var result = await Task.Run(() => InstallPackage(downloadPath, gameRoot));
            SaveGameRoot(gameRoot);
            _progress.Value = 100;

            var message = $"PAYDAY 2 Music Importer 1.0 is installed in:\n{result.InstallPath}";
            if (result.BackupPath is not null)
                message += $"\n\nYour previous installation was backed up to:\n{result.BackupPath}";
            var missing = GetMissingPrerequisites(gameRoot);
            if (missing.Count > 0)
            {
                message += "\n\nBefore using the mod, install:\n" + string.Join("\n", missing);
                message += "\n\nSuperBLT: https://superblt.znix.xyz/\nBeardLib: https://modworkshop.net/mod/14924";
                _status.Text = "Installed. Prerequisites are needed before use.";
                MessageBox.Show(this, message, "Installed — prerequisites needed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            else
            {
                message += "\n\nStart PAYDAY 2. The mod will open its PowerShell helper automatically.";
                _status.Text = "Installation complete.";
                MessageBox.Show(this, message, "Installation complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        catch (Exception ex)
        {
            _status.Text = "Installation failed.";
            MessageBox.Show(this, ex.Message, "Could not install the mod", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            if (downloadPath is not null)
            {
                try { File.Delete(downloadPath); } catch { }
            }
            SetBusy(false);
        }
    }

    private void SetBusy(bool busy)
    {
        _detect.Enabled = !busy;
        _browse.Enabled = !busy;
        _install.Enabled = !busy && IsValidGameExecutable(_exePath.Text);
        _progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
        if (!busy && _progress.Value != 100)
            _progress.Value = 0;
    }

    private static async Task<string> GetLatestPackageUrlAsync()
    {
        var endpoint = $"https://api.github.com/repos/{RepoOwner}/{Repository}/releases/latest";
        using var response = await Http.GetAsync(endpoint, HttpCompletionOption.ResponseHeadersRead);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"GitHub could not provide the latest release (HTTP {(int)response.StatusCode}). Check your connection or try again later.");
        await using var stream = await response.Content.ReadAsStreamAsync();
        using var document = await JsonDocument.ParseAsync(stream);
        if (!document.RootElement.TryGetProperty("assets", out var assets))
            throw new InvalidDataException("The GitHub release does not contain any downloadable assets yet.");
        foreach (var asset in assets.EnumerateArray())
        {
            if (asset.TryGetProperty("name", out var name) && name.GetString() == PackageAsset &&
                asset.TryGetProperty("browser_download_url", out var url))
                return url.GetString() ?? throw new InvalidDataException("The release package has no download URL.");
        }
        throw new InvalidDataException($"The latest GitHub release is missing {PackageAsset}.");
    }

    private async Task DownloadAsync(string url, string destination)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength;
        await using var input = await response.Content.ReadAsStreamAsync();
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
        var buffer = new byte[81920];
        long received = 0;
        int count;
        while ((count = await input.ReadAsync(buffer)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, count));
            received += count;
            if (total is > 0)
            {
                var percent = Math.Clamp((int)(received * 100 / total.Value), 0, 100);
                _progress.Style = ProgressBarStyle.Continuous;
                _progress.Value = percent;
                _status.Text = $"Downloading the mod package… {percent}%";
            }
        }
        await output.FlushAsync();
        if (received == 0)
            throw new InvalidDataException("GitHub returned an empty mod package.");
    }

    private static InstallResult InstallPackage(string zipPath, string gameRoot)
    {
        var modsRoot = Path.Combine(gameRoot, "mods");
        Directory.CreateDirectory(modsRoot);
        var target = Path.Combine(modsRoot, ModFolder);
        var stage = Path.Combine(modsRoot, $".{ModFolder}.installing-{Guid.NewGuid():N}");
        string? backup = null;
        Directory.CreateDirectory(stage);
        try
        {
            using (var archive = ZipFile.OpenRead(zipPath))
            {
                var names = archive.Entries.Select(e => e.FullName.Replace('\\', '/')).ToList();
                if (!names.Contains($"{ModFolder}/mod.txt", StringComparer.OrdinalIgnoreCase) ||
                    !names.Contains($"{ModFolder}/main.lua", StringComparer.OrdinalIgnoreCase) ||
                    !names.Contains($"{ModFolder}/Importer.ps1", StringComparer.OrdinalIgnoreCase))
                    throw new InvalidDataException("This is not a complete PAYDAY 2 Music Importer release package.");

                var stagePrefix = Path.GetFullPath(stage) + Path.DirectorySeparatorChar;
                foreach (var entry in archive.Entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    if (!name.StartsWith(ModFolder + "/", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The package contains files outside the expected mod folder.");
                    var relative = name[(ModFolder.Length + 1)..];
                    if (relative.Length == 0)
                        continue;
                    if (relative.Split('/').Any(segment => segment is "." or ".."))
                        throw new InvalidDataException("The package contains an unsafe relative path.");
                    var destination = Path.GetFullPath(Path.Combine(stage, ModFolder, relative.Replace('/', Path.DirectorySeparatorChar)));
                    if (!destination.StartsWith(stagePrefix, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The package contains an unsafe file path.");
                    if (name.EndsWith('/'))
                    {
                        Directory.CreateDirectory(destination);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    using var source = entry.Open();
                    using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    source.CopyTo(output);
                }
            }

            var stagedMod = Path.Combine(stage, ModFolder);
            if (!File.Exists(Path.Combine(stagedMod, "Start-Helper.cmd")))
                throw new InvalidDataException("The mod package is missing its PowerShell helper launcher.");
            var ready = Path.Combine(modsRoot, $".{ModFolder}.ready-{Guid.NewGuid():N}");
            Directory.Move(stagedMod, ready);
            Directory.Delete(stage, recursive: true);
            if (Directory.Exists(target))
            {
                backup = Path.Combine(modsRoot, $"{ModFolder}.backup-{DateTime.Now:yyyyMMdd-HHmmss}");
                if (Directory.Exists(backup))
                    backup += $"-{Guid.NewGuid():N}";
                Directory.Move(target, backup);
            }
            try
            {
                Directory.Move(ready, target);
            }
            catch
            {
                if (backup is not null && !Directory.Exists(target))
                    Directory.Move(backup, target);
                throw;
            }
            return new InstallResult(target, backup);
        }
        finally
        {
            if (Directory.Exists(stage))
                Directory.Delete(stage, recursive: true);
        }
    }

    private static void SaveGameRoot(string gameRoot)
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PD2MusicImporter");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "settings.json");
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(new { gameRoot }));
        File.Move(temp, path, overwrite: true);
    }

    private static List<string> GetMissingPrerequisites(string gameRoot)
    {
        var missing = new List<string>();
        var superBlt = File.Exists(Path.Combine(gameRoot, "WSOCK32.dll")) || File.Exists(Path.Combine(gameRoot, "IPHLPAPI.dll")) ||
                       File.Exists(Path.Combine(gameRoot, "mods", "base", "mod.txt"));
        if (!superBlt)
            missing.Add("SuperBLT");
        if (!File.Exists(Path.Combine(gameRoot, "mods", "BeardLib", "mod.txt")))
            missing.Add("BeardLib");
        return missing;
    }

    private static string? FindGameExecutable()
    {
        var libraries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var keyPath in new[] { @"HKEY_CURRENT_USER\Software\Valve\Steam", @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam" })
        {
            foreach (var valueName in new[] { "SteamPath", "InstallPath" })
            {
                var path = Registry.GetValue(keyPath, valueName, null) as string;
                if (!string.IsNullOrWhiteSpace(path) && Directory.Exists(path))
                    libraries.Add(path.Replace('/', '\\'));
            }
        }

        foreach (var steamRoot in libraries.ToArray())
        {
            var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf))
                continue;
            foreach (Match match in Regex.Matches(File.ReadAllText(vdf), "\\\"path\\\"\\s+\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase))
                libraries.Add(match.Groups[1].Value.Replace("\\\\", "\\"));
        }

        foreach (var library in libraries)
        {
            var candidate = Path.Combine(library, "steamapps", "common", "PAYDAY 2", "PAYDAY2.exe");
            if (IsValidGameExecutable(candidate))
                return Path.GetFullPath(candidate);
        }
        return null;
    }

    private static bool IsValidGameExecutable(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.GetFileName(path).Equals("PAYDAY2.exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
            return false;
        var root = Path.GetDirectoryName(Path.GetFullPath(path));
        return root is not null && Directory.Exists(Path.Combine(root, "assets"));
    }

    private sealed record InstallResult(string InstallPath, string? BackupPath);
}
