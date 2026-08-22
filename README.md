# Pawxy

Pawxy is a native macOS utility for managing local development domains with
[dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html). It discovers existing
mappings, keeps macOS resolvers in sync, safely applies configuration changes,
restarts dnsmasq, and verifies that hostnames actually resolve.

The goal is simple: make local DNS feel like an application feature instead of
a collection of shell commands and configuration files.

> [!IMPORTANT]
> Pawxy is an early-stage project. Public builds are ad-hoc signed and are not
> notarized because the project does not currently use a paid Apple Developer
> account. See [Installing a release](#installing-a-release) for the first-run
> Gatekeeper step.

## Why Pawxy?

A local hostname normally involves several pieces that are easy to leave out of
sync:

- a valid dnsmasq directive;
- an appropriate file under `/etc/resolver`;
- a dnsmasq configuration check;
- a service restart;
- and a final resolution test through both dnsmasq and macOS.

Pawxy treats those pieces as one operation. Changes are validated, backed up,
applied through a constrained privileged helper, and followed by a service
restart when required.

## Use cases

### Give a project a stable local hostname

Map a name such as `storefront.test` to `127.0.0.1` and use it in browsers,
reverse proxies, local HTTPS certificates, callbacks, and development scripts.

### Route a domain and all of its subdomains

Create a DNS zone for a project that needs names such as `api.storefront.test`,
`admin.storefront.test`, or tenant-specific subdomains without maintaining each
record separately.

### Manage an existing dnsmasq setup

Pawxy reads supported `address` and `host-record` directives from existing
Homebrew dnsmasq configuration files. The files remain the source of truth, and
the app records the source file and line for every discovered mapping.

### Diagnose a mapping that looks correct but does not resolve

Run a per-domain test against dnsmasq and the macOS system resolver. Pawxy can
distinguish between a missing DNS answer, an incorrect address, a missing
resolver file, and a `.local` Bonjour conflict.

### Move configuration between Macs

Export a versioned JSON backup containing domains, addresses, coverage, and
enabled state. Importing reviews the mappings, skips conflicts, and creates one
managed `.conf` file per new domain.

## Features

- Automatic discovery of Homebrew on Apple Silicon and Intel Macs.
- Automatic discovery of existing dnsmasq mappings.
- One readable dnsmasq configuration file per Pawxy-managed domain.
- Exact-domain and domain-plus-subdomains coverage.
- Managed `/etc/resolver` entries for enabled domains.
- Enable, disable, edit, and delete operations that update the real dnsmasq
  configuration.
- Full configuration validation before dnsmasq is restarted.
- Per-domain resolution health checks.
- Finder access to the source configuration file.
- Portable JSON backup and restore.
- Native English and Italian localizations using Xcode String Catalogs.
- Sparkle updates distributed through GitHub Releases and verified with EdDSA.

## Requirements

- macOS 26.5 or later.
- [Homebrew](https://brew.sh).
- dnsmasq installed through Homebrew.

Install dnsmasq with:

```sh
brew install dnsmasq
```

Pawxy detects both `/opt/homebrew` and `/usr/local` installations.

## Installing a release

1. Download `Pawxy-<version>.zip` from
   [GitHub Releases](https://github.com/dreamwhite/Pawxy/releases).
2. Extract the archive and move `Pawxy.app` to `/Applications`.
3. Open the app once.
4. If macOS blocks the launch, open **System Settings → Privacy & Security** and
   choose **Open Anyway** for Pawxy.
5. Approve Pawxy under **General → Login Items & Extensions** when macOS asks to
   enable its privileged helper.

The manual Gatekeeper step is required only because current builds do not carry
a notarized Developer ID signature. Sparkle still verifies subsequent update
archives using the public EdDSA key embedded in the app.

## Getting started

### Existing mappings

Open **Local Domains** and choose **Refresh**. Pawxy scans the active dnsmasq
configuration and shows supported mappings together with their address, source,
coverage, state, and resolution health.

### Add a domain

Choose **Add domain** or press <kbd>⌘</kbd><kbd>N</kbd>, then provide:

- the development domain;
- its IPv4 address;
- exact-domain or subdomain coverage;
- and its initial enabled state.

For a zone named `storefront.test`, Pawxy writes a dnsmasq-compatible directive:

```ini
address=/storefront.test/127.0.0.1
```

It also creates the corresponding macOS resolver, validates the complete
configuration, and restarts dnsmasq.

### Test a domain

Use the **Test** control on a domain row. The result reports whether dnsmasq and
macOS agree on the expected address. When only the system resolver is missing,
the domain menu offers **Repair system resolver**.

### Back up configuration

Use **Backup → Export Backup** to create a portable `.pawxy.json` file. Importing
a backup always presents its contents before making changes.

## How configuration is managed

Pawxy-managed mappings are stored in the Homebrew dnsmasq configuration
directory using descriptive filenames. Pre-existing third-party files retain
their original directive style and surrounding content.

For protected changes, the app performs this sequence:

1. build a typed file transaction;
2. validate every destination against an allowlist;
3. create rollback backups;
4. write or remove the requested dnsmasq and resolver files;
5. run `dnsmasq --test` against the complete configuration;
6. restore the previous files if validation fails;
7. restart the Homebrew dnsmasq service after a successful change.

## Security model

Pawxy uses a LaunchDaemon registered through `SMAppService` and communicates
with it over XPC. The helper:

- accepts structured Pawxy operations rather than arbitrary shell commands;
- verifies the connecting application;
- permits only supported Homebrew dnsmasq and `/etc/resolver` paths;
- restricts the number and size of files in a transaction;
- and validates dnsmasq before completing a change.

Ad-hoc signing is suitable for the current community and personal distribution
model, but it does not provide the first-launch experience of a notarized
Developer ID build.

## Build from source

Clone the repository and open `Pawxy.xcodeproj` in Xcode. Swift Package Manager
resolves Sparkle automatically.

```sh
git clone https://github.com/dreamwhite/Pawxy.git
cd Pawxy
xcodebuild \
  -project Pawxy.xcodeproj \
  -scheme Pawxy \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Run the unit tests with:

```sh
xcodebuild \
  -project Pawxy.xcodeproj \
  -scheme Pawxy \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PawxyTests \
  test
```

The privileged helper needs macOS approval before a development build can make
protected DNS changes. Read-only discovery and the Swift test suite do not
modify the system configuration.

## Updates and releases

Pawxy uses [Sparkle](https://sparkle-project.org) for in-app updates. A tagged
release triggers the GitHub Actions workflow, which builds a universal macOS
application, creates the ZIP archive, signs its appcast entry, and publishes the
release assets.

Maintainer instructions are available in
[Docs/RELEASING.md](Docs/RELEASING.md).

## Contributing

Issues and focused pull requests are welcome. Before submitting a change:

1. explain the dnsmasq or macOS behavior being addressed;
2. keep privileged operations narrowly scoped;
3. add or update tests for configuration parsing and file transactions;
4. update both English and Italian String Catalog entries for user-facing text;
5. verify that the app builds and the `PawxyTests` suite passes.

Please avoid including private domains, resolver files, signing keys, exported
Sparkle keys, or machine-specific Xcode data in commits.

## Acknowledgements

Pawxy builds on [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html),
[Homebrew](https://brew.sh), and [Sparkle](https://sparkle-project.org).
