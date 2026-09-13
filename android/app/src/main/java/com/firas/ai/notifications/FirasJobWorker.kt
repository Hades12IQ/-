package com.firas.ai.notifications

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.firas.ai.data.FirasRepository
import kotlinx.coroutines.CancellationException
import java.util.concurrent.TimeUnit

/** Reconciles existing server work. Killing the UI does not cancel its jobs. */
class FirasJobWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val repository = FirasRepository.get(applicationContext)
        return try {
            repository.restoreSession()
            if (repository.state.value.session.user == null) return if (repository.state.value.error != null) Result.retry() else Result.success()
            repository.registerPushForCurrentAccount()
            val succeeded = repository.refreshJobs()
            if (!succeeded || repository.state.value.jobs.any { !it.terminal }) Result.retry() else Result.success()
        } catch (error: CancellationException) { throw error }
        catch (_: Exception) { Result.retry() }
    }
    companion object {
        private val constraints get() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
        fun schedule(context: Context) {
            val manager = WorkManager.getInstance(context)
            manager.enqueueUniquePeriodicWork("firas-reconcile-periodic", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<FirasJobWorker>(15, TimeUnit.MINUTES).setConstraints(constraints).build())
            manager.enqueueUniqueWork("firas-reconcile", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<FirasJobWorker>().setConstraints(constraints).setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build())
        }
        fun wakeFromPush(context: Context) {
            // Separate unique work can wake a job currently waiting for normal retry backoff.
            WorkManager.getInstance(context).enqueueUniqueWork("firas-push-reconcile", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<FirasJobWorker>().setConstraints(constraints).build())
        }
    }
}
