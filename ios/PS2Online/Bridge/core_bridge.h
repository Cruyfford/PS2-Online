// جسر C بسيط فوق نواة PCSX ReARMED (libretro) المربوطة ستاتيكياً.
// السلوك مطابق تماماً لنسخة الكمبيوتر (نفس أوامر البيئة ونفس المدخلات) حتى تبقى المزامنة سليمة.
#ifndef CORE_BRIDGE_H
#define CORE_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

bool cb_init(const char *system_dir, const char *saves_dir, bool hle_bios);
bool cb_load(const char *path);
// دقة الصورة 2x (Enhanced Resolution) — تُطبَّق فوراً حتى أثناء اللعب، ولا تؤثر على المزامنة
void cb_set_enhance(bool on);
void cb_unload(void);
void cb_run(uint16_t p1, uint16_t p2);

// آخر إطار: البكسلات + الأبعاد + الصيغة (0=0RGB1555، 1=XRGB8888، 2=RGB565) + رقم تسلسلي يتغير مع كل إطار جديد
const uint8_t *cb_frame(unsigned *w, unsigned *h, size_t *pitch, unsigned *fmt, uint64_t *serial);

// الصوت: حلقة int16 ستيريو (يكتب فيها retro_run، ويقرأ منها خيط الصوت)
size_t cb_audio_pull(int16_t *out, size_t frames);
void cb_audio_clear(void);

size_t cb_state_size(void);
bool cb_save_state(void *buf, size_t size);
bool cb_load_state(const void *buf, size_t size);

uint8_t *cb_memory(unsigned id, size_t *size);
double cb_fps(void);
double cb_sample_rate(void);
const char *cb_version(void);

#endif
