// PS2 Online (Cruyfford) — game-modding tools.
// SPDX-License-Identifier: GPL-3.0+

#include "PS2Mod.h"

#include "Netplay.h"

#include "DebugTools/Debug.h"
#include "IopMem.h"
#include "Memory.h"
#include "VMManager.h"

#include "common/FileSystem.h"
#include "common/Path.h"

#include <chrono>
#include <cstring>
#include <ctime>
#include <map>
#include <mutex>

namespace PS2Mod
{
	struct Pending
	{
		uint32_t addr;
		int width;
		uint32_t value;
	};

	static std::mutex s_mutex;
	static std::vector<Pending> s_writes;
	static std::map<uint32_t, Frozen> s_frozen;

	// Search state (UI thread only).
	static std::vector<uint8_t> s_snapshot;
	static std::vector<uint32_t> s_candidates;
	static int s_width = W32;
	static bool s_searching = false;

	bool Available() { return eeMem != nullptr && VMManager::HasValidVM(); }
	uint32_t RamSize() { return Ps2MemSize::MainRam; }

	static int Bytes(int width) { return width == WFloat ? 4 : width; }

	uint32_t Read(uint32_t addr, uint8_t* out, uint32_t len)
	{
		if (!Available() || addr >= Ps2MemSize::MainRam)
			return 0;
		const uint32_t n = std::min(len, Ps2MemSize::MainRam - addr);
		std::memcpy(out, eeMem->Main + addr, n);
		return n;
	}

	static uint32_t Load(const uint8_t* base, uint32_t addr, int width)
	{
		switch (Bytes(width))
		{
			case 1: return base[addr];
			case 2: { uint16_t v; std::memcpy(&v, base + addr, 2); return v; }
			default: { uint32_t v; std::memcpy(&v, base + addr, 4); return v; }
		}
	}

	void Write(uint32_t addr, int width, uint32_t value)
	{
		std::lock_guard lock(s_mutex);
		s_writes.push_back({addr & (Ps2MemSize::MainRam - 1), width, value});
	}

	void Freeze(uint32_t addr, int width, uint32_t value)
	{
		std::lock_guard lock(s_mutex);
		addr &= Ps2MemSize::MainRam - 1;
		s_frozen[addr] = {addr, width, value};
	}

	void Unfreeze(uint32_t addr)
	{
		std::lock_guard lock(s_mutex);
		s_frozen.erase(addr & (Ps2MemSize::MainRam - 1));
	}

	void UnfreezeAll()
	{
		std::lock_guard lock(s_mutex);
		s_frozen.clear();
	}

	std::vector<Frozen> FrozenList()
	{
		std::lock_guard lock(s_mutex);
		std::vector<Frozen> out;
		for (const auto& [a, f] : s_frozen)
			out.push_back(f);
		return out;
	}

	static void Store(uint32_t addr, int width, uint32_t value)
	{
		// Through the VTLB at the kseg0 mirror, so the recompiler sees code changes.
		const u32 va = 0x80000000u | addr;
		switch (Bytes(width))
		{
			case 1: memWrite8(va, static_cast<u8>(value)); break;
			case 2: memWrite16(va, static_cast<u16>(value)); break;
			default: memWrite32(va, value); break;
		}
	}

	void OnFrame()
	{
		std::vector<Pending> writes;
		std::vector<Frozen> frozen;
		{
			std::lock_guard lock(s_mutex);
			if (s_writes.empty() && s_frozen.empty())
				return;
			writes.swap(s_writes);
			for (const auto& [a, f] : s_frozen)
				frozen.push_back(f);
		}
		// Changing memory on one side only would split an online match.
		if (Netplay::IsActive() || !eeMem)
			return;
		for (const auto& w : writes)
			Store(w.addr, w.width, w.value);
		for (const auto& f : frozen)
			Store(f.addr, f.width, f.value);
	}

	// ---- search ----

	void SearchReset()
	{
		s_snapshot.clear();
		s_snapshot.shrink_to_fit();
		s_candidates.clear();
		s_candidates.shrink_to_fit();
		s_searching = false;
	}

	void SearchBegin(int width, bool aligned)
	{
		SearchReset();
		if (!Available())
			return;
		s_width = width;
		s_snapshot.assign(eeMem->Main, eeMem->Main + Ps2MemSize::MainRam);
		const uint32_t step = aligned ? static_cast<uint32_t>(Bytes(width)) : 1;
		const uint32_t end = Ps2MemSize::MainRam - static_cast<uint32_t>(Bytes(width));
		s_candidates.reserve(Ps2MemSize::MainRam / step);
		for (uint32_t a = 0; a <= end; a += step)
			s_candidates.push_back(a);
		s_searching = true;
	}

	static bool Test(int op, int width, uint32_t cur, uint32_t prev, uint32_t value)
	{
		if (width == WFloat)
		{
			float c, p, v;
			std::memcpy(&c, &cur, 4);
			std::memcpy(&p, &prev, 4);
			std::memcpy(&v, &value, 4);
			switch (op)
			{
				case Equal: return c == v;
				case NotEqual: return c != v;
				case Greater: return c > v;
				case Less: return c < v;
				case Changed: return cur != prev;
				case Unchanged: return cur == prev;
				case Increased: return c > p;
				case Decreased: return c < p;
			}
			return false;
		}
		switch (op)
		{
			case Equal: return cur == value;
			case NotEqual: return cur != value;
			case Greater: return cur > value;
			case Less: return cur < value;
			case Changed: return cur != prev;
			case Unchanged: return cur == prev;
			case Increased: return cur > prev;
			case Decreased: return cur < prev;
		}
		return false;
	}

	uint32_t SearchFilter(int op, uint32_t value)
	{
		if (!s_searching || !Available())
			return 0;
		const uint8_t* now = eeMem->Main;
		const uint8_t* before = s_snapshot.data();
		size_t keep = 0;
		for (size_t i = 0; i < s_candidates.size(); i++)
		{
			const uint32_t a = s_candidates[i];
			if (Test(op, s_width, Load(now, a, s_width), Load(before, a, s_width), value))
				s_candidates[keep++] = a;
		}
		s_candidates.resize(keep);
		std::memcpy(s_snapshot.data(), now, Ps2MemSize::MainRam);
		return static_cast<uint32_t>(keep);
	}

	uint32_t SearchCount() { return static_cast<uint32_t>(s_candidates.size()); }

	std::vector<Result> SearchResults(uint32_t max)
	{
		std::vector<Result> out;
		if (!s_searching || !Available())
			return out;
		const uint32_t n = std::min<uint32_t>(max, static_cast<uint32_t>(s_candidates.size()));
		out.reserve(n);
		for (uint32_t i = 0; i < n; i++)
		{
			const uint32_t a = s_candidates[i];
			out.push_back({a, Load(eeMem->Main, a, s_width), Load(s_snapshot.data(), a, s_width)});
		}
		return out;
	}

	// ---- dumps, disassembly ----

	std::string Serial()
	{
		std::string s = VMManager::HasValidVM() ? VMManager::GetDiscSerial() : std::string();
		return s.empty() ? std::string("UNKNOWN") : s;
	}

	std::string Dump(const std::string& dir)
	{
		if (!Available())
			return {};
		FileSystem::EnsureDirectoryExists(dir.c_str(), true);
		char stamp[32];
		const std::time_t t = std::time(nullptr);
		std::strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", std::localtime(&t));
		const std::string base = Path::Combine(dir, Serial() + "_" + stamp);
		const std::string ee = base + "_EE.bin";
		if (!FileSystem::WriteBinaryFile(ee.c_str(), eeMem->Main, Ps2MemSize::MainRam))
			return {};
		if (iopMem)
			FileSystem::WriteBinaryFile((base + "_IOP.bin").c_str(), iopMem->Main, Ps2MemSize::IopRam);
		return ee;
	}

	std::vector<std::string> Disassemble(uint32_t addr, uint32_t count)
	{
		std::vector<std::string> out;
		if (!Available())
			return out;
		addr &= ~3u;
		for (uint32_t i = 0; i < count; i++)
		{
			const uint32_t a = addr + i * 4;
			if (a + 4 > Ps2MemSize::MainRam)
				break;
			uint32_t code;
			std::memcpy(&code, eeMem->Main + a, 4);
			std::string text;
			R5900::disR5900Fasm(text, code, a, true);
			out.push_back(std::move(text));
		}
		return out;
	}
} // namespace PS2Mod
