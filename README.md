# PAYDAY 2 Music Importer

PAYDAY 2 Music Importer is a free, open-source PAYDAY 2 mod for Windows. The game mod adds an in-game YouTube music importer. A PowerShell helper downloads and converts audio, and the installer makes setup accessible for players who have not installed PAYDAY 2 mods before.

## Install

1. Download `PD2MusicImporterInstaller.exe` from the [latest GitHub release](https://github.com/ILOVEOGURI/Payday2-Music-Importer/releases/latest).
2. Run it. Choose **Auto Detect** or **Browse for PAYDAY2.exe**, then click **Install PAYDAY 2 Music Importer**.
3. If SuperBLT or BeardLib is missing, follow the links shown by the installer.
4. Start PAYDAY 2. The mod opens its visible PowerShell helper automatically.
5. Open **Options → PAYDAY 2 Music Importer** and choose **Open YouTube picker**.

The installer downloads the stable mod ZIP from GitHub Releases. It validates the game folder and package, keeps a backup when updating, and stores the selected game path for the helper. It does not install SuperBLT or BeardLib.

## Requirements

- PAYDAY 2 for Windows
- Steam
- SuperBLT
- BeardLib
- Internet access for the installer, YouTube, and first-run browser/tool setup

See [`PaydayMusicImporter/README.md`](PaydayMusicImporter/README.md) for the mod's features, setup, and troubleshooting. The mod stays at version **1.0** until its author chooses to make a 2.0 release.

## Build the installer

With the .NET 8 SDK on Windows, run:

```powershell
dotnet publish .\PD2MusicImporterInstaller\PD2MusicImporterInstaller.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\artifacts\installer
```

Run the package installation checks with `dotnet run --project .\PD2MusicImporterInstaller.Tests\PD2MusicImporterInstaller.Tests.csproj -c Release`.

The `v1.0` GitHub Actions workflow builds the standalone installer, packages the mod ZIP, and attaches both to the GitHub Release.

## License

The importer and installer source are released under the MIT License. The bundled InlineInput library retains its own MIT license and attribution. Chromium and audio tools are downloaded from their upstream sources and are not included in the repository.
