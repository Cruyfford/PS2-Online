#!/usr/bin/env python3
"""Lays PS2 Online's netplay over an ARMSX2 checkout.

    python3 ios/apply.py <armsx2-dir>

Copies ios/overlay/ into the tree, then makes the few edits ARMSX2's own files need. Each edit
names the exact text it expects, so a newer ARMSX2 that moved it fails here, loudly, instead of
building something half-patched.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(sys.argv[1])


def edit(rel, old, new, count=1):
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as f:
        s = f.read()
    n = s.count(old)
    if n != count:
        sys.exit(f"apply.py: {rel}: expected {count} match(es), found {n}:\n{old}")
    s = s.replace(old, new)
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"patched {rel}")


# 1) New files
overlay = os.path.join(HERE, "overlay")
for base, _, files in os.walk(overlay):
    for name in files:
        src = os.path.join(base, name)
        dst = os.path.join(ROOT, os.path.relpath(src, overlay))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        print(f"added {os.path.relpath(dst, ROOT)}")

# 2) Core: build the netplay hook
edit("pcsx2/CMakeLists.txt", "\tVMManager.cpp\n", "\tVMManager.cpp\n\tNetplay.cpp\n")
edit("pcsx2/CMakeLists.txt", "\tVMManager.h\n", "\tVMManager.h\n\tNetplay.h\n")

# 3) Core: the hooks around the frame's pad poll, and the settings netplay pins
edit("pcsx2/VMManager.cpp", '#include "Achievements.h"\n', '#include "Achievements.h"\n#include "Netplay.h"\n')
edit("pcsx2/VMManager.cpp",
     "\tHost::PumpMessagesOnCPUThread();\n\tInputManager::PollSources();\n",
     "\tNetplay::PreInput();\n\tHost::PumpMessagesOnCPUThread();\n\tInputManager::PollSources();\n")
edit("pcsx2/VMManager.cpp",
     "\tAutosave::OnPollInput();\n",
     "\tAutosave::OnPollInput();\n\tNetplay::PostInput();\n")
edit("pcsx2/VMManager.cpp",
     "\tif (Arcade::IsActive())\n\t\tApplyArcadeSessionSettings(si);\n}\n",
     "\tif (Arcade::IsActive())\n\t\tApplyArcadeSessionSettings(si);\n\n\tNetplay::ApplyConfigOverrides(EmuConfig);\n}\n")

# 4) iOS: on-screen pad goes through the netplay staging while a session runs
inp = "platforms/ios/Bridge/ARMSX2Bridge+Input.mm"
edit(inp, '#include "SIO/Pad/PadDualshock2.h"\n', '#include "SIO/Pad/PadDualshock2.h"\n#include "PS2NetplayPad.h"\n')
with open(os.path.join(ROOT, inp), encoding="utf-8") as f:
    n = f.read().count("pad->Set(")
if n < 3:
    sys.exit(f"apply.py: {inp}: expected pad->Set( calls, found {n}")
edit(inp, "pad->Set(", "PS2NetplayPadSet(pad, ", count=n)

# 5) iOS: Swift sees the bridge
edit("platforms/ios/Bridge/ARMSX2-Bridging-Header.h", '#import "ARMSX2Bridge.h"\n',
     '#import "ARMSX2Bridge.h"\n#import "PS2NetplayBridge.h"\n')

# 6) iOS: the online button / in-game netplay HUD over everything
edit("platforms/ios/Swift/App/RootView.swift",
     "    var body: some View {\n        jitAlertContent\n",
     "    var body: some View {\n        jitAlertContent\n            .overlay { NetplayRootOverlay() }\n")

# 7) iOS: boot for netplay never loads the last save state (the host's state replaces it anyway)
edit("platforms/ios/Swift/App/AppState.swift",
     "    @discardableResult\n    func bootBIOSOnly() -> Bool {\n",
     "    @discardableResult\n"
     "    func bootGameForNetplay(isoName: String) -> Bool {\n"
     "        if runningGameName != nil { return false }\n"
     "        guard requireBootableBIOS() else { return false }\n"
     "        guard ARMSX2Bridge.isJITAvailable() else { return false }\n"
     "        return performBootGame(isoName: isoName, launchTransition: nil, automaticallyLoadLastState: false)\n"
     "    }\n\n"
     "    @discardableResult\n    func bootBIOSOnly() -> Bool {\n")

# 8) iOS: voice chat needs the microphone
edit("platforms/ios/Info.plist.in",
     "    <key>NSMotionUsageDescription</key>\n",
     "    <key>NSMicrophoneUsageDescription</key>\n"
     "    <string>PS2 Online uses the microphone for voice chat with the other player.</string>\n"
     "    <key>NSMotionUsageDescription</key>\n")

print("PS2 Online netplay applied.")
