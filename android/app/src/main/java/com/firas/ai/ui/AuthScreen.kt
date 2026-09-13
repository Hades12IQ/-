package com.firas.ai.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.firas.ai.data.RepositoryState
import com.firas.ai.ui.glass.GlassSurface

data class AuthActions(val login: (String, String) -> Unit, val signup: (String, String, String) -> Unit,
    val browser: () -> Unit, val guest: () -> Unit, val forgot: (String) -> Unit,
    val verify: (String) -> Unit, val cancelBrowser: () -> Unit)

@Composable fun AuthScreen(state: RepositoryState, actions: AuthActions) {
    val p = LocalPalette.current
    var register by rememberSaveable { mutableStateOf(false) }
    var email by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    val busy = state.loading || state.session.restoring
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().verticalScroll(rememberScrollState())
        .padding(horizontal = 28.dp, vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(48.dp))
        FirasMark(Modifier.size(width = 44.dp, height = 60.dp))
        Spacer(Modifier.height(24.dp))
        Text("Firas AI", fontSize = 32.sp, fontWeight = FontWeight.SemiBold, fontFamily=androidx.compose.ui.text.font.FontFamily.SansSerif)
        Spacer(Modifier.height(8.dp))
        Text(tr("مساحة لأفكارك، وأدوات لإنجازها.", "A place for your ideas. Tools to make them happen."),
            color = p.secondary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(40.dp))
        if (state.authFlow.code != null) {
            Surface(shape = RoundedCornerShape(20.dp), tonalElevation = 2.dp) {
                Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(tr("تأكيد تسجيل الدخول", "Confirm sign-in"), style = MaterialTheme.typography.titleMedium)
                    Text(state.authFlow.code.orEmpty(), fontSize = 32.sp, letterSpacing = 5.sp, modifier = Modifier.padding(16.dp))
                    Text(tr("طابق الرمز في المتصفح ثم وافق على الربط.", "Match this code in your browser, then approve the connection."), textAlign = TextAlign.Center)
                    TextButton(onClick = actions.cancelBrowser) { Text(tr("إلغاء", "Cancel")) }
                }
            }
        } else if (state.authFlow.pendingId != null) {
            Text(tr("افتح رابط التحقق الذي أُرسل إلى بريدك.", "Open the verification link sent to your email."))
            Button(onClick = { actions.verify(state.authFlow.pendingId.orEmpty()) }, enabled = !busy,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp).heightIn(min = 52.dp)) {
                Text(tr("التحقق من البريد", "Check verification"))
            }
        } else {
            GlassSurface(modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp)) {
                TextButton(onClick = actions.browser, enabled = !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 58.dp)) {
                    Text(tr("متابعة مع Google أو المتصفح", "Continue with Google or browser"))
                }
            }
            Row(Modifier.padding(vertical = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                HorizontalDivider(Modifier.weight(1f)); Text(tr(" أو بالبريد ", " or email "), color = p.secondary); HorizontalDivider(Modifier.weight(1f))
            }
            if (register) OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text(tr("الاسم", "Name")) },
                singleLine = true, shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp))
            OutlinedTextField(value = email, onValueChange = { email = it }, label = { Text(tr("البريد الإلكتروني", "Email")) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), singleLine = true,
                shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(value = password, onValueChange = { password = it }, label = { Text(tr("كلمة المرور", "Password")) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), visualTransformation = PasswordVisualTransformation(), singleLine = true,
                shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { actions.forgot(email.trim()) }, enabled = email.isNotBlank() && !busy, modifier = Modifier.align(Alignment.Start)) {
                Text(tr("نسيت كلمة المرور", "Forgot password"))
            }
            Button(onClick = { if (register) actions.signup(name.trim(), email.trim(), password) else actions.login(email.trim(), password) },
                enabled = !busy && email.isNotBlank() && password.isNotBlank() && (!register || name.isNotBlank()),
                modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp), shape = RoundedCornerShape(16.dp)) {
                if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else Text(if (register) tr("إنشاء الحساب", "Create account") else tr("تسجيل الدخول", "Sign in"))
            }
            TextButton(onClick = { register = !register; password = "" }, enabled = !busy) {
                Text(if (register) tr("لديك حساب؟ تسجيل الدخول", "Already a member? Sign in") else tr("حساب جديد", "Create an account"))
            }
            TextButton(onClick = actions.guest, enabled = !busy) { Text(tr("تجربة كضيف", "Try as a guest"), color = p.secondary) }
        }
        state.error?.let { Text(it.text(if (LocalArabic.current) "ar" else "en"), color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 12.dp)) }
        Spacer(Modifier.height(24.dp))
    }
}
