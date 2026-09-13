package com.firas.ai.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.firas.ai.data.*
import kotlinx.coroutines.launch
import java.util.Locale

@Composable fun LanguagePicker(onDismiss:()->Unit,onChoose:(String)->Unit) {
    var search by remember {mutableStateOf("")}
    val ar=LocalArabic.current
    val language=if(ar) Locale.forLanguageTag("ar") else Locale.ENGLISH
    val languages=remember(ar) {Locale.getISOLanguages().map {Locale.forLanguageTag(it)}.filter {it.language.isNotBlank()}.distinctBy {it.language}.sortedBy {it.getDisplayLanguage(language)}}
    AlertDialog(onDismissRequest=onDismiss,title={Text(if(ar) "اختر لغة الترجمة" else "Choose a language")},
        text={Column {
            OutlinedTextField(search,{search=it},singleLine=true,label={Text(if(ar) "ابحث عن لغة" else "Search languages")})
            LazyColumn(Modifier.heightIn(max=440.dp)) {
                items(languages.filter {it.getDisplayLanguage(language).contains(search,true)||it.getDisplayLanguage(it).contains(search,true)||it.language.contains(search,true)},key={it.language}) { locale ->
                    ListItem(headlineContent={Text(locale.getDisplayLanguage(locale))},supportingContent={Text(locale.getDisplayLanguage(language))},modifier=Modifier.clickable {onChoose(locale.getDisplayLanguage(Locale.ENGLISH))})
                }
            }
        }},confirmButton={TextButton(onClick=onDismiss) {Text(if(ar) "إلغاء" else "Cancel")}})
}

@Composable fun JobsScreen(jobs:List<JobState>,open:(JobState)->Unit,stop:(String)->Unit) {
    val ar=LocalArabic.current
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        if(jobs.isEmpty()) item {Text(if(ar) "ستظهر مهامك هنا عند البدء." else "Your tasks will appear here when you start.",color=LocalPalette.current.secondary)}
        items(jobs.sortedByDescending {it.startedAt},key={it.id}) {job ->
            Surface(shape=MaterialTheme.shapes.large,color=LocalPalette.current.surface,modifier=Modifier.fillMaxWidth()) {
                Column(Modifier.padding(18.dp)) {
                    Text(job.title.ifBlank {job.product.title},style=MaterialTheme.typography.titleMedium)
                    Text(when(job.phase) {JobPhase.COMPLETE -> if(ar) "مكتملة" else "Complete"; JobPhase.FAILED -> if(ar) "تعذر الإكمال" else "Could not complete"; JobPhase.STOPPED -> if(ar) "متوقفة" else "Stopped";else -> if(ar) "قيد العمل" else "Working"},color=LocalPalette.current.secondary)
                    if(!job.terminal) {
                        val percent=runCatching { org.json.JSONObject(job.progress).optInt("percent",-1) }.getOrDefault(-1)
                        if(percent>=0) LinearProgressIndicator(progress={percent/100f},modifier=Modifier.fillMaxWidth().padding(top=12.dp))
                        else LinearProgressIndicator(Modifier.fillMaxWidth().padding(top=12.dp))
                    }
                    Row {TextButton(onClick={open(job)}) {Text(if(ar) "عرض" else "Open")}
                        if(job.canCancel) TextButton(onClick={stop(job.id)}) {Text(if(ar) "إيقاف" else "Stop")}}
                }
            }
        }
    }
}

@Composable fun SettingsScreen(state:RepositoryState,preferences:UiPreferences,repository:FirasRepository,notifications:()->Unit,logout:()->Unit,openTelegram:()->Unit = {}) {
    val ar=LocalArabic.current
    val scope=rememberCoroutineScope()
    var memory by remember {mutableStateOf<List<String>?>(null)}
    var password by remember {mutableStateOf("")}
    var newPassword by remember {mutableStateOf("")}
    var changePassword by remember {mutableStateOf(false)}
    var code by remember {mutableStateOf("")}
    var notice by remember {mutableStateOf("")}
    LazyColumn(contentPadding=PaddingValues(22.dp),verticalArrangement=Arrangement.spacedBy(22.dp),modifier=Modifier.fillMaxSize()) {
        item {Text(state.session.user?.name.orEmpty(),style=MaterialTheme.typography.titleLarge);Text(state.session.user?.email.orEmpty(),color=LocalPalette.current.secondary)}
        item {Text(if(ar) "المظهر" else "Appearance",style=MaterialTheme.typography.titleMedium)}
        item { Column(verticalArrangement=Arrangement.spacedBy(10.dp)) {
            palettes.chunked(3).forEach { group -> Row(horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                group.forEach { p ->
                    Surface(onClick={preferences.selectTheme(p.id)},modifier=Modifier.weight(1f),shape=androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                        color=p.ground,border=BorderStroke(if(preferences.theme==p.id) 2.dp else 1.dp,if(preferences.theme==p.id) LocalPalette.current.accent else p.border)) {
                        Column(Modifier.padding(12.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                            Box(Modifier.fillMaxWidth().height(28.dp).background(p.bubble,androidx.compose.foundation.shape.RoundedCornerShape(10.dp)))
                            Text(if(ar) p.nameAr else p.nameEn,color=p.ink,style=MaterialTheme.typography.bodySmall,modifier=Modifier.padding(top=10.dp))
                            if(preferences.theme==p.id) Icon(Icons.Outlined.Check,if(ar) "محدد" else "Selected",tint=p.accent,modifier=Modifier.size(18.dp))
                            else Spacer(Modifier.height(18.dp))
                        }
                    }
                }
            } }
        } }
        item {HorizontalDivider();Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
            Text("العربية / English",Modifier.weight(1f));Switch(checked=ar,onCheckedChange={preferences.selectArabic(it)})
        } }
        item {OutlinedButton(onClick=notifications,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) {Icon(Icons.Outlined.Notifications,null);Spacer(Modifier.width(12.dp));Text(if(ar) "إشعارات اكتمال المهام" else "Completion notifications")}}
        if(state.session.user?.guest != true) {
            item { Surface(onClick=openTelegram,shape=androidx.compose.foundation.shape.RoundedCornerShape(22.dp),color=LocalPalette.current.surface,modifier=Modifier.fillMaxWidth()) {
                Row(Modifier.padding(20.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(16.dp)) {
                    Icon(Icons.Outlined.Send,null,tint=LocalPalette.current.accent)
                    Column(Modifier.weight(1f)) {Text("Omnix · Telegram",style=MaterialTheme.typography.titleMedium);Text(if(ar) "اربط بوتك بحساب فراس" else "Connect your bot to Firas",style=MaterialTheme.typography.bodySmall,color=LocalPalette.current.secondary)}
                    Icon(Icons.Outlined.ChevronRight,null)
                }
            } }
            item {OutlinedButton(onClick={scope.launch {runCatching {repository.readMemory()}.onSuccess {memory=it}}},modifier=Modifier.fillMaxWidth()) {Text(if(ar) "إدارة الذاكرة" else "Manage memory")}}
            item {OutlinedButton(onClick={changePassword=true},modifier=Modifier.fillMaxWidth()) {Text(if(ar) "تغيير كلمة المرور" else "Change password")}}
            item {OutlinedTextField(code,{code=it},label={Text(if(ar) "رمز الاشتراك" else "Subscription code")},singleLine=true,modifier=Modifier.fillMaxWidth())
                TextButton(onClick={scope.launch {if(repository.redeemCode(code)){code="";notice=if(ar) "تم تفعيل الرمز." else "Code redeemed."}}},enabled=code.isNotBlank()) {Text(if(ar) "تفعيل" else "Redeem")}}
        }
        item {TextButton(onClick=logout,modifier=Modifier.fillMaxWidth()) {Text(if(ar) "تسجيل الخروج" else "Sign out")}}
        if(notice.isNotBlank()) item {Text(notice,color=LocalPalette.current.accent)}
    }
    memory?.let {rows ->AlertDialog(onDismissRequest={memory=null},title={Text(if(ar) "الذاكرة" else "Memory")},text={LazyColumn {
        if(rows.isEmpty()) item {Text(if(ar) "لا توجد معلومات محفوظة." else "No saved memories.")}
        items(rows.size) {i ->ListItem(headlineContent={Text(rows[i])},trailingContent={IconButton(onClick={scope.launch {if(repository.deleteMemory(i)) memory=repository.readMemory()}}) {Icon(Icons.Outlined.Delete,if(ar) "حذف" else "Delete")}})}
    }},confirmButton={TextButton(onClick={memory=null}) {Text(if(ar) "تم" else "Done")}})}
    if(changePassword) AlertDialog(onDismissRequest={changePassword=false;password="";newPassword=""},title={Text(if(ar) "تغيير كلمة المرور" else "Change password")},text={Column(verticalArrangement=Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(password,{password=it},label={Text(if(ar) "كلمة المرور الحالية" else "Current password")},visualTransformation=PasswordVisualTransformation())
        OutlinedTextField(newPassword,{newPassword=it},label={Text(if(ar) "كلمة المرور الجديدة" else "New password")},visualTransformation=PasswordVisualTransformation())
    }},confirmButton={TextButton(onClick={scope.launch {if(repository.changePassword(password,newPassword)){changePassword=false;password="";newPassword=""}}},enabled=password.isNotBlank()&&newPassword.length>=8) {Text(if(ar) "حفظ" else "Save")}},dismissButton={TextButton(onClick={changePassword=false;password="";newPassword=""}) {Text(if(ar) "إلغاء" else "Cancel")}})
}

@Composable fun BrainLibraryScreen(state:RepositoryState,repository:FirasRepository,openChat:()->Unit,browse:(String)->Unit) {
    val ar=LocalArabic.current
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var title by remember {mutableStateOf("")}
    var content by remember {mutableStateOf("")}
    var question by remember {mutableStateOf("")}
    var selected by remember {mutableStateOf(setOf<String>())}
    var importing by remember {mutableStateOf(false)}
    var error by remember {mutableStateOf("")}
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) {uri ->if(uri!=null) scope.launch {
        runCatching {AttachmentReader.read(context,listOf(uri))}.onSuccess {attachments ->
            val a=attachments.firstOrNull();title=a?.name.orEmpty();content=a?.text.orEmpty()
            if(content.isBlank()) error=if(ar) "هذا الملف يحتاج استخراج النص قبل إضافته." else "This file needs text extraction before import."
        }.onFailure {error=if(ar) "تعذر قراءة الملف." else "The file could not be read."}
    }}
    LaunchedEffect(Unit) {repository.refreshBrainLibrary()}
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        item {Text(if(ar) "مصادرك، وفهم أعمق." else "Your sources, understood.",style=MaterialTheme.typography.titleLarge)}
        item {OutlinedButton(onClick={picker.launch(arrayOf("text/*","application/pdf"))}) {Icon(Icons.Outlined.AttachFile,null);Text(if(ar) "إرفاق مصدر" else "Attach a source")}}
        item {OutlinedTextField(title,{title=it},label={Text(if(ar) "عنوان المصدر" else "Source title")},modifier=Modifier.fillMaxWidth())}
        item {OutlinedTextField(content,{content=it},label={Text(if(ar) "نص المصدر" else "Source text")},minLines=3,maxLines=8,modifier=Modifier.fillMaxWidth())}
        item {Button(onClick={scope.launch {importing=true;try {repository.importBrain(title,"text","",listOf(BrainPage(1,content)));title="";content=""} catch(_:Exception) {error=if(ar) "تعذر استيراد المصدر." else "Source import failed."} finally {importing=false}}},enabled=title.isNotBlank()&&content.isNotBlank()&&!importing) {Text(if(ar) "إضافة للمكتبة" else "Add to library")}}
        if(error.isNotBlank()) item {Text(error,color=MaterialTheme.colorScheme.error)}
        items(state.brainLibrary.sources,key={it.id}) {source ->
            ListItem(headlineContent={Text(source.title)},supportingContent={Text(if(ar) "${source.pages} صفحة" else "${source.pages} pages")},
                leadingContent={Checkbox(checked=source.id in selected,onCheckedChange={selected=if(it) selected+source.id else selected-source.id})},
                trailingContent={IconButton(onClick={scope.launch {repository.deleteBrainSource(source.id);selected=selected-source.id}}) {Icon(Icons.Outlined.Delete,if(ar) "حذف المصدر" else "Delete source")}})
        }
        item {OutlinedTextField(question,{question=it},label={Text(if(ar) "اسأل عن المصادر المحددة" else "Ask about selected sources")},modifier=Modifier.fillMaxWidth())}
        item {Button(onClick={scope.launch {repository.newThread(Product.BRAIN);repository.askBrain(question,selected.toList());openChat()}},enabled=question.isNotBlank()&&selected.isNotEmpty()) {Text(if(ar) "اسأل فراس برين" else "Ask Firas Brain")}}
    }
}
