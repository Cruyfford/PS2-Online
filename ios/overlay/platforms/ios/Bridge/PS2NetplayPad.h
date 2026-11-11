// PS2NetplayPad.h — while netplay runs, on-screen input is staged for the CPU thread instead of
// written straight into port 1 (which, on the guest, holds the other player).
// SPDX-License-Identifier: GPL-3.0+
#pragma once

#include "Netplay.h"
#include "SIO/Pad/PadBase.h"

static inline void PS2NetplayPadSet(PadBase* pad, u32 index, float value)
{
	if (Netplay::IsActive())
		Netplay::SetLocalPad(index, value);
	else
		pad->Set(index, value);
}
