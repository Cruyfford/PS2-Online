#include "core_bridge.h"
#include "libretro.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- audio ring
#define RING_FRAMES 16384
static int16_t ring[RING_FRAMES * 2];
static atomic_size_t ring_w, ring_r;

static void ring_push(const int16_t *s, size_t frames) {
    size_t w = atomic_load_explicit(&ring_w, memory_order_relaxed);
    size_t r = atomic_load_explicit(&ring_r, memory_order_acquire);
    size_t space = RING_FRAMES - (w - r);
    if (frames > space) frames = space;
    for (size_t i = 0; i < frames; i++) {
        size_t idx = (w + i) % RING_FRAMES;
        ring[idx * 2] = s[i * 2];
        ring[idx * 2 + 1] = s[i * 2 + 1];
    }
    atomic_store_explicit(&ring_w, w + frames, memory_order_release);
}

size_t cb_audio_pull(int16_t *out, size_t frames) {
    size_t r = atomic_load_explicit(&ring_r, memory_order_relaxed);
    size_t w = atomic_load_explicit(&ring_w, memory_order_acquire);
    size_t avail = w - r;
    if (avail > 6000) {               // تأخير صوت كبير → اقفز للأحدث
        r = w - 2048;
        avail = 2048;
    }
    if (frames > avail) frames = avail;
    for (size_t i = 0; i < frames; i++) {
        size_t idx = (r + i) % RING_FRAMES;
        out[i * 2] = ring[idx * 2];
        out[i * 2 + 1] = ring[idx * 2 + 1];
    }
    atomic_store_explicit(&ring_r, r + frames, memory_order_release);
    return frames;
}

void cb_audio_clear(void) {
    atomic_store(&ring_r, atomic_load(&ring_w));
}

// ---------------------------------------------------------------- state
static char sys_dir[1024];
static char save_dir[1024];
static int bios_hle;
static volatile int enhance;          // دقة الصورة 2x — اختيار كل لاعب، رسم فقط
static volatile bool opt_update;

// خيارات النواة — نفس جدول CORE_OPTIONS في نسخة الكمبيوتر حرفياً (ضروري للتزامن)
static const char *core_opts[][2] = {
    { "pcsx_rearmed_drc", "disabled" },
    { "pcsx_rearmed_gpu_thread_rendering", "disabled" },
    { "pcsx_rearmed_spu_thread", "disabled" },
    { "pcsx_rearmed_cd_readahead", "0" },
    { "pcsx_rearmed_cd_turbo", "disabled" },
    { "pcsx_rearmed_frameskip_type", "disabled" },
    { "pcsx_rearmed_region", "auto" },
    { "pcsx_rearmed_memcard2", "none" },
    { "pcsx_rearmed_multitap", "disabled" },
    { "pcsx_rearmed_icache_emulation", "enabled" },
    { "pcsx_rearmed_show_bios_bootlogo", "disabled" },
};
static enum retro_pixel_format pix_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static uint8_t fb[1024 * 512 * 4];
static unsigned fb_w, fb_h;
static size_t fb_pitch;
static uint64_t fb_serial;
static uint16_t inputs[2];
static bool inited, loaded;
static char rom_path[1024];

// نفس ما تقبله نسخة الكمبيوتر بالضبط — أي أمر آخر يُرفض
static bool env_cb(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
        if (f > RETRO_PIXEL_FORMAT_RGB565) return false;
        pix_fmt = f;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:          // البايوس
        *(const char **)data = sys_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = save_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *v = (struct retro_variable *)data;
        if (!v || !v->key) return false;
        if (strcmp(v->key, "pcsx_rearmed_bios") == 0) {
            v->value = bios_hle ? "HLE" : "auto";
            return true;
        }
        if (strcmp(v->key, "pcsx_rearmed_neon_enhancement_enable") == 0) {
            v->value = enhance ? "enabled" : "disabled";
            return true;
        }
        for (size_t i = 0; i < sizeof(core_opts) / sizeof(core_opts[0]); i++) {
            if (strcmp(v->key, core_opts[i][0]) == 0) {
                v->value = core_opts[i][1];
                return true;
            }
        }
        return false;
    }
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *(bool *)data = true;
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = opt_update;
        opt_update = false;
        return true;
    default:
        return false;
    }
}

static void video_cb(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data || !w || !h) return;
    size_t n = pitch * h;
    if (n > sizeof(fb)) return;
    memcpy(fb, data, n);
    fb_w = w; fb_h = h; fb_pitch = pitch;
    fb_serial++;
}

static void audio_cb(int16_t l, int16_t r) {
    int16_t s[2] = { l, r };
    ring_push(s, 1);
}

static size_t audio_batch_cb(const int16_t *data, size_t frames) {
    ring_push(data, frames);
    return frames;
}

static void input_poll_cb(void) {}

static int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    if (port > 1 || (device & 0xFF) != RETRO_DEVICE_JOYPAD) return 0;
    if (id == 256) return (int16_t)inputs[port];         // JOYPAD_MASK
    return (inputs[port] >> id) & 1;
}

// ---------------------------------------------------------------- API
void cb_set_enhance(bool on) {
    if ((int)on != enhance) {
        enhance = on;
        opt_update = true;
    }
}

bool cb_init(const char *system_dir, const char *saves_dir, bool hle_bios) {
    cb_unload();
    strncpy(sys_dir, system_dir ? system_dir : ".", sizeof(sys_dir) - 1);
    strncpy(save_dir, saves_dir ? saves_dir : sys_dir, sizeof(save_dir) - 1);
    bios_hle = hle_bios;
    pix_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
    fb_w = fb_h = 0; fb_pitch = 0;
    retro_set_environment(env_cb);
    retro_init();
    retro_set_video_refresh(video_cb);
    retro_set_audio_sample(audio_cb);
    retro_set_audio_sample_batch(audio_batch_cb);
    retro_set_input_poll(input_poll_cb);
    retro_set_input_state(input_state_cb);
    inited = true;
    cb_audio_clear();
    return true;
}

bool cb_load(const char *path) {
    if (!inited) return false;
    strncpy(rom_path, path ? path : "", sizeof(rom_path) - 1);
    struct retro_game_info gi = { rom_path, NULL, 0, NULL };     // النواة تقرأ القرص بنفسها
    if (!retro_load_game(&gi)) return false;
    retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    retro_set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
    loaded = true;
    return true;
}

void cb_unload(void) {
    if (loaded) retro_unload_game();
    if (inited) retro_deinit();
    loaded = inited = false;
}

void cb_run(uint16_t p1, uint16_t p2) {
    inputs[0] = p1;
    inputs[1] = p2;
    retro_run();
}

const uint8_t *cb_frame(unsigned *w, unsigned *h, size_t *pitch, unsigned *fmt, uint64_t *serial) {
    *w = fb_w; *h = fb_h; *pitch = fb_pitch; *fmt = (unsigned)pix_fmt; *serial = fb_serial;
    return fb;
}

size_t cb_state_size(void) { return retro_serialize_size(); }
bool cb_save_state(void *buf, size_t size) { return retro_serialize(buf, size); }
bool cb_load_state(const void *buf, size_t size) { return retro_unserialize(buf, size); }

uint8_t *cb_memory(unsigned id, size_t *size) {
    *size = retro_get_memory_size(id);
    return (uint8_t *)retro_get_memory_data(id);
}

double cb_fps(void) {
    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    return av.timing.fps;
}

double cb_sample_rate(void) {
    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    return av.timing.sample_rate;
}

const char *cb_version(void) {
    static char buf[128];
    struct retro_system_info si;
    memset(&si, 0, sizeof(si));
    retro_get_system_info(&si);
    strncpy(buf, si.library_version ? si.library_version : "?", sizeof(buf) - 1);
    return buf;
}
