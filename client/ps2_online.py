#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PS2 Online — Cruyfford
----------------------
لعب ألعاب بلايستيشن 2 أونلاين بين جهازين:
  * كل لاعب يشغّل المحاكي (نواة LRPS2 = pcsx2_libretro) على جهازه — لا يوجد بث فيديو.
  * المزامنة بالمدخلات فقط (lockstep مع تأخير قابل للضبط) عبر سيرفر Cloudflare
    (نفس سيرفر SNES Online و PS1 Online)، فلا حاجة لنفس الراوتر ولا لفتح منافذ.
  * المضيف يحدد إعدادات المحاكي، والضيف يأخذها منه تلقائياً — حتى تبقى اللعبة متطابقة.

المتطلبات:  pip install PySide6 websockets      (اختياري لليد: pip install pygame)
"""
import os, sys, json, zlib, time, struct, shutil, tempfile, threading, queue, array, uuid, base64
import random, string, glob, itertools, importlib.util, urllib.parse, socket, hashlib
from ctypes import (CDLL, CFUNCTYPE, POINTER, Structure, byref, cast, addressof, string_at,
                    memmove, create_string_buffer, c_bool, c_uint, c_int, c_int16, c_float,
                    c_double, c_size_t, c_char_p, c_void_p, c_ubyte, c_char, c_uint32)

APP_DIR = os.path.dirname(os.path.abspath(__file__))
PROTO = 1
SYSTEM = "PS2"
PLATFORM = {'win32': 'Windows', 'darwin': 'macOS'}.get(sys.platform, 'Linux')
GAME_EXTS = (".iso", ".chd", ".cso", ".zso", ".gz", ".ciso", ".cue", ".m3u", ".elf")

SYSTEM_DIR = os.path.join(APP_DIR, "system")              # النواة تبحث عن البايوس في system/pcsx2/bios
BIOS_DIR = os.path.join(SYSTEM_DIR, "pcsx2", "bios")

RENDERERS = {           # القيمة في الإعدادات -> قيمة خيار النواة
    "sw": "Software (SW)",     # المعالج فقط: أبطأ لكنه متطابق 100% بين أي جهازين (الأضمن للأونلاين)
    "gl": "OpenGL",            # كرت الشاشة: أسرع ويدعم الدقة العالية
}
UPSCALE = {1: "1x (Native)", 2: "2x", 4: "4x"}

# خيارات النواة التي تؤثر على اللعبة نفسها. المضيف يرسلها للضيف كما هي، فتكون متطابقة دائماً.
# أي خيار غير مذكور هنا يأخذ القيمة الافتراضية للنواة (نفس الـ DLL = نفس القيم).
CORE_OPTIONS = {
    "pcsx2_bios": "",                               # يُملأ باسم ملف البايوس المختار
    "pcsx2_shared_memory_cards": "disabled",        # بطاقة ذاكرة لكل لعبة: saves/<اسم اللعبة>.ps2
    "pcsx2_fastboot": "enabled",
    "pcsx2_fastcdvd": "disabled",
    "pcsx2_mtvu": "disabled",                       # خيط VU1 منفصل = توقيت غير ثابت = desync
    "pcsx2_instant_vu1": "enabled",
    "pcsx2_ee_cpu": "Recompiler",
    "pcsx2_ee_cycle_rate": "100% (Normal Speed)",
    "pcsx2_ee_cycle_skip": "disabled",
    "pcsx2_enable_cheats": "disabled",
    "pcsx2_hint_language_unlock": "disabled",
    "pcsx2_game_enhancements_hint": "disabled",
    "pcsx2_uncapped_framerate_hint": "disabled",
    "pcsx2_widescreen_hint": "disabled",
    "pcsx2_nointerlacing_hint": "disabled",
    "pcsx2_multitap": "disabled",
    "pcsx2_usb_camera": "disabled",
    "pcsx2_enable_rumble1": "disabled",
    "pcsx2_enable_rumble2": "disabled",
    "pcsx2_hw_download_mode": "Accurate",
    "pcsx2_renderer": RENDERERS["sw"],
    "pcsx2_upscale_multiplier": UPSCALE[1],
}

# ============================================================================
#  libretro core wrapper
# ============================================================================
RETRO_DEVICE_JOYPAD, RETRO_DEVICE_ANALOG = 1, 5
MEM_SAVE_RAM, MEM_SYSTEM_RAM = 0, 2
ENV_EXP = 0x10000

# ترتيب أزرار libretro (رقم البت في قناع الأزرار)
BTN_B, BTN_Y, BTN_SELECT, BTN_START, BTN_UP, BTN_DOWN, BTN_LEFT, BTN_RIGHT, \
    BTN_A, BTN_X, BTN_L, BTN_R, BTN_L2, BTN_R2, BTN_L3, BTN_R3 = range(16)
# في PS2:  B = ✕   A = ○   Y = □   X = △   L/R = L1/R1

NO_INPUT = (0, 0, 0, 0, 0)          # (أزرار، يسار X، يسار Y، يمين X، يمين Y)

HW_NONE, HW_OPENGL, HW_OPENGL_CORE = 0, 1, 3
HW_FRAME_VALID = (1 << (8 * __import__("ctypes").sizeof(c_void_p))) - 1     # RETRO_HW_FRAME_BUFFER_VALID = (void*)-1


class GameGeometry(Structure):
    _fields_ = [("base_width", c_uint), ("base_height", c_uint),
                ("max_width", c_uint), ("max_height", c_uint), ("aspect_ratio", c_float)]


class SystemTiming(Structure):
    _fields_ = [("fps", c_double), ("sample_rate", c_double)]


class SystemAvInfo(Structure):
    _fields_ = [("geometry", GameGeometry), ("timing", SystemTiming)]


class SystemInfo(Structure):
    _fields_ = [("library_name", c_char_p), ("library_version", c_char_p),
                ("valid_extensions", c_char_p), ("need_fullpath", c_bool), ("block_extract", c_bool)]


class GameInfo(Structure):
    _fields_ = [("path", c_char_p), ("data", c_void_p), ("size", c_size_t), ("meta", c_char_p)]


class RetroVariable(Structure):
    _fields_ = [("key", c_char_p), ("value", c_char_p)]


class HwRenderCallback(Structure):
    _fields_ = [("context_type", c_int), ("context_reset", c_void_p),
                ("get_current_framebuffer", c_void_p), ("get_proc_address", c_void_p),
                ("depth", c_bool), ("stencil", c_bool), ("bottom_left_origin", c_bool),
                ("version_major", c_uint), ("version_minor", c_uint), ("cache_context", c_bool),
                ("context_destroy", c_void_p), ("debug_context", c_bool)]


ENV_CB = CFUNCTYPE(c_bool, c_uint, c_void_p)
VIDEO_CB = CFUNCTYPE(None, c_void_p, c_uint, c_uint, c_size_t)
AUDIO_CB = CFUNCTYPE(None, c_int16, c_int16)
AUDIO_BATCH_CB = CFUNCTYPE(c_size_t, c_void_p, c_size_t)
POLL_CB = CFUNCTYPE(None)
STATE_CB = CFUNCTYPE(c_int16, c_uint, c_uint, c_uint, c_uint)
HW_VOID_CB = CFUNCTYPE(None)
HW_FB_CB = CFUNCTYPE(c_size_t)
HW_PROC_CB = CFUNCTYPE(c_void_p, c_char_p)

_instance_ids = itertools.count()


def _cleanup_old_core_copies():
    for p in glob.glob(os.path.join(tempfile.gettempdir(), "ps2online_core_*")):
        try:
            os.remove(p)
        except OSError:
            pass


# ---------------------------------------------------------------------------
#  OpenGL (للمعالج الرسومي): سياق Qt خارج الشاشة + framebuffer ترسم فيه النواة
# ---------------------------------------------------------------------------
GL_FRAMEBUFFER, GL_READ_FRAMEBUFFER = 0x8D40, 0x8CA8
GL_READ_FRAMEBUFFER_BINDING, GL_FRAMEBUFFER_BINDING = 0x8CAA, 0x8CA6
GL_RENDERBUFFER, GL_COLOR_ATTACHMENT0, GL_DEPTH_STENCIL_ATTACHMENT = 0x8D41, 0x8CE0, 0x821A
GL_DEPTH24_STENCIL8, GL_TEXTURE_2D, GL_RGBA8, GL_RGBA = 0x88F0, 0x0DE1, 0x8058, 0x1908
GL_BGRA, GL_UNSIGNED_BYTE, GL_FRAMEBUFFER_COMPLETE = 0x80E1, 0x1401, 0x8CD5
GL_PIXEL_PACK_BUFFER, GL_PIXEL_PACK_BUFFER_BINDING = 0x88EB, 0x88ED
GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_TEXTURE_BINDING_2D = 0x0D05, 0x0D02, 0x8069
GL_RENDERBUFFER_BINDING, GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER, GL_LINEAR = 0x8CA7, 0x2801, 0x2800, 0x2601
GL_ACTIVE_TEXTURE, GL_TEXTURE0 = 0x84E0, 0x84C0


class GLTarget:
    """سياق OpenGL 3.3 Core خارج الشاشة (عبر Qt) + FBO. النواة ترسم في الـ FBO، ونحن نقرأ الصورة
    بـ glReadPixels ونعرضها مثل أي إطار عادي. نحفظ حالة GL التي نغيّرها ونرجعها، لأن نواة PCSX2
    تحتفظ بنسخة من حالة GL وتنكسر إذا غيّرناها من خلفها."""

    def __init__(self, log=print):
        from PySide6.QtGui import QOpenGLContext, QOffscreenSurface, QSurfaceFormat
        self.log = log
        fmt = QSurfaceFormat()
        fmt.setRenderableType(QSurfaceFormat.OpenGL)
        fmt.setVersion(3, 3)
        fmt.setProfile(QSurfaceFormat.CoreProfile)
        fmt.setDepthBufferSize(24)
        fmt.setStencilBufferSize(8)
        fmt.setSwapInterval(0)
        self.ctx = QOpenGLContext()
        self.ctx.setFormat(fmt)
        if not self.ctx.create():
            raise RuntimeError("تعذّر إنشاء سياق OpenGL 3.3 — حدّث تعريف كرت الشاشة أو اختر «المعالج (Software)»")
        got = self.ctx.format()
        if (got.majorVersion(), got.minorVersion()) < (3, 3):
            raise RuntimeError(f"كرت الشاشة يدعم OpenGL {got.majorVersion()}.{got.minorVersion()} فقط "
                               "والمطلوب 3.3 — اختر «المعالج (Software)» من الإعدادات")
        self.surface = QOffscreenSurface()
        self.surface.setFormat(got)
        self.surface.create()
        self.make_current()
        self._procs = {}
        g = self._fn
        V, U, I = None, c_uint, c_int
        self.glGetError = g("glGetError", c_uint)
        self.glGetIntegerv = g("glGetIntegerv", V, U, POINTER(c_int))
        self.glGenFramebuffers = g("glGenFramebuffers", V, I, POINTER(c_uint))
        self.glDeleteFramebuffers = g("glDeleteFramebuffers", V, I, POINTER(c_uint))
        self.glBindFramebuffer = g("glBindFramebuffer", V, U, U)
        self.glFramebufferTexture2D = g("glFramebufferTexture2D", V, U, U, U, U, I)
        self.glFramebufferRenderbuffer = g("glFramebufferRenderbuffer", V, U, U, U, U)
        self.glCheckFramebufferStatus = g("glCheckFramebufferStatus", c_uint, U)
        self.glGenRenderbuffers = g("glGenRenderbuffers", V, I, POINTER(c_uint))
        self.glDeleteRenderbuffers = g("glDeleteRenderbuffers", V, I, POINTER(c_uint))
        self.glBindRenderbuffer = g("glBindRenderbuffer", V, U, U)
        self.glRenderbufferStorage = g("glRenderbufferStorage", V, U, U, I, I)
        self.glGenTextures = g("glGenTextures", V, I, POINTER(c_uint))
        self.glDeleteTextures = g("glDeleteTextures", V, I, POINTER(c_uint))
        self.glBindTexture = g("glBindTexture", V, U, U)
        self.glActiveTexture = g("glActiveTexture", V, U)
        self.glTexParameteri = g("glTexParameteri", V, U, U, I)
        self.glTexImage2D = g("glTexImage2D", V, U, I, I, I, I, I, U, U, c_void_p)
        self.glBindBuffer = g("glBindBuffer", V, U, U)
        self.glPixelStorei = g("glPixelStorei", V, U, I)
        self.glReadPixels = g("glReadPixels", V, I, I, I, I, U, U, c_void_p)
        self.fbo = self.tex = self.rb = 0
        self.w = self.h = 0
        self._buf = None

        def proc(name):
            try:
                return self._addr(name) or None
            except Exception:
                return None
        self.cb_proc = HW_PROC_CB(proc)
        self.cb_fb = HW_FB_CB(lambda: self.fbo)

    def _addr(self, name):
        """عنوان دالة OpenGL. في ويندوز دوال OpenGL 1.1 موجودة في opengl32.dll وليس في wglGetProcAddress"""
        addr = int(self.ctx.getProcAddress(name) or 0)
        if not addr and sys.platform == "win32":
            import ctypes
            if not hasattr(self, "_gl32"):
                k32 = ctypes.WinDLL("kernel32")
                k32.GetModuleHandleW.restype = c_void_p
                k32.GetProcAddress.restype = c_void_p
                k32.GetProcAddress.argtypes = [c_void_p, c_char_p]
                self._k32, self._gl32 = k32, k32.GetModuleHandleW("opengl32.dll")
            if self._gl32:
                addr = self._k32.GetProcAddress(self._gl32, name) or 0
        return addr

    def _fn(self, name, restype, *argtypes):
        addr = self._addr(name.encode("ascii"))
        if not addr:
            raise RuntimeError(f"دالة OpenGL غير متوفرة: {name}")
        return CFUNCTYPE(restype, *argtypes)(addr)

    def make_current(self):
        if not self.ctx.makeCurrent(self.surface):
            raise RuntimeError("تعذّر تفعيل سياق OpenGL")

    def _geti(self, pname):
        v = c_int(0)
        self.glGetIntegerv(pname, byref(v))
        return v.value

    def resize(self, w, h):
        """ينشئ/يعيد إنشاء الـ FBO بحجم أقصى صورة ممكنة من النواة"""
        w, h = max(int(w), 64), max(int(h), 64)
        if (w, h) == (self.w, self.h) and self.fbo:
            return
        self.make_current()
        keep_tex, keep_rb, keep_fb = (self._geti(GL_TEXTURE_BINDING_2D), self._geti(GL_RENDERBUFFER_BINDING),
                                      self._geti(GL_FRAMEBUFFER_BINDING))
        keep_unit = self._geti(GL_ACTIVE_TEXTURE)
        self._delete()
        ids = (c_uint * 1)()
        self.glActiveTexture(GL_TEXTURE0)
        self.glGenTextures(1, ids); self.tex = ids[0]
        self.glBindTexture(GL_TEXTURE_2D, self.tex)
        self.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        self.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        self.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, None)
        self.glGenRenderbuffers(1, ids); self.rb = ids[0]
        self.glBindRenderbuffer(GL_RENDERBUFFER, self.rb)
        self.glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h)
        self.glGenFramebuffers(1, ids); self.fbo = ids[0]
        self.glBindFramebuffer(GL_FRAMEBUFFER, self.fbo)
        self.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, self.tex, 0)
        self.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, self.rb)
        st = self.glCheckFramebufferStatus(GL_FRAMEBUFFER)
        self.glBindFramebuffer(GL_FRAMEBUFFER, keep_fb)
        self.glBindRenderbuffer(GL_RENDERBUFFER, keep_rb)
        self.glBindTexture(GL_TEXTURE_2D, keep_tex)
        self.glActiveTexture(keep_unit or GL_TEXTURE0)
        if st != GL_FRAMEBUFFER_COMPLETE:
            raise RuntimeError(f"OpenGL: الـ framebuffer غير مكتمل (0x{st:X})")
        self.w, self.h = w, h
        self._buf = create_string_buffer(w * h * 4)

    def read(self, w, h):
        """يقرأ الصورة التي رسمتها النواة (الأصل أسفل-يسار) ويرجع (bytes, w, h, pitch, 1) مقلوبة للأعلى"""
        w, h = min(int(w), self.w), min(int(h), self.h)
        if w <= 0 or h <= 0:
            return None
        keep_read = self._geti(GL_READ_FRAMEBUFFER_BINDING)
        keep_pbo = self._geti(GL_PIXEL_PACK_BUFFER_BINDING)
        keep_align, keep_row = self._geti(GL_PACK_ALIGNMENT), self._geti(GL_PACK_ROW_LENGTH)
        self.glBindFramebuffer(GL_READ_FRAMEBUFFER, self.fbo)
        if keep_pbo:
            self.glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
        self.glPixelStorei(GL_PACK_ALIGNMENT, 4)
        self.glPixelStorei(GL_PACK_ROW_LENGTH, 0)
        self.glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, self._buf)
        self.glPixelStorei(GL_PACK_ALIGNMENT, keep_align)
        self.glPixelStorei(GL_PACK_ROW_LENGTH, keep_row)
        if keep_pbo:
            self.glBindBuffer(GL_PIXEL_PACK_BUFFER, keep_pbo)
        self.glBindFramebuffer(GL_READ_FRAMEBUFFER, keep_read)
        pitch = w * 4
        raw = self._buf.raw[:pitch * h]
        # قلب الصورة عمودياً (OpenGL يبدأ من الأسفل)
        flipped = b"".join(raw[y * pitch:(y + 1) * pitch] for y in range(h - 1, -1, -1))
        return (flipped, w, h, pitch, 1)

    def _delete(self):
        ids = (c_uint * 1)()
        if self.fbo:
            ids[0] = self.fbo; self.glDeleteFramebuffers(1, ids)
        if self.rb:
            ids[0] = self.rb; self.glDeleteRenderbuffers(1, ids)
        if self.tex:
            ids[0] = self.tex; self.glDeleteTextures(1, ids)
        self.fbo = self.tex = self.rb = 0

    def close(self):
        try:
            self.make_current()
            self._delete()
            self.ctx.doneCurrent()
        except Exception:
            pass


class Core:
    """نواة libretro واحدة (LRPS2)."""

    def __init__(self, core_path, save_dir, system_dir=None, options=None, log=print):
        ext = os.path.splitext(core_path)[1]
        self._copy = os.path.join(tempfile.gettempdir(),
                                  f"ps2online_core_{os.getpid()}_{next(_instance_ids)}{ext}")
        shutil.copyfile(core_path, self._copy)
        self.log = log
        self.lib = L = CDLL(self._copy)
        L.retro_api_version.restype = c_uint
        L.retro_serialize_size.restype = c_size_t
        L.retro_serialize.argtypes = [c_void_p, c_size_t]
        L.retro_serialize.restype = c_bool
        L.retro_unserialize.argtypes = [c_void_p, c_size_t]
        L.retro_unserialize.restype = c_bool
        L.retro_load_game.argtypes = [POINTER(GameInfo)]
        L.retro_load_game.restype = c_bool
        L.retro_get_memory_data.argtypes = [c_uint]
        L.retro_get_memory_data.restype = c_void_p
        L.retro_get_memory_size.argtypes = [c_uint]
        L.retro_get_memory_size.restype = c_size_t
        L.retro_get_system_av_info.argtypes = [POINTER(SystemAvInfo)]
        L.retro_get_system_info.argtypes = [POINTER(SystemInfo)]
        L.retro_set_controller_port_device.argtypes = [c_uint, c_uint]

        si = SystemInfo()
        L.retro_get_system_info(byref(si))
        self.version = (si.library_version or b"").decode("utf-8", "replace")
        self.name = (si.library_name or b"").decode("utf-8", "replace")

        self.pixel_format = 0
        self.frame = None              # (bytes, w, h, pitch, pixel_format)
        self.presented = False         # هل أخرج آخر retro_run إطاراً حقيقياً؟
        self.audio = bytearray()       # int16 stereo
        self.inputs = [NO_INPUT, NO_INPUT]
        self.loaded = False
        self.fps, self.sample_rate = 59.94, 48000.0
        self.max_w, self.max_h = 640, 512
        self.hw = None                 # HwRenderCallback إذا طلبت النواة OpenGL
        self.gl = None
        self.options = dict(CORE_OPTIONS if options is None else options)
        self._optbuf = {}
        self._opt_update = False
        self._dir = create_string_buffer(os.path.abspath(save_dir).encode("utf-8"))
        self._sys = create_string_buffer(os.path.abspath(system_dir or save_dir).encode("utf-8"))
        self._cb_env = ENV_CB(self._env)
        self._cb_video = VIDEO_CB(self._video)
        self._cb_audio = AUDIO_CB(self._audio1)
        self._cb_batch = AUDIO_BATCH_CB(self._audio_batch)
        self._cb_poll = POLL_CB(lambda: None)
        self._cb_state = STATE_CB(self._state)

        L.retro_set_environment(self._cb_env)
        L.retro_init()
        L.retro_set_video_refresh(self._cb_video)
        L.retro_set_audio_sample(self._cb_audio)
        L.retro_set_audio_sample_batch(self._cb_batch)
        L.retro_set_input_poll(self._cb_poll)
        L.retro_set_input_state(self._cb_state)
        self._inited = True

    @property
    def wants_gl(self):
        return self.options.get("pcsx2_renderer") == RENDERERS["gl"]

    # ---- callbacks ----
    def _env(self, cmd, data):
        try:
            if cmd == 10:                                  # SET_PIXEL_FORMAT
                fmt = cast(data, POINTER(c_int))[0]
                if fmt not in (0, 1, 2):
                    return False
                self.pixel_format = fmt
                return True
            if cmd == 9:                                   # GET_SYSTEM_DIRECTORY (البايوس)
                cast(data, POINTER(c_void_p))[0] = addressof(self._sys)
                return True
            if cmd == 31:                                  # GET_SAVE_DIRECTORY (بطاقة الذاكرة)
                cast(data, POINTER(c_void_p))[0] = addressof(self._dir)
                return True
            if cmd == 3:                                   # GET_CAN_DUPE
                cast(data, POINTER(c_bool))[0] = True
                return True
            if cmd == 15:                                  # GET_VARIABLE
                var = cast(data, POINTER(RetroVariable))[0]
                key = (var.key or b"").decode("ascii", "replace")
                val = self.options.get(key)
                if not val:
                    return False
                buf = self._optbuf.get(key)
                if buf is None or buf.value != val.encode("utf-8"):
                    buf = self._optbuf[key] = create_string_buffer(val.encode("utf-8"))
                cast(data, POINTER(c_void_p))[1] = addressof(buf)    # var->value
                return True
            if cmd == 17:                                  # GET_VARIABLE_UPDATE
                cast(data, POINTER(c_bool))[0] = self._opt_update
                self._opt_update = False
                return True
            if cmd == (51 | ENV_EXP):                      # GET_INPUT_BITMASKS
                return True
            if cmd == 56:                                  # GET_PREFERRED_HW_RENDER
                cast(data, POINTER(c_int))[0] = HW_OPENGL_CORE if self.wants_gl else HW_NONE
                return True
            if cmd == 14:                                  # SET_HW_RENDER
                hw = cast(data, POINTER(HwRenderCallback))[0]
                if not self.wants_gl or hw.context_type not in (HW_OPENGL_CORE, HW_OPENGL):
                    return False
                if self.gl is None:
                    self.gl = GLTarget(self.log)
                hw.get_current_framebuffer = cast(self.gl.cb_fb, c_void_p).value
                hw.get_proc_address = cast(self.gl.cb_proc, c_void_p).value
                self.hw = HwRenderCallback.from_buffer_copy(hw)
                return True
            if cmd == (44 | ENV_EXP):                      # SET_HW_SHARED_CONTEXT
                return self.wants_gl
            if cmd == 32:                                  # SET_SYSTEM_AV_INFO
                av = cast(data, POINTER(SystemAvInfo))[0]
                self._apply_av(av)
                return True
            if cmd == 37:                                  # SET_GEOMETRY
                return True
        except Exception as e:
            try:
                self.log(f"خطأ في النواة (env {cmd}): {e}")
            except Exception:
                pass
        return False

    def _apply_av(self, av):
        if av.timing.fps:
            self.fps = av.timing.fps
        if av.timing.sample_rate:
            self.sample_rate = av.timing.sample_rate
        self.max_w = av.geometry.max_width or av.geometry.base_width or self.max_w
        self.max_h = av.geometry.max_height or av.geometry.base_height or self.max_h
        if self.gl is not None and self.loaded:
            self.gl.resize(self.max_w, self.max_h)

    def _video(self, data, w, h, pitch):
        if not data or not w or not h:
            return                                         # تكرار الإطار السابق (لا يوجد إطار جديد)
        self.presented = True
        if self.hw is not None and data == HW_FRAME_VALID:
            fr = self.gl.read(w, h)
            if fr is not None:
                self.frame = fr
        else:
            self.frame = (string_at(data, pitch * h), w, h, pitch, self.pixel_format)

    def _audio1(self, l, r):
        self.audio += struct.pack("<hh", l, r)

    def _audio_batch(self, data, frames):
        self.audio += string_at(data, frames * 4)
        return frames

    def _state(self, port, device, index, id_):
        if port > 1:
            return 0
        m, lx, ly, rx, ry = self.inputs[port]
        dev = device & 0xFF
        if dev == RETRO_DEVICE_JOYPAD:
            if id_ == 256:                                 # JOYPAD_MASK
                return m
            return (m >> id_) & 1
        if dev == RETRO_DEVICE_ANALOG:
            if index == 0:
                return lx if id_ == 0 else ly
            if index == 1:
                return rx if id_ == 0 else ry
            return 0                                       # ضغط الأزرار التناظري: النواة تستخدم الرقمي
        return 0

    # ---- API ----
    def set_option(self, key, val):
        if self.options.get(key) != val:
            self.options[key] = val
            self._opt_update = True

    def load(self, game_path):
        L = self.lib
        self._rom_path = os.path.abspath(game_path).encode("utf-8")
        gi = GameInfo(self._rom_path, None, 0, None)        # النواة تقرأ القرص بنفسها (need_fullpath)
        if not L.retro_load_game(byref(gi)):
            if self.wants_gl and self.hw is None:
                raise RuntimeError("النواة رفضت OpenGL — اختر «المعالج (Software)» من الإعدادات")
            raise RuntimeError("النواة رفضت تحميل اللعبة — تأكد من ملف اللعبة ومن وجود البايوس "
                               "في client/system/pcsx2/bios")
        self.loaded = True
        av = SystemAvInfo()
        L.retro_get_system_av_info(byref(av))
        self._apply_av(av)
        if self.hw is not None:
            self.gl.make_current()
            self.gl.resize(self.max_w, self.max_h)
            if self.hw.context_reset:
                HW_VOID_CB(self.hw.context_reset)()
        for p in (0, 1):
            L.retro_set_controller_port_device(p, RETRO_DEVICE_JOYPAD)

    def run(self, p1, p2):
        """يشغّل retro_run مرة. يرجع True إذا أخرجت النواة إطاراً حقيقياً (وليس تكراراً)."""
        self.inputs[0], self.inputs[1] = p1, p2
        self.presented = False
        if self.gl is not None:
            self.gl.make_current()
        self.lib.retro_run()
        return self.presented

    def save_state(self):
        if self.gl is not None:
            self.gl.make_current()
        n = self.lib.retro_serialize_size()
        buf = create_string_buffer(n)
        if not self.lib.retro_serialize(buf, n):
            raise RuntimeError("فشل حفظ الحالة")
        return buf.raw

    def load_state(self, data):
        if self.gl is not None:
            self.gl.make_current()
        buf = (c_char * len(data)).from_buffer_copy(data)
        return bool(self.lib.retro_unserialize(buf, len(data)))

    def memory(self, kind=MEM_SYSTEM_RAM):
        p = self.lib.retro_get_memory_data(kind)
        n = self.lib.retro_get_memory_size(kind)
        if not p or not n:
            return None
        return (c_ubyte * n).from_address(p)

    def close(self):
        try:
            if self.gl is not None:
                self.gl.make_current()
            if self.loaded:
                if self.hw is not None and self.hw.context_destroy:
                    HW_VOID_CB(self.hw.context_destroy)()
                self.lib.retro_unload_game()
            if getattr(self, "_inited", False):
                self.lib.retro_deinit()
        except Exception:
            pass
        if self.gl is not None:
            self.gl.close()
            self.gl = None
        self.loaded = False
        self._inited = False
        if sys.platform == "win32":
            try:
                import ctypes
                k32 = ctypes.WinDLL("kernel32", use_last_error=True)
                k32.FreeLibrary.argtypes = [c_void_p]
                k32.FreeLibrary(c_void_p(self.lib._handle))
            except Exception:
                pass
        try:
            os.remove(self._copy)
        except OSError:
            pass


# ============================================================================
#  View plugins (شيء مختلف فوق الشاشة لكل لاعب)
# ============================================================================
class NoView:
    name = "بدون (نفس الشاشة للجميع)"

    def overlay(self, painter, rect, ram, player):
        pass


def load_plugins(log=print):
    plugins = [NoView()]
    for path in sorted(glob.glob(os.path.join(APP_DIR, "plugins", "*.py"))):
        if os.path.basename(path).startswith("_"):
            continue
        try:
            spec = importlib.util.spec_from_file_location(
                "ps2view_" + os.path.splitext(os.path.basename(path))[0], path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            p = getattr(mod, "PLUGIN", None)
            if p is not None:
                plugins.append(p)
        except Exception as e:
            log(f"فشل تحميل الإضافة {os.path.basename(path)}: {e}")
    return plugins


# ============================================================================
#  Network (WebSocket إلى سيرفر Cloudflare)
# ============================================================================
class Net:
    def __init__(self, url):
        from websockets.sync.client import connect
        self.inbox = queue.Queue()
        self.ws = connect(url, max_size=None, compression=None, open_timeout=15)
        try:
            self.ws.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception:
            pass
        self._lock = threading.Lock()
        threading.Thread(target=self._rx, daemon=True).start()

    def _rx(self):
        try:
            for msg in self.ws:
                self.inbox.put(msg)
        except Exception:
            pass
        self.inbox.put(None)

    def send(self, data):
        try:
            with self._lock:
                self.ws.send(data)
        except Exception:
            pass

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


# ============================================================================
#  ملفات اللعبة + البايوس + بطاقة الذاكرة
# ============================================================================
def disc_files(path):
    """كل الملفات التي يتكون منها القرص (cue + bin...) بالترتيب"""
    path = os.path.abspath(path)
    ext = os.path.splitext(path)[1].lower()
    base = os.path.dirname(path)
    out = [path]
    try:
        if ext == ".cue":
            import re
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = re.match(r'\s*FILE\s+"?(.+?)"?\s+\w+\s*$', line)
                    if m:
                        out.append(os.path.join(base, m.group(1)))
        elif ext == ".m3u":
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        out += disc_files(os.path.join(base, line))
    except OSError:
        pass
    return out


_CRC_CACHE = None


def _disc_key(path):
    return "|".join(f"{os.path.abspath(f)}:{os.path.getsize(f)}:{int(os.path.getmtime(f))}"
                    for f in disc_files(path) if os.path.isfile(f))


def _load_crc_cache():
    global _CRC_CACHE
    cache_path = os.path.join(APP_DIR, "disc_cache.json")
    if _CRC_CACHE is None:
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                _CRC_CACHE = json.load(f)
        except (OSError, ValueError):
            _CRC_CACHE = {}
    return cache_path


def disc_crc_cached(path):
    """البصمة إذا كانت محسوبة سابقاً، وإلا None (بدون قراءة الملف)"""
    _load_crc_cache()
    try:
        return _CRC_CACHE.get(_disc_key(path))
    except OSError:
        return None


def disc_crc(path):
    """بصمة القرص = CRC32 لكل ملفاته (تُحفظ مؤقتاً حتى لا نقرأ عدة جيجابايت كل مرة)"""
    cache_path = _load_crc_cache()
    files = disc_files(path)
    key = _disc_key(path)
    if key in _CRC_CACHE:
        return _CRC_CACHE[key]
    crc = 0
    for fn in files:
        if not os.path.isfile(fn):
            raise RuntimeError(f"ملف ناقص من القرص: {os.path.basename(fn)}")
        if os.path.splitext(fn)[1].lower() in (".cue", ".m3u"):
            continue                       # اسم الملف داخل الـ cue لا يهم — المهم البيانات
        with open(fn, "rb") as f:
            while True:
                b = f.read(8 << 20)
                if not b:
                    break
                crc = zlib.crc32(b, crc)
    _CRC_CACHE[key] = crc
    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(_CRC_CACHE, f)
    except OSError:
        pass
    return crc


def list_bios():
    """[(اسم الملف، البصمة)] لكل ملفات البايوس في system/pcsx2/bios (حجم 4–8MB)"""
    out = []
    try:
        names = sorted(os.listdir(BIOS_DIR))
    except OSError:
        return out
    for n in names:
        p = os.path.join(BIOS_DIR, n)
        try:
            if not os.path.isfile(p) or not (4 << 20) <= os.path.getsize(p) <= (8 << 20):
                continue
            with open(p, "rb") as f:
                out.append((n, hashlib.sha1(f.read()).hexdigest()[:16]))
        except OSError:
            pass
    return out


def bios_by_hash(h):
    for n, bh in list_bios():
        if bh == h:
            return n
    return None


def card_path(save_dir, game_path):
    """النواة تسمّي بطاقة الذاكرة باسم ملف اللعبة بدون الامتداد"""
    name = os.path.splitext(os.path.basename(game_path))[0]
    return os.path.join(save_dir, name + ".ps2")


def file_sha(path, n=16):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()[:n]


# ============================================================================
#  Netplay session (lockstep)
# ============================================================================
MSG_HELLO, MSG_STATE, MSG_START, MSG_READY, MSG_INPUT, MSG_CHECK, MSG_PING, MSG_PONG, MSG_VOICE, MSG_CHAT, \
    MSG_MCD, MSG_SETUP = range(1, 13)
CHUNK = 128 * 1024
CHECK_EVERY = 120
STALL_LIMIT = 600            # محاولات retro_run متتالية بدون إطار = المحاكي توقف

SERVER_ERRORS = {
    "room_taken": "هذه الغرفة مستخدمة — اختر كوداً آخر",
    "room_full": "الغرفة ممتلئة (لاعبان فقط)",
    "no_room": "لا توجد غرفة بهذا الكود — تأكد أن المضيف أنشأها أولاً",
}


def pack_input(inp):
    return struct.pack("<Hhhhh", *inp)


class Session:
    """mode: 'offline' | 'host' | 'join'. المضيف = اللاعب 1، الضيف = اللاعب 2.

    المضيف يشغّل اللعبة فوراً. الضيف ينتظر إعدادات المضيف وبطاقة ذاكرته، ثم يشغّل اللعبة
    ويحمّل حالة المضيف — بهذا تكون اللعبة متطابقة عند الاثنين."""

    def __init__(self, core_path, rom_path, plugin, mode, server=None, room=None,
                 name="Player", delay=3, bios=None, renderer="sw", upscale=1, log=print, token=""):
        self.mode = mode
        self.host = mode != "join"
        self.player = 0 if self.host else 1
        self.plugin = plugin
        self.delay = max(1, min(int(delay), 20))
        self.name = name
        self.log = log
        self.status = ""
        self.rtt = None
        self.desync = False
        self.peer = None
        self.video = None
        self.net = None
        self.rom_path = rom_path
        self._last_ping = 0.0
        self._chunks = {MSG_STATE: {}, MSG_MCD: {}}
        self._totals = {MSG_STATE: 0, MSG_MCD: 0}
        self._setup = None
        self._stall = 0
        self._frames_run = 0
        self.sync_progress = None    # (المستلم، الكل) أثناء استقبال حالة اللعبة
        self.voice_in = []           # حزم صوت µ-law واردة من الخصم
        self.voice_last = 0.0
        self._voice_seq = 0
        self.chat_in = []            # رسائل نصية واردة من الخصم

        os.makedirs(BIOS_DIR, exist_ok=True)
        self.rom_crc = disc_crc(rom_path)
        self.saves = os.path.join(APP_DIR, "saves")
        # الضيف يستخدم مجلداً منفصلاً لبطاقة الذاكرة، فتُكتب فيه بطاقة المضيف ولا تضيع بطاقته هو
        self.save_dir = self.saves if self.host else os.path.join(self.saves, "netplay")
        os.makedirs(self.save_dir, exist_ok=True)
        self.card = card_path(self.save_dir, rom_path)

        self.options = dict(CORE_OPTIONS)
        self.options["pcsx2_renderer"] = RENDERERS.get(renderer, RENDERERS["sw"])
        self.options["pcsx2_upscale_multiplier"] = UPSCALE.get(int(upscale), UPSCALE[1])
        self.bios_list = list_bios()
        if not self.bios_list:
            raise RuntimeError("لا يوجد بايوس PS2 — ضع ملف البايوس (مثل SCPH-70012.bin) في المجلد:\n"
                               + BIOS_DIR)
        if self.host:
            pick = next((b for b in self.bios_list if b[0] == bios), self.bios_list[0])
            self.options["pcsx2_bios"] = pick[0]
            self.bios_hash = pick[1]

        self.core = Core(core_path, self.save_dir, SYSTEM_DIR, self.options, log=log)
        try:
            if self.host:
                self.core.load(rom_path)
            self._reset_lockstep()

            if mode == "offline":
                self.phase = "running"
            else:
                if not server or "YOUR-NAME" in server:
                    raise RuntimeError("لم تكتب رابط السيرفر بعد — اكتب رابط سيرفرك بصيغة wss://….workers.dev في الإعدادات")
                q = urllib.parse.urlencode({"role": "host" if self.host else "guest", "name": name,
                                            "token": token})
                url = f"{server.rstrip('/')}/room/{room}?{q}"
                self.phase = "connecting"
                self.status = "جارِ الاتصال بالسيرفر..."
                self.net = Net(url)
        except Exception:
            self.close(save=False)
            raise

    # ---------------- helpers ----------------
    def _reset_lockstep(self):
        D = self.delay
        self.frame = 0
        self.local = {f: NO_INPUT for f in range(D)}
        self.remote = {f: NO_INPUT for f in range(D)}
        self.remote_max = D - 1
        self.chk_l, self.chk_r = {}, {}
        self.desync = False
        self._stall = 0

    def _warmup(self):
        """يشغّل إطاراً واحداً على الأقل قبل حفظ/تحميل الحالة (النواة تفتح الرسم عند أول retro_run)"""
        if self._frames_run:
            return
        for _ in range(STALL_LIMIT):
            if self.core.run(NO_INPUT, NO_INPUT):
                break
        self._frames_run += 1
        self.core.audio.clear()

    def _hello(self):
        info = {"proto": PROTO, "system": SYSTEM, "crc": self.rom_crc, "name": self.name,
                "plugin": self.plugin.name, "core": self.core.version, "platform": PLATFORM,
                "bios": [h for _, h in self.bios_list]}
        self.net.send(bytes([MSG_HELLO]) + json.dumps(info).encode("utf-8"))

    def _send_chunks(self, kind, blob):
        chunks = [blob[i:i + CHUNK] for i in range(0, len(blob), CHUNK)] or [b""]
        for i, c in enumerate(chunks):
            self.net.send(struct.pack("<BHH", kind, i, len(chunks)) + c)

    def _send_sync(self):
        """المضيف: إعدادات المحاكي + بطاقة الذاكرة + حالة اللعبة"""
        self.status = "جارِ تجهيز حالة اللعبة للاعب الآخر..."
        setup = {"options": self.options, "bios": self.bios_hash, "delay": self.delay}
        self.net.send(bytes([MSG_SETUP]) + json.dumps(setup).encode("utf-8"))
        card = b""
        if os.path.isfile(self.card):
            with open(self.card, "rb") as f:
                card = f.read()
        self._send_chunks(MSG_MCD, zlib.compress(card, 6) if card else b"")
        self._warmup()
        st = zlib.compress(self.core.save_state(), 1)
        self._send_chunks(MSG_STATE, st)
        self.log(f"تم إرسال حالة اللعبة ({len(st) / 1048576:.1f} MB)")
        self._reset_lockstep()
        self.net.send(struct.pack("<BB", MSG_START, self.delay))
        self.phase = "syncing"
        self.status = "جارِ مزامنة اللعبة مع اللاعب الآخر..."

    def _blob(self, kind):
        parts = self._chunks[kind]
        total = self._totals[kind]
        if total == 0 or len(parts) < total:
            return None
        blob = b"".join(parts[i] for i in range(total))
        self._chunks[kind] = {}
        self._totals[kind] = 0
        return blob

    def _guest_start(self, delay):
        """الضيف: يكتب بطاقة المضيف، يطبّق إعداداته، يشغّل اللعبة ثم يحمّل حالة المضيف"""
        setup = self._setup or {}
        st = self._blob(MSG_STATE)
        card = self._blob(MSG_MCD)
        if st is None:
            raise RuntimeError("لم تصل حالة اللعبة كاملة من المضيف")
        if not self.core.loaded:
            opts = dict(setup.get("options") or {})
            bios = bios_by_hash(setup.get("bios"))
            if not bios:
                raise RuntimeError("البايوس عند المضيف غير موجود عندك — انسخ نفس ملف البايوس إلى "
                                   + BIOS_DIR)
            opts["pcsx2_bios"] = bios
            self.options = opts
            self.core.options = dict(opts)
            if card is not None:
                if card:
                    with open(self.card, "wb") as f:
                        f.write(zlib.decompress(card))
                elif os.path.isfile(self.card):
                    os.remove(self.card)       # المضيف بدون بطاقة = الضيف بدون بطاقة
            self.status = "جارِ تشغيل اللعبة..."
            self.core.load(self.rom_path)
            self._warmup()
            self.log("المحاكي: " + ("كرت الشاشة (OpenGL)" if self.core.wants_gl else "المعالج (Software)")
                     + f" — دقة {opts.get('pcsx2_upscale_multiplier', '1x')}")
        if not self.core.load_state(zlib.decompress(st)):
            raise RuntimeError("فشل تحميل حالة اللعبة من المضيف (نسخة النواة أو البايوس مختلف؟)")
        self.delay = delay
        self._reset_lockstep()

    # ---------------- network events ----------------
    def poll(self):
        if not self.net:
            return
        while True:
            try:
                msg = self.net.inbox.get_nowait()
            except queue.Empty:
                break
            if msg is None:
                if self.phase != "error":
                    self.phase = "closed"
                    self.status = "انقطع الاتصال بالسيرفر"
                return
            try:
                if isinstance(msg, str):
                    self._on_server(json.loads(msg))
                elif msg:
                    self._on_peer(msg)
            except Exception as e:
                self.log(f"رسالة غير صالحة: {e}")
            if self.phase == "error":
                return
        now = time.perf_counter()
        if self.peer and now - self._last_ping > 1.0:
            self._last_ping = now
            self.net.send(struct.pack("<Bd", MSG_PING, now))

    def _on_server(self, m):
        t = m.get("t")
        if t == "welcome":
            self.phase = "waiting"
            self.status = ("الغرفة جاهزة — بانتظار انضمام اللاعب الآخر..."
                           if self.host else "بانتظار المضيف...")
        elif t == "peer_join":
            self.peer = m.get("name", "?")
            self.log(f"انضم: {self.peer}")
            self._hello()
        elif t == "peer_left":
            self.log(f"خرج: {self.peer}")
            self.peer = None
            if self.host:
                self.phase = "waiting"
                self.status = "اللاعب الآخر خرج — بانتظار عودته..."
            else:
                self.phase, self.status = "closed", "المضيف خرج من الغرفة"
        elif t == "error":
            self.phase = "error"
            self.status = SERVER_ERRORS.get(m.get("code"), f"خطأ من السيرفر: {m.get('code')}")

    def _fail(self, text):
        self.phase, self.status = "error", text
        self.log(text)

    def _on_peer(self, data):
        k, p = data[0], data[1:]
        if k == MSG_INPUT:
            f, b, lx, ly, rx, ry = struct.unpack_from("<IHhhhh", p)
            self.remote[f] = (b, lx, ly, rx, ry)
            if f > self.remote_max:
                self.remote_max = f
        elif k == MSG_CHECK:
            f, c = struct.unpack_from("<II", p)
            self.chk_r[f] = c
            self._compare(f)
        elif k == MSG_PING:
            self.net.send(bytes([MSG_PONG]) + p)
        elif k == MSG_PONG:
            (t0,) = struct.unpack_from("<d", p)
            self.rtt = (time.perf_counter() - t0) * 1000.0
        elif k == MSG_HELLO:
            info = json.loads(bytes(p).decode("utf-8"))
            if info.get("system", "SNES") != SYSTEM:
                return self._fail(f"اللاعب الآخر يستخدم برنامج {info.get('system', 'SNES')} Online وليس PS2 Online")
            if info.get("proto") != PROTO:
                return self._fail("إصدار البرنامج مختلف عند اللاعب الآخر — حدّث البرنامجين")
            if info.get("core") != self.core.version:
                return self._fail(f"نسخة النواة مختلفة: عندك {self.core.version} وعند الخصم {info.get('core')} "
                                  "— استخدما نفس حزمة PS2-Online-PC")
            if info.get("platform"):
                self.log(f"جهاز الخصم: {info.get('platform')}")
            if info.get("crc") != self.rom_crc:
                return self._fail("ملف اللعبة مختلف عند اللاعبين! يجب أن يكون نفس ملف ISO بالضبط (ونفس الباتش)")
            if self.host and self.bios_hash not in (info.get("bios") or []):
                return self._fail("اللاعب الآخر لا يملك نفس ملف البايوس الذي تستخدمه — "
                                  "أرسل له نفس الملف أو اختر بايوساً موجوداً عنده")
            if not self.host and not set(info.get("bios") or []) & {h for _, h in self.bios_list}:
                return self._fail("لا يوجد عندك نفس بايوس المضيف — انسخ نفس الملف إلى " + BIOS_DIR)
            if info.get("plugin") != self.plugin.name:
                self.log(f"تنبيه: اللاعب الآخر يستخدم إضافة عرض مختلفة ({info.get('plugin')})")
            if self.host:
                self._send_sync()
        elif k == MSG_SETUP:
            self._setup = json.loads(bytes(p).decode("utf-8"))
            self.status = "جارِ استقبال حالة اللعبة من المضيف..."
        elif k in (MSG_STATE, MSG_MCD):
            idx, total = struct.unpack_from("<HH", p)
            self._chunks[k][idx] = bytes(p[4:])
            self._totals[k] = total
            if k == MSG_STATE:
                self.sync_progress = (len(self._chunks[k]), total)
        elif k == MSG_START:
            (delay,) = struct.unpack_from("<B", p)
            self.sync_progress = None
            try:
                self._guest_start(delay)
            except Exception as e:
                return self._fail(str(e))
            self.phase, self.status = "running", ""
            self.net.send(bytes([MSG_READY]))
        elif k == MSG_CHAT:
            text = bytes(p).decode("utf-8", "replace").strip()[:200]
            if text:
                self.chat_in.append(text)
        elif k == MSG_VOICE:
            if len(p) > 2:
                if len(self.voice_in) < 50:
                    self.voice_in.append(bytes(p[2:]))
                self.voice_last = time.perf_counter()
        elif k == MSG_READY and self.host:
            self.phase, self.status = "running", ""
            self.log("بدأت المباراة!")

    def _compare(self, f):
        if f in self.chk_l and f in self.chk_r:
            if self.chk_l.pop(f) != self.chk_r.pop(f):
                self.desync = True
                self.log(f"⚠ عدم تطابق (desync) عند الإطار {f}")

    # ---------------- emulation ----------------
    def behind(self):
        return self.net is not None and self.phase == "running" and \
            self.remote_max - self.frame > self.delay + 1

    def step(self, inp):
        """يشغّل إطاراً واحداً إذا كانت مدخلات الطرفين متوفرة. يرجع True إذا تقدّم.
        inp = (أزرار، lx، ly، rx، ry)"""
        if self.phase != "running":
            return False
        if self.mode == "offline":
            if self._run(inp, NO_INPUT):
                self.frame += 1
                return True
            return False
        tf = self.frame + self.delay
        if tf not in self.local:
            self.local[tf] = inp
            self.net.send(struct.pack("<BI", MSG_INPUT, tf) + pack_input(inp))
        r = self.remote.get(self.frame)
        if r is None:
            return False
        l = self.local[self.frame]
        # PCSX2 قد يرجع من retro_run قبل اكتمال الإطار (انتظار محدود). نعيد نفس المدخلات حتى يكتمل،
        # فالنواة تثبّت المدخلات عند بداية الإطار ولا تتغير — وبهذا يبقى الطرفان متطابقين.
        if not (self._run(l, r) if self.host else self._run(r, l)):
            return False
        del self.remote[self.frame]
        del self.local[self.frame]
        if self.frame % CHECK_EVERY == 0:
            mem = self.core.memory(MEM_SYSTEM_RAM)
            c = zlib.crc32(mem) if mem is not None else 0
            self.chk_l[self.frame] = c
            self.net.send(struct.pack("<BII", MSG_CHECK, self.frame, c))
            self._compare(self.frame)
        self.frame += 1
        return True

    def _run(self, p1, p2):
        ok = self.core.run(p1, p2)
        if ok:
            self._stall = 0
            self._frames_run += 1
            self.video = self.core.frame
        else:
            self._stall += 1
            if self._stall == STALL_LIMIT:
                self.log("⚠ المحاكي لا يُخرج إطارات — قد تكون اللعبة أو البايوس غير مدعومين")
        return ok

    def send_chat(self, text):
        text = text.strip()[:200]
        if text and self.net and self.peer:
            self.net.send(bytes([MSG_CHAT]) + text.encode("utf-8"))
            return True
        return False

    def send_voice(self, data):
        if self.net and self.peer:
            self._voice_seq = (self._voice_seq + 1) & 0xFFFF
            self.net.send(struct.pack("<BH", MSG_VOICE, self._voice_seq) + data)

    def close(self, save=True):
        # بطاقة الذاكرة تكتبها النواة بنفسها في saves/ (للمضيف فقط — الضيف يستخدم saves/netplay)
        if self.net:
            self.net.close()
            self.net = None
        if getattr(self, "core", None) is not None:
            self.core.close()


# ============================================================================
#  Voice codec (G.711 µ-law, 16 kHz mono) — مطابق لنسخة الآيفون
# ============================================================================
VOICE_RATE = 16000
VOICE_FRAME = 640            # 40ms


def _mulaw_encode_one(sample):
    BIAS, CLIP = 0x84, 32635
    sign = 0x80 if sample < 0 else 0
    if sample < 0:
        sample = -sample
    if sample > CLIP:
        sample = CLIP
    sample += BIAS
    exponent, mask = 7, 0x4000
    while exponent > 0 and not (sample & mask):
        exponent -= 1
        mask >>= 1
    mantissa = (sample >> (exponent + 3)) & 0x0F
    return ~(sign | (exponent << 4) | mantissa) & 0xFF


def _mulaw_decode_one(u):
    u = ~u & 0xFF
    t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
    return (0x84 - t) if (u & 0x80) else (t - 0x84)


_MULAW_ENC = None
MULAW_DEC = [_mulaw_decode_one(i) for i in range(256)]


def mulaw_encode(samples):
    global _MULAW_ENC
    if _MULAW_ENC is None:
        _MULAW_ENC = bytes(_mulaw_encode_one(v - 65536 if v >= 32768 else v) for v in range(65536))
    t = _MULAW_ENC
    return bytes(t[v & 0xFFFF] for v in samples)


def mulaw_decode(data):
    d = MULAW_DEC
    return [d[b] for b in data]


# ============================================================================
#  Lobby: اللاعبون المتصلون + التحدي
# ============================================================================
class Lobby:
    def __init__(self, log=print):
        self.log = log
        self.net = None
        self.server = self.pid = None
        self.name = ""
        self.game = ""
        self.status = "idle"
        self.players = []
        self.online = 0
        self.connected = False
        self.version = 0
        self._connecting = False
        self._retry_at = 0.0
        self.dms = {}          # peer_id -> [(who, text, ts, mine)]
        self.unread = {}       # peer_id -> count

    def configure(self, server, pid, name, token=""):
        if (server, pid, name, token) != (self.server, self.pid, self.name, getattr(self, "token", "")):
            self.close()
            self.server, self.pid, self.name, self.token = server, pid, name, token
            self._retry_at = 0.0

    def _connect(self):
        if self._connecting or not self.server or "YOUR-NAME" in self.server:
            return
        self._connecting = True
        q = urllib.parse.urlencode({"id": self.pid, "name": self.name, "platform": f"{PLATFORM} PS2",
                                    "game": self.game, "status": self.status,
                                    "token": getattr(self, "token", "")})
        url = f"{self.server.rstrip('/')}/lobby?{q}"

        def run():
            try:
                self.net = Net(url)
            except Exception:
                self._retry_at = time.time() + 5
            finally:
                self._connecting = False
        threading.Thread(target=run, daemon=True).start()

    def poll(self):
        """يرجع قائمة أحداث: challenge / answer / cancel"""
        events = []
        if self.net is None:
            if time.time() >= self._retry_at:
                self._connect()
            return events
        while True:
            try:
                msg = self.net.inbox.get_nowait()
            except queue.Empty:
                break
            if msg is None:
                self.net = None
                self.connected = False
                self.players, self.online = [], 0
                self.version += 1
                self._retry_at = time.time() + 3
                break
            if not isinstance(msg, str):
                continue
            try:
                m = json.loads(msg)
            except ValueError:
                continue
            if m.get("t") == "players":
                self.players = m.get("players") or []
                self.online = int(m.get("online") or len(self.players))
                self.connected = True
                self.version += 1
            else:
                if m.get("t") == "dm":
                    frm = m.get("from") or {}
                    pid = frm.get("id", "")
                    self.dms.setdefault(pid, []).append((frm.get("name") or "?", m.get("text", ""), time.time(), False))
                    self.unread[pid] = self.unread.get(pid, 0) + 1
                    self.version += 1
                events.append(m)
        return events

    def _send(self, obj):
        if self.net:
            self.net.send(json.dumps(obj))

    def set_status(self, status, game=""):
        game = f"PS2 · {game}" if game else ""
        self.status, self.game = status, game
        self._send({"t": "status", "status": status, "game": game})

    def challenge(self, to, game, crc, room):
        self._send({"t": "challenge", "to": to, "game": f"PS2 · {game}", "crc": crc, "room": room})

    def answer(self, to, accept, room, reason=""):
        self._send({"t": "answer", "to": to, "accept": accept, "room": room, "reason": reason})

    def cancel(self, to):
        self._send({"t": "cancel", "to": to})

    def send_dm(self, to, text):
        text = text.strip()[:500]
        if not text or not self.net:
            return False
        self._send({"t": "dm", "to": to, "text": text})
        self.dms.setdefault(to, []).append(("أنت", text, time.time(), True))
        self.version += 1
        return True

    def call(self, to, room):
        self._send({"t": "call", "to": to, "room": room})

    def call_answer(self, to, accept, room, reason=""):
        self._send({"t": "call_answer", "to": to, "accept": accept, "room": room, "reason": reason})

    def call_end(self, to):
        self._send({"t": "call_end", "to": to})

    def close(self):
        if self.net:
            self.net.close()
            self.net = None
        self.connected = False


class VoiceCall:
    """مكالمة صوتية خاصة خارج اللعب — تستخدم نظام الغرف نفسه لتمرير الصوت"""

    def __init__(self, server, room, host, name, peer_id, peer_name, token=""):
        self.peer_id, self.peer_name, self.host, self.room = peer_id, peer_name, host, room
        self.phase = "connecting"
        self.peer = None
        self.voice_in = []
        self.voice_last = 0.0
        self.started = None
        self.reason = ""
        self._seq = 0
        self.net = None
        q = urllib.parse.urlencode({"role": "host" if host else "guest", "name": name, "token": token})
        url = f"{server.rstrip('/')}/room/{room}?{q}"

        def run():
            try:
                self.net = Net(url)
            except Exception:
                self.phase, self.reason = "ended", "تعذّر الاتصال بالسيرفر"
        threading.Thread(target=run, daemon=True).start()

    def poll(self):
        if not self.net:
            return
        while True:
            try:
                msg = self.net.inbox.get_nowait()
            except queue.Empty:
                break
            if msg is None:
                if self.phase != "ended":
                    self.phase, self.reason = "ended", "انقطع الاتصال"
                return
            if isinstance(msg, str):
                try:
                    m = json.loads(msg)
                except ValueError:
                    continue
                t = m.get("t")
                if t == "welcome" and self.phase == "connecting":
                    self.phase = "waiting"
                elif t == "peer_join":
                    self.peer = m.get("name") or self.peer_name
                    self.phase = "running"
                    self.started = time.time()
                elif t == "peer_left":
                    self.phase, self.reason = "ended", "انتهت المكالمة"
                elif t == "error":
                    self.phase, self.reason = "ended", "تعذّرت المكالمة"
            elif msg and msg[0] == MSG_VOICE and len(msg) > 3:
                if len(self.voice_in) < 50:
                    self.voice_in.append(bytes(msg[3:]))
                self.voice_last = time.perf_counter()

    def send_voice(self, data):
        if self.net and self.peer:
            self._seq = (self._seq + 1) & 0xFFFF
            self.net.send(struct.pack("<BH", MSG_VOICE, self._seq) + data)

    def close(self):
        if self.net:
            self.net.close()
        self.phase = "ended"


def find_rom_by_crc(crc, folders):
    """يبحث عن لعبة بنفس البصمة في المجلدات المعطاة — الملفات المحسوبة سابقاً أولاً (ملفات PS2 كبيرة)"""
    paths = []
    for d in folders:
        if d and os.path.isdir(d):
            paths += [p for p in sorted(glob.glob(os.path.join(d, "*"))) if p.lower().endswith(GAME_EXTS)]
    for cached_only in (True, False):
        for path in paths:
            try:
                if cached_only and disc_crc_cached(path) is None:
                    continue
                if disc_crc(path) == crc:
                    return path
            except Exception:
                pass
    return None


# ============================================================================
#  Accounts API (عبر السيرفر)
# ============================================================================
DEFAULT_SERVER = "wss://snes-online-relay.cruyfford4488.workers.dev"

AUTH_ERRORS = {
    "taken": "اسم المستخدم مستخدم من شخص آخر",
    "bad_username": "اسم المستخدم من 3 إلى 20 حرفاً (حروف وأرقام و _ . - فقط)",
    "bad_password": "كلمة المرور يجب أن تكون 6 أحرف على الأقل",
    "wrong": "اسم المستخدم أو كلمة المرور غير صحيحة",
    "locked": "محاولات كثيرة — انتظر دقيقة ثم حاول مرة أخرى",
    "network": "تعذّر الاتصال بالسيرفر — تأكد من الإنترنت",
    "too_big": "الصورة كبيرة جداً",
    "not_jpeg": "صيغة الصورة غير مدعومة",
    "auth": "انتهت الجلسة — سجّل الدخول من جديد",
}


def http_base(server):
    s = (server or DEFAULT_SERVER).strip().rstrip("/")
    if s.startswith("wss://"):
        return "https://" + s[6:]
    if s.startswith("ws://"):
        return "http://" + s[5:]
    return s


def api_call(server, path, body=None, token=None, timeout=15):
    """يرجع (status, json). status = 0 عند فشل الشبكة."""
    import urllib.request
    import urllib.error
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(http_base(server) + path, data=data,
                                 method="POST" if data is not None else "GET",
                                 headers={"content-type": "application/json", "user-agent": "PS2Online/2026"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": "network", "detail": str(e)}


def auth_error(res):
    return AUTH_ERRORS.get((res or {}).get("error"), "حدث خطأ — حاول مرة أخرى")


def disc_serial(path):
    """رقم القرص (مثل SLUS-20062) من ملف SYSTEM.CNF داخل القرص — يعمل مع .iso و .cue/.bin فقط"""
    import re
    files = [f for f in disc_files(path) if os.path.splitext(f)[1].lower() not in (".cue", ".m3u")]
    if not files or os.path.splitext(files[0])[1].lower() not in (".bin", ".iso", ".img"):
        return ""
    try:
        with open(files[0], "rb") as f:
            head = f.read(16)
            raw = head[:12] == b"\x00" + b"\xff" * 10 + b"\x00"
            size = 2352 if raw else 2048

            def sector(lba):
                f.seek(lba * size)
                d = f.read(size)
                if not raw:
                    return d
                return d[24:24 + 2048] if d[15] == 2 else d[16:16 + 2048]
            pvd = sector(16)
            if pvd[1:6] != b"CD001":
                return ""
            root = pvd[156:156 + 34]
            lba, length = int.from_bytes(root[2:6], "little"), int.from_bytes(root[10:14], "little")
            data = b"".join(sector(lba + i) for i in range((length + 2047) // 2048))
            i = 0
            while i < len(data):
                n = data[i]
                if n == 0:
                    i = (i // 2048 + 1) * 2048
                    continue
                name = data[i + 33:i + 33 + data[i + 32]].split(b";")[0].upper()
                if name == b"SYSTEM.CNF":
                    cnf = sector(int.from_bytes(data[i + 2:i + 6], "little")).decode("latin-1", "replace")
                    m = re.search(r"BOOT2?\s*=\s*cdrom0?:\\?\\?([A-Za-z]{4})[_-](\d{3})\.?(\d{2})", cnf)
                    return f"{m.group(1).upper()}-{m.group(2)}{m.group(3)}" if m else ""
                i += n
    except (OSError, IndexError):
        pass
    return ""


def fetch_cover(server, path, cache_dir):
    """يجلب غلاف اللعبة من السيرفر (يبحث برقم القرص أو بالاسم) ويحفظه. يرجع مسار الصورة أو None"""
    try:
        crc = f"{disc_crc(path) & 0xFFFFFFFF:08X}"
    except Exception:
        return None
    os.makedirs(cache_dir, exist_ok=True)
    out = os.path.join(cache_dir, crc + ".png")
    miss = out + ".none"
    if os.path.isfile(out):
        return out
    if os.path.isfile(miss) and time.time() - os.path.getmtime(miss) < 86400:
        return None
    q = urllib.parse.urlencode({"system": "ps2", "serial": disc_serial(path), "name": os.path.basename(path)})
    data = fetch_bytes(f"{http_base(server)}/cover?{q}", timeout=20)
    if data and data[:4] == b"\x89PNG":
        with open(out, "wb") as f:
            f.write(data)
        return out
    if data is None:
        open(miss, "w").close()
    return None


def fetch_bytes(url, timeout=10):
    import urllib.request
    try:
        req = urllib.request.Request(url, headers={"user-agent": "PS2Online/2026"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read() if r.status == 200 else None
    except Exception:
        return None


# ============================================================================
#  GUI (PySide6) — واجهة 2026
# ============================================================================
ACCENT_A, ACCENT_B = "#7C5CFF", "#00C2FF"

QSS = """
* { color: #E8EAF2; font-size: 14px; }
QMainWindow, #root, #page { background: #0B0D12; }
#sidebar { background: #0F121A; border-left: 1px solid #1C2231; }
#brand { font-size: 20px; font-weight: 800; }
#brandSub, #muted { color: #8A91A6; }
#h1 { font-size: 28px; font-weight: 800; }
#label { color: #8A91A6; font-size: 12px; font-weight: 700; }
#card { background: #141822; border: 1px solid #222939; border-radius: 18px; }
#romTitle { font-size: 16px; font-weight: 700; }
#chip { background: #141A27; border: 1px solid #232B3E; border-radius: 13px; padding: 5px 12px;
        color: #A7AEC2; font-size: 12px; font-weight: 600; }

QPushButton#nav { text-align: right; padding: 11px 14px; border-radius: 11px; background: transparent;
                  border: none; color: #9AA2B8; font-weight: 600; }
QPushButton#nav:hover { background: #161B27; color: #E8EAF2; }
QPushButton#nav:checked { background: #1C2236; color: #FFFFFF; }

QLineEdit, QSpinBox, QComboBox { background: #0D1017; border: 1px solid #252C3F; border-radius: 11px;
                                 padding: 10px 12px; selection-background-color: #7C5CFF; }
QLineEdit:focus, QSpinBox:focus, QComboBox:focus { border: 1px solid #7C5CFF; }
QLineEdit#code { font-size: 28px; font-weight: 800; padding: 8px 14px; }
QComboBox::drop-down { border: none; width: 26px; }
QComboBox QAbstractItemView { background: #141822; border: 1px solid #252C3F; outline: 0;
                              selection-background-color: #24304F; padding: 4px; }

QPushButton { background: #1A1F2E; border: 1px solid #293148; border-radius: 11px; padding: 10px 16px;
              font-weight: 600; }
QPushButton:hover { background: #212840; border-color: #36406A; }
QPushButton:pressed { background: #171C2B; }
QPushButton#primary { border: none; color: white; font-size: 16px; font-weight: 800; padding: 17px;
    border-radius: 15px;
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #7C5CFF, stop:1 #00C2FF); }
QPushButton#primary:hover {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #8F73FF, stop:1 #2ED0FF); }
QPushButton#secondary { font-size: 16px; font-weight: 800; padding: 17px; border-radius: 15px;
                        background: #181E30; border: 1px solid #3A4675; }
QPushButton#secondary:hover { background: #1F2740; border-color: #5A6BB0; }
QPushButton#ghost { background: transparent; border: 1px dashed #2E3650; color: #A7AEC2;
                    padding: 13px; border-radius: 14px; }
QPushButton#ghost:hover { border-color: #7C5CFF; color: #E8EAF2; }

QPlainTextEdit { background: #0D1017; border: 1px solid #222939; border-radius: 14px; padding: 12px;
                 font-family: Consolas, "DejaVu Sans Mono"; font-size: 12px; color: #B9C0D4; }
QCheckBox { spacing: 10px; }
QCheckBox::indicator { width: 18px; height: 18px; border-radius: 6px; border: 1px solid #36405A;
                       background: #0D1017; }
QCheckBox::indicator:checked { background: #7C5CFF; border-color: #7C5CFF; }
QScrollBar:vertical { background: transparent; width: 8px; margin: 4px; }
QScrollBar::handle:vertical { background: #2A3247; border-radius: 4px; min-height: 30px; }
QScrollBar::add-line, QScrollBar::sub-line { height: 0; }
QToolTip { background: #1A1F2E; color: #E8EAF2; border: 1px solid #293148; padding: 6px; }
QMessageBox { background: #141822; }
"""


def run_gui():
    from PySide6.QtCore import Qt, QTimer, QSettings, QRectF, QPointF, QBuffer, QByteArray, QIODevice
    from PySide6.QtGui import (QImage, QPainter, QColor, QFont, QPen, QLinearGradient,
                               QPainterPath, QFontMetricsF, QPixmap)
    from PySide6.QtWidgets import (QApplication, QWidget, QMainWindow, QLineEdit, QPushButton,
                                   QSpinBox, QComboBox, QHBoxLayout, QVBoxLayout, QGridLayout,
                                   QFileDialog, QMessageBox, QStackedWidget, QLabel, QFrame,
                                   QPlainTextEdit, QCheckBox, QAbstractSpinBox,
                                   QGraphicsDropShadowEffect, QButtonGroup, QListWidget,
                                   QListWidgetItem, QSlider, QDialog, QScrollArea)
    try:
        from PySide6.QtMultimedia import QAudioFormat, QAudioSink, QAudioSource, QMediaDevices
    except Exception:
        QAudioSink = None

    try:
        import pygame
        pygame.init()
        pygame.joystick.init()
    except Exception:
        pygame = None

    QIMG_FMT = {0: QImage.Format_RGB555, 1: QImage.Format_RGB32, 2: QImage.Format_RGB16}
    KEYMAP = {   # Z=✕  X=○  A=□  S=△  Q/W=L1/R1  E/R=L2/R2  C/V=L3/R3
        Qt.Key_Up: BTN_UP, Qt.Key_Down: BTN_DOWN, Qt.Key_Left: BTN_LEFT, Qt.Key_Right: BTN_RIGHT,
        Qt.Key_Z: BTN_B, Qt.Key_X: BTN_A, Qt.Key_A: BTN_Y, Qt.Key_S: BTN_X,
        Qt.Key_Q: BTN_L, Qt.Key_W: BTN_R, Qt.Key_E: BTN_L2, Qt.Key_R: BTN_R2,
        Qt.Key_C: BTN_L3, Qt.Key_V: BTN_R3,
        Qt.Key_Return: BTN_START, Qt.Key_Enter: BTN_START,
        Qt.Key_Shift: BTN_SELECT, Qt.Key_Backspace: BTN_SELECT,
    }
    # العصا التناظرية من لوحة المفاتيح: I J K L = اليسرى،  8 4 5 6 = اليمنى (نوع: (محور، قيمة))
    STICK_KEYS = {
        Qt.Key_J: (0, -32767), Qt.Key_L: (0, 32767), Qt.Key_I: (1, -32767), Qt.Key_K: (1, 32767),
        Qt.Key_4: (2, -32767), Qt.Key_6: (2, 32767), Qt.Key_8: (3, -32767), Qt.Key_5: (3, 32767),
    }
    # يد Xbox/PlayStation عبر pygame: A=✕ B=○ X=□ Y=△ LB/RB=L1/R1 — والزنادان L2/R2
    PAD_MAP = {0: BTN_B, 1: BTN_A, 2: BTN_Y, 3: BTN_X, 4: BTN_L, 5: BTN_R, 6: BTN_SELECT, 7: BTN_START,
               8: BTN_L3, 9: BTN_R3}
    FONT_FAMILIES = ["Segoe UI Variable Text", "Segoe UI", "Noto Sans Arabic", "DejaVu Sans"]

    def font(size, weight=QFont.Normal, mono=False):
        f = QFont()
        f.setFamilies(["Cascadia Mono", "Consolas", "DejaVu Sans Mono"] if mono else FONT_FAMILIES)
        f.setPointSizeF(size)
        f.setWeight(weight)
        return f

    def shadow(w, blur=36, alpha=110):
        e = QGraphicsDropShadowEffect(w)
        e.setBlurRadius(blur)
        e.setOffset(0, 10)
        e.setColor(QColor(0, 0, 0, alpha))
        w.setGraphicsEffect(e)

    def card():
        c = QFrame()
        c.setObjectName("card")
        shadow(c)
        return c

    def label(text, name="label"):
        l = QLabel(text)
        l.setObjectName(name)
        return l

    # ---------------- painted logo ----------------
    class Logo(QWidget):
        def __init__(self, size=44):
            super().__init__()
            self.setFixedSize(size, size)

        def paintEvent(self, e):
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            r = QRectF(self.rect())
            g = QLinearGradient(r.topLeft(), r.bottomRight())
            g.setColorAt(0, QColor(ACCENT_A))
            g.setColorAt(1, QColor(ACCENT_B))
            p.setBrush(g)
            p.setPen(Qt.NoPen)
            p.drawRoundedRect(r, r.width() * 0.28, r.width() * 0.28)
            c, d, rad = r.center(), r.width() * 0.2, r.width() * 0.1
            for (dx, dy), col in (((0, -1), "#FFFFFF"), ((1, 0), "#FFFFFFCC"),
                                  ((0, 1), "#FFFFFF99"), ((-1, 0), "#FFFFFF66")):
                p.setBrush(QColor(col))
                p.drawEllipse(QPointF(c.x() + dx * d, c.y() + dy * d), rad, rad)
            p.end()

    # ---------------- game view ----------------
    class VoiceIO:
        """ميكروفون + سماعة للمحادثة الصوتية (16kHz µ-law عبر السيرفر)"""

        def __init__(self, log):
            self.ok = False
            self.muted = False
            self.talking = False
            self.gain = 1.0
            self._hang = 0
            self._src_buf = []
            self._pos = 0.0
            self._frame = []
            self._out_pos = 0.0
            self._pending = bytearray()
            if QAudioSink is None or os.environ.get("PS2_ONLINE_NOAUDIO"):
                return
            try:
                indev, outdev = QMediaDevices.defaultAudioInput(), QMediaDevices.defaultAudioOutput()
                if indev.isNull() or outdev.isNull():
                    log("لا يوجد ميكروفون — المحادثة الصوتية غير متاحة")
                    return
                self.in_fmt, self.out_fmt = self._pick(indev), self._pick(outdev)
                self.src = QAudioSource(indev, self.in_fmt)
                self.mic = self.src.start()
                self.sink = QAudioSink(outdev, self.out_fmt)
                self.sink.setBufferSize(int(self.out_fmt.sampleRate() * self.out_fmt.bytesPerFrame() * 0.4))
                self.spk = self.sink.start()
                self.ok = self.mic is not None and self.spk is not None
                if self.ok:
                    log("🎤 المحادثة الصوتية تعمل — M للكتم (يفضّل استخدام سماعة رأس)")
            except Exception as e:
                log(f"تعذّر تشغيل الميكروفون: {e}")

        @staticmethod
        def _pick(dev):
            f = QAudioFormat()
            f.setSampleFormat(QAudioFormat.Int16)
            f.setChannelCount(1)
            for rate in (VOICE_RATE, 48000, 44100):
                f.setSampleRate(rate)
                if dev.isFormatSupported(f):
                    return QAudioFormat(f)
            return dev.preferredFormat()

        @staticmethod
        def _to_mono(data, fmt):
            ch = max(1, fmt.channelCount())
            sf = fmt.sampleFormat()
            if sf == QAudioFormat.Float:
                a = array.array("f"); a.frombytes(data[:len(data) - len(data) % 4])
                vals = [int(max(-1.0, min(1.0, v)) * 32767) for v in a]
            elif sf == QAudioFormat.Int32:
                a = array.array("i"); a.frombytes(data[:len(data) - len(data) % 4])
                vals = [v >> 16 for v in a]
            elif sf == QAudioFormat.UInt8:
                vals = [(v - 128) << 8 for v in data]
            else:
                a = array.array("h"); a.frombytes(data[:len(data) - len(data) % 2])
                vals = list(a)
            return vals if ch == 1 else vals[::ch]

        @staticmethod
        def _from_mono(vals, fmt):
            ch = max(1, fmt.channelCount())
            if ch > 1:
                vals = [v for v in vals for _ in range(ch)]
            sf = fmt.sampleFormat()
            if sf == QAudioFormat.Float:
                return array.array("f", [v / 32768.0 for v in vals]).tobytes()
            if sf == QAudioFormat.Int32:
                return array.array("i", [v << 16 for v in vals]).tobytes()
            if sf == QAudioFormat.UInt8:
                return bytes((v >> 8) + 128 for v in vals)
            return array.array("h", vals).tobytes()

        def tick(self, session):
            if not self.ok:
                return
            # ---- الميكروفون → الخصم
            data = bytes(self.mic.readAll().data())
            if data:
                self._src_buf.extend(self._to_mono(data, self.in_fmt))
                ratio = self.in_fmt.sampleRate() / VOICE_RATE
                buf, pos, out = self._src_buf, self._pos, self._frame
                while pos + ratio <= len(buf):
                    a, b = int(pos), max(int(pos) + 1, int(pos + ratio))
                    seg = buf[a:b]
                    out.append(sum(seg) // len(seg))
                    pos += ratio
                cut = int(pos)
                del buf[:cut]
                self._pos = pos - cut
                while len(out) >= VOICE_FRAME:
                    frame = out[:VOICE_FRAME]
                    del out[:VOICE_FRAME]
                    rms = (sum(v * v for v in frame[::4]) / (VOICE_FRAME / 4)) ** 0.5
                    self._hang = 8 if rms > 450 else max(0, self._hang - 1)
                    self.talking = self._hang > 0 and not self.muted
                    if self.talking and session.peer and session.phase in ("running", "waiting", "syncing"):
                        session.send_voice(mulaw_encode(frame))
            # ---- الخصم → السماعة
            if session.voice_in:
                ratio = VOICE_RATE / self.out_fmt.sampleRate()
                g = self.gain
                for pkt in session.voice_in:
                    vals = mulaw_decode(pkt)
                    if g != 1.0:
                        vals = [max(-32768, min(32767, int(v * g))) for v in vals]
                    res, pos = [], self._out_pos
                    while pos < len(vals):
                        res.append(vals[int(pos)])
                        pos += ratio
                    self._out_pos = pos - len(vals)
                    self._pending += self._from_mono(res, self.out_fmt)
                session.voice_in.clear()
                cap = int(self.out_fmt.sampleRate() * self.out_fmt.bytesPerFrame() * 0.5)
                if len(self._pending) > cap:
                    del self._pending[:len(self._pending) - cap]
            if self._pending:
                bpf = max(1, self.out_fmt.bytesPerFrame())
                n = min(len(self._pending), self.sink.bytesFree())
                n -= n % bpf
                if n > 0:
                    self.spk.write(bytes(self._pending[:n]))
                    del self._pending[:n]

        def stop(self):
            for o in ("src", "sink"):
                try:
                    getattr(self, o).stop()
                except Exception:
                    pass
            self.ok = False

    class GameView(QWidget):
        def __init__(self, win):
            super().__init__()
            self.win = win
            self.img = None
            self._img_src = None
            self.setFocusPolicy(Qt.StrongFocus)
            self.setMinimumSize(512, 448)

        def _ensure_chat_box(self):
            if getattr(self, "chat_box", None) is None:
                e = QLineEdit(self)
                e.setPlaceholderText("اكتب رسالة واضغط Enter…  (Esc للإغلاق)")
                e.setMaxLength(200)
                e.setStyleSheet("QLineEdit{background:rgba(12,14,20,235); border:1px solid #7C5CFF;"
                                " border-radius:14px; padding:10px 14px; font-size:15px; color:#E8EAF2;}")
                e.returnPressed.connect(self._send_chat)
                e.installEventFilter(self)
                e.hide()
                self.chat_box = e
            return self.chat_box

        def open_chat(self):
            s = self.win.session
            if s is None or s.mode == "offline":
                return
            e = self._ensure_chat_box()
            self.win.keys.clear()
            e.setGeometry(24, self.height() - 74, self.width() - 48, 46)
            e.show()
            e.setFocus()

        def close_chat(self):
            e = getattr(self, "chat_box", None)
            if e is not None:
                e.clear()
                e.hide()
            self.setFocus()

        def _send_chat(self):
            e = self.chat_box
            s = self.win.session
            text = e.text().strip()
            if text and s is not None and s.send_chat(text):
                self.win.chat.append(("أنت", text, time.time(), True))
            elif text:
                self.win.log("لا يوجد خصم متصل لإرسال الرسالة")
            self.close_chat()

        def eventFilter(self, obj, ev):
            if obj is getattr(self, "chat_box", None) and ev.type() == ev.Type.KeyPress \
                    and ev.key() == Qt.Key_Escape:
                self.close_chat()
                return True
            return super().eventFilter(obj, ev)

        def resizeEvent(self, e):
            box = getattr(self, "chat_box", None)
            if box is not None and box.isVisible():
                box.setGeometry(24, self.height() - 74, self.width() - 48, 46)
            super().resizeEvent(e)

        def set_frame(self, fr):
            if fr is None or fr is self._img_src:
                return
            self._img_src = fr
            data, w, h, pitch, fmt = fr
            self._img_bytes = data
            self.img = QImage(data, w, h, pitch, QIMG_FMT.get(fmt, QImage.Format_RGB16))

        def _pill(self, p, rect, fill=QColor(12, 14, 20, 200), border=QColor(255, 255, 255, 28)):
            p.setPen(QPen(border, 1))
            p.setBrush(fill)
            p.drawRoundedRect(rect, rect.height() / 2, rect.height() / 2)

        def paintEvent(self, e):
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            p.fillRect(self.rect(), QColor("#05060A"))
            s = self.win.session
            W, H = self.width(), self.height()
            if self.img is not None:
                w = min(W - 24, (H - 24) * 4 / 3)
                h = w * 3 / 4
                r = QRectF((W - w) / 2, (H - h) / 2, w, h)
                path = QPainterPath()
                path.addRoundedRect(r, 14, 14)
                p.save()
                p.setClipPath(path)
                p.setRenderHint(QPainter.SmoothPixmapTransform, self.win.smooth)
                p.drawImage(r, self.img)
                if s is not None:
                    try:
                        s.plugin.frame = self.img          # صورة الإطار الحالي (للفحص بالبكسل)
                        s.plugin.overlay(p, r, s.core.memory(MEM_SYSTEM_RAM), s.player)
                    except Exception:
                        pass
                p.restore()
            if s is None:
                p.end()
                return

            # ---- HUD pill ----
            p.setFont(font(10, QFont.DemiBold))
            fm = QFontMetricsF(p.font())
            if s.mode == "offline":
                parts = [("badge", "تجربة"), ("text", "بدون نت")]
            else:
                parts = [("badge", "P1" if s.host else "P2")]
                if s.rtt is not None:
                    col = "#2BD67B" if s.rtt < 70 else "#FFB020" if s.rtt < 140 else "#FF4D6D"
                    parts.append(("dot", col))
                    parts.append(("text", f"{s.rtt:.0f}ms"))
                parts.append(("text", f"تأخير {s.delay}"))
                if s.peer:
                    parts.append(("text", f"ضد {s.peer}"))
                vo = self.win.voice
                if vo is not None and vo.ok:
                    parts.append(("text", "🔇" if vo.muted else ("🎙️" if vo.talking else "🎤")))
                    if time.perf_counter() - s.voice_last < 0.35:
                        parts.append(("text", "🔊"))
            widths = []
            for kind, val in parts:
                widths.append(fm.horizontalAdvance(val) + 18 if kind == "badge"
                              else 8 if kind == "dot" else fm.horizontalAdvance(val))
            total = sum(widths) + 14 * (len(parts) - 1) + 28
            pill = QRectF((W - total) / 2, 14, total, 32)
            self._pill(p, pill)
            x = pill.right() - 14                      # RTL: من اليمين لليسار
            for (kind, val), wd in zip(parts, widths):
                if kind == "badge":
                    br = QRectF(x - wd, pill.y() + 6, wd, 20)
                    g = QLinearGradient(br.topLeft(), br.topRight())
                    g.setColorAt(0, QColor(ACCENT_A))
                    g.setColorAt(1, QColor(ACCENT_B))
                    p.setPen(Qt.NoPen)
                    p.setBrush(g)
                    p.drawRoundedRect(br, 10, 10)
                    p.setPen(QColor("white"))
                    p.drawText(br, Qt.AlignCenter, val)
                elif kind == "dot":
                    p.setPen(Qt.NoPen)
                    p.setBrush(QColor(val))
                    p.drawEllipse(QPointF(x - 4, pill.center().y()), 4, 4)
                else:
                    p.setPen(QColor("#E8EAF2"))
                    p.drawText(QRectF(x - wd, pill.y(), wd, pill.height()), Qt.AlignCenter, val)
                x -= wd + 14

            # ---- waiting / error overlay ----
            if s.phase != "running":
                p.fillRect(self.rect(), QColor(5, 6, 10, 215))
                bad = s.phase in ("error", "closed")
                cy = H / 2
                if not bad:
                    ang = (time.perf_counter() * 300) % 360
                    sr = QRectF(W / 2 - 22, cy - 110, 44, 44)
                    p.setPen(QPen(QColor(255, 255, 255, 25), 4))
                    p.setBrush(Qt.NoBrush)
                    p.drawEllipse(sr)
                    pen = QPen(QColor(ACCENT_A), 4)
                    pen.setCapStyle(Qt.RoundCap)
                    p.setPen(pen)
                    p.drawArc(sr, int(-ang * 16), 100 * 16)
                else:
                    p.setPen(Qt.NoPen)
                    p.setBrush(QColor("#FF4D6D"))
                    p.drawEllipse(QPointF(W / 2, cy - 88), 22, 22)
                    p.setPen(QColor("white"))
                    p.setFont(font(16, QFont.Bold))
                    p.drawText(QRectF(W / 2 - 22, cy - 110, 44, 44), Qt.AlignCenter, "!")
                p.setPen(QColor("#E8EAF2"))
                p.setFont(font(15, QFont.Bold))
                p.drawText(QRectF(20, cy - 52, W - 40, 34), Qt.AlignCenter,
                           self.win.waiting_hint if (self.win.waiting_hint and s.phase == "waiting")
                           else (s.status or "...") + (f"  {100 * s.sync_progress[0] // max(1, s.sync_progress[1])}%"
                                                       if s.sync_progress else ""))
                if s.host and s.mode == "host" and s.phase == "waiting" and self.win.room \
                        and not self.win.waiting_hint:
                    p.setFont(font(10, QFont.DemiBold))
                    p.setPen(QColor("#8A91A6"))
                    p.drawText(QRectF(0, cy - 6, W, 22), Qt.AlignCenter, "كود الغرفة — أرسله لصديقك")
                    p.setFont(font(34, QFont.ExtraBold, mono=True))
                    p.setPen(QColor("white"))
                    p.drawText(QRectF(0, cy + 16, W, 60), Qt.AlignCenter, " ".join(self.win.room))
                p.setFont(font(9.5))
                p.setPen(QColor("#6E768C"))
                p.drawText(QRectF(0, H - 44, W, 24), Qt.AlignCenter, "Esc للخروج · F11 ملء الشاشة")

            # ---- desync banner ----
            if s.desync:
                p.setFont(font(10, QFont.DemiBold))
                txt = "⚠  عدم تطابق — أعد الانضمام للمزامنة"
                tw = QFontMetricsF(p.font()).horizontalAdvance(txt) + 32
                rr = QRectF((W - tw) / 2, H - 56, tw, 34)
                self._pill(p, rr, QColor(255, 77, 109, 220), QColor(255, 255, 255, 60))
                p.setPen(QColor("white"))
                p.drawText(rr, Qt.AlignCenter, txt)

            # ---- chat bubbles ----
            now_t = time.time()
            lines = [c for c in self.win.chat[-5:] if now_t - c[2] < 10]
            box_up = 60 if (getattr(self, "chat_box", None) is not None and self.chat_box.isVisible()) else 0
            y = H - 70 - box_up
            p.setFont(font(10.5, QFont.DemiBold))
            fmc = QFontMetricsF(p.font())
            for who, text, t0c, mine in reversed(lines):
                a = max(0.0, min(1.0, (10 - (now_t - t0c)) / 1.5))
                msg_c = f"{who}: {text}"
                tw = min(W * 0.6, fmc.horizontalAdvance(msg_c) + 28)
                rr = QRectF(W - 24 - tw, y - 32, tw, 30) if mine else QRectF(24, y - 32, tw, 30)
                fill = QColor(124, 92, 255, int(225 * a)) if mine else QColor(20, 24, 34, int(230 * a))
                self._pill(p, rr, fill, QColor(255, 255, 255, int(40 * a)))
                p.setPen(QColor(255, 255, 255, int(255 * a)))
                p.drawText(rr.adjusted(12, 0, -12, 0), Qt.AlignVCenter | Qt.AlignHCenter,
                           fmc.elidedText(msg_c, Qt.ElideRight, tw - 24))
                y -= 36

            # ---- toast ----
            msg, t0 = self.win.toast
            age = time.time() - t0
            if msg and age < 3.5 and s.phase == "running" and not s.desync:
                a = max(0.0, min(1.0, (3.5 - age) / 0.5))
                p.setFont(font(10, QFont.DemiBold))
                tw = QFontMetricsF(p.font()).horizontalAdvance(msg) + 36
                rr = QRectF((W - tw) / 2, H - 58, tw, 34)
                self._pill(p, rr, QColor(20, 24, 34, int(230 * a)), QColor(255, 255, 255, int(30 * a)))
                p.setPen(QColor(232, 234, 242, int(255 * a)))
                p.drawText(rr, Qt.AlignCenter, msg)
            p.end()

        def keyPressEvent(self, e):
            if e.key() == Qt.Key_Escape:
                self.win.leave_game()
                return
            if e.key() == Qt.Key_F11:
                self.win.toggle_fullscreen()
                return
            if e.key() in (Qt.Key_Minus, Qt.Key_Equal, Qt.Key_Plus):
                self.win.change_voice_volume(-10 if e.key() == Qt.Key_Minus else 10)
                return
            if e.key() == Qt.Key_T and not e.isAutoRepeat():
                self.open_chat()
                return
            if e.key() == Qt.Key_M and not e.isAutoRepeat():
                if self.win.voice is not None and self.win.voice.ok:
                    self.win.voice.muted = not self.win.voice.muted
                    self.win.log("🔇 تم كتم الميكروفون" if self.win.voice.muted else "🎤 الميكروفون يعمل")
                return
            if not e.isAutoRepeat():
                self.win.keys.add(e.key())

        def keyReleaseEvent(self, e):
            if not e.isAutoRepeat():
                self.win.keys.discard(e.key())

        def focusOutEvent(self, e):
            self.win.keys.clear()

    # ---------------- main window ----------------

    # ---------------- accounts: avatars + login dialog ----------------
    def round_pixmap(img_bytes, size, fallback_text="?"):
        pm = QPixmap(size, size)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)
        path = QPainterPath()
        path.addEllipse(QRectF(0, 0, size, size))
        p.setClipPath(path)
        img = QImage()
        if img_bytes and img.loadFromData(img_bytes):
            img = img.scaled(size, size, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation)
            p.drawImage((size - img.width()) // 2, (size - img.height()) // 2, img)
        else:
            g = QLinearGradient(0, 0, size, size)
            g.setColorAt(0, QColor(ACCENT_A))
            g.setColorAt(1, QColor(ACCENT_B))
            p.fillRect(0, 0, size, size, g)
            p.setPen(QColor("white"))
            p.setFont(font(max(8, int(size * 0.2)), QFont.Black))
            p.drawText(QRectF(0, 0, size, size), Qt.AlignCenter, (fallback_text or "?")[:1].upper())
        p.end()
        return pm

    def encode_avatar(path):
        img = QImage(path)
        if img.isNull():
            return None
        img = img.scaled(160, 160, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation)
        img = img.copy((img.width() - 160) // 2, (img.height() - 160) // 2, 160, 160)
        ba = QByteArray()
        buf = QBuffer(ba)
        buf.open(QIODevice.WriteOnly)
        img.save(buf, "JPEG", 85)
        buf.close()
        return bytes(ba)

    class AvatarCache:
        """تحميل صور اللاعبين من السيرفر في الخلفية"""
        def __init__(self):
            self.data = {}
            self.loading = set()
            self.dirty = False

        def get(self, server, uid, av):
            if not uid or not av:
                return None
            key = (uid, int(av))
            if key in self.data:
                return self.data[key]
            if key not in self.loading:
                self.loading.add(key)

                def run():
                    self.data[key] = fetch_bytes(f"{http_base(server)}/avatar/{uid}?v={av}")
                    self.dirty = True
                threading.Thread(target=run, daemon=True).start()
            return None

        def put(self, uid, av, data):
            self.data[(uid, int(av))] = data

    class AuthDialog(QDialog):
        """إنشاء حساب / تسجيل الدخول — إلزامي لاستخدام البرنامج"""
        def __init__(self, server, last_user=""):
            super().__init__()
            self.server = server
            self.result_data = None
            self.mode = "login"
            self.setWindowTitle("PS2 Online — الحساب")
            self.setFixedWidth(440)
            self.setStyleSheet(f"QDialog {{ background: #0B0D12; }}")
            v = QVBoxLayout(self)
            v.setContentsMargins(28, 26, 28, 24)
            v.setSpacing(10)
            top = QHBoxLayout()
            top.addWidget(Logo(52))
            tc = QVBoxLayout()
            tc.setSpacing(0)
            tc.addWidget(label("PS2 Online", "h1"))
            self.sub = label("سجّل الدخول إلى حسابك", "muted")
            tc.addWidget(self.sub)
            top.addLayout(tc, 1)
            v.addLayout(top)
            v.addSpacing(8)
            seg = QHBoxLayout()
            self.b_login = QPushButton("تسجيل الدخول")
            self.b_reg = QPushButton("إنشاء حساب")
            for b in (self.b_login, self.b_reg):
                b.setCheckable(True)
                b.setObjectName("nav")
                b.setCursor(Qt.PointingHandCursor)
                seg.addWidget(b, 1)
            self.b_login.setChecked(True)
            self.b_login.clicked.connect(lambda: self.set_mode("login"))
            self.b_reg.clicked.connect(lambda: self.set_mode("register"))
            v.addLayout(seg)
            v.addSpacing(6)
            v.addWidget(label("اسم المستخدم"))
            self.ed_user = QLineEdit(last_user)
            self.ed_user.setMaxLength(20)
            self.ed_user.setMinimumHeight(44)
            v.addWidget(self.ed_user)
            v.addWidget(label("كلمة المرور"))
            self.ed_pass = QLineEdit()
            self.ed_pass.setEchoMode(QLineEdit.Password)
            self.ed_pass.setMinimumHeight(44)
            v.addWidget(self.ed_pass)
            self.lb_pass2 = label("تأكيد كلمة المرور")
            self.ed_pass2 = QLineEdit()
            self.ed_pass2.setEchoMode(QLineEdit.Password)
            self.ed_pass2.setMinimumHeight(44)
            v.addWidget(self.lb_pass2)
            v.addWidget(self.ed_pass2)
            self.err = label("", "muted")
            self.err.setWordWrap(True)
            self.err.setStyleSheet("color:#FF4D6D; font-weight:700;")
            v.addWidget(self.err)
            self.go = QPushButton("دخول")
            self.go.setObjectName("primary")
            self.go.setCursor(Qt.PointingHandCursor)
            self.go.clicked.connect(self.submit)
            v.addWidget(self.go)
            hint = label("الحساب مطلوب لاستخدام اللعب أونلاين والدردشة والمكالمات", "muted")
            hint.setWordWrap(True)
            hint.setStyleSheet("font-size:11px;")
            v.addWidget(hint)
            self.ed_pass.returnPressed.connect(self.submit)
            self.ed_pass2.returnPressed.connect(self.submit)
            self._busy = None
            self._poll = QTimer(self)
            self._poll.timeout.connect(self._check)
            self.set_mode("login")

        def set_mode(self, m):
            self.mode = m
            self.b_login.setChecked(m == "login")
            self.b_reg.setChecked(m == "register")
            reg = m == "register"
            self.lb_pass2.setVisible(reg)
            self.ed_pass2.setVisible(reg)
            self.go.setText("إنشاء الحساب" if reg else "دخول")
            self.sub.setText("أنشئ حساباً جديداً" if reg else "سجّل الدخول إلى حسابك")
            self.err.setText("")
            self.adjustSize()

        def submit(self):
            if self._busy is not None:
                return
            u, pw = self.ed_user.text().strip(), self.ed_pass.text()
            if len(u) < 3:
                self.err.setText(AUTH_ERRORS["bad_username"])
                return
            if len(pw) < 6:
                self.err.setText(AUTH_ERRORS["bad_password"])
                return
            if self.mode == "register" and pw != self.ed_pass2.text():
                self.err.setText("كلمتا المرور غير متطابقتين")
                return
            self.err.setText("")
            self.go.setEnabled(False)
            self.go.setText("جارِ الاتصال...")
            box = {}
            self._busy = box
            path = "/auth/register" if self.mode == "register" else "/auth/login"

            def run():
                box["res"] = api_call(self.server, path, {"username": u, "password": pw})
            threading.Thread(target=run, daemon=True).start()
            self._poll.start(50)

        def _check(self):
            box = self._busy
            if box is None or "res" not in box:
                return
            self._poll.stop()
            self._busy = None
            code, res = box["res"]
            self.set_mode(self.mode)
            if code == 200 and res.get("token"):
                self.result_data = res
                self.accept()
            else:
                msg = auth_error(res)
                if res.get("error") == "locked":
                    msg = f"محاولات كثيرة — انتظر {res.get('retry', 60)} ثانية"
                self.err.setText(msg)

    class MainWindow(QMainWindow):
        relaunch = None

        def __init__(self, account):
            super().__init__()
            self.account = account
            self.avatars = AvatarCache()
            self.setWindowTitle("PS2 Online 2026")
            self.settings = QSettings(os.path.join(APP_DIR, "settings.ini"), QSettings.IniFormat)
            self.session = None
            self.keys = set()
            self.smooth = False
            self.audio_sink = None
            self.audio_dev = None
            self.joy = None
            self.room = ""
            self.toast = ("", 0.0)
            self.voice = None
            self.chat = []
            self.lobby = Lobby()
            self.pending_to = None
            self.waiting_hint = ""
            self.waiting_hint_name = ""
            self.challenge_box = None
            self._incoming = None
            self._lobby_ver = -1
            self.plugins = load_plugins(self.log_early)
            self._early = []

            self.stack = QStackedWidget()
            self.setCentralWidget(self.stack)
            self.stack.addWidget(self._build_home())
            self.game = GameView(self)
            self.stack.addWidget(self.game)
            for m in self._early:
                self.log(m)
            self.setAcceptDrops(True)

            self.timer = QTimer(self)
            self.timer.setTimerType(Qt.PreciseTimer)
            self.timer.timeout.connect(self.tick)
            self.pid = account["user"]["id"]
            self.lobby_timer = QTimer(self)
            self.lobby_timer.timeout.connect(self._lobby_tick)
            self.lobby_timer.start(250)
            self.resize(1040, 680)
            self.setMinimumSize(900, 600)

        def log_early(self, m):
            self._early.append(m)

        # ---------- home ----------
        def _build_home(self):
            root = QWidget()
            root.setObjectName("root")
            h = QHBoxLayout(root)
            h.setContentsMargins(0, 0, 0, 0)
            h.setSpacing(0)

            # sidebar
            side = QFrame()
            side.setObjectName("sidebar")
            side.setFixedWidth(250)
            sv = QVBoxLayout(side)
            sv.setContentsMargins(18, 22, 18, 18)
            sv.setSpacing(6)
            brand = QHBoxLayout()
            brand.setSpacing(12)
            brand.addWidget(Logo())
            bt = QVBoxLayout()
            bt.setSpacing(0)
            bt.addWidget(label("PS2 Online", "brand"))
            bt.addWidget(label("نسخة 2026 · Cruyfford", "brandSub"))
            brand.addLayout(bt)
            brand.addStretch()
            sv.addLayout(brand)
            sv.addSpacing(26)

            self.pages = QStackedWidget()
            group = QButtonGroup(self)
            for i, (txt, page) in enumerate((("🎮   اللعب", self._page_play()),
                                             ("👥   اللاعبون", self._page_players()),
                                             ("⚙   الإعدادات", self._page_settings()),
                                             ("☰   السجل", self._page_log()))):
                b = QPushButton(txt)
                b.setObjectName("nav")
                b.setCheckable(True)
                b.setCursor(Qt.PointingHandCursor)
                group.addButton(b, i)
                sv.addWidget(b)
                self.pages.addWidget(page)
                if i == 0:
                    b.setChecked(True)
            group.idClicked.connect(self.pages.setCurrentIndex)
            self._nav_group = group
            sv.addStretch()
            self.chip = label("●  جاهز", "chip")
            self.chip.setCursor(Qt.PointingHandCursor)
            self.chip.setToolTip("اللاعبون المتصلون")
            self.chip.mousePressEvent = lambda e: self._go_players()
            sv.addWidget(self.chip, 0, Qt.AlignRight)
            sv.addSpacing(8)
            hint = label("Z ✕   X ○   A □   S △\nQ/W L1/R1 · E/R L2/R2 · C/V L3/R3\nالعصا: IJKL يسرى · 8456 يمنى\nEnter Start · Shift Select\nT دردشة · M كتم · F11 · Esc خروج", "muted")
            hint.setStyleSheet("font-size:11px;")
            sv.addWidget(hint)

            h.addWidget(side)
            h.addWidget(self.pages, 1)
            return root

        def _page(self, title, sub):
            page = QWidget()
            page.setObjectName("page")
            v = QVBoxLayout(page)
            v.setContentsMargins(40, 34, 40, 30)
            v.setSpacing(16)
            v.addWidget(label(title, "h1"))
            v.addWidget(label(sub, "muted"))
            v.addSpacing(6)
            return page, v

        def _page_play(self):
            page, v = self._page("العب مع صديقك",
                                 "كل لاعب يشغّل اللعبة على جهازه — والمزامنة عبر سيرفر Cloudflare")
            st = self.settings

            # ROM card
            rc = card()
            rl = QHBoxLayout(rc)
            rl.setContentsMargins(18, 16, 18, 16)
            rl.setSpacing(14)
            tile = QLabel("PS2")
            self.rom_tile = tile
            tile.setFixedSize(54, 54)
            tile.setAlignment(Qt.AlignCenter)
            tile.setStyleSheet("background: qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #2A2150,"
                               " stop:1 #0E3550); border-radius: 14px; font-weight: 800;"
                               " color: #CFC6FF; font-size: 13px;")
            rl.addWidget(tile)
            rt = QVBoxLayout()
            rt.setSpacing(2)
            self.rom_title = label("", "romTitle")
            self.rom_sub = label("", "muted")
            rt.addWidget(self.rom_title)
            rt.addWidget(self.rom_sub)
            rl.addLayout(rt, 1)
            b = QPushButton("اختيار…")
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(self._pick_rom)
            rl.addWidget(b)
            v.addWidget(rc)
            self.rom_path = st.value("rom", "")
            self._update_rom_card()

            # code + name
            grid = QGridLayout()
            grid.setHorizontalSpacing(16)
            cc = card()
            cl = QVBoxLayout(cc)
            cl.setContentsMargins(18, 14, 18, 16)
            cl.addWidget(label("كود الغرفة"))
            row = QHBoxLayout()
            self.ed_room = QLineEdit(st.value("room", ""))
            self.ed_room.setObjectName("code")
            self.ed_room.setPlaceholderText("— — — — —")
            self.ed_room.setMaxLength(12)
            self.ed_room.setLayoutDirection(Qt.LeftToRight)
            self.ed_room.setAlignment(Qt.AlignCenter)
            f = font(20, QFont.ExtraBold, mono=True)
            f.setLetterSpacing(QFont.AbsoluteSpacing, 6)
            self.ed_room.setFont(f)
            self.ed_room.textEdited.connect(lambda t: self.ed_room.setText(t.upper()))
            row.addWidget(self.ed_room, 1)
            for txt, tip, fn in (("↻", "كود جديد", self._new_code), ("⧉", "نسخ", self._copy_code)):
                ib = QPushButton(txt)
                ib.setToolTip(tip)
                ib.setFixedSize(46, 46)
                ib.setCursor(Qt.PointingHandCursor)
                ib.clicked.connect(fn)
                row.addWidget(ib)
            cl.addLayout(row)
            nc = card()
            nl = QVBoxLayout(nc)
            nl.setContentsMargins(18, 14, 18, 16)
            nl.addWidget(label("حسابك"))
            pr = QHBoxLayout()
            pr.setSpacing(12)
            self.home_avatar = QLabel()
            self.home_avatar.setFixedSize(52, 52)
            pr.addWidget(self.home_avatar)
            self.ed_name = QLineEdit(self.account["user"]["username"])
            self.ed_name.setReadOnly(True)
            self.ed_name.setMinimumHeight(46)
            self.ed_name.setToolTip("غيّر اسمك وصورتك من الإعدادات")
            pr.addWidget(self.ed_name, 1)
            nl.addLayout(pr)
            be = QPushButton("✎  تعديل الملف الشخصي")
            be.setObjectName("ghost")
            be.setCursor(Qt.PointingHandCursor)
            be.clicked.connect(self._go_settings)
            nl.addWidget(be)
            nl.addStretch()
            grid.addWidget(cc, 0, 0)
            grid.addWidget(nc, 0, 1)
            grid.setColumnStretch(0, 3)
            grid.setColumnStretch(1, 2)
            v.addLayout(grid)

            # actions
            v.addSpacing(6)
            ar = QHBoxLayout()
            ar.setSpacing(16)
            bh = QPushButton("＋   إنشاء غرفة")
            bh.setObjectName("primary")
            bj = QPushButton("⇠   انضمام")
            bj.setObjectName("secondary")
            for b_ in (bh, bj):
                b_.setCursor(Qt.PointingHandCursor)
                ar.addWidget(b_, 1)
            shadow(bh, 40, 140)
            bh.clicked.connect(lambda: self.start("host"))
            bj.clicked.connect(lambda: self.start("join"))
            v.addLayout(ar)
            bo = QPushButton("▶   تجربة بدون نت")
            bo.setObjectName("ghost")
            bo.setCursor(Qt.PointingHandCursor)
            bo.clicked.connect(lambda: self.start("offline"))
            v.addWidget(bo)
            v.addStretch()
            tip = label("💡  اسحب ملف اللعبة (.iso / .chd / .cso) وأفلته على النافذة لاختياره بسرعة", "muted")
            tip.setStyleSheet("font-size:12px;")
            v.addWidget(tip)
            return page

        def _page_settings(self):
            page, v = self._page("الإعدادات", "حسابك والسيرفر والنواة وإضافات العرض")
            st = self.settings
            ac = card()
            ah = QHBoxLayout(ac)
            ah.setContentsMargins(20, 16, 20, 16)
            ah.setSpacing(16)
            self.set_avatar = QLabel()
            self.set_avatar.setFixedSize(84, 84)
            self.set_avatar.setCursor(Qt.PointingHandCursor)
            self.set_avatar.setToolTip("تغيير الصورة")
            self.set_avatar.mousePressEvent = lambda e: self.change_avatar()
            ah.addWidget(self.set_avatar)
            acol = QVBoxLayout()
            acol.setSpacing(6)
            acol.addWidget(label("اسم المستخدم"))
            urow = QHBoxLayout()
            self.ed_uname = QLineEdit(self.account["user"]["username"])
            self.ed_uname.setMaxLength(20)
            self.ed_uname.setMinimumHeight(42)
            urow.addWidget(self.ed_uname, 1)
            self.b_uname = QPushButton("حفظ")
            self.b_uname.setCursor(Qt.PointingHandCursor)
            self.b_uname.clicked.connect(self.change_username)
            urow.addWidget(self.b_uname)
            acol.addLayout(urow)
            brow = QHBoxLayout()
            bp = QPushButton("🖼  تغيير الصورة")
            bp.setCursor(Qt.PointingHandCursor)
            bp.clicked.connect(self.change_avatar)
            brow.addWidget(bp)
            bo_ = QPushButton("⎋  تسجيل الخروج")
            bo_.setCursor(Qt.PointingHandCursor)
            bo_.setStyleSheet("color:#FF4D6D;")
            bo_.clicked.connect(self.logout)
            brow.addWidget(bo_)
            brow.addStretch()
            acol.addLayout(brow)
            self.lb_acc = label("", "muted")
            acol.addWidget(self.lb_acc)
            ah.addLayout(acol, 1)
            v.addWidget(ac)
            c = card()
            g = QGridLayout(c)
            g.setContentsMargins(22, 20, 22, 22)
            g.setHorizontalSpacing(16)
            g.setVerticalSpacing(8)

            srv = st.value("server", "wss://snes-online-relay.cruyfford4488.workers.dev")
            if not srv or "YOUR-NAME" in srv:
                srv = "wss://snes-online-relay.cruyfford4488.workers.dev"
            self.ed_server = QLineEdit(srv)
            self.ed_server.setLayoutDirection(Qt.LeftToRight)
            self.ed_core = QLineEdit(st.value("core", os.path.join(APP_DIR, "cores",
                                       "pcsx2_libretro.dll" if sys.platform == "win32" else "pcsx2_libretro.so")))
            self.ed_core.setLayoutDirection(Qt.LeftToRight)
            core_row = QHBoxLayout()
            core_row.addWidget(self.ed_core, 1)
            cb = QPushButton("…")
            cb.setFixedWidth(46)
            cb.clicked.connect(lambda: self._browse(self.ed_core, "نواة libretro (*.dll *.so *.dylib)"))
            core_row.addWidget(cb)
            self.cb_plugin = QComboBox()
            for p in self.plugins:
                self.cb_plugin.addItem(p.name)
            idx = self.cb_plugin.findText(st.value("plugin", ""))
            if idx >= 0:
                self.cb_plugin.setCurrentIndex(idx)
            self.sp_delay = QSpinBox()
            self.sp_delay.setRange(1, 15)
            self.sp_delay.setValue(int(st.value("delay", 3)))
            self.sp_delay.setSuffix("  إطار")
            self.sp_delay.setButtonSymbols(QAbstractSpinBox.NoButtons)
            self.sl_voice = QSlider(Qt.Horizontal)
            self.sl_voice.setRange(0, 200)
            self.sl_voice.setValue(int(st.value("voice_volume", 100)))
            self.lb_voice = label(f"{self.sl_voice.value()}%", "muted")
            self.lb_voice.setFixedWidth(48)
            self.sl_voice.valueChanged.connect(lambda v: self.change_voice_volume(0, absolute=v))
            voice_row = QHBoxLayout()
            voice_row.addWidget(QLabel("🔈"))
            voice_row.addWidget(self.sl_voice, 1)
            voice_row.addWidget(QLabel("🔊"))
            voice_row.addWidget(self.lb_voice)
            self.cb_bios = QComboBox()
            bios_row = QHBoxLayout()
            bios_row.addWidget(self.cb_bios, 1)
            bb = QPushButton("📁")
            bb.setFixedWidth(46)
            bb.setToolTip("فتح مجلد البايوس")
            bb.clicked.connect(self._open_bios_dir)
            bios_row.addWidget(bb)
            br = QPushButton("⟳")
            br.setFixedWidth(46)
            br.setToolTip("تحديث القائمة")
            br.clicked.connect(self._refresh_bios)
            bios_row.addWidget(br)
            self._refresh_bios()
            self.ck_smooth = QCheckBox("تنعيم الصورة (Bilinear)")
            self.ck_smooth.setChecked(st.value("smooth", "false") in (True, "true"))
            self.cb_renderer = QComboBox()
            self.cb_renderer.addItem("المعالج (Software) — الأضمن للأونلاين، يحتاج معالجاً قوياً", "sw")
            self.cb_renderer.addItem("كرت الشاشة (OpenGL) — أسرع ويدعم دقة أعلى", "gl")
            self.cb_renderer.setCurrentIndex(max(0, self.cb_renderer.findData(st.value("renderer", "sw"))))
            self.cb_res = QComboBox()
            self.cb_res.addItem("أصلية 1x (أخف)", 1)
            self.cb_res.addItem("2x — أوضح", 2)
            self.cb_res.addItem("4x — كرت شاشة قوي", 4)
            self.cb_res.setCurrentIndex(max(0, self.cb_res.findData(int(st.value("upscale", 1)))))

            rows = [("رابط السيرفر (wss://)", self.ed_server), ("نواة libretro (pcsx2_libretro)", core_row),
                    ("البايوس — يجب أن يكون نفس الملف عند اللاعبين (client/system/pcsx2/bios)", bios_row),
                    ("المحاكاة الرسومية — المضيف يحددها والضيف يأخذها تلقائياً", self.cb_renderer),
                    ("الدقة الداخلية (OpenGL فقط) — المضيف يحددها", self.cb_res),
                    ("إضافة العرض — شاشة مختلفة لكل لاعب", self.cb_plugin),
                    ("تأخير المدخلات (المضيف يحدده) — زده إذا كان البنق عالياً", self.sp_delay),
                    ("صوت المحادثة الصوتية (أثناء اللعب: - و = )", voice_row)]
            r = 0
            for txt, w in rows:
                g.addWidget(label(txt), r, 0)
                r += 1
                if isinstance(w, QHBoxLayout):
                    g.addLayout(w, r, 0)
                else:
                    g.addWidget(w, r, 0)
                r += 1
                g.setRowMinimumHeight(r, 8)
                r += 1
            g.addWidget(self.ck_smooth, r, 0)
            v.addWidget(c)
            v.addStretch()
            sc = QScrollArea()
            sc.setWidgetResizable(True)
            sc.setFrameShape(QFrame.NoFrame)
            sc.setStyleSheet("QScrollArea { background: #0B0D12; border: none; }")
            sc.setWidget(page)
            return sc

        def _page_players(self):
            page, v = self._page("اللاعبون المتصلون",
                                 "تحدَّ أي لاعب، أو راسله، أو اتصل به صوتياً")
            self.players_count = label("جارِ الاتصال بالسيرفر...", "muted")
            self.players_count.setStyleSheet("font-size:15px; font-weight:700; color:#2BD67B;")
            v.addWidget(self.players_count)
            body = QHBoxLayout()
            body.setSpacing(16)
            self.players_list = QListWidget()
            self.players_list.setStyleSheet(
                "QListWidget{background:transparent;border:none;outline:0;}"
                "QListWidget::item{border:none;margin:0 0 10px 0;}"
                "QListWidget::item:selected{background:transparent;}")
            self.players_list.setSelectionMode(QListWidget.NoSelection)
            body.addWidget(self.players_list, 3)

            # ---- لوحة المحادثة الخاصة
            panel = card()
            pv = QVBoxLayout(panel)
            pv.setContentsMargins(16, 14, 16, 14)
            pv.setSpacing(10)
            self.dm_title = label("اختر لاعباً لمراسلته", "romTitle")
            pv.addWidget(self.dm_title)
            self.call_bar = QFrame()
            cb = QHBoxLayout(self.call_bar)
            cb.setContentsMargins(12, 8, 12, 8)
            self.call_label = label("", "muted")
            self.call_label.setStyleSheet("color:#2BD67B; font-weight:700;")
            cb.addWidget(self.call_label, 1)
            self.call_mute = QPushButton("🎤")
            self.call_mute.setFixedWidth(46)
            self.call_mute.clicked.connect(self._toggle_call_mute)
            cb.addWidget(self.call_mute)
            hang = QPushButton("إنهاء")
            hang.setStyleSheet("background:#FF4D6D; border:none; color:white; font-weight:800;")
            hang.clicked.connect(lambda: self.end_call(notify=True))
            cb.addWidget(hang)
            self.call_bar.setStyleSheet("QFrame{background:#10251A; border:1px solid #1E5A3A; border-radius:12px;}")
            self.call_bar.hide()
            pv.addWidget(self.call_bar)
            self.dm_view = QPlainTextEdit()
            self.dm_view.setReadOnly(True)
            self.dm_view.setStyleSheet("font-family: 'Segoe UI', 'DejaVu Sans'; font-size: 14px;")
            pv.addWidget(self.dm_view, 1)
            row = QHBoxLayout()
            self.dm_input = QLineEdit()
            self.dm_input.setPlaceholderText("اكتب رسالة…")
            self.dm_input.setMaxLength(500)
            self.dm_input.returnPressed.connect(self._send_dm)
            row.addWidget(self.dm_input, 1)
            sb = QPushButton("إرسال")
            sb.setObjectName("primary")
            sb.setStyleSheet("padding: 10px 16px; font-size: 14px; border-radius: 11px;")
            sb.clicked.connect(self._send_dm)
            row.addWidget(sb)
            pv.addLayout(row)
            body.addWidget(panel, 2)
            v.addLayout(body, 1)
            self.dm_peer = None
            self.call = None
            self.call_box = None
            self._incoming_call = None
            self.call_timer = QTimer(self)
            self.call_timer.timeout.connect(self._call_tick)
            return page

        def _player_row(self, pl):
            w = QFrame()
            w.setObjectName("card")
            h = QHBoxLayout(w)
            h.setContentsMargins(14, 10, 14, 10)
            h.setSpacing(12)
            av = QLabel()
            av.setFixedSize(42, 42)
            av.setPixmap(round_pixmap(self.avatars.get(self._server(), pl.get("id"), pl.get("av")), 42,
                                      pl.get("name") or "?"))
            h.addWidget(av)
            col = QVBoxLayout()
            col.setSpacing(1)
            col.addWidget(label(pl.get("name") or "Player", "romTitle"))
            plat = pl.get("platform") or ""
            game = pl.get("game") or ""
            playing = pl.get("status") == "playing"
            sub = " · ".join(x for x in (("📱 " if plat.startswith("iOS") else "💻 ") + plat, game) if x.strip())
            col.addWidget(label(sub, "muted"))
            st = label("● يلعب الآن" if playing else "● متاح", "muted")
            st.setStyleSheet(f"color: {'#FFB020' if playing else '#2BD67B'}; font-weight:700; font-size:12px;")
            col.addWidget(st)
            h.addLayout(col, 1)
            pid = pl.get("id")
            n = self.lobby.unread.get(pid, 0)
            bm = QPushButton(f"💬 {n}" if n else "💬")
            bm.setToolTip("رسالة خاصة")
            bm.setFixedWidth(56 if n else 46)
            if n:
                bm.setStyleSheet("background:#FF4D6D; border:none; color:white; font-weight:800;")
            bm.clicked.connect(lambda _=False, pl=pl: self.open_dm(pl))
            h.addWidget(bm)
            bc = QPushButton("📞")
            bc.setToolTip("مكالمة صوتية")
            bc.setFixedWidth(46)
            bc.setEnabled(self.call is None and self.session is None)
            bc.clicked.connect(lambda _=False, pl=pl: self.start_call(pl))
            h.addWidget(bc)
            b = QPushButton("⚔  تحدي")
            b.setObjectName("primary")
            b.setStyleSheet("padding: 9px 14px; font-size: 13px; border-radius: 11px;")
            b.setEnabled(not playing and self.session is None)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(lambda _=False, pl=pl: self.challenge_player(pl))
            h.addWidget(b)
            return w

        def _refresh_players(self):
            lb = self.lobby
            others = [p for p in lb.players if p.get("id") != self.pid and "PS2" in (p.get("platform") or "")]
            total_unread = sum(lb.unread.values())
            if lb.connected:
                n_ps2 = sum(1 for p in lb.players if "PS2" in (p.get("platform") or ""))
                self.players_count.setText(f"🟢  {n_ps2} متصل الآن في PS2 Online  ·  {lb.online} على السيرفر كله")
                if self.session is None:
                    self.set_chip(f"{lb.online} متصل" + (f"  ·  💬 {total_unread}" if total_unread else ""),
                                  "#FF4D6D" if total_unread else "#2BD67B")
            else:
                self.players_count.setText("جارِ الاتصال بالسيرفر...")
            self.players_list.clear()
            if not others:
                self.players_list.addItem(QListWidgetItem("لا يوجد لاعبون آخرون الآن" if lb.connected else ""))
            for pl in others:
                it = QListWidgetItem()
                row = self._player_row(pl)
                it.setSizeHint(row.sizeHint())
                self.players_list.addItem(it)
                self.players_list.setItemWidget(it, row)
            self._render_dm()

        # ---------- private messages ----------
        def _peer(self, pid):
            return next((p for p in self.lobby.players if p.get("id") == pid), None)

        def _go_players(self):
            self.pages.setCurrentIndex(1)
            self._nav_group.button(1).setChecked(True)

        def open_dm(self, pl):
            self.dm_peer = pl.get("id")
            self.lobby.unread.pop(self.dm_peer, None)
            self._go_players()
            self._lobby_ver = -1
            self.dm_input.setFocus()

        def _render_dm(self):
            pid = self.dm_peer
            if not pid:
                self.dm_title.setText("اختر لاعباً (💬) لمراسلته")
                self.dm_view.setPlainText("")
                return
            pl = self._peer(pid)
            name = (pl or {}).get("name") or "لاعب"
            self.dm_title.setText(f"💬 محادثة مع {name}" + ("" if pl else "  (غير متصل)"))
            self.lobby.unread.pop(pid, None)
            lines = [f"{'أنت' if mine else who}  ·  {time.strftime('%H:%M', time.localtime(ts))}\n{text}\n"
                     for who, text, ts, mine in self.lobby.dms.get(pid, [])]
            self.dm_view.setPlainText("\n".join(lines) if lines else "لا توجد رسائل بعد — ابدأ المحادثة 👋")
            self.dm_view.verticalScrollBar().setValue(self.dm_view.verticalScrollBar().maximum())

        def _send_dm(self):
            text = self.dm_input.text().strip()
            if not text or not self.dm_peer:
                return
            if self.lobby.send_dm(self.dm_peer, text):
                self.dm_input.clear()

        # ---------- voice calls ----------
        def start_call(self, pl):
            if self.call is not None or self.session is not None:
                return
            server, name = self._settings_snapshot()
            room = "C" + "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(7))
            self.call = VoiceCall(server, room, True, name, pl.get("id"), pl.get("name") or "لاعب",
                                  token=self.token)
            self.lobby.call(pl.get("id"), room)
            self.dm_peer = pl.get("id")
            self._begin_call_audio()

        def _begin_call_audio(self):
            self.call_voice = VoiceIO(self.log)
            self.call_voice.gain = self.sl_voice.value() / 100.0
            self.call_bar.show()
            self.call_timer.start(20)
            self._lobby_ver = -1

        def _toggle_call_mute(self):
            v = getattr(self, "call_voice", None)
            if v is not None:
                v.muted = not v.muted
                self.call_mute.setText("🔇" if v.muted else "🎤")

        def _call_tick(self):
            c = self.call
            if c is None:
                return
            c.poll()
            if c.phase == "ended":
                reason = c.reason
                self.end_call(notify=False)
                if reason:
                    self.log(f"📞 {reason}")
                return
            if self.call_voice is not None:
                self.call_voice.tick(c)
            if c.phase == "running" and c.started:
                sec = int(time.time() - c.started)
                talk = " 🔊" if time.perf_counter() - c.voice_last < 0.35 else ""
                self.call_label.setText(f"📞 مكالمة مع {c.peer_name}  ·  {sec // 60:02d}:{sec % 60:02d}{talk}")
            else:
                self.call_label.setText(f"📞 جارِ الاتصال بـ {c.peer_name}...")

        def end_call(self, notify=True):
            c = self.call
            if c is None:
                return
            if notify:
                self.lobby.call_end(c.peer_id)
            c.close()
            self.call = None
            self.call_timer.stop()
            if getattr(self, "call_voice", None) is not None:
                self.call_voice.stop()
                self.call_voice = None
            self.call_bar.hide()
            self.call_mute.setText("🎤")
            self._lobby_ver = -1

        def _call_answered(self, box, accepted):
            ev, self._incoming_call = self._incoming_call, None
            self.call_box = None
            if not ev:
                return
            frm = ev.get("from") or {}
            room = ev.get("room", "")
            if not accepted or self.session is not None or self.call is not None:
                self.lobby.call_answer(frm.get("id", ""), False, room, "declined")
                return
            server, name = self._settings_snapshot()
            self.call = VoiceCall(server, room, False, name, frm.get("id", ""), frm.get("name") or "لاعب",
                                  token=self.token)
            self.lobby.call_answer(frm.get("id", ""), True, room)
            self.dm_peer = frm.get("id")
            self._go_players()
            self._begin_call_audio()

        # ---------- account ----------
        @property
        def token(self):
            return self.account["token"]

        def _server(self):
            return self.ed_server.text().strip() if hasattr(self, "ed_server") else DEFAULT_SERVER

        def _go_settings(self):
            for b in self._nav_group.buttons():
                if "الإعدادات" in b.text():
                    b.click()
                    return

        def _my_avatar_bytes(self):
            u = self.account["user"]
            return self.avatars.get(self._server(), u["id"], u.get("av"))

        def _refresh_avatars(self):
            u = self.account["user"]
            data = self._my_avatar_bytes()
            if hasattr(self, "home_avatar"):
                self.home_avatar.setPixmap(round_pixmap(data, 52, u["username"]))
            if hasattr(self, "set_avatar"):
                self.set_avatar.setPixmap(round_pixmap(data, 84, u["username"]))

        def _apply_user(self, user):
            self.account["user"] = user
            self.settings.setValue("acc_user", json.dumps(user))
            self.ed_name.setText(user["username"])
            self.ed_uname.setText(user["username"])
            self._refresh_avatars()
            self.lobby.close()
            self.lobby.server = None   # يعيد الاتصال بالاسم/الصورة الجديدة

        def _profile_call(self, body, done):
            box = {}

            def run():
                box["res"] = api_call(self._server(), "/auth/profile", body, self.token)
            threading.Thread(target=run, daemon=True).start()
            t = QTimer(self)

            def check():
                if "res" in box:
                    t.stop()
                    t.deleteLater()
                    code, res = box["res"]
                    if code == 401:
                        self.logout(silent=True)
                        return
                    done(code, res)
            t.timeout.connect(check)
            t.start(60)

        def change_username(self):
            new = self.ed_uname.text().strip()
            if new == self.account["user"]["username"]:
                return
            self.b_uname.setEnabled(False)
            self.lb_acc.setText("جارِ الحفظ...")

            def done(code, res):
                self.b_uname.setEnabled(True)
                if code == 200 and res.get("user"):
                    self._apply_user(res["user"])
                    self.lb_acc.setText("✓  تم تغيير اسم المستخدم")
                else:
                    self.lb_acc.setText("✗  " + auth_error(res))
                    self.ed_uname.setText(self.account["user"]["username"])
            self._profile_call({"username": new}, done)

        def change_avatar(self):
            path, _ = QFileDialog.getOpenFileName(self, "اختر صورتك", os.path.expanduser("~"),
                                                  "صور (*.png *.jpg *.jpeg *.bmp *.webp *.gif)")
            if not path:
                return
            data = encode_avatar(path)
            if not data:
                QMessageBox.warning(self, "الصورة", "تعذّر فتح الصورة")
                return
            self.lb_acc.setText("جارِ رفع الصورة...")

            def done(code, res):
                if code == 200 and res.get("user"):
                    u = res["user"]
                    self.avatars.put(u["id"], u["av"], data)
                    self._apply_user(u)
                    self.lb_acc.setText("✓  تم تغيير الصورة")
                else:
                    self.lb_acc.setText("✗  " + auth_error(res))
            self._profile_call({"avatar": base64.b64encode(data).decode()}, done)

        def logout(self, silent=False):
            if not silent and QMessageBox.question(self, "تسجيل الخروج", "هل تريد تسجيل الخروج من حسابك؟") \
                    != QMessageBox.Yes:
                return
            tok, srv = self.token, self._server()
            threading.Thread(target=lambda: api_call(srv, "/auth/logout", {}, tok), daemon=True).start()
            self.settings.remove("acc_token")
            MainWindow.relaunch = True
            self.close()

        def _settings_snapshot(self):
            return self.ed_server.text().strip(), (self.ed_name.text().strip() or "Player")

        def _lobby_tick(self):
            server, name = self._settings_snapshot()
            self.lobby.configure(server, self.pid, name, self.token)
            for ev in self.lobby.poll():
                self._on_lobby_event(ev)
            if self.lobby.version != self._lobby_ver:
                self._lobby_ver = self.lobby.version
                self._refresh_players()

        def _rom_title(self):
            return os.path.splitext(os.path.basename(self.rom_path))[0] if self.rom_path else ""

        def _on_lobby_event(self, ev):
            t = ev.get("t")
            frm = ev.get("from") or {}
            fid, fname = frm.get("id", ""), frm.get("name") or "لاعب"
            if t == "dm":
                if self.dm_peer == fid and self.pages.currentIndex() == 1 and self.isActiveWindow():
                    self.lobby.unread.pop(fid, None)
                else:
                    self.log(f"💬 {fname}: {ev.get('text', '')[:60]}")
                    QApplication.beep()
                return
            if t == "dm_failed":
                self.log("لم تصل الرسالة — اللاعب غير متصل")
                return
            if t == "call":
                if self.session is not None or self.call is not None or self.call_box is not None:
                    self.lobby.call_answer(fid, False, ev.get("room", ""), "busy")
                    return
                self._incoming_call = ev
                box = QMessageBox(self)
                box.setWindowTitle("مكالمة واردة 📞")
                box.setText(f"{fname} يتصل بك…")
                box.setStyleSheet("QLabel{font-size:16px; font-weight:700; min-width:280px;}"
                                  "QPushButton{min-width:90px; padding:10px 18px;}")
                acc = box.addButton("رد", QMessageBox.AcceptRole)
                box.addButton("رفض", QMessageBox.RejectRole)
                box.setModal(False)
                box.finished.connect(lambda _r, b=box, a=acc: self._call_answered(b, b.clickedButton() is a))
                self.call_box = box
                box.show()
                QApplication.alert(self)
                QApplication.beep()
                return
            if t == "call_answer":
                if self.call is not None and self.call.peer_id == fid and not ev.get("accept"):
                    reason = {"busy": "مشغول الآن", "offline": "غير متصل"}.get(ev.get("reason"), "رفض المكالمة")
                    self.end_call(notify=False)
                    self.log(f"📞 {fname}: {reason}")
                return
            if t == "call_end":
                if self.call is not None and self.call.peer_id == fid:
                    self.end_call(notify=False)
                    self.log(f"📞 {fname} أنهى المكالمة")
                if self._incoming_call and (self._incoming_call.get("from") or {}).get("id") == fid and self.call_box:
                    self._incoming_call = None
                    b, self.call_box = self.call_box, None
                    b.close()
                    self.log(f"📞 مكالمة فائتة من {fname}")
                return
            if t == "challenge":
                if self.session is not None or self.challenge_box is not None:
                    self.lobby.answer(fid, False, ev.get("room", ""), "busy")
                    return
                self._incoming = ev
                box = QMessageBox(self)
                box.setWindowTitle("تحدٍ جديد ⚔️")
                box.setStyleSheet("QLabel{font-size:16px; font-weight:700; min-width:300px;}"
                                  "QPushButton{min-width:90px; padding:10px 18px;}")
                box.setText(f"{fname} يتحداك في:\n{ev.get('game') or 'لعبة'}")
                acc = box.addButton("قبول", QMessageBox.AcceptRole)
                box.addButton("رفض", QMessageBox.RejectRole)
                box.setModal(False)
                box.finished.connect(lambda _r, b=box, a=acc: self._challenge_answered(b, b.clickedButton() is a))
                self.challenge_box = box
                box.show()
                QApplication.alert(self)
            elif t == "cancel":
                if self._incoming and (self._incoming.get("from") or {}).get("id") == fid and self.challenge_box:
                    self._incoming = None
                    b, self.challenge_box = self.challenge_box, None
                    b.close()
                    self.log(f"{fname} ألغى التحدي")
            elif t == "answer":
                if fid != self.pending_to:
                    return
                who = self.waiting_hint_name
                self.pending_to = None
                if ev.get("accept"):
                    self.waiting_hint = ""
                    self.log(f"{who} قبل التحدي!")
                else:
                    reason = {"busy": "مشغول الآن", "no_rom": "لا يملك هذه اللعبة",
                              "offline": "غير متصل"}.get(ev.get("reason"), "رفض التحدي")
                    self.leave_game()
                    QMessageBox.information(self, "التحدي", f"{who}: {reason}")

        def _challenge_answered(self, box, accepted):
            ev, self._incoming = self._incoming, None
            self.challenge_box = None
            if not ev:
                return
            fid = (ev.get("from") or {}).get("id", "")
            room = ev.get("room", "")
            if not accepted:
                self.lobby.answer(fid, False, room, "declined")
                return
            folders = [os.path.dirname(self.rom_path) if self.rom_path else "", os.path.join(APP_DIR, "roms")]
            crc = int(ev.get("crc") or 0)
            rom = self.rom_path if (self.rom_path and os.path.isfile(self.rom_path) and
                                    disc_crc(self.rom_path) == crc) else \
                find_rom_by_crc(crc, folders)
            if not rom:
                self.lobby.answer(fid, False, room, "no_rom")
                QMessageBox.warning(self, "التحدي", f"لا تملك نفس ملف اللعبة:\n{ev.get('game')}\n"
                                    "ضعه في نفس مجلد اللعبة الحالية ثم اطلب تحدياً جديداً.")
                return
            self.rom_path = rom
            self._update_rom_card()
            self.lobby.answer(fid, True, room)
            self.start("join", room=room)

        def challenge_player(self, pl):
            if self.session is not None:
                return
            if not self.rom_path or not os.path.isfile(self.rom_path):
                QMessageBox.warning(self, "التحدي", "اختر اللعبة أولاً من صفحة «اللعب»")
                return
            room = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))
            self.waiting_hint_name = pl.get("name") or "اللاعب"
            if not self.start("host", room=room):
                return
            crc = disc_crc(self.rom_path)
            self.pending_to = pl.get("id")
            self.waiting_hint = f"⚔  بانتظار رد {self.waiting_hint_name} على التحدي..."
            self.lobby.challenge(pl.get("id"), self._rom_title(), crc, room)

        def _page_log(self):
            page, v = self._page("السجل", "أحداث الاتصال والمزامنة")
            self.logbox = QPlainTextEdit()
            self.logbox.setReadOnly(True)
            self.logbox.setLayoutDirection(Qt.RightToLeft)
            v.addWidget(self.logbox, 1)
            return page

        # ---------- helpers ----------
        def _update_rom_card(self):
            p = self.rom_path
            if p and os.path.isfile(p):
                self.rom_title.setText(os.path.splitext(os.path.basename(p))[0])
                size = sum(os.path.getsize(f) for f in disc_files(p) if os.path.isfile(f))
                self.rom_sub.setText(f"{size / (1 << 20):.0f} MB · {os.path.dirname(p)}")
                self._load_cover(p)
            else:
                self._set_cover(None)
                self.rom_title.setText("لم يتم اختيار لعبة")
                self.rom_sub.setText("اختر ملف .iso / .chd / .cso أو اسحبه إلى هنا")

        def _set_cover(self, img_path):
            t = self.rom_tile
            img = QImage(img_path) if img_path else QImage()
            if img.isNull():
                t.setPixmap(QPixmap())
                t.setText("PS2")
                t.setFixedSize(54, 54)
                return
            h = 92
            w = max(48, min(130, round(img.width() * h / max(1, img.height()))))
            img = img.scaled(w * 2, h * 2, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation)
            pm = QPixmap(w * 2, h * 2)
            pm.fill(Qt.transparent)
            p = QPainter(pm)
            p.setRenderHint(QPainter.Antialiasing)
            path = QPainterPath()
            path.addRoundedRect(QRectF(0, 0, w * 2, h * 2), 18, 18)
            p.setClipPath(path)
            p.drawImage((w * 2 - img.width()) // 2, (h * 2 - img.height()) // 2, img)
            p.end()
            pm.setDevicePixelRatio(2)
            t.setText("")
            t.setFixedSize(w, h)
            t.setPixmap(pm)

        def _load_cover(self, rom):
            cache = os.path.join(APP_DIR, "covers")
            server = self._server() if hasattr(self, "ed_server") else \
                (self.settings.value("server", DEFAULT_SERVER) or DEFAULT_SERVER)
            box = {}
            threading.Thread(target=lambda: box.setdefault("p", fetch_cover(server, rom, cache)),
                             daemon=True).start()
            self._cover_for = rom

            def check(n=0):
                if "p" in box:
                    if self._cover_for == rom:
                        self._set_cover(box["p"])
                elif n < 1500:
                    QTimer.singleShot(60, lambda: check(n + 1))
            check()

        def _pick_rom(self):
            path, _ = QFileDialog.getOpenFileName(self, "اختر لعبة PS2", os.path.dirname(self.rom_path),
                                                  "PS2 (*.iso *.chd *.cso *.zso *.gz *.ciso *.cue *.m3u *.elf)")
            if path:
                self.rom_path = path
                self._update_rom_card()

        def dragEnterEvent(self, e):
            if e.mimeData().hasUrls():
                e.acceptProposedAction()

        def dropEvent(self, e):
            for u in e.mimeData().urls():
                p = u.toLocalFile()
                if os.path.isfile(p):
                    if p.lower().endswith((".dll", ".so", ".dylib")):
                        self.ed_core.setText(p)
                    elif p.lower().endswith(".bin") and os.path.isfile(os.path.splitext(p)[0] + ".cue"):
                        self.rom_path = os.path.splitext(p)[0] + ".cue"
                        self._update_rom_card()
                    else:
                        self.rom_path = p
                        self._update_rom_card()
                    break

        def _browse(self, edit, flt):
            path, _ = QFileDialog.getOpenFileName(self, "اختر ملف", os.path.dirname(edit.text()), flt)
            if path:
                edit.setText(path)

        def _new_code(self):
            self.ed_room.setText("".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
                                         for _ in range(5)))

        def _copy_code(self):
            if self.ed_room.text():
                QApplication.clipboard().setText(self.ed_room.text())
                self.set_chip("تم نسخ الكود", "#2BD67B")

        def set_chip(self, text, color="#8A91A6"):
            self.chip.setText(f"●  {text}")
            self.chip.setStyleSheet(f"color: {color};")

        def log(self, msg):
            self.toast = (msg, time.time())
            if hasattr(self, "logbox"):
                self.logbox.appendPlainText(time.strftime("%H:%M:%S   ") + msg)

        def _refresh_bios(self):
            os.makedirs(BIOS_DIR, exist_ok=True)
            cur = self.cb_bios.currentData() or self.settings.value("bios", "")
            self.cb_bios.clear()
            for n, h in list_bios():
                self.cb_bios.addItem(f"{n}   ·   {h[:8]}", n)
            if self.cb_bios.count() == 0:
                self.cb_bios.addItem("⚠ لا يوجد بايوس — ضع ملف البايوس في المجلد ثم اضغط ⟳", "")
            self.cb_bios.setCurrentIndex(max(0, self.cb_bios.findData(cur)))

        def _open_bios_dir(self):
            os.makedirs(BIOS_DIR, exist_ok=True)
            from PySide6.QtGui import QDesktopServices
            from PySide6.QtCore import QUrl
            QDesktopServices.openUrl(QUrl.fromLocalFile(BIOS_DIR))

        # ---------- session ----------
        def start(self, mode, room=None):
            if getattr(self, "call", None) is not None:
                self.end_call(notify=True)
            st = self.settings
            st.setValue("server", self.ed_server.text().strip())
            st.setValue("room", self.ed_room.text().strip())
            st.setValue("core", self.ed_core.text().strip())
            st.setValue("rom", self.rom_path)
            st.setValue("plugin", self.cb_plugin.currentText())
            st.setValue("delay", self.sp_delay.value())
            st.setValue("smooth", self.ck_smooth.isChecked())
            st.setValue("renderer", self.cb_renderer.currentData())
            st.setValue("upscale", self.cb_res.currentData())
            st.setValue("bios", self.cb_bios.currentData())
            self.smooth = self.ck_smooth.isChecked()

            core, rom = self.ed_core.text().strip(), self.rom_path
            if not os.path.isfile(core):
                QMessageBox.warning(self, "النواة", "ملف النواة غير موجود — حدده من صفحة الإعدادات")
                return False
            if not os.path.isfile(rom):
                QMessageBox.warning(self, "اللعبة", "اختر ملف اللعبة (.iso أو .chd) أولاً")
                return False
            if room is None:
                room = self.ed_room.text().strip().upper()
            if mode == "host" and not room:
                self._new_code()
                room = self.ed_room.text()
            if mode != "offline" and not room:
                QMessageBox.warning(self, "كود الغرفة", "اكتب كود الغرفة الذي أرسله لك صديقك")
                return False
            self.room = room if mode != "offline" else ""
            plugin = self.plugins[self.cb_plugin.currentIndex()]
            try:
                self.session = Session(core, rom, plugin, mode, server=self.ed_server.text().strip(),
                                       room=room, name=self.ed_name.text().strip() or "Player",
                                       delay=self.sp_delay.value(), bios=self.cb_bios.currentData(),
                                       renderer=self.cb_renderer.currentData(),
                                       upscale=self.cb_res.currentData(),
                                       log=self.log, token=self.token)
            except Exception as e:
                self.session = None
                self.set_chip("تعذّر الاتصال", "#FF4D6D")
                QMessageBox.critical(self, "تعذّر البدء", str(e))
                return False
            if mode == "host" and self.pending_to is None and room == self.ed_room.text().strip().upper():
                QApplication.clipboard().setText(room)
                self.log(f"كود الغرفة {room} — تم نسخه")
            self.set_chip("في اللعب", "#2BD67B")
            self._open_audio(self.session.core.sample_rate)
            self._open_joystick()
            self.keys.clear()
            self.stack.setCurrentWidget(self.game)
            self.game.setFocus()
            self._acc = 0.0
            self._last = time.perf_counter()
            self.timer.start(1)
            if mode != "offline":
                self.voice = VoiceIO(self.log)
                self.voice.gain = self.sl_voice.value() / 100.0
            self.lobby.set_status("playing", self._rom_title())
            self._lobby_ver = -1
            return True

        def change_voice_volume(self, delta, absolute=None):
            v = absolute if absolute is not None else self.sl_voice.value() + delta
            v = max(0, min(200, int(v)))
            if self.sl_voice.value() != v:
                self.sl_voice.blockSignals(True)
                self.sl_voice.setValue(v)
                self.sl_voice.blockSignals(False)
            self.lb_voice.setText(f"{v}%")
            self.settings.setValue("voice_volume", v)
            if self.voice is not None:
                self.voice.gain = v / 100.0
            if absolute is None:
                self.log(f"🔊 صوت المحادثة: {v}%")

        def leave_game(self):
            self.timer.stop()
            if self.voice is not None:
                self.voice.stop()
                self.voice = None
            if self.pending_to:
                self.lobby.cancel(self.pending_to)
                self.pending_to = None
            self.waiting_hint = ""
            self.chat.clear()
            self.game.close_chat()
            self.lobby.set_status("idle", "")
            self._lobby_ver = -1
            if self.session:
                self.session.close()
                self.session = None
            if self.audio_sink:
                self.audio_sink.stop()
                self.audio_sink = self.audio_dev = None
            if self.isFullScreen():
                self.showNormal()
            self.game.img = None
            self.game._img_src = None
            self.set_chip("جاهز")
            self.stack.setCurrentIndex(0)

        def toggle_fullscreen(self):
            self.showNormal() if self.isFullScreen() else self.showFullScreen()

        def _open_audio(self, rate):
            if QAudioSink is None or os.environ.get("PS2_ONLINE_NOAUDIO"):
                return
            out = QMediaDevices.defaultAudioOutput()
            if out.isNull():
                self.log("لا يوجد جهاز صوت — سيعمل البرنامج بدون صوت")
                return
            fmt = QAudioFormat()
            fmt.setSampleRate(int(round(rate)))
            fmt.setChannelCount(2)
            fmt.setSampleFormat(QAudioFormat.Int16)
            self.audio_sink = QAudioSink(out, fmt)
            self.audio_sink.setBufferSize(int(rate) * 4 // 6)
            self.audio_dev = self.audio_sink.start()

        def _open_joystick(self):
            self.joy = None
            if pygame and pygame.joystick.get_count() > 0:
                self.joy = pygame.joystick.Joystick(0)
                self.joy.init()
                self.log(f"يد تحكم: {self.joy.get_name()}")

        def read_buttons(self):
            m = 0
            for k in self.keys:
                b = KEYMAP.get(k)
                if b is not None:
                    m |= 1 << b
            if self.joy is not None:
                try:
                    pygame.event.pump()
                    for i, b in PAD_MAP.items():
                        if i < self.joy.get_numbuttons() and self.joy.get_button(i):
                            m |= 1 << b
                    if self.joy.get_numhats():
                        hx, hy = self.joy.get_hat(0)
                        if hx < 0: m |= 1 << BTN_LEFT
                        if hx > 0: m |= 1 << BTN_RIGHT
                        if hy > 0: m |= 1 << BTN_UP
                        if hy < 0: m |= 1 << BTN_DOWN
                    if self.joy.get_numaxes() >= 6:
                        if self.joy.get_axis(4) > 0.5: m |= 1 << BTN_L2
                        if self.joy.get_axis(5) > 0.5: m |= 1 << BTN_R2
                except Exception:
                    pass
            return m

        def read_input(self):
            """(أزرار، يسار X، يسار Y، يمين X، يمين Y) — العصا من اليد، أو I J K L و 8 4 5 6 في لوحة المفاتيح"""
            m = self.read_buttons()
            ax = [0, 0, 0, 0]
            for k in self.keys:
                a = STICK_KEYS.get(k)
                if a is not None:
                    ax[a[0]] += a[1]
            ax = [max(-32767, min(32767, v)) for v in ax]
            if self.joy is not None:
                try:
                    n = self.joy.get_numaxes()
                    for i in range(min(4, n)):
                        v = self.joy.get_axis(i)
                        if abs(v) > 0.12:
                            ax[i] = int(max(-1.0, min(1.0, v)) * 32767)
                except Exception:
                    pass
            return (m, ax[0], ax[1], ax[2], ax[3])

        def tick(self):
            s = self.session
            if s is None:
                return
            s.poll()
            if s.phase in ("error", "closed") and not getattr(self, "_err_shown", False):
                self._err_shown = True
                self.log(s.status)
            elif s.phase not in ("error", "closed"):
                self._err_shown = False

            now = time.perf_counter()
            ft = 1.0 / s.core.fps
            self._acc = min(self._acc + now - self._last, ft * 4)
            self._last = now
            btn = self.read_input()
            while self._acc >= ft:
                if not s.step(btn):
                    self._acc = min(self._acc, ft)
                    break
                self._acc -= ft
            if s.behind():
                s.step(btn)

            self.game.set_frame(s.video)
            if s.core.audio:
                if self.audio_dev is not None:
                    n = min(len(s.core.audio), self.audio_sink.bytesFree()) & ~3
                    if n > 0:
                        self.audio_dev.write(bytes(s.core.audio[:n]))
                s.core.audio.clear()
            if s.chat_in:
                for text in s.chat_in:
                    self.chat.append((s.peer or "الخصم", text, time.time(), False))
                s.chat_in.clear()
                QApplication.beep()
                del self.chat[:-50]
            if self.voice is not None and now - getattr(self, "_voice_t", 0) > 0.02:
                self._voice_t = now
                self.voice.tick(s)
            self.game.update()

        def closeEvent(self, e):
            self.end_call(notify=True)
            self.leave_game()
            self.lobby.close()
            super().closeEvent(e)
            QTimer.singleShot(0, QApplication.instance().quit)

    _cleanup_old_core_copies()
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setLayoutDirection(Qt.RightToLeft)
    app.setFont(font(10))
    app.setStyleSheet(QSS)
    settings = QSettings(os.path.join(APP_DIR, "settings.ini"), QSettings.IniFormat)

    def login_flow():
        srv = settings.value("server", DEFAULT_SERVER) or DEFAULT_SERVER
        if "YOUR-NAME" in srv:
            srv = DEFAULT_SERVER
        tok = settings.value("acc_token", "")
        try:
            cached = json.loads(settings.value("acc_user", "") or "null")
        except Exception:
            cached = None
        if tok:
            code, res = api_call(srv, "/auth/me", token=tok, timeout=8)
            if code == 200 and res.get("user"):
                settings.setValue("acc_user", json.dumps(res["user"]))
                return {"token": tok, "user": res["user"]}
            if code == 0 and cached:
                return {"token": tok, "user": cached}   # لا يوجد نت: نكمل بالحساب المحفوظ
            settings.remove("acc_token")
        dlg = AuthDialog(srv, (cached or {}).get("username", ""))
        if dlg.exec() != QDialog.Accepted or not dlg.result_data:
            return None
        acc = {"token": dlg.result_data["token"], "user": dlg.result_data["user"]}
        settings.setValue("acc_token", acc["token"])
        settings.setValue("acc_user", json.dumps(acc["user"]))
        settings.sync()
        return acc

    app.setQuitOnLastWindowClosed(False)
    while True:
        acc = login_flow()
        if acc is None:
            sys.exit(0)
        MainWindow.relaunch = False
        win = MainWindow(acc)
        win._refresh_avatars()
        win.show()
        app.exec()
        if not MainWindow.relaunch:
            break
    sys.exit(0)


if __name__ == "__main__":
    run_gui()
