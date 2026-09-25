# nopcommerce-plugin-packager

Builds a [nopCommerce](https://www.nopcommerce.com/) plugin from a plugin repository and
produces a `.zip` that nopCommerce's admin will actually accept, verified before the build
reports success.

Nothing about a specific plugin is hardcoded. The plugin project, assembly name, plugin
folder, system name, target nopCommerce version and payload files are all discovered, so
the same tooling packages any nopCommerce plugin.

## Use it from a plugin repository

Add a five line workflow:

```yaml
# .github/workflows/package-plugin.yml
name: Package plugin
on: [push, pull_request, workflow_dispatch]

jobs:
  package:
    uses: BabuBahir/nopcommerce-plugin-packager/.github/workflows/pack-plugin.yml@v1
    with:
      nopcommerce-release: release-4.90.8
```

The workflow clones that nopCommerce release as a build dependency, builds the plugin,
packages it, verifies the archive and uploads it as a workflow artifact named
`plugin-package-<SystemName>`.

Pin `uses:` to a tag or a commit SHA rather than a branch, so a change here cannot silently
change the contents of somebody's release artifact.

### Inputs

| input | default | meaning |
|---|---|---|
| `nopcommerce-release` | `release-4.90.8` | nopCommerce release tag to build against |
| `nopcommerce-repository` | `nopSolutions/nopCommerce` | repository to clone from |
| `packager-ref` | `v1` | reference of this repository to run |
| `artifact-name` | derived | artifact name override |
| `artifact-retention-days` | `30` | artifact retention |

### Outputs

`system-name`, `nopcommerce-version` and `plugin-version` from the package metadata.

## Use it locally

You need a nopCommerce source tree. Clone this repository, then point the script at your
plugin repository:

```powershell
git clone --depth 1 -b release-4.90.8 https://github.com/nopSolutions/nopCommerce.git

.\build\Build-PluginPackage.ps1 `
    -RepoRoot        D:\path\to\your-plugin-repo `
    -NopCommerceSrc  D:\path\to\nopCommerce `
    -OutputZip       D:\path\to\output\plugin-package.zip
```

It runs the same code path as CI, and writes a `<zip>.json` sidecar with the system name,
versions, entry count and sha256.

| switch | effect |
|---|---|
| `-PackageLayout Single` | force a single-root archive instead of a marketplace package |
| `-PackageLayout Marketplace` | require `uploadedItems.json` |
| `-SkipBuild` | package the existing build output |
| `-VerifyOnly` | re-check an archive, needs no nopCommerce tree |
| `-NopCommerceVersion` | override the version read from the tree's `NopVersion.cs` |
| `-ProjectPath` | override project discovery |

## Two package layouts

**Marketplace** (chosen when the repository has an `uploadedItems.json`) stages binaries and
sources at exactly the paths the manifest declares, and ships the manifest unchanged.
Multi-version manifests are fine: nopCommerce skips the versions it cannot use.

**Single** (chosen otherwise) produces an archive with exactly one root directory, named
after the plugin's system name, holding the build output. nopCommerce's
`UploadSingleItemAsync` rejects an archive with more than one root entry, so no README or
LICENSE is added at the root.

## What the script protects you from

* **`0 plugins and 0 themes have been uploaded`.** nopCommerce matches `entry.FullName`
  against forward-slash literals. `Compress-Archive` on Windows PowerShell 5.1 stores
  backslash separated names, so such an archive uploads as zero plugins. The script writes
  forward slashes and fails if any backslash entry name is present.
* **A reference assembly in the package.** A .NET reference assembly has no method bodies,
  so the plugin installs and then fails. Roslyn emits one beside the real output under
  `obj\<Config>\<tfm>\ref\`. The script refuses to package one.
* **A build that silently did nothing.** The plugin csproj references
  `$(SolutionDir)\Presentation\Nop.Web\Nop.Web.csproj`; outside the solution that variable
  is empty and the build fails with ~61 `CS0246` errors. The script passes `-p:SolutionDir`
  explicitly.
* **4 MB of the wrong files.** The build output folder also receives the referenced
  `Nop.Web` project's output. The payload is the project's own `<Content Include>` items
  plus the assembly, so nothing else can ship.
* **A wrong-SDK build.** The SDK is taken from the nopCommerce tree's own `global.json`.

The final step replays nopCommerce's upload logic against the finished archive, so a
package that would report zero plugins fails the build instead of failing in the admin.

## Mirroring from a nopCommerce source tree

If you develop inside a nopCommerce clone and release from a standalone repository:

```powershell
.\build\Sync-Plugin.ps1 -NopCommerceSrc D:\path\to\nopCommerce -RepoRoot D:\path\to\your-plugin-repo
.\build\Sync-Plugin.ps1 -NopCommerceSrc D:\path\to\nopCommerce -RepoRoot D:\path\to\your-plugin-repo -Check
```

`-Check` writes nothing and exits 1 on drift, so it works as a CI guard.

## Requirements

Windows PowerShell 5.1 or PowerShell 7, and the .NET SDK required by the nopCommerce
release you are building against. nopCommerce plugin branches that target .NET Framework
rather than .NET need msbuild and Windows.

## License

MIT. See [LICENSE](LICENSE).
