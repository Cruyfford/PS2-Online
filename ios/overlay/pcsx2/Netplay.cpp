// PS2 Online (Cruyfford) — lockstep netplay hook for the ARMSX2 core.
// SPDX-License-Identifier: GPL-3.0+

#include "Netplay.h"

#include "Config.h"
#include "Memory.h"
#include "Recording/PadData.h"
#include "SIO/Pad/Pad.h"
#include "SIO/Pad/PadBase.h"
#include "SIO/Pad/PadDualshock2.h"
#include "VMManager.h"

#include "common/Path.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <utility>
#include <vector>

#include <zlib.h>

namespace Netplay
{
	using Input = std::array<u8, INPUT_SIZE>;

	enum class Phase
	{
		WaitSync, // host: until RequestSync; guest: until ProvideState
		Running,
	};

	static std::mutex s_mutex;
	static std::condition_variable s_cv;
	static std::atomic<bool> s_active{false};
	static std::atomic<bool> s_waiting{false};
	static std::atomic<uint32_t> s_frame_pub{0};

	// Guarded by s_mutex.
	static bool s_host = true;
	static int s_delay = 3;
	static Phase s_phase = Phase::WaitSync;
	static bool s_sync_requested = false;
	static std::string s_sync_path;
	static bool s_load_ready = false;
	static std::string s_load_path;
	static int s_load_delay = 3;
	static std::map<uint32_t, Input> s_remote;
	static Callbacks s_cb;
	static std::string s_guest_card;

	// CPU thread only.
	static uint32_t s_frame = 0;
	static std::map<uint32_t, Input> s_local;
	static Input s_shadow{};
	static bool s_have_shadow = false;

	// Touch input staged by the UI thread.
	static std::mutex s_touch_mutex;
	static std::vector<std::pair<u32, float>> s_touch_pending;

	static Input Neutral()
	{
		Input in{};
		in[0] = 0xFF; // all released (active low)
		in[1] = 0xFF;
		in[2] = in[3] = in[4] = in[5] = 0x7F; // sticks centred
		return in;
	}

	static void Capture(u32 port, Input& out)
	{
		PadBase* pad = Pad::GetPad(static_cast<u8>(port), 0);
		if (!pad)
		{
			out = Neutral();
			return;
		}
		const u32 buttons = pad->GetButtons();
		out[0] = static_cast<u8>((buttons & 0xFF00) >> 8);
		out[1] = static_cast<u8>(buttons & 0xFF);
		const auto [rx, ry] = pad->GetRawRightAnalog();
		const auto [lx, ly] = pad->GetRawLeftAnalog();
		out[2] = rx;
		out[3] = ry;
		out[4] = lx;
		out[5] = ly;
		out[6] = pad->GetRawInput(PadDualshock2::Inputs::PAD_RIGHT);
		out[7] = pad->GetRawInput(PadDualshock2::Inputs::PAD_LEFT);
		out[8] = pad->GetRawInput(PadDualshock2::Inputs::PAD_UP);
		out[9] = pad->GetRawInput(PadDualshock2::Inputs::PAD_DOWN);
		out[10] = pad->GetRawInput(PadDualshock2::Inputs::PAD_TRIANGLE);
		out[11] = pad->GetRawInput(PadDualshock2::Inputs::PAD_CIRCLE);
		out[12] = pad->GetRawInput(PadDualshock2::Inputs::PAD_CROSS);
		out[13] = pad->GetRawInput(PadDualshock2::Inputs::PAD_SQUARE);
		out[14] = pad->GetRawInput(PadDualshock2::Inputs::PAD_L1);
		out[15] = pad->GetRawInput(PadDualshock2::Inputs::PAD_R1);
		out[16] = pad->GetRawInput(PadDualshock2::Inputs::PAD_L2);
		out[17] = pad->GetRawInput(PadDualshock2::Inputs::PAD_R2);
	}

	static void Apply(u32 port, const Input& in)
	{
		if (!Pad::GetPad(static_cast<u8>(port), 0))
			return;
		PadData(static_cast<int>(port), 0, in).OverrideActualController();
	}

	static void ResetLockstepLocked(int delay)
	{
		s_delay = std::max(1, std::min(delay, 20));
		s_frame = 0;
		s_frame_pub.store(0);
		s_local.clear();
		s_remote.clear();
		for (int f = 0; f < s_delay; f++)
		{
			s_local[static_cast<uint32_t>(f)] = Neutral();
			s_remote[static_cast<uint32_t>(f)] = Neutral();
		}
	}

	void Configure(bool host, int delay, const Callbacks& cb, const char* guest_card)
	{
		std::lock_guard lock(s_mutex);
		s_host = host;
		s_cb = cb;
		s_phase = Phase::WaitSync;
		s_sync_requested = false;
		s_load_ready = false;
		s_guest_card = (!host && guest_card) ? guest_card : "";
		s_have_shadow = false;
		ResetLockstepLocked(delay);
		{
			std::lock_guard tl(s_touch_mutex);
			s_touch_pending.clear();
		}
		s_active.store(true);
	}

	void Stop()
	{
		{
			std::lock_guard lock(s_mutex);
			s_active.store(false);
			s_cb = {};
			s_remote.clear();
		}
		s_cv.notify_all();
	}

	bool IsActive() { return s_active.load(); }
	bool IsWaiting() { return s_waiting.load(); }
	uint32_t Frame() { return s_frame_pub.load(); }

	void RequestSync(const char* path)
	{
		{
			std::lock_guard lock(s_mutex);
			s_sync_path = path ? path : "";
			s_sync_requested = true;
			s_phase = Phase::WaitSync;
		}
		s_cv.notify_all();
	}

	void WaitForPeer()
	{
		{
			std::lock_guard lock(s_mutex);
			s_phase = Phase::WaitSync;
			s_sync_requested = false;
		}
		s_cv.notify_all();
	}

	void ProvideState(const char* path, int delay)
	{
		{
			std::lock_guard lock(s_mutex);
			s_load_path = path ? path : "";
			s_load_delay = delay;
			s_load_ready = true;
			s_phase = Phase::WaitSync;
		}
		s_cv.notify_all();
	}

	void PushRemoteInput(uint32_t frame, const uint8_t* data)
	{
		{
			std::lock_guard lock(s_mutex);
			Input in;
			std::copy(data, data + INPUT_SIZE, in.begin());
			s_remote[frame] = in;
		}
		s_cv.notify_all();
	}

	void SetLocalPad(uint32_t index, float value)
	{
		std::lock_guard tl(s_touch_mutex);
		s_touch_pending.emplace_back(index, value);
	}

	std::string MemoryCardFolder() { return EmuFolders::MemoryCards; }

	std::string HostCardPath()
	{
		const auto& mcd = EmuConfig.Mcd[0];
		if (!mcd.Enabled || mcd.Type != MemoryCardType::File || mcd.Filename.empty())
			return {};
		return Path::Combine(EmuFolders::MemoryCards, mcd.Filename);
	}

	void ApplyConfigOverrides(Pcsx2Config& cfg)
	{
		if (!s_active.load())
			return;
		// Anything that lets host timing reach the guest's state is off: a threaded VU1 or IOP, the
		// dynamic EE clock governor and auto-tune all change emulated timing with host load.
		cfg.Speedhacks.vuThread = false;
		cfg.Speedhacks.iopThread = false;
		cfg.Speedhacks.DynamicEECycleRate = false;
		cfg.Speedhacks.EECycleRate = 0;
		cfg.Speedhacks.EECycleSkip = 0;
		cfg.Speedhacks.fastCDVD = false;
		cfg.AutoTune = false;
		cfg.EnableCheats = false;
		cfg.EnableWideScreenPatches = false;
		cfg.EnableNoInterlacingPatches = false;
		cfg.EnableFastBoot = true;
		cfg.Achievements.HardcoreMode = false;
		cfg.Pad.MultitapPort0_Enabled = false;
		cfg.Pad.MultitapPort1_Enabled = false;
		cfg.Pad.Ports[0].Type = Pad::ControllerType::DualShock2;
		cfg.Pad.Ports[1].Type = Pad::ControllerType::DualShock2;
		// One card, in slot 1, holding the host's data on both sides.
		cfg.Mcd[1].Enabled = false;
		std::string card;
		{
			std::lock_guard lock(s_mutex);
			card = s_guest_card;
		}
		if (!card.empty())
		{
			cfg.Mcd[0].Enabled = true;
			cfg.Mcd[0].Type = MemoryCardType::File;
			cfg.Mcd[0].Filename = card;
		}
	}

	void PreInput()
	{
		if (!s_active.load())
			return;
		PadBase* pad = Pad::GetPad(0, 0);
		if (!pad)
			return;
		// The frame before left port 1 holding whoever is player 1; put the local player's own
		// state back before the frontend's input pump adds to it.
		if (s_have_shadow)
			Apply(0, s_shadow);
		std::vector<std::pair<u32, float>> pending;
		{
			std::lock_guard tl(s_touch_mutex);
			pending.swap(s_touch_pending);
		}
		for (const auto& [idx, value] : pending)
			pad->Set(idx, value);
	}

	// Waits on s_cv until pred() or netplay stops. Returns false when stopped.
	template <typename Pred>
	static bool WaitFor(std::unique_lock<std::mutex>& lock, Pred pred)
	{
		s_waiting.store(true);
		while (s_active.load() && !pred())
			s_cv.wait_for(lock, std::chrono::milliseconds(100));
		s_waiting.store(false);
		return s_active.load();
	}

	static void SyncPoint(std::unique_lock<std::mutex>& lock)
	{
		while (s_active.load() && s_phase == Phase::WaitSync)
		{
			if (s_host)
			{
				if (!WaitFor(lock, [] { return s_sync_requested; }))
					return;
				const std::string path = s_sync_path;
				s_sync_requested = false;
				const Callbacks cb = s_cb;
				lock.unlock();
				bool ok = true;
				VMManager::SaveState(path.c_str(), false, false, [&ok](const std::string&) { ok = false; });
				lock.lock();
				if (ok)
				{
					ResetLockstepLocked(s_delay);
					s_phase = Phase::Running;
				}
				if (cb.state_saved)
				{
					lock.unlock();
					cb.state_saved(cb.ctx, path.c_str(), ok ? 1 : 0);
					lock.lock();
				}
			}
			else
			{
				if (!WaitFor(lock, [] { return s_load_ready; }))
					return;
				const std::string path = s_load_path;
				const int delay = s_load_delay;
				s_load_ready = false;
				const Callbacks cb = s_cb;
				lock.unlock();
				const bool ok = VMManager::LoadState(path.c_str());
				lock.lock();
				if (ok)
				{
					ResetLockstepLocked(delay);
					s_phase = Phase::Running;
				}
				if (cb.state_loaded)
				{
					lock.unlock();
					cb.state_loaded(cb.ctx, ok ? 1 : 0);
					lock.lock();
				}
			}
		}
	}

	void PostInput()
	{
		if (!s_active.load() || !Pad::GetPad(0, 0))
			return;

		// What the local player is holding this frame: touch plus the frontend's gamepad poll.
		Capture(0, s_shadow);
		s_have_shadow = true;

		std::unique_lock lock(s_mutex);
		SyncPoint(lock);
		if (!s_active.load())
			return;

		const uint32_t f = s_frame;
		const uint32_t target = f + static_cast<uint32_t>(s_delay);
		if (s_local.find(target) == s_local.end())
		{
			s_local[target] = s_shadow;
			const Callbacks cb = s_cb;
			if (cb.send_input)
			{
				lock.unlock();
				cb.send_input(cb.ctx, target, s_shadow.data());
				lock.lock();
			}
		}

		if (!WaitFor(lock, [f] { return s_remote.find(f) != s_remote.end() || s_phase == Phase::WaitSync; }))
			return;
		if (s_phase == Phase::WaitSync)
		{
			// The host restarted the session (the guest rejoined); this frame is replaced by the new state.
			SyncPoint(lock);
			return;
		}

		const Input remote = s_remote[f];
		const Input local = s_local.count(f) ? s_local[f] : Neutral();
		s_remote.erase(f);
		s_local.erase(f);
		const Callbacks cb = s_cb;
		const bool host = s_host;
		s_frame = f + 1;
		s_frame_pub.store(s_frame);
		lock.unlock();

		Apply(0, host ? local : remote);
		Apply(1, host ? remote : local);

		if (f % CHECK_EVERY == 0 && cb.send_check && eeMem)
		{
			const uint32_t crc = static_cast<uint32_t>(
				crc32(0L, reinterpret_cast<const Bytef*>(eeMem->Main), Ps2MemSize::MainRam));
			cb.send_check(cb.ctx, f, crc);
		}
	}
} // namespace Netplay
