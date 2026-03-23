import React, { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { listJobs } from '../api/jobs'
import JobTable from '../components/JobTable'
import { useAuthContext } from '../App'
import {
  Plus,
  RefreshCw,
  Loader2,
  BarChart3,
  Play,
  CheckCircle,
  XCircle,
  Layers,
} from 'lucide-react'

const StatCard = ({ label, value, icon: Icon, color }) => (
  <div className="card flex items-center gap-4">
    <div className={`w-12 h-12 rounded-xl flex items-center justify-center shrink-0 ${color}`}>
      <Icon className="w-6 h-6" />
    </div>
    <div>
      <p className="text-2xl font-bold text-white">{value}</p>
      <p className="text-sm text-slate-400">{label}</p>
    </div>
  </div>
)

export default function Dashboard() {
  const { user } = useAuthContext()
  const navigate = useNavigate()
  const [jobs, setJobs] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [lastRefresh, setLastRefresh] = useState(null)

  const fetchJobs = useCallback(async (silent = false) => {
    if (!silent) setLoading(true)
    try {
      const data = await listJobs()
      setJobs(data)
      setError(null)
      setLastRefresh(new Date())
    } catch (err) {
      setError(err.response?.data?.detail || 'Failed to load jobs')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchJobs()
    const interval = setInterval(() => fetchJobs(true), 10000)
    return () => clearInterval(interval)
  }, [fetchJobs])

  const stats = {
    total: jobs.length,
    running: jobs.filter((j) => j.status === 'RUNNING').length,
    completed: jobs.filter((j) => j.status === 'COMPLETED').length,
    failed: jobs.filter((j) => j.status === 'FAILED').length,
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">HPC Dashboard</h1>
          <p className="text-slate-400 text-sm mt-1">
            Welcome back, <span className="text-slate-300">{user?.username}</span>
            {lastRefresh && (
              <span className="ml-2 text-slate-600">
                — last updated {lastRefresh.toLocaleTimeString()}
              </span>
            )}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => fetchJobs()}
            disabled={loading}
            className="btn-secondary"
            title="Refresh jobs"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
            <span className="hidden sm:inline">Refresh</span>
          </button>
          <button
            onClick={() => navigate('/submit')}
            className="btn-primary"
          >
            <Plus className="w-4 h-4" />
            Submit New Job
          </button>
        </div>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          label="Total Jobs"
          value={stats.total}
          icon={Layers}
          color="bg-slate-700 text-slate-300"
        />
        <StatCard
          label="Running"
          value={stats.running}
          icon={Play}
          color="bg-blue-500/20 text-blue-400"
        />
        <StatCard
          label="Completed"
          value={stats.completed}
          icon={CheckCircle}
          color="bg-emerald-500/20 text-emerald-400"
        />
        <StatCard
          label="Failed"
          value={stats.failed}
          icon={XCircle}
          color="bg-red-500/20 text-red-400"
        />
      </div>

      {/* Job Table */}
      <div className="card">
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <BarChart3 className="w-5 h-5 text-slate-400" />
            <h2 className="text-lg font-semibold text-white">
              {user?.is_admin ? 'All Jobs' : 'Your Jobs'}
            </h2>
          </div>
          {loading && <Loader2 className="w-4 h-4 animate-spin text-slate-500" />}
        </div>

        {error ? (
          <div className="text-center py-8">
            <p className="text-red-400 text-sm">{error}</p>
            <button
              onClick={() => fetchJobs()}
              className="mt-3 text-sm text-blue-400 hover:text-blue-300 transition-colors"
            >
              Try again
            </button>
          </div>
        ) : (
          <JobTable jobs={jobs} showUser={user?.is_admin} />
        )}

        {!loading && !error && jobs.length === 0 && (
          <div className="text-center pt-4 pb-2">
            <button
              onClick={() => navigate('/submit')}
              className="btn-primary"
            >
              <Plus className="w-4 h-4" />
              Submit your first job
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
