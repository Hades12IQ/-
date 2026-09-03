import SwiftUI

/// The account page's side effects, split out so neither file grows past reading length.
///
/// Every one of these goes through `SessionStore`: the view never touches `APIClient`, never sees
/// an HTTP status, and never renders the server's own sentence — `session.errorText` is already
/// localized by `ErrorPresenter` (`audit-ios-shell-settings-design.md F15`).
extension AccountSettingsView {

    func submitEmail() {
        let address = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            notice = Notice(text: Strings.Settings.Account.emailRequired(lang), kind: .error)
            return
        }
        notice = nil
        Task {
            let ok = await env.session.changeEmail(
                currentPassword: emailPassword,
                newEmail: address
            )
            if ok {
                newEmail = ""
                emailPassword = ""
                notice = Notice(text: Strings.Settings.Account.emailUpdated(lang), kind: .success)
            } else {
                Haptics.error()
            }
        }
    }

    func submitPassword() {
        guard newPassword.count >= 8 else {
            notice = Notice(text: Strings.Settings.Account.passwordShort(lang), kind: .error)
            return
        }
        notice = nil
        Task {
            let ok = await env.session.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            if ok {
                currentPassword = ""
                newPassword = ""
                notice = Notice(text: Strings.Settings.Account.passwordChanged(lang), kind: .success)
            } else {
                Haptics.error()
            }
        }
    }

    func submitRedeem() {
        let code = redeemCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        notice = nil
        Task {
            let ok = await env.session.redeem(code: code)
            if ok {
                redeemCode = ""
                notice = Notice(text: Strings.Settings.Account.redeemDone(lang), kind: .success)
            } else {
                Haptics.error()
            }
        }
    }

    func armDelete() {
        Haptics.select()
        isDeleteArmed = true
    }

    func disarmDelete() {
        isDeleteArmed = false
        deletePassword = ""
    }

    func submitDelete() {
        notice = nil
        Task {
            let ok = await env.session.deleteAccount(currentPassword: deletePassword)
            deletePassword = ""
            if ok {
                isDeleteArmed = false
                env.toasts.show(Strings.Settings.Account.deleted(lang))
                env.router.sheet = nil
            } else {
                Haptics.error()
            }
        }
    }

    func signOut() {
        Task {
            await env.session.logout()
            env.memory.reset()
            env.router.sheet = nil
        }
    }

    func startSignUp() {
        env.router.sheet = nil
        env.router.open(.auth(mode: .signup))
    }

    func startSignIn() {
        env.router.sheet = nil
        env.router.open(.auth(mode: .login))
    }

}
