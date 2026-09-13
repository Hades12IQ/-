package com.firas.ai.ui

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.firas.ai.data.*
import com.firas.ai.documents.AuthoredDocument
import com.firas.ai.render.MathGlyphCache
import com.firas.ai.worker.WorkerApi
import com.firas.ai.worker.WorkerRuntime
import com.firas.ai.worker.WorkerScreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import com.firas.ai.ui.glass.LocalGlassState
import com.firas.ai.ui.glass.FirasGlassHeader

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun FirasRoot(repository: FirasRepository, preferences: UiPreferences, destination: Intent?, consumed: () -> Unit, browse: (String) -> Unit) {
    val context = LocalContext.current
    val state by repository.state.collectAsState()
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val glass = remember { HazeState() }
    var screen by rememberSaveable { mutableStateOf("chat") }
    var workerPc by rememberSaveable { mutableStateOf(false) }
    var translateText by remember { mutableStateOf<String?>(null) }
    var translated by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<PreviewFile?>(null) }
    var exporting by remember { mutableStateOf(false) }
    var call by remember { mutableStateOf(false) }
    val owner = state.session.ownerId
    val ar = preferences.arabic
    BackHandler(enabled=screen!="chat" && !drawer.isOpen) {screen="chat"}
    val workerApi = remember(repository) { object : WorkerApi {
        override suspend fun get(path: String): JSONObject = repository.workerGet(path)
        override suspend fun post(path: String, body: JSONObject): JSONObject = repository.workerPost(path,body)
    } }
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    fun launch(block: suspend () -> Unit) { scope.launch {
        try { block() } catch (_: kotlinx.coroutines.CancellationException) { }
        catch (e: Exception) { snackbar.showSnackbar((e as? FirasFailure)?.notice?.text(if(ar) "ar" else "en") ?: if(ar) "تعذر إكمال العملية. حاول مجدداً." else "This action could not finish. Please try again.") }
    } }
    suspend fun selectProduct(product: Product, temporary: Boolean = false) {
        repository.newThread(product, temporary); screen="chat"
        if (temporary) snackbar.showSnackbar(if(ar) "بدأت محادثة مؤقتة — ما ينحفظ منها شي" else "Temporary conversation started — nothing is saved")
    }
    LaunchedEffect(Unit) { repository.restoreSession() }
    LaunchedEffect(ar) { repository.setLanguage(if(ar) "ar" else "en") }
    LaunchedEffect(repository) { repository.notices.collect { snackbar.showSnackbar(it.text(if(preferences.arabic) "ar" else "en")) } }
    LaunchedEffect(owner) {
        WorkerRuntime.bind(context,owner,workerApi)
        preview=null; translated=null; translateText=null; call=false
        if (owner != null && state.activeThread == null) repository.newThread()
    }
    LaunchedEffect(state.authFlow.browserUrl) {
        val url=state.authFlow.browserUrl
        if (!url.isNullOrBlank()) {
            browse(url)
            while (repository.state.value.authFlow.browserUrl == url && !repository.state.value.session.signedIn) {
                delay(2000); repository.pollBrowserLogin()
            }
        }
    }
    LaunchedEffect(destination,state.session.restoring,owner) {
        val intent=destination ?: return@LaunchedEffect
        if (state.session.restoring) return@LaunchedEffect
        if (intent.getStringExtra("firas_destination") == "worker" && intent.getStringExtra("ownerId")==owner && owner!=null) {
            workerPc=intent.getStringExtra("firas_worker_target")=="pc"; screen="worker"
        }
        else if (intent.getStringExtra("ownerId") == owner && owner != null) {
            val id=intent.getStringExtra("threadId")
            if (!id.isNullOrBlank()) { repository.openThread(id);screen="chat" } else screen="jobs"
        }
        consumed()
    }
    CompositionLocalProvider(LocalGlassState provides glass) {
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(LocalPalette.current.ground).hazeSource(glass))
        if (state.session.restoring) Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) { CircularProgressIndicator() }
        else if (state.session.user == null) AuthScreen(state,AuthActions(
            login={email,password -> launch { repository.login(email,password) }},
            signup={name,email,password -> launch { repository.signup(name,email,password) }},
            browser={launch { repository.beginBrowserLogin() }}, guest={launch { repository.startGuest() }},
            forgot={email -> launch { if(repository.forgotPassword(email)) snackbar.showSnackbar(if(ar) "تحقق من بريدك الإلكتروني." else "Check your email.") }},
            verify={pid -> launch { repository.pollSignup(pid) }},cancelBrowser={launch { repository.cancelBrowserLogin() }}))
        else ModalNavigationDrawer(drawerState=drawer,drawerContent={
            ModalDrawerSheet(drawerContainerColor=LocalPalette.current.ground) {
                Row(Modifier.fillMaxWidth().padding(24.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(14.dp)) {
                    FirasMark(); Text("Firas AI",style=MaterialTheme.typography.titleLarge)
                }
                LazyColumn(Modifier.weight(1f)) {
                    items(listOf(Product.AI,Product.AGENT,Product.CODE,Product.BRAIN)) { product ->
                        NavigationDrawerItem(label={Text(product.title)},selected=screen=="chat" && state.activeThread?.product==product,
                            onClick={launch { selectProduct(product);drawer.close() }},modifier=Modifier.padding(horizontal=12.dp))
                    }
                    item { HorizontalDivider(Modifier.padding(16.dp)) }
                    items(listOf("studio" to if(ar) "الاستوديو" else "Studio", "library" to if(ar) "مصادري" else "My sources", "worker" to "Firas Worker", "jobs" to if(ar) "المهام" else "Tasks", "settings" to if(ar) "الإعدادات" else "Settings")) { (key,label) ->
                        NavigationDrawerItem(label={Text(label)},selected=screen==key,onClick={screen=key;launch { drawer.close() }},modifier=Modifier.padding(horizontal=12.dp))
                    }
                    item { HorizontalDivider(Modifier.padding(16.dp)); Text(if(ar) "المحادثات" else "Conversations",Modifier.padding(horizontal=24.dp,vertical=8.dp),color=LocalPalette.current.secondary) }
                    items(state.threads,key={it.id}) { thread ->
                        ListItem(headlineContent={Text(thread.title,maxLines=1,overflow=TextOverflow.Ellipsis)},
                            modifier=Modifier.clickable {launch { repository.openThread(thread.id);screen="chat";drawer.close() }},
                            trailingContent={IconButton(onClick={launch {repository.pinThread(thread.id,!thread.pinned)}}) {Icon(if(thread.pinned) Icons.Outlined.PushPin else Icons.Outlined.BookmarkBorder,if(ar) "تثبيت" else "Pin")}},
                            colors=ListItemDefaults.colors(containerColor=LocalPalette.current.ground))
                    }
                }
                Text(state.session.user?.name.orEmpty(),Modifier.padding(24.dp),color=LocalPalette.current.secondary)
            }
        }) {
            Scaffold(containerColor=androidx.compose.ui.graphics.Color.Transparent,snackbarHost={SnackbarHost(snackbar)},topBar={
                Column(Modifier.statusBarsPadding()) {
                    FirasGlassHeader(
                        title=when(screen) { "chat" -> state.activeThread?.product?.title ?: "Firas AI"; "code-workspace" -> "Firas Code"; "worker" -> "Firas Worker"; "studio" -> if(ar) "الاستوديو" else "Studio"; "library" -> if(ar) "مصادري" else "My sources"; "jobs" -> if(ar) "المهام" else "Tasks"; "telegram" -> "Omnix · Telegram"; else -> if(ar) "الإعدادات" else "Settings" },
                        onMenu={launch {drawer.open()}},
                        onNew=if(screen=="chat") ({launch {selectProduct(state.activeThread?.product ?: Product.AI)}}) else null,
                        onTemporary=if(screen=="chat") ({launch {selectProduct(state.activeThread?.product ?: Product.AI,true)}}) else null,
                        onTitle=if(screen=="chat" && state.activeThread?.product==Product.CODE) ({screen="code-workspace"}) else null
                    )
                }
            }) { padding -> Box(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()) {
                when(screen) {
                    "chat" -> ChatScreen(state.activeThread,state.jobs,ChatActions(
                        send={text,uris,tier -> launch {
                            val capturedOwner=repository.state.value.session.ownerId
                            val capturedThread=repository.state.value.activeThread?.id
                            val attachments=AttachmentReader.read(context,uris)
                            if(repository.state.value.session.ownerId==capturedOwner && repository.state.value.activeThread?.id==capturedThread)
                                repository.send(text,attachments,tier)
                        }},stop={id ->launch {repository.cancelJob(id)}},
                        export={message,request ->launch {
                            val doc=AuthoredDocument.extract(message.visibleContent) ?: return@launch
                            val captured=repository.state.value.session.ownerId
                            exporting=true
                            try {
                                val file=repository.exportDocument(doc.sourceHtml,doc.filename,repository.documentAssets(state.activeThread?.id.orEmpty()))
                                if(repository.state.value.session.ownerId==captured) preview=PreviewFile(file,doc.filename,"application/pdf")
                            } finally {exporting=false}
                        }},translate={translateText=it},speak={text ->launch {SpeechPlayback.speak(context,repository,text)}},link=browse,voice={call=true},
                        openArtifact={artifact ->launch {
                            val captured=repository.state.value.session.ownerId
                            val saved=repository.downloadArtifact(artifact)
                            if(repository.state.value.session.ownerId==captured) preview=PreviewFile(saved.file,artifact.name,saved.mime ?: artifact.type)
                        }},approve={job,id,choice ->launch {repository.approveOmnix(job.id,id,choice)}},
                        openDocument={document ->launch {
                            val captured=repository.state.value.session.ownerId
                            val file=repository.downloadNativeDocument(document)
                            if(repository.state.value.session.ownerId==captured) preview=PreviewFile(file,document.filename,"application/pdf")
                        }},openMedia={media ->launch {
                            val captured=repository.state.value.session.ownerId
                            val saved=repository.downloadMedia(media)
                            if(repository.state.value.session.ownerId==captured) preview=PreviewFile(saved.file,saved.name,saved.mime ?: "application/octet-stream")
                        }}),media=state.media)
                    "worker" -> WorkerScreen(ownerId=owner,api=workerApi,initialPc=workerPc)
                    "code-workspace" -> state.activeThread?.takeIf {it.product==Product.CODE && it.ownerId==owner}?.let {thread ->
                        CodeWorkspaceScreen(thread,repository,onBack={screen="chat"},onExport={file,mime ->
                            preview=PreviewFile(file,file.name,mime)
                        })
                    }
                    "studio" -> StudioScreen(state,{command ->launch {repository.createMedia(command)}},{media ->launch {
                        val captured=repository.state.value.session.ownerId
                        val saved=repository.downloadMedia(media)
                        if(repository.state.value.session.ownerId==captured) preview=PreviewFile(saved.file,saved.name,saved.mime ?: "application/octet-stream")
                    }})
                    "library" -> BrainLibraryScreen(state,repository,{screen="chat"},browse)
                    "jobs" -> JobsScreen(state.jobs,{job ->launch {repository.openThread(job.threadId);screen="chat"}},{id ->launch {repository.cancelJob(id)}})
                    "settings" -> SettingsScreen(state,preferences,repository,{
                        if(Build.VERSION.SDK_INT>=33) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                    },{launch {repository.logout();MathGlyphCache.clear(context);WorkerRuntime.bind(context,null,workerApi)}},openTelegram={screen="telegram"})
                    "telegram" -> TelegramSettingsScreen(repository,browse)
                }
                if(exporting) Surface(Modifier.align(Alignment.BottomCenter).padding(18.dp),shape=MaterialTheme.shapes.large,color=LocalPalette.current.surface,tonalElevation=3.dp) {
                    Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp)
                        Text(if(ar) "جارٍ تجهيز الملف…" else "Preparing your file…")
                    }
                }
            } }
        }
        translateText?.let { text -> LanguagePicker(onDismiss={translateText=null}) { language ->
            translateText=null; launch {translated=repository.translate(text,language)}
        } }
        translated?.let { text -> AlertDialog(onDismissRequest={translated=null},title={Text(if(ar) "الترجمة" else "Translation")},
            text={androidx.compose.foundation.text.selection.SelectionContainer {Text(text,Modifier.verticalScroll(rememberScrollState()))}},confirmButton={TextButton(onClick={translated=null}) {Text(if(ar) "تم" else "Done")}}) }
        preview?.let { FilePreview(it,onClose={preview=null}) }
        if(call) VoiceCallSheet(repository,onClose={call=false})
    }
    }
}
