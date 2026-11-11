// PS2 Online (Cruyfford) — lockstep netplay hook for the ARMSX2 core.
// SPDX-License-Identifier: GPL-3.0+
//
// The game reads its pads once per frame, after VMManager::Internal::PollInputOnCPUThread. That is the
// same point PCSX2's input recording overwrites the pads at, so it is where both players' inputs for a
// frame are put into ports 1 and 2. Nothing else may touch the pads while netplay is active: touch input
// is staged here and applied on the CPU thread, before the frame's pad poll.

#pragma once

#include <cstdint>
#include <string>

struct Pcsx2Config;

namespace Netplay
{
	// One DualShock 2 for one frame, in PCSX2's input-recording layout (Recording/PadData).
	static constexpr int INPUT_SIZE = 18;

	struct Callbacks
	{
		void* ctx = nullptr;
		// The local player's input for `frame` (frame = emulated frame + delay). CPU thread.
		void (*send_input)(void* ctx, uint32_t frame, const uint8_t* data) = nullptr;
		// CRC32 of EE main RAM, every CHECK_EVERY frames. CPU thread.
		void (*send_check)(void* ctx, uint32_t frame, uint32_t crc) = nullptr;
		// Host: the save state asked for by RequestSync is on disk (ok = 0 on failure). CPU thread.
		void (*state_saved)(void* ctx, const char* path, int ok) = nullptr;
		// Guest: the host's state was loaded (ok = 1) or refused (ok = 0). CPU thread.
		void (*state_loaded)(void* ctx, int ok) = nullptr;
	};

	static constexpr uint32_t CHECK_EVERY = 120;

	// Before booting. host = player 1. guest_card = memory card file name (inside the memory card
	// folder) the guest boots with, holding the host's card; empty = keep the configured card.
	void Configure(bool host, int delay, const Callbacks& cb, const char* guest_card);
	// Ends netplay; a CPU thread waiting for the peer is released and the game runs on alone.
	void Stop();
	bool IsActive();
	// True while the CPU thread is parked waiting for the peer (for the UI).
	bool IsWaiting();
	uint32_t Frame();

	// Host: at the next frame, save a state to `path` and start (or restart) the lockstep from it.
	void RequestSync(const char* path);
	// Host: the guest left; park at the next frame until RequestSync.
	void WaitForPeer();
	// Guest: load the host's state from `path` at the next frame and start the lockstep.
	void ProvideState(const char* path, int delay);
	// Network thread: the peer's input for `frame`.
	void PushRemoteInput(uint32_t frame, const uint8_t* data);
	// UI thread: touch / on-screen pad for the local player while netplay is active.
	void SetLocalPad(uint32_t index, float value);

	// The memory card file the host plays with (to send to the guest); empty for folder cards.
	std::string HostCardPath();
	std::string MemoryCardFolder();

	// VMManager hooks (CPU thread).
	void PreInput();
	void PostInput();
	void ApplyConfigOverrides(Pcsx2Config& cfg);
} // namespace Netplay
