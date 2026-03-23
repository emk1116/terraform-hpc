import React from 'react'
import { Clock, Play, CheckCircle, XCircle, Ban, Send, HelpCircle } from 'lucide-react'

const STATUS_CONFIG = {
  PENDING: {
    label: 'Pending',
    classes: 'bg-amber-500/15 text-amber-400 border border-amber-500/30',
    icon: Clock,
    animate: false,
  },
  RUNNING: {
    label: 'Running',
    classes: 'bg-blue-500/15 text-blue-400 border border-blue-500/30',
    icon: Play,
    animate: true,
  },
  COMPLETED: {
    label: 'Completed',
    classes: 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30',
    icon: CheckCircle,
    animate: false,
  },
  FAILED: {
    label: 'Failed',
    classes: 'bg-red-500/15 text-red-400 border border-red-500/30',
    icon: XCircle,
    animate: false,
  },
  CANCELLED: {
    label: 'Cancelled',
    classes: 'bg-slate-500/15 text-slate-400 border border-slate-500/30',
    icon: Ban,
    animate: false,
  },
  SUBMITTED: {
    label: 'Submitted',
    classes: 'bg-purple-500/15 text-purple-400 border border-purple-500/30',
    icon: Send,
    animate: false,
  },
  UNKNOWN: {
    label: 'Unknown',
    classes: 'bg-slate-600/15 text-slate-500 border border-slate-600/30',
    icon: HelpCircle,
    animate: false,
  },
}

export default function StatusBadge({ status, size = 'md' }) {
  const config = STATUS_CONFIG[status] || STATUS_CONFIG.UNKNOWN
  const Icon = config.icon

  const sizeClasses = size === 'sm'
    ? 'text-xs px-2 py-0.5 gap-1'
    : size === 'lg'
    ? 'text-sm px-3 py-1.5 gap-1.5'
    : 'text-xs px-2.5 py-1 gap-1.5'

  const iconSize = size === 'sm' ? 'w-3 h-3' : size === 'lg' ? 'w-4 h-4' : 'w-3.5 h-3.5'

  return (
    <span
      className={`inline-flex items-center rounded-full font-medium ${config.classes} ${sizeClasses}`}
    >
      {config.animate ? (
        <span className="relative flex">
          <span
            className={`animate-ping absolute inline-flex rounded-full bg-blue-400 opacity-60 ${iconSize}`}
          />
          <Icon className={`relative inline-flex ${iconSize}`} />
        </span>
      ) : (
        <Icon className={iconSize} />
      )}
      {config.label}
    </span>
  )
}
