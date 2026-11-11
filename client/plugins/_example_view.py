# -*- coding: utf-8 -*-
"""
قالب إضافة عرض لـ PS2 Online — انسخ هذا الملف (بدون _ في أول الاسم) وعدّله لكل لعبة.

  * اللعبة "الحقيقية" تعمل متزامنة عند اللاعبين (نفس المدخلات = نفس النتيجة).
  * الإضافة ترسم فوق الصورة فقط ولا تلمس اللعبة، لذلك لا يحدث desync.

  overlay(painter, rect, ram, player): ارسم فوق الصورة حسب رقم اللاعب (إخفاء، علامة، نص...).
      ram    = ذاكرة PS2 الرئيسية (EE RAM) 32MB — الفهرس 0 يقابل العنوان 0x00000000
               (في PCSX2 Debugger يظهر نفس العنوان، و 0x20xxxxxx = نفس الذاكرة بدون كاش).
      rect   = مكان الصورة على الشاشة؛ إحداثيات PS2 المعتادة 640×448.
      player = 0 للمضيف (الكنترول الأول)، 1 للضيف (الكنترول الثاني).
      self.frame = صورة الإطار الحالي (QImage) لفحص لون بكسل.
"""
from PySide6.QtCore import QRectF
from PySide6.QtGui import QColor

TURN_ADDR = 0x00100000          # عنوان وهمي للتوضيح: بايت يحدد صاحب القائمة الظاهرة (0/1)
MENU_RECT = (0, 336, 640, 112)  # منطقة القائمة بإحداثيات PS2 (x, y, w, h)


class ExampleView:
    name = "مثال: إخفاء قائمة الخصم"

    def overlay(self, painter, rect, ram, player):
        if ram is None:
            return
        owner = ram[TURN_ADDR] & 1
        if owner != player:
            x, y, w, h = MENU_RECT
            sx, sy = rect.width() / 640, rect.height() / 448
            r = QRectF(rect.x() + x * sx, rect.y() + y * sy, w * sx, h * sy)
            painter.fillRect(r, QColor(8, 10, 16, 240))
            painter.setPen(QColor(232, 234, 242))
            painter.drawText(r, 0x0084, "🔒  الخصم يختار...")


PLUGIN = ExampleView()
