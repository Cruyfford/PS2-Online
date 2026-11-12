// PS2 Online (Cruyfford) — game-modding tools: EE RAM viewer, search, poke/freeze, dumps, disassembly.
// SPDX-License-Identifier: GPL-3.0+
//
// Reads go straight to EE RAM (racy, like any memory viewer on a running game). Writes and freezes are
// queued and applied on the CPU thread at the frame's input poll through the VTLB, so recompiled code
// sees them the way it would a store from the game.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace PS2Mod
{
	enum Width : int
	{
		W8 = 1,
		W16 = 2,
		W32 = 4,
		WFloat = 0x14, // 4 bytes, compared as float
	};

	enum Op : int
	{
		Equal = 0,
		NotEqual,
		Greater,
		Less,
		Changed,
		Unchanged,
		Increased,
		Decreased,
	};

	struct Result
	{
		uint32_t addr;
		uint32_t value; // raw bits
		uint32_t previous;
	};

	bool Available();
	uint32_t RamSize();

	// Copies `len` bytes of EE RAM from `addr` (physical, 0..32MB) into out. Returns bytes copied.
	uint32_t Read(uint32_t addr, uint8_t* out, uint32_t len);

	// Queued for the CPU thread.
	void Write(uint32_t addr, int width, uint32_t value);
	void Freeze(uint32_t addr, int width, uint32_t value);
	void Unfreeze(uint32_t addr);
	void UnfreezeAll();
	struct Frozen
	{
		uint32_t addr;
		int width;
		uint32_t value;
	};
	std::vector<Frozen> FrozenList();

	// Search. Begin snapshots RAM with every address (of the width's alignment) a candidate.
	void SearchBegin(int width, bool aligned);
	// Keeps candidates for which `op` holds (value is used by Equal..Less; others compare to the last scan).
	uint32_t SearchFilter(int op, uint32_t value);
	uint32_t SearchCount();
	std::vector<Result> SearchResults(uint32_t max);
	void SearchReset();

	// Writes EE (and IOP) RAM to `dir`; returns the EE file's path or empty on failure.
	std::string Dump(const std::string& dir);

	// R5900 disassembly of `count` instructions from `addr`.
	std::vector<std::string> Disassemble(uint32_t addr, uint32_t count);

	std::string Serial();

	// CPU thread, every frame (VMManager hook).
	void OnFrame();
} // namespace PS2Mod
