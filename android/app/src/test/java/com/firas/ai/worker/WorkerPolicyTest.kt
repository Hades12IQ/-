package com.firas.ai.worker

import org.junit.Assert.*
import org.junit.Test

class WorkerPolicyTest {
    @Test fun pathsStayInsideAccountWorkspace() {
        listOf("../secret", "/sdcard/a", "a/../../b", "C:/x", "a\\b", ".hidden", "a//b", "a/./b").forEach { assertFalse(it, WorkerPolicy.safeRelativePath(it)) }
        assertTrue(WorkerPolicy.safeRelativePath("reports/نتيجة.txt"))
        assertNotEquals(WorkerPolicy.hash("owner-a"), WorkerPolicy.hash("owner-b"))
    }
    @Test fun staleObservationCannotApproveAnotherControl() {
        assertTrue(WorkerPolicy.sameTarget("app", 2, "signature", "app", 2, "signature"))
        assertFalse(WorkerPolicy.sameTarget("app", 2, "signature", "other", 2, "signature"))
        assertFalse(WorkerPolicy.sameTarget("app", 2, "signature", "app", 3, "signature"))
        assertFalse(WorkerPolicy.sameTarget("app", 2, "signature", "app", 2, "changed"))
    }
    @Test fun secretsAndDestructiveControlsAreManual() {
        listOf("Password", "verification code", "حذف الملف", "Pay now", "factory reset").forEach { assertFalse(it, WorkerPolicy.allowedControl(it)) }
        assertTrue(WorkerPolicy.allowedControl("Search"))
    }
    @Test fun interruptedRunsAreNeverAutoReplayed() {
        listOf("planning", "running", "approval").forEach { assertEquals("interrupted", WorkerPolicy.terminalAfterRestart(it)) }
        assertEquals("completed", WorkerPolicy.terminalAfterRestart("completed"))
    }
    @Test fun modelSelectionUsesReviewedServerAdvertisedModelOnly() {
        assertNull(WorkerPolicy.chooseModel(listOf("gemini-expensive-future")))
        assertEquals("gemini-2.5-flash", WorkerPolicy.chooseModel(listOf("gemini-expensive-future", "gemini-2.5-flash")))
    }
}
