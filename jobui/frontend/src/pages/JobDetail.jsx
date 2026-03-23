import React, { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useJobPolling } from '../hooks/useJobPolling'
import { getLogs, getResults, cancelJob } from '../api/jobs'
import StatusBadge from '../components/StatusBadge'
import LogViewer from '../components/LogViewer'
import {
  ArrowLeft,
  Download,
  Loader2,
  AlertCircle,
  FileText,
  FolderOpen,
  Cpu,
  MemoryStick,
  Clock,
  User,
  Hash,
  Calendar,
  Trash2,
  RefreshCw,
} from 'lucide-react'

const TERMINAL_STATES = new Set(['COMPLETED', 'FAILED', 'CANCELLED'])

const InfoItem = ({ label, value, icon: Icon, mono }) => (
  <div className="flex flex-col gap-1">
    <dt className="flex items-center gap-1.5 text-xs font-medium text-slate-500 uppercase tracking-wider">
      {Icon && <Icon className="w-3.5 h-3.5" />}
      {label}
    </dt>
    <dd className={`text-sm text-slate-200 ${mono ? 'font-mono text-xs' : ''}`}>
      {value ?? '—'}
    </dd>
  </div>
)

const formatDate = (isoString) => {
  if (!isoString) return '—'
  try {
    return new Date(isoString).toLocaleString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  } catch {
    return isoString
  }
}

const formatBytes = (bytes) => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`
}

export default function JobDetail() {
  const { id } = useParams()
  const navigate = useNavigate()

  const { job, loading, error } = useJobPolling(id, 5000)
  const [activeTab, setActiveTab] = useState('logs')
  const [logData, setLogData] = useState(null)
  const [logLoading, setLogLoading] = useState(false)
  const [results, setResults] = useState([])
  const [resultsLoading, setResultsLoading] = useState(false)
  const [resultsError, setResultsError] = useState(null)
  const [cancelling, setCancelling] = useState(false)
  const [cancelError, setCancelError] = useState(null)

  const fetchLogs = useCallback(async () => {
    if (!id) return
    setLogLoading(true)
    try {
      const data = await getLogs(id)
      setLogData(data)
    } catch (err) {
      setLogData({ job_id: id, log: `Error fetching logs: ${err.response?.data?.detail || err.message}`, available: false })
    } finally {
      setLogLoading(false)
    }
  }, [id])

  const fetchResults = useCallback(async () => {
    if (!id) return
    setResultsLoading(true)
    setResultsError(null)
    try {
      const data = await getResults(id)
      setResults(data)
    } catch (err) {
      setResultsError(err.response?.data?.detail || 'Failed to load results')
    } finally {
      setResultsLoading(false)
    }
  }, [id])

  // Initial log fetch
  useEffect(() => {
    fetchLogs()
  }, [fetchLogs])

  // Auto-refresh logs every 5s if job is running
  useEffect(() => {
    if (!job || TERMINAL_STATES.has(job.status)) return
    const interval = setInterval(fetchLogs, 5000)
    return () => clearInterval(interval)
  }, [job, fetchLogs])

  // Fetch results when tab is selected and job is complete
  useEffect(() => {
    if (activeTab === 'results' && job?.status === 'COMPLETED') {
      fetchResults()
    }
  }, [activeTab, job?.status, fetchResults])

  const handleCancel = async () => {
    if (!job) return
    if (!window.confirm(`Cancel job "${job.name}"?`)) return
    setCancelling(true)
    setCancelError(null)
    try {
      await cancelJob(id)
    } catch (err) {
      setCancelError(err.response?.data?.detail || 'Failed to cancel job')
    } finally {
      setCancelling(false)
    }
  }

  if (loading && !job) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="flex flex-col items-center gap-3">
          <Loader2 className="w-8 h-8 animate-spin text-blue-400" />
          <p className="text-slate-400 text-sm">Loading job details...</p>
        </div>
      </div>
    )
  }

  if (error && !job) {
    return (
      <div className="max-w-lg mx-auto py-16 text-center">
        <AlertCircle className="w-12 h-12 text-red-400 mx-auto mb-4" />
        <h2 className="text-lg font-semibold text-white mb-2">Job Not Found</h2>
        <p className="text-slate-400 text-sm mb-6">{error}</p>
        <button onClick={() => navigate('/')} className="btn-secondary">
          <ArrowLeft className="w-4 h-4" />
          Back to Dashboard
        </button>
      </div>
    )
  }

  if (!job) return null

  const canCancel = !TERMINAL_STATES.has(job.status) && !cancelling

  return (
    <div className="space-y-6 max-w-5xl">
      {/* Back + Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-4">
          <button
            onClick={() => navigate('/')}
            className="btn-secondary text-sm py-1.5 px-3"
          >
            <ArrowLeft className="w-4 h-4" />
            Dashboard
          </button>
          <div className="flex items-center gap-3">
            <h1 className="text-xl font-bold text-white">{job.name}</h1>
            <StatusBadge status={job.status} size="lg" />
          </div>
        </div>
        <div className="flex items-center gap-2">
          {canCancel && (
            <button
              onClick={handleCancel}
              disabled={cancelling}
              className="btn-danger text-sm"
            >
              {cancelling ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Trash2 className="w-4 h-4" />
              )}
              Cancel Job
            </button>
          )}
        </div>
      </div>

      {cancelError && (
        <div className="flex items-start gap-3 p-4 bg-red-500/10 border border-red-500/30 rounded-xl">
          <AlertCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
          <p className="text-sm text-red-400">{cancelError}</p>
        </div>
      )}

      {/* Error message if failed */}
      {job.status === 'FAILED' && job.error_message && (
        <div className="flex items-start gap-3 p-4 bg-red-500/10 border border-red-500/30 rounded-xl">
          <AlertCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
          <div>
            <p className="text-sm font-medium text-red-400">Job Failed</p>
            <p className="text-xs text-red-400/80 mt-0.5">{job.error_message}</p>
          </div>
        </div>
      )}

      {/* Info grid */}
      <div className="card">
        <h2 className="text-base font-semibold text-white mb-5">Job Details</h2>
        <dl className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-6">
          <InfoItem label="Job ID" value={job.id} icon={Hash} mono />
          <InfoItem
            label="Slurm ID"
            value={job.slurm_job_id ?? 'Not assigned'}
            icon={Hash}
            mono
          />
          <InfoItem label="Cluster User" value={job.cluster_user} icon={User} mono />
          <InfoItem label="Input Prefix" value={job.input_prefix} icon={FolderOpen} mono />
          <InfoItem label="Submitted" value={formatDate(job.created_at)} icon={Calendar} />
          <InfoItem label="Last Updated" value={formatDate(job.updated_at)} icon={RefreshCw} />
          <InfoItem label="CPUs" value={job.cpus} icon={Cpu} />
          <InfoItem label="Memory" value={`${job.memory_mb} MB`} icon={MemoryStick} />
          <InfoItem label="Time Limit" value={job.time_limit} icon={Clock} />
        </dl>

        {/* Command */}
        <div className="mt-6 pt-5 border-t border-slate-700">
          <dt className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-2 flex items-center gap-1.5">
            <FileText className="w-3.5 h-3.5" />
            Command
          </dt>
          <pre className="text-xs font-mono text-slate-300 bg-slate-900 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap border border-slate-700">
            {job.command}
          </pre>
        </div>
      </div>

      {/* Tabs */}
      <div className="card">
        <div className="flex gap-1 mb-6 border-b border-slate-700 -mx-6 px-6">
          {['logs', 'results'].map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`px-4 py-2.5 text-sm font-medium capitalize border-b-2 transition-colors -mb-px ${
                activeTab === tab
                  ? 'border-blue-500 text-blue-400'
                  : 'border-transparent text-slate-500 hover:text-slate-300'
              }`}
            >
              {tab === 'results' ? (
                <>Results {job.status === 'COMPLETED' && results.length > 0 && `(${results.length})`}</>
              ) : (
                'Logs'
              )}
            </button>
          ))}
        </div>

        {activeTab === 'logs' && (
          <LogViewer
            log={logData?.log}
            available={logData?.available ?? false}
            onRefresh={fetchLogs}
            autoScroll
          />
        )}

        {activeTab === 'results' && (
          <div>
            {job.status !== 'COMPLETED' ? (
              <div className="text-center py-10 text-slate-500">
                <FolderOpen className="w-10 h-10 mx-auto mb-3 opacity-40" />
                <p className="text-sm">Results will be available when the job completes</p>
                <p className="text-xs mt-1 text-slate-600">
                  Current status: <StatusBadge status={job.status} size="sm" />
                </p>
              </div>
            ) : resultsLoading ? (
              <div className="flex items-center justify-center py-10">
                <Loader2 className="w-6 h-6 animate-spin text-slate-500" />
              </div>
            ) : resultsError ? (
              <div className="text-center py-8">
                <AlertCircle className="w-8 h-8 text-red-400 mx-auto mb-2" />
                <p className="text-sm text-red-400">{resultsError}</p>
                <button
                  onClick={fetchResults}
                  className="mt-3 text-sm text-blue-400 hover:text-blue-300 transition-colors"
                >
                  Try again
                </button>
              </div>
            ) : results.length === 0 ? (
              <div className="text-center py-10 text-slate-500">
                <FolderOpen className="w-10 h-10 mx-auto mb-3 opacity-40" />
                <p className="text-sm">No result files found</p>
                <p className="text-xs mt-1">Check if your job wrote files to $OUTPUT_DIR</p>
              </div>
            ) : (
              <div className="space-y-2">
                <div className="flex items-center justify-between mb-4">
                  <p className="text-sm text-slate-400">
                    {results.length} file{results.length !== 1 ? 's' : ''} available for download
                  </p>
                  <button
                    onClick={fetchResults}
                    className="btn-secondary text-xs py-1.5"
                  >
                    <RefreshCw className="w-3.5 h-3.5" />
                    Refresh
                  </button>
                </div>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-slate-700">
                        <th className="table-header text-left pb-3 pr-4">Filename</th>
                        <th className="table-header text-right pb-3 pr-4">Size</th>
                        <th className="table-header text-right pb-3">Download</th>
                      </tr>
                    </thead>
                    <tbody>
                      {results.map((file) => (
                        <tr
                          key={file.key}
                          className="border-b border-slate-700/50 hover:bg-slate-700/20 transition-colors"
                        >
                          <td className="py-3 pr-4">
                            <span className="font-mono text-xs text-slate-200">{file.filename}</span>
                          </td>
                          <td className="py-3 pr-4 text-right">
                            <span className="text-xs text-slate-400">{formatBytes(file.size)}</span>
                          </td>
                          <td className="py-3 text-right">
                            <a
                              href={file.presigned_url}
                              download={file.filename}
                              target="_blank"
                              rel="noreferrer"
                              className="inline-flex items-center gap-1.5 text-xs text-blue-400 hover:text-blue-300 transition-colors px-2 py-1 rounded hover:bg-blue-500/10"
                            >
                              <Download className="w-3.5 h-3.5" />
                              Download
                            </a>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
