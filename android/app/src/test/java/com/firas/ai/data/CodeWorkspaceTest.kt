package com.firas.ai.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class CodeWorkspaceTest {
    private fun rejected(block: () -> Unit) {
        try { block(); fail("Unsafe or stale workspace was accepted") } catch (_: CodeWorkspaceFailure) { }
    }
    private fun archive(entries: List<Pair<String, ByteArray>>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip -> entries.forEach { (name, bytes) ->
            zip.putNextEntry(ZipEntry(name)); zip.write(bytes); zip.closeEntry()
        } }
        return output.toByteArray()
    }
    @Test fun extractsOnlyExplicitNamesAndPreservesNestedMarkdownAndUnicode() {
        val answer = """
            ```python
            print('anonymous')
            ```
            ```file:src/main.py
            print('مرحبا 🌍')
            ```
            ````file:README.md
            # Run
            ```sh
            python src/main.py
            ```
            ````
            ```kotlin filename="src/App.kt"
            fun main() = println("Hello")
            ```
        """.trimIndent()
        val files = CodeWorkspacePolicy.namedFiles(answer)
        assertEquals(listOf("src/main.py", "README.md", "src/App.kt"), files.map { it.path })
        assertEquals("print('مرحبا 🌍')\n", files[0].content)
        assertTrue(files[1].content.contains("```sh\npython src/main.py\n```\n"))
        assertEquals(emptyList<CodeWorkspaceFile>(), CodeWorkspacePolicy.namedFiles("```swift\nlet x = 1\n```"))
    }
    @Test fun unfinishedOrDuplicateNamedFilesCannotSilentlyReplaceSource() {
        rejected { CodeWorkspacePolicy.namedFiles("```file:main.py\nprint('unfinished')") }
        rejected { CodeWorkspacePolicy.namedFiles("```file:A.py\na\n```\n```file:a.py\nb\n```") }
        rejected { CodeWorkspacePolicy.namedFiles("```file:../main.py\na\n```") }
    }
    @Test fun pathsRejectTraversalAbsoluteControlsAliasesAndFileDirectoryCollision() {
        listOf("../a.py", "/a.py", "C:/a.py", "src/../../x", "src\\x", "a//b", "./x", "x\u0000.py", "a\u202Eb.py", "NUL.txt", "a. ")
            .forEach { name -> rejected { CodeWorkspacePolicy.path(name) } }
        assertEquals(".github/workflows/build.yml", CodeWorkspacePolicy.path(".github/workflows/build.yml"))
        assertEquals("مصدر/main.py", CodeWorkspacePolicy.path("مصدر/main.py"))
        rejected { CodeWorkspacePolicy.validate(CodeWorkspace(listOf(CodeWorkspaceFile("src", "x"), CodeWorkspaceFile("src/main.py", "y")))) }
        rejected { CodeWorkspacePolicy.validate(CodeWorkspace(listOf(CodeWorkspaceFile("é.py", "x"), CodeWorkspaceFile("e\u0301.py", "y")))) }
    }
    @Test fun zipRoundTripPreservesEveryFilenameAndSource() {
        val source = CodeWorkspace(listOf(CodeWorkspaceFile("src/main.rs", "fn main() { println!(\"مرحبا 🌍\"); }\n"), CodeWorkspaceFile("README.md", "# Read me\n")))
        val bytes = ByteArrayOutputStream().also { CodeWorkspacePolicy.writeZip(source, it) }.toByteArray()
        assertEquals(source, CodeWorkspacePolicy.readZip(ByteArrayInputStream(bytes)))
    }
    @Test fun zipRejectsTraversalDuplicateAliasesBinaryAndExpansionBombs() {
        val small = "content".toByteArray()
        listOf(
            listOf("../escape" to small),
            listOf("X.py" to small, "x.py" to small),
            listOf("file.bin" to byteArrayOf(0xC3.toByte(), 0x28)),
            listOf("file.bin" to byteArrayOf(0, 1, 2)),
            listOf("huge.txt" to ByteArray(CodeWorkspacePolicy.MAX_FILE_CHARS * 4 + 1) { 65 }),
            listOf("directory/" to ByteArray(100_000) { 65 })
        ).forEach { entries -> rejected { CodeWorkspacePolicy.readZip(ByteArrayInputStream(archive(entries))) } }
    }
    @Test fun reviewAppliesOnlyChosenFilesAndRequiresExactOriginalSource() {
        val base = CodeWorkspace(listOf(CodeWorkspaceFile("main.py", "old"), CodeWorkspaceFile("keep.txt", "untouched")))
        val review = CodeWorkspacePolicy.review(base, listOf(CodeWorkspaceFile("main.py", "new"), CodeWorkspaceFile("test.py", "test")), "Answer")
        assertEquals(base, base.copy()) // Preparing a review has no side effects.
        val result = CodeWorkspacePolicy.apply(base, review, setOf("test.py"))
        assertEquals("old", result.files.first { it.path == "main.py" }.content)
        assertEquals("untouched", result.files.first { it.path == "keep.txt" }.content)
        assertEquals(3, result.files.size)
        rejected { CodeWorkspacePolicy.apply(base.copy(files = base.files + CodeWorkspaceFile("edit.txt", "manual")), review, setOf("main.py")) }
        rejected { CodeWorkspacePolicy.apply(base, review, setOf("not-proposed.py")) }
    }
    @Test fun capacityValidationIsAtomicAndNeverTruncatesFiles() {
        val source = CodeWorkspace((1..30).map { CodeWorkspaceFile("$it.py", "source") })
        val review = CodeWorkspacePolicy.review(source, listOf(CodeWorkspaceFile("1.py", "changed"), CodeWorkspaceFile("new.py", "new")), "Answer")
        assertEquals(30, CodeWorkspacePolicy.apply(source, review, setOf("1.py")).files.size)
        rejected { CodeWorkspacePolicy.apply(source, review, setOf("1.py", "new.py")) }
        assertEquals("source", source.files.first().content)
        rejected { CodeWorkspacePolicy.validate(CodeWorkspace(listOf(CodeWorkspaceFile("big.txt", "a".repeat(60_001))))) }
        rejected { CodeWorkspacePolicy.validate(CodeWorkspace((1..4).map { CodeWorkspaceFile("$it.txt", "x".repeat(50_000)) })) }
    }
    @Test fun accountThreadEpochAndTemporaryScopesAreEnforced() {
        val user = User("owner", "", "")
        val thread = ChatThread("code", "owner", product = Product.CODE)
        val state = RepositoryState(session = SessionState(user, false, 4), activeThread = thread)
        val session = CodeWorkspaceSession("owner", "code", 4)
        assertTrue(session.accepts(state))
        assertFalse(session.accepts(state.copy(session = state.session.copy(epoch = 5))))
        assertFalse(session.accepts(state.copy(activeThread = thread.copy(id = "other"))))
        assertFalse(session.accepts(state.copy(activeThread = thread.copy(ownerId = "other"))))
        assertFalse(session.accepts(state.copy(activeThread = thread.copy(temporary = true))))
        assertFalse(session.accepts(state.copy(activeThread = thread.copy(product = Product.AI))))
    }
    @Test fun delayedReadAfterIdentityOrProjectSwitchNeverWrites() = runBlocking {
        val base = CodeWorkspace()
        val candidate = CodeWorkspace(listOf(CodeWorkspaceFile("main.py", "print(1)")))
        var current = true; var writes = 0
        try {
            CodeWorkspacePersistence.commit(CodeWorkspacePolicy.hash(base), candidate, { current },
                { current = false; base }, { writes++ })
            fail("Old workspace wrote after switching identity")
        } catch (_: OwnerChanged) { }
        assertEquals(0, writes)
    }
    @Test fun staleSavedWorkspaceRejectsBeforeWritingAndRoundTripsStorage() = runBlocking {
        val base = CodeWorkspace()
        val candidate = CodeWorkspace(listOf(CodeWorkspaceFile("main.py", "new")))
        var writes = 0
        try {
            CodeWorkspacePersistence.commit(CodeWorkspacePolicy.hash(base), candidate, { true }, { candidate }, { writes++ })
            fail("Stale writer overwrote newer workspace")
        } catch (_: CodeWorkspaceFailure) { }
        assertEquals(0, writes)
        val result = CodeWorkspacePersistence.commit(CodeWorkspacePolicy.hash(base), candidate, { true }, { base }, { writes++ })
        assertEquals(candidate, result)
        assertEquals(1, writes)
        assertEquals(candidate, CodeWorkspacePolicy.decode(CodeWorkspacePolicy.json(candidate)))
        assertEquals("firas-code-workspace.txt", CodeWorkspacePolicy.sourceAttachment(candidate).name)
        assertTrue(CodeWorkspacePolicy.sourceAttachment(candidate).text!!.contains("main.py"))
        assertTrue(CodeWorkspacePolicy.request("Build Python CLI").contains("```file:relative/path.ext"))
    }
}
