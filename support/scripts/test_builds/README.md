# Android and Windows test builds

The `Android and Windows test builds` GitHub Actions workflow creates two test
artifacts without production signing credentials or store publication:

- `LocalSend-Test-Android`: a universal debug APK, signature/metadata checks,
  source commit, license, and SHA-256 checksum. The app is named **LocalSend Debug**
  and has the separate ID `org.localsend.localsend_app.debug`.
- `LocalSend-Test-Windows-x64`: an unsigned portable release ZIP containing the
  executable, every required DLL, Flutter assets, portable settings, license,
  build metadata, and checksum. The optional MSIX share-target integration is
  excluded from this portable package.

The workflow runs on pushes to `codex/localsend-test-builds`, or through
`workflow_dispatch` once the workflow is available
on the repository's default branch. It uses the Flutter and Rust versions pinned
by this checkout. Artifacts are retained for 30 days.

Manual dispatch can select one platform or both. On this dedicated test branch,
a commit message containing `[windows-only]` or `[android-only]` selects that
platform for a helper-only fix. Omit these markers after shared app/source changes.
The platforms queue independently so fixing one does not cancel the other.

## Download and test

Open the completed workflow run in the fork's Actions tab, then download its
Android and Windows artifacts. Build checks establish package structure and
signing/architecture properties; they do not establish device interoperability.

1. Install the Android test APK. It can coexist with the official app, but close
   the official app before testing to avoid competing for the default port.
2. Extract the complete Windows portable ZIP to a writable directory. Open
   `localsend_app.exe` there; do not move the EXE away from its DLLs and `data/`.
3. Connect both devices to the same local network and allow the application's
   requested local-network access. Guest-network isolation can prevent discovery.
4. Send a small text file in both directions and verify its contents. Then test
   an image, a folder, rejecting a transfer, and cancelling an in-progress send.
5. Keep the source commit and build metadata when reporting a failure.

Windows may show an unknown-publisher/reputation prompt because the test package
is unsigned. Android uses a development signing key; these artifacts are not
store releases. Each fresh runner can generate a different Android debug key,
so installing a later test build may require uninstalling the previous debug
app (which clears that debug app's settings).

## Local commands

Use a Linux build host with Android SDK/NDK and JDK 17 for Android:

```sh
bash support/scripts/test_builds/android.sh /absolute/output/android
```

Use a Windows x64 build host with Visual Studio C++ and the Windows SDK:

```powershell
./support/scripts/test_builds/windows.ps1 -RepoRoot C:\src\localsend -OutputDirectory C:\builds\localsend
```

Both helpers default to FVM. CI installs the exact Flutter pin and explicitly
selects that `flutter` command. The Android helper reads `FLUTTER_COMMAND`; the
Windows helper accepts `-FlutterCommand flutter`.
