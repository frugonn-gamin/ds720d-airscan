# AirScan bridge for the Brother DS-720D

**English summary.** Makes the USB sheet-fed **Brother DS-720D** scanner (an Avision/Novatek OEM device) work **natively on modern macOS** as an AirScan/eSCL scanner. It appears in Image Capture, Preview and the system scanning stack, just like a network scanner. Brother's driver needs an x86 kernel extension plus a TWAIN data source, and is unusable on Apple Silicon with macOS 26. This project replaces it with:

- a reverse-engineered implementation of the scanner protocol: Novatek "MsdcNvt" vendor commands tunnelling Avision SCSI commands over USB Bulk-Only Transport;
- a tiny root USB helper started from the user session (required by macOS's *Removable Volumes* privacy rule for mass-storage-class devices);
- an eSCL server with Bonjour announcement.

It supports colour, grayscale and B&W output, 150–600 dpi, duplex scanning and automatic paper cropping. No kext, no Rosetta: universal (arm64 + x86_64) binaries for macOS 11 and later. See [`docs/PROTOCOLE.md`](docs/PROTOCOLE.md) for the protocol notes.

> **Disclaimer:** independent project, not affiliated with or endorsed by Brother Industries or Avision. "Brother" and "DS-720D" are trademarks of their respective owners. The protocol was reverse-engineered for interoperability purposes only. No vendor code or file is included. Use at your own risk.

---

Makes the Brother DS-720D (an Avision/Novatek sheet-fed scanner, connected over USB) usable natively by macOS as an **AirScan** (eSCL) scanner. It shows up in Image Capture and Preview, like a network scanner. No kernel extension (kext), no Rosetta; universal binaries (Apple Silicon and Intel), macOS 11 or later.

## Installation

Download `DS720D-AirScan-x.y.z.pkg` from the project's [Releases](../../releases) page.

1. Double-click `DS720D-AirScan-1.1.0.pkg`, then enter your password.
   - If you get the "unidentified developer" warning: right-click the file, then **Open**.
   - From Terminal instead: `sudo installer -pkg DS720D-AirScan-1.1.0.pkg -target /`.
2. Unplug the scanner, then plug it back in.
3. If macOS asks to allow **ds720d-agent** to access **removable volumes**, click **Allow**.
4. In Image Capture, **Brother DS-720D** appears. Slide in a sheet, then scan.

**Uninstall:** `sudo /usr/local/libexec/ds720d/uninstall.sh`.

## Architecture

| Component | Location | Runs as | Role |
|---|---|---|---|
| `ds720d-agent` | `/usr/local/libexec/ds720d/`, LaunchAgent `local.ds720d.agent` | the logged-in user | Launches (and relaunches) the USB daemon from the user's session |
| `local.ds720d.usbd` | `/Library/PrivilegedHelperTools/` | root, through `sudo -n` | Takes the scanner over from the system disk driver (`USBDeviceReEnumerate` with capture), handles Bulk-Only transport, exposes a Unix socket |
| sudo rule | `/etc/sudoers.d/ds720d` | none | `%staff ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/local.ds720d.usbd -g staff` (that command only) |
| `ds720d-airscan` | `/usr/local/libexec/ds720d/`, LaunchDaemon `local.ds720d.airscan` | `nobody:staff` | Novatek/Avision protocol, image processing (ColorSync/ImageIO), eSCL server, Bonjour announcement `_uscan._tcp` (this Mac only by default; add `--lan` to share on the network) |

**Logs:**
- `~/Library/Logs/ds720d-usbd.log` (agent and USB daemon);
- `/var/log/ds720d-airscan.log` (AirScan server).

### Why a session agent and a sudo rule?

macOS (Sequoia/Tahoe) treats raw USB access to a "mass storage" class device as access to a **removable volume**.

- **The permission.** Opening the scanner's USB interface triggers a privacy check (`kTCCServiceSystemPolicyRemovableVolumes`).
- **Who can get it.** The decision can only be made for a program started from the user's session. Root services (LaunchDaemons) get a silent refusal (`missing 'auth_value'`) and `deny iokit-open-service IOUSBHostInterface`, even with "Full Disk Access".
- **Why root is still needed.** Taking the scanner over from the disk driver requires capture, which requires root (or an entitlement Apple doesn't grant).

So the root daemon is launched **by an agent in the session**: macOS attributes its USB accesses to that agent and can ask the user for permission.

The sudo rule only authorizes this exact command line. Before installing it, the installer checks that the binary and all its parent folders belong to root and are not writable by anyone else, then validates it with `visudo`.

## Development

- `usbd/`: USB daemon (Objective-C, IOKit).
- `airscan/`: AirScan server (Swift).
- `agent/`: session agent (C).
- `pkg/build-pkg.sh`: builds the universal package.
- `py/`: Python prototypes used for reverse engineering and testing (USB link probe, first eSCL server).
- `tools/icbrowse.swift`: lists the scanners ImageCaptureCore sees and runs a test scan.
- `docs/PROTOCOLE.md`: the reverse-engineered protocol.

## License

MIT — see [LICENSE](LICENSE).
