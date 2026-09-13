package com.firas.ai.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.firas.ai.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Sensitive setup state lives only in this composition and is cleared on account changes. */
@Composable fun TelegramSettingsScreen(repository:FirasRepository,browse:(String)->Unit) {
    val session by repository.state.collectAsState()
    val owner=session.session.ownerId
    val scope=rememberCoroutineScope()
    val ar=LocalArabic.current
    var token by remember(owner) {mutableStateOf("")}
    var userId by remember(owner) {mutableStateOf("")}
    var status by remember(owner) {mutableStateOf<JSONObject?>(null)}
    var pairing by remember(owner) {mutableStateOf<JSONObject?>(null)}
    var pairingConnection by remember(owner) {mutableStateOf("")}
    var now by remember {mutableLongStateOf(System.currentTimeMillis())}
    var busy by remember(owner) {mutableStateOf(false)}
    var notice by remember(owner) {mutableStateOf("")}
    var confirmDisconnect by remember {mutableStateOf(false)}
    fun current()=owner!=null && repository.state.value.session.ownerId==owner
    fun accept(value:JSONObject,allowPairing:Boolean) {
        require(OmnixTelegramPolicy.validStatus(value))
        val connection=value.optString("connectionId")
        if(allowPairing) {pairing=value.optJSONObject("pairing");pairingConnection=connection}
        status=value
        if(value.optString("state")!="pairing" || connection!=pairingConnection) pairing=null
    }
    fun refresh() { if(!busy) scope.launch {
        busy=true
        try {val reply=repository.omnixTelegramStatus();if(current()) {accept(reply,false);notice=""}}
        catch(e:CancellationException) {throw e}
        catch(_:Exception) {if(current()){status=null;pairing=null;notice=if(ar) "تعذر تحديث حالة الربط. حاول مجدداً." else "Could not refresh the connection. Try again."}}
        finally {if(current()) busy=false}
    } }
    fun mutate(disconnect:Boolean) {if(!busy) scope.launch {
        busy=true;status=null;pairing=null;notice=""
        val providedToken=token.trim();token=""
        val numeric=OmnixTelegramPolicy.userId(userId)
        try {
            val reply=if(disconnect) repository.omnixTelegramDisconnect() else repository.omnixTelegramConfigure(providedToken,numeric ?: 0)
            if(current()) accept(reply,true)
        } catch(e:CancellationException) {throw e}
        catch(_:Exception) {if(current()) notice=if(ar) "لم تتأكد العملية. نتحقق من حالتها قبل إعادة المحاولة." else "The operation is unconfirmed. Checking its status before retrying."}
        try {val reply=repository.omnixTelegramStatus();if(current()) accept(reply,false)}
        catch(e:CancellationException) {throw e}
        catch(_:Exception) {if(current() && notice.isBlank()) notice=if(ar) "تعذر تحديث الحالة. اضغط تحديث." else "Could not refresh the status. Tap Refresh."}
        finally {if(current()) busy=false}
    } }
    LaunchedEffect(owner) {refresh()}
    LaunchedEffect(status?.optString("state"),owner) {
        while(status?.optString("state") in setOf("pairing","setting_up","disconnecting")) {
            delay(5000);now=System.currentTimeMillis()
            if(pairing?.optLong("expiresAt",0)?.let {it<=now}==true) pairing=null
            refresh()
        }
    }
    val phase=status?.optString("state").orEmpty()
    val canConfigure=status?.let(OmnixTelegramPolicy::mayConfigure)==true
    val canDisconnect=status?.let(OmnixTelegramPolicy::canDisconnect)==true
    val label=when(phase) {
        "connected" -> if(ar) "متصل بحسابك" else "Connected to your account"
        "pairing" -> if(ar) "بانتظار تأكيدك في تيليغرام" else "Waiting for confirmation in Telegram"
        "setting_up" -> if(ar) "جارٍ إعداد الربط" else "Setting up the connection"
        "disconnecting" -> if(ar) "جارٍ إزالة الربط" else "Disconnecting"
        "not_configured","disconnected" -> if(ar) "غير مرتبط" else "Not connected"
        "setup_uncertain","disconnect_uncertain" -> if(ar) "بانتظار تأكيد الحالة" else "Awaiting confirmed status"
        else -> if(ar) "حالة الربط" else "Connection status"
    }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(22.dp),verticalArrangement=Arrangement.spacedBy(22.dp)) {
        item {Column(verticalArrangement=Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Outlined.Send,null,tint=LocalPalette.current.accent,modifier=Modifier.size(36.dp))
            Text(if(ar) "أومنكس، معك في تيليغرام" else "Omnix, with you on Telegram",style=MaterialTheme.typography.titleLarge)
            Text(if(ar) "اربط بوتك الخاص، وتابع مهامك من حساب فراس نفسه." else "Connect your private bot and continue tasks with the same Firas account.",color=LocalPalette.current.secondary)
        } }
        item {Surface(shape=RoundedCornerShape(22.dp),color=LocalPalette.current.surface) {Row(Modifier.fillMaxWidth().padding(18.dp),verticalAlignment=Alignment.CenterVertically) {
            Icon(if(phase=="connected") Icons.Outlined.CheckCircle else Icons.Outlined.Link,null,tint=LocalPalette.current.accent)
            Text(label,Modifier.weight(1f).padding(horizontal=12.dp))
            IconButton(onClick={refresh()},enabled=!busy) {Icon(Icons.Outlined.Refresh,if(ar) "تحديث الحالة" else "Refresh status")}
        }} }
        if(busy) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        if(canConfigure) {
            item {OutlinedTextField(token,{token=it},label={Text(if(ar) "رمز البوت من BotFather" else "Bot token from BotFather")},visualTransformation=PasswordVisualTransformation(),singleLine=true,modifier=Modifier.fillMaxWidth(),enabled=!busy)}
            item {OutlinedTextField(userId,{userId=it},label={Text(if(ar) "معرّف حسابك الرقمي في تيليغرام" else "Your numeric Telegram user ID")},supportingText={Text(if(ar) "ليس رقم الهاتف أو اسم المستخدم" else "Not your phone number or username")},keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number),singleLine=true,modifier=Modifier.fillMaxWidth(),enabled=!busy)}
            item {Button(onClick={mutate(false)},enabled=!busy && OmnixTelegramPolicy.validToken(token.trim()) && OmnixTelegramPolicy.userId(userId)!=null,modifier=Modifier.fillMaxWidth().heightIn(min=52.dp)) {Text(if(ar) "ربط البوت" else "Connect bot")}}
        } else if(phase in setOf("not_configured","disconnected")) item {Text(if(ar) "تحتاج مساحة أومنكس سحابية جاهزة وموافقة الحساب قبل الربط." else "A ready Omnix cloud workspace and account approval are required before linking.",color=LocalPalette.current.secondary)}
        val code=pairing?.optString("code").orEmpty()
        val username=status?.optJSONObject("bot")?.optString("username").orEmpty()
        if(phase=="pairing" && pairingConnection==status?.optString("connectionId") && (pairing?.optLong("expiresAt") ?: 0)>now && code.matches(Regex("[A-Za-z0-9_-]{32}")) && username.matches(Regex("[A-Za-z][A-Za-z0-9_]{4,31}"))) {
            item {Button(onClick={if(current() && (pairing?.optLong("expiresAt") ?: 0)>System.currentTimeMillis()) browse("https://t.me/$username?start=$code")},modifier=Modifier.fillMaxWidth().heightIn(min=52.dp)) {Text(if(ar) "فتح البوت وتأكيد الربط" else "Open bot and confirm")}}
        }
        if(canDisconnect) item {OutlinedButton(onClick={confirmDisconnect=true},enabled=!busy,modifier=Modifier.fillMaxWidth()) {Text(if(ar) "إزالة الربط" else "Disconnect")}}
        if(notice.isNotBlank()) item {Text(notice,color=LocalPalette.current.secondary)}
    }
    if(confirmDisconnect) AlertDialog(onDismissRequest={confirmDisconnect=false},title={Text(if(ar) "إزالة ربط البوت؟" else "Disconnect this bot?")},text={Text(if(ar) "يتوقف البوت عن تنفيذ مهام حسابك بعد تأكيد الخادم." else "The bot will stop running tasks for your account after the server confirms.")},confirmButton={TextButton(onClick={confirmDisconnect=false;mutate(true)}) {Text(if(ar) "إزالة الربط" else "Disconnect")}},dismissButton={TextButton(onClick={confirmDisconnect=false}) {Text(if(ar) "إلغاء" else "Cancel")}})
}
