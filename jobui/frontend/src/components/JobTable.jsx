import React from 'react'
import { useNavigate } from 'react-router-dom'
import StatusBadge from './StatusBadge'
import { ExternalLink, Inbox } from 'lucide-react'

const formatDate = (isoString) => {
  if (!isoString) return '—'
  try {
    return new Date(isoString).toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return isoString
  }
}

const truncateId = (id) => {
  if (!id) return '—'
  return id.substring(0, 8) + '...'
}

export default function JobTable({ jobs = [], showUser = false }) {
  const navigate = useNavigate()

  if (jobs.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-16 text-slate-500">
        <Inbox className="w-12 h-12 mb-3 opacity-50" />
        <p className="text-sm font-medium">No jobs found</p>
        <p className="text-xs mt-1">Submit your first job to get started</p>
      </div>
    )
  }

  // Sort by created_at descending
  const sorted = [...jobs].sort((a, b) => {
    const ta = new Date(a.created_at).getTime()
    const tb = new Date(b.created_at).getTime()
    return tb - ta
  })

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-slate-700">
            <th className="table-header text-left pb-3 pr-4">Job Name</th>
            <th className="table-header text-left pb-3 pr-4">Job ID</th>
            <th className="table-header text-left pb-3 pr-4">Slurm ID</th>
            <th className="table-header text-left pb-3 pr-4">Status</th>
            <th className="table-header text-left pb-3 pr-4">Submitted</th>
            {showUser && <th className="table-header text-left pb-3 pr-4">User</th>}
            <th className="table-header text-right pb-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {sorted.map((job) => (
            <tr
              key={job.id}
              onClick={() => navigate(`/jobs/${job.id}`)}
              className="border-b border-slate-700/50 hover:bg-slate-700/30 cursor-pointer transition-colors group"
            >
              <td className="py-3.5 pr-4">
                <span className="font-medium text-slate-200 group-hover:text-white transition-colors">
                  {job.name}
                </span>
              </td>
              <td className="py-3.5 pr-4">
                <span
                  className="font-mono text-xs text-slate-400 cursor-pointer hover:text-slate-200 transition-colors"
                  title={job.id}
                >
                  {truncateId(job.id)}
                </span>
              </td>
              <td className="py-3.5 pr-4">
                <span className="font-mono text-xs text-slate-400">
                  {job.slurm_job_id ?? '—'}
                </span>
              </td>
              <td className="py-3.5 pr-4">
                <StatusBadge status={job.status} size="sm" />
              </td>
              <td className="py-3.5 pr-4 text-slate-400 text-xs whitespace-nowrap">
                {formatDate(job.created_at)}
              </td>
              {showUser && (
                <td className="py-3.5 pr-4">
                  <span className="font-mono text-xs text-slate-400">{job.cluster_user}</span>
                </td>
              )}
              <td className="py-3.5 text-right">
                <button
                  onClick={(e) => { e.stopPropagation(); navigate(`/jobs/${job.id}`) }}
                  className="inline-flex items-center gap-1 text-xs text-blue-400 hover:text-blue-300 transition-colors px-2 py-1 rounded hover:bg-blue-500/10"
                >
                  <ExternalLink className="w-3.5 h-3.5" />
                  View
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
