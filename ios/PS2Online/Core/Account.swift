import Foundation
import SwiftUI
import UIKit

struct UserInfo: Codable, Equatable {
    var id: String
    var username: String
    var av: Int
}

/// حساب اللاعب — التسجيل والدخول والملف الشخصي عبر السيرفر
final class Account: ObservableObject {
    static let shared = Account()

    @Published private(set) var user: UserInfo?
    @Published private(set) var token: String = ""
    /// صورة محلية تظهر فوراً بعد الرفع
    @Published var localAvatar: UIImage?

    var isLoggedIn: Bool { user != nil && !token.isEmpty }

    static let errors: [String: String] = [
        "taken": "اسم المستخدم مستخدم من شخص آخر",
        "bad_username": "اسم المستخدم من 3 إلى 20 حرفاً (حروف وأرقام و _ . - فقط)",
        "bad_password": "كلمة المرور يجب أن تكون 6 أحرف على الأقل",
        "wrong": "اسم المستخدم أو كلمة المرور غير صحيحة",
        "locked": "محاولات كثيرة — انتظر دقيقة ثم حاول مرة أخرى",
        "network": "تعذّر الاتصال بالسيرفر — تأكد من الإنترنت",
        "too_big": "الصورة كبيرة جداً",
        "not_jpeg": "صيغة الصورة غير مدعومة",
        "auth": "انتهت الجلسة — سجّل الدخول من جديد",
    ]

    static func message(_ res: [String: Any]) -> String {
        if res["error"] as? String == "locked", let r = res["retry"] as? Int {
            return "محاولات كثيرة — انتظر \(r) ثانية"
        }
        return errors[res["error"] as? String ?? ""] ?? "حدث خطأ — حاول مرة أخرى"
    }

    private init() {
        let d = UserDefaults.standard
        token = d.string(forKey: "accToken") ?? ""
        if let data = d.data(forKey: "accUser"), let u = try? JSONDecoder().decode(UserInfo.self, from: data) {
            user = u
        }
        if token.isEmpty { user = nil }
    }

    // MARK: - server

    static var server: String {
        var s = UserDefaults.standard.string(forKey: "server") ?? AppDefaults.server
        if s.isEmpty || s.contains("YOUR-NAME") { s = AppDefaults.server }
        return s
    }

    static var httpBase: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("wss://") { return "https://" + s.dropFirst(6) }
        if s.hasPrefix("ws://") { return "http://" + s.dropFirst(5) }
        return s
    }

    static func avatarURL(id: String, av: Int) -> URL? {
        guard av > 0, !id.isEmpty else { return nil }
        return URL(string: "\(httpBase)/avatar/\(id)?v=\(av)")
    }

    /// (status, json) — status = 0 عند فشل الشبكة
    private func call(_ path: String, body: [String: Any]? = nil, auth: Bool = false,
                      done: @escaping (Int, [String: Any]) -> Void) {
        guard let url = URL(string: Account.httpBase + path) else { done(0, ["error": "network"]); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body {
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        if auth { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var obj = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            if err != nil || code == 0 { obj = ["error": "network"] }
            DispatchQueue.main.async { done(err != nil ? 0 : code, obj) }
        }.resume()
    }

    private func parseUser(_ o: Any?) -> UserInfo? {
        guard let d = o as? [String: Any], let id = d["id"] as? String,
              let name = d["username"] as? String else { return nil }
        return UserInfo(id: id, username: name, av: (d["av"] as? NSNumber)?.intValue ?? 0)
    }

    private func save(token t: String?, user u: UserInfo?) {
        let d = UserDefaults.standard
        if let t = t { token = t; d.set(t, forKey: "accToken") }
        user = u
        if let u = u, let data = try? JSONEncoder().encode(u) { d.set(data, forKey: "accUser") }
    }

    func auth(register: Bool, username: String, password: String, done: @escaping (String?) -> Void) {
        call(register ? "/auth/register" : "/auth/login",
             body: ["username": username, "password": password]) { [weak self] code, res in
            guard let self = self else { return }
            if code == 200, let t = res["token"] as? String, let u = self.parseUser(res["user"]) {
                self.localAvatar = nil
                self.save(token: t, user: u)
                done(nil)
            } else {
                done(Account.message(res))
            }
        }
    }

    /// يتحقق من الجلسة عند فتح التطبيق
    func refresh() {
        guard !token.isEmpty else { return }
        call("/auth/me", auth: true) { [weak self] code, res in
            guard let self = self else { return }
            if code == 200, let u = self.parseUser(res["user"]) {
                self.save(token: nil, user: u)
            } else if code == 401 {
                self.clear()
            }
        }
    }

    func updateUsername(_ name: String, done: @escaping (String?) -> Void) {
        call("/auth/profile", body: ["username": name], auth: true) { [weak self] code, res in
            self?.handleProfile(code, res, done)
        }
    }

    func updateAvatar(_ image: UIImage, done: @escaping (String?) -> Void) {
        guard let jpeg = Account.squareJPEG(image) else { done("تعذّر فتح الصورة"); return }
        call("/auth/profile", body: ["avatar": jpeg.base64EncodedString()], auth: true) { [weak self] code, res in
            if code == 200 { self?.localAvatar = UIImage(data: jpeg) }
            self?.handleProfile(code, res, done)
        }
    }

    private func handleProfile(_ code: Int, _ res: [String: Any], _ done: (String?) -> Void) {
        if code == 200, let u = parseUser(res["user"]) {
            save(token: nil, user: u)
            done(nil)
        } else {
            if code == 401 { clear() }
            done(Account.message(res))
        }
    }

    func logout() {
        if !token.isEmpty { call("/auth/logout", body: [:], auth: true) { _, _ in } }
        clear()
    }

    private func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "accToken")
        token = ""
        user = nil
        localAvatar = nil
    }

    /// قص الصورة مربعاً 160×160 وضغطها JPEG
    static func squareJPEG(_ img: UIImage, side: CGFloat = 160) -> Data? {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return nil }
        let scale = max(side / s.width, side / s.height)
        let w = s.width * scale, h = s.height * scale
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        return out.jpegData(compressionQuality: 0.85)
    }
}
