import React, { useEffect, useRef, useState, useCallback } from 'react'
import { RefreshCw, Copy, Check, Terminal } from 'lucide-react'

export default function LogViewer({ log, available, onRefresh, autoScroll = true }) {
  const containerRef = useRef(null)
  const [copied, setCopied] = useState(false)
  const [isAtBottom, setIsAtBottom] = useState(true)

  // Auto-scroll to bottom when new content arrives
  useEffect(() => {
    if (autoScroll && isAtBottom && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
    }
  }, [log, autoScroll, isAtBottom])

  const handleScroll = useCallback(() => {
    const el = containerRef.current
    if (!el) return
    const threshold = 50
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < threshold
    setIsAtBottom(atBottom)
  }, [])

  const handleCopy = async () => {
    if (!log) return
    try {
      await navigator.clipboard.writeText(log)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // Clipboard not available — silently fail
    }
  }

  const scrollToBottom = () => {
    if (containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
      setIsAtBottom(true)
    }
  }

  const lines = log ? log.split('\n') : []

  return (
    <div className="flex flex-col bg-slate-900 rounded-xl border border-slate-700 overflow-hidden">
      {/* Toolbar */}
      <div className="flex items-center justify-between px-4 py-2.5 bg-slate-800 border-b border-slate-700">
        <div className="flex items-center gap-2 text-slate-400">
          <Terminal className="w-4 h-4" />
          <span className="text-xs font-medium">
            {available ? `${lines.length} lines` : 'Waiting for output'}
          </span>
          {!available && (
            <span className="flex gap-0.5">
              <span className="w-1 h-1 rounded-full bg-slate-500 animate-bounce" style={{ animationDelay: '0ms' }} />
              <span className="w-1 h-1 rounded-full bg-slate-500 animate-bounce" style={{ animationDelay: '150ms' }} />
              <span className="w-1 h-1 rounded-full bg-slate-500 animate-bounce" style={{ animationDelay: '300ms' }} />
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {!isAtBottom && log && (
            <button
              onClick={scrollToBottom}
              className="text-xs text-blue-400 hover:text-blue-300 transition-colors px-2 py-1 rounded hover:bg-blue-500/10"
            >
              Scroll to bottom
            </button>
          )}
          <button
            onClick={handleCopy}
            disabled={!log}
            className="inline-flex items-center gap-1.5 text-xs text-slate-400 hover:text-white transition-colors px-2 py-1 rounded hover:bg-slate-700 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {copied ? (
              <>
                <Check className="w-3.5 h-3.5 text-emerald-400" />
                <span className="text-emerald-400">Copied</span>
              </>
            ) : (
              <>
                <Copy className="w-3.5 h-3.5" />
                Copy
              </>
            )}
          </button>
          {onRefresh && (
            <button
              onClick={onRefresh}
              className="inline-flex items-center gap-1.5 text-xs text-slate-400 hover:text-white transition-colors px-2 py-1 rounded hover:bg-slate-700"
            >
              <RefreshCw className="w-3.5 h-3.5" />
              Refresh
            </button>
          )}
        </div>
      </div>

      {/* Log content */}
      <div
        ref={containerRef}
        onScroll={handleScroll}
        className="overflow-auto font-mono text-xs leading-5 p-4 max-h-[600px] min-h-[200px]"
        style={{ background: '#0a0f1e' }}
      >
        {!available || !log ? (
          <div className="flex flex-col items-center justify-center h-32 text-slate-600">
            <Terminal className="w-8 h-8 mb-2 opacity-40" />
            <p className="text-sm">Waiting for logs...</p>
            <p className="text-xs mt-1 text-slate-700">Output will appear here once the job starts running</p>
          </div>
        ) : (
          lines.map((line, idx) => (
            <div key={idx} className="flex group hover:bg-slate-800/30 px-1 rounded">
              <span className="select-none text-slate-600 w-10 text-right shrink-0 pr-3 group-hover:text-slate-500">
                {idx + 1}
              </span>
              <span className={`whitespace-pre-wrap break-all ${
                line.startsWith('ERROR') || line.startsWith('FAIL')
                  ? 'text-red-400'
                  : line.startsWith('WARNING')
                  ? 'text-amber-400'
                  : line.startsWith('========')
                  ? 'text-blue-400 font-semibold'
                  : line.startsWith('[')
                  ? 'text-emerald-400'
                  : 'text-slate-300'
              }`}>
                {line || '\u00a0'}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  )
}
