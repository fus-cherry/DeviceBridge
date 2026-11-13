# HDC tool management (0.1.8 candidate)

This release does not bundle or redistribute Huawei's SDK. It never changes the system PATH, shell profile, existing SDK or HDC server. Actual HarmonyOS hardware remains unverified.

## Configure an existing official toolchain

Open Settings → HDC Manager (or HDC tools in the workspace). Discover known DevEco Studio installations, or select an `hdc` executable / SDK directory. Both `HarmonyOS/toolchains` and the older `openharmony/toolchains` layouts are searched. Static inspection checks a macOS Mach-O executable, native CPU support and local linked libraries, including declared `LC_RPATH` paths. It is not a publisher-signature guarantee.

Use **Import directory** to copy an unpacked official toolchain and its sibling dependencies into the application's private support directory. Imports reject symlinks and special files, and are limited to 10,000 entries, 128 MiB per file and 1 GiB total. Keep the original SDK; do not copy only `hdc` without its libraries. Import is not activation or execution. An archive must first be obtained and unpacked using the official Huawei flow.

Enable a checked tool explicitly. This authorizes subsequent device discovery to run that tool. Checking `hdc -v` has its own execution confirmation. No quarantine flags or macOS security prompts are removed or bypassed. Changing a tool invalidates pending discovery and HarmonyOS operations; reconnect the HarmonyOS device. A previous selection can be restored, and clearing selection restores ordinary automatic discovery.

The client version is obtained only by an explicit `hdc -v` check. This is not the server version or a connection check: `hdc version` and `hdc checkserver` are not run by this settings action. A known client/server version mismatch from ordinary device discovery is reported without automatically stopping or replacing an existing server. A detected transport is not proof that every device feature or permission is available.

## Download sources and speed tests

The built-in Huawei entry opens the official browser download page for SDK, architecture selection, login and terms as required. It is not falsely presented as an unauthenticated archive mirror. No third-party source is pre-endorsed and no downloaded program is automatically executed.

Custom public HTTPS sources are saved with an exact declared package version and CPU architecture. Optional SHA-256 metadata is only **provided**, not proof that an archive was verified or is safe. In this iteration full package downloads are handled by the browser, then an official unpacked directory may be imported. DeviceBridge never auto-extracts an arbitrary network archive.

Only matching declared version/architecture sources are speed-tested. The default sample is 256 KiB, up to four seconds, with at most two concurrent probes (hard ceilings: 1 MiB, 15 seconds, four concurrent probes). The source must honor an uncompressed HTTP Range response. Unsupported Range, authentication, timeout, invalid range, extra data and insecure redirects produce explicit results rather than an uncontrolled full download. Byte ceilings apply to bytes accepted as a sample. They are not a claim that a server, URLSession or the network stack cannot prefetch or queue extra bytes before cancellation reaches it; rejected and late bytes are not retained as an archive. Ranking uses measured throughput, not trust. Cookies, saved HTTP credentials and cache are not used. Literal local/private addresses are refused; this is not a universal DNS-rebinding defense. No device data is sent to a download source.

Speed is a small-sample estimate including connection latency, not a guarantee of a complete archive's sustained rate. Results carry sample size, time and failure reason and are not persisted as permanent trust.

## Verification boundary

Cloud Swift checks run real production core sources using injected tools/network fixtures and a Linux compatibility harness. macOS XCTest covers settings paths, native file selection, static inspection, import, explicit execution consent, persistence, rollback, custom-source errors, bounded-probe ranking/cancellation and Chinese UI. These fixture checks do not establish Huawei SDK compatibility or real-device behavior.

Apple Developer ID signing and notarization are separate CI jobs; see `apple-signing.md`. Secrets existing does not mean signing or notarization succeeded. Only an accepted, stapled and verified output may be labeled notarized.

Official references:
- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/hdc/
- https://developer.huawei.com/consumer/cn/deveco-studio/resources/
- https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos
