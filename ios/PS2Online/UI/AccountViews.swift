import PhotosUI
import SwiftUI
import UIKit

/// صورة اللاعب (من السيرفر) أو الحرف الأول من اسمه
struct AvatarView: View {
    let id: String
    let av: Int
    let name: String
    var size: CGFloat = 42
    var local: UIImage? = nil

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.accentA, Theme.accentB],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .heavy))
                .foregroundColor(.white)
            if let img = local {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let url = Account.avatarURL(id: id, av: av) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// شاشة إنشاء حساب / تسجيل الدخول — إلزامية قبل استخدام التطبيق
struct AuthView: View {
    @EnvironmentObject var account: Account
    @State private var register = false
    @State private var username = UserDefaults.standard.string(forKey: "lastUsername") ?? ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accentA.opacity(0.22), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 460)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        LogoView(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PS2 Online").font(.system(size: 26, weight: .heavy))
                            Text(register ? "أنشئ حساباً جديداً" : "سجّل الدخول إلى حسابك")
                                .font(.subheadline).foregroundColor(Theme.muted)
                        }
                    }
                    .padding(.top, 40)

                    HStack(spacing: 6) {
                        segment("تسجيل الدخول", selected: !register) { register = false; error = nil }
                        segment("إنشاء حساب", selected: register) { register = true; error = nil }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))

                    VStack(alignment: .leading, spacing: 12) {
                        field("اسم المستخدم") {
                            TextField("username", text: $username)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .textContentType(.username)
                        }
                        field("كلمة المرور") {
                            SecureField("••••••", text: $password)
                                .textContentType(register ? .newPassword : .password)
                        }
                        if register {
                            field("تأكيد كلمة المرور") {
                                SecureField("••••••", text: $password2).textContentType(.newPassword)
                            }
                        }
                        if let e = error {
                            Text(e).font(.subheadline.weight(.bold)).foregroundColor(Theme.danger)
                        }
                        Button(action: submit) {
                            HStack {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? "جارِ الاتصال..." : (register ? "إنشاء الحساب" : "دخول"))
                                    .font(.headline.weight(.heavy))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accent))
                            .foregroundColor(.white)
                            .shadow(color: Theme.accentA.opacity(0.45), radius: 14, y: 6)
                        }
                        .disabled(busy)
                        .padding(.top, 4)
                    }
                    .card()

                    Text("الحساب مطلوب لاستخدام اللعب أونلاين والدردشة والمكالمات.")
                        .font(.caption).foregroundColor(Theme.muted)
                }
                .padding(22)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(Theme.text)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.heavy))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 11).fill(selected ? Theme.surface2 : .clear))
                .foregroundColor(selected ? Theme.text : Theme.muted)
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundColor(Theme.muted)
            content()
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x0D1017)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        }
    }

    private func submit() {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.count < 3 { error = Account.errors["bad_username"]; return }
        if password.count < 6 { error = Account.errors["bad_password"]; return }
        if register && password != password2 { error = "كلمتا المرور غير متطابقتين"; return }
        error = nil
        busy = true
        account.auth(register: register, username: u, password: password) { err in
            busy = false
            if let e = err {
                error = e
            } else {
                UserDefaults.standard.set(u, forKey: "lastUsername")
                Haptics.tap()
            }
        }
    }
}

/// قسم الحساب في الإعدادات: الصورة واسم المستخدم وتسجيل الخروج
struct ProfileSection: View {
    @EnvironmentObject var account: Account
    @State private var newName = ""
    @State private var msg: String?
    @State private var ok = false
    @State private var busy = false
    @State private var confirmLogout = false

    var body: some View {
        Section(header: Text("حسابك")) {
            if let u = account.user {
                HStack(spacing: 14) {
                    Button { pickPhoto() } label: {
                        AvatarView(id: u.id, av: u.av, name: u.username, size: 72, local: account.localAvatar)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Circle().fill(Theme.accentA))
                            }
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(u.username).font(.headline)
                        Text("اضغط على الصورة لتغييرها").font(.caption).foregroundColor(Theme.muted)
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    TextField("اسم المستخدم", text: $newName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button("حفظ") { saveName() }
                        .disabled(busy || newName.trimmingCharacters(in: .whitespaces) == u.username
                                  || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let m = msg {
                    Text(m).font(.footnote.weight(.semibold)).foregroundColor(ok ? Theme.good : Theme.danger)
                }
                Button(role: .destructive) { confirmLogout = true } label: {
                    Label("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .onAppear { newName = account.user?.username ?? "" }
        .confirmationDialog("هل تريد تسجيل الخروج من حسابك؟", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("تسجيل الخروج", role: .destructive) { account.logout() }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private func pickPhoto() {
        PhotoPickerPresenter.present { img in
            busy = true
            msg = "جارِ رفع الصورة..."
            ok = true
            account.updateAvatar(img) { err in
                busy = false
                ok = err == nil
                msg = err ?? "✓ تم تغيير الصورة"
            }
        }
    }

    private func saveName() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        account.updateUsername(n) { err in
            busy = false
            ok = err == nil
            msg = err ?? "✓ تم تغيير اسم المستخدم"
            if err != nil { newName = account.user?.username ?? "" }
        }
    }
}

/// منتقي الصور (iOS 15+) — يُعرض مباشرة عبر UIKit فوق أعلى شاشة،
/// لأن sheet داخل Form يُغلق نفسه فوراً
enum PhotoPickerPresenter {
    private static var delegate: Delegate?

    static func present(_ onPick: @escaping (UIImage) -> Void) {
        guard let top = topController() else { return }
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        let d = Delegate(onPick: onPick)
        delegate = d
        vc.delegate = d
        top.present(vc, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = win?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }

    final class Delegate: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            defer { PhotoPickerPresenter.delegate = nil }
            guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { return }
            let cb = onPick
            p.loadObject(ofClass: UIImage.self) { obj, _ in
                guard let img = obj as? UIImage else { return }
                DispatchQueue.main.async { cb(img) }
            }
        }
    }
}
