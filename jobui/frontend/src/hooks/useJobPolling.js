import { useState, useEffect, useRef, useCallback } from 'react'
import { getJob } from '../api/jobs'

const TERMINAL_STATES = new Set(['COMPLETED', 'FAILED', 'CANCELLED'])

export const useJobPolling = (jobId, intervalMs = 5000) => {
  const [job, setJob] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const intervalRef = useRef(null)
  const mountedRef = useRef(true)

  const fetchJob = useCallback(async () => {
    if (!jobId) return
    try {
      const data = await getJob(jobId)
      if (!mountedRef.current) return
      setJob(data)
      setError(null)

      // Stop polling when terminal state is reached
      if (TERMINAL_STATES.has(data.status)) {
        if (intervalRef.current) {
          clearInterval(intervalRef.current)
          intervalRef.current = null
        }
      }
    } catch (err) {
      if (!mountedRef.current) return
      const message = err.response?.data?.detail || 'Failed to fetch job status'
      setError(message)
    } finally {
      if (mountedRef.current) {
        setLoading(false)
      }
    }
  }, [jobId])

  useEffect(() => {
    mountedRef.current = true
    setLoading(true)
    setJob(null)
    setError(null)

    if (!jobId) {
      setLoading(false)
      return
    }

    // Initial fetch
    fetchJob()

    // Start polling
    intervalRef.current = setInterval(fetchJob, intervalMs)

    return () => {
      mountedRef.current = false
      if (intervalRef.current) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }
  }, [jobId, intervalMs, fetchJob])

  return { job, loading, error, refetch: fetchJob }
}
