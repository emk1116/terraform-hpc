import React, { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { submitJob } from '../api/jobs'
import { listFiles } from '../api/files'
import {
  CheckCircle,
  Loader2,
  AlertCircle,
  ExternalLink,
  ChevronRight,
  Cpu,
  MemoryStick,
  Clock,
  Terminal,
} from 'lucide-react'

const DEFAULT_COMMAND = "echo 'Processing complete' > $OUTPUT_DIR/result.txt"
const TIME_REGEX = /^\d{2}:\d{2}:\d{2}$/
const NAME_REGEX = /^[a-zA-Z0-9_-]+$/

export default function SubmitJob() {
  const navigate = useNavigate()

  const [form, setForm] = useState({
    name: '',
    input_prefix: '',
    command: DEFAULT_COMMAND,
    cpus: 1,
    memory_mb: 800,
    time_limit: '01:00:00',
  })
  const [errors, setErrors] = useState({})
  const [loading, setLoading] = useState(false)
  const [submitError, setSubmitError] = useState(null)
  const [submitted, setSubmitted] = useState(null)
  const [files, setFiles] = useState([])
  const [filesLoading, setFilesLoading] = useState(true)

  useEffect(() => {
    listFiles()
      .then((data) => setFiles(data))
      .catch(() => {})
      .finally(() => setFilesLoading(false))
  }, [])

  const validate = () => {
    const errs = {}
    if (!form.name.trim()) {
      errs.name = 'Job name is required'
    } else if (!NAME_REGEX.test(form.name)) {
      errs.name = 'Only letters, numbers, dashes, and underscores allowed'
    } else if (form.name.length > 64) {
      errs.name = 'Name must be 64 characters or fewer'
    }
    if (!form.input_prefix.trim()) {
      errs.input_prefix = 'Input prefix is required'
    }
    if (!form.command.trim()) {
      errs.command = 'Command is required'
    }
    if (!TIME_REGEX.test(form.time_limit)) {
      errs.time_limit = 'Time limit must be in HH:MM:SS format'
    }
    if (form.cpus < 1 || form.cpus > 8) {
      errs.cpus = 'CPUs must be between 1 and 8'
    }
    if (form.memory_mb < 256 || form.memory_mb > 7500) {
      errs.memory_mb = 'Memory must be between 256 and 7500 MB'
    }
    return errs
  }

  const handleChange = (field, value) => {
    setForm((prev) => ({ ...prev, [field]: value }))
    if (errors[field]) {
      setErrors((prev) => ({ ...prev, [field]: undefined }))
    }
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    const errs = validate()
    if (Object.keys(errs).length > 0) {
      setErrors(errs)
      return
    }

    setLoading(true)
    setSubmitError(null)

    try {
      const payload = {
        ...form,
        cpus: Number(form.cpus),
        memory_mb: Number(form.memory_mb),
      }
      const job = await submitJob(payload)
      setSubmitted(job)
    } catch (err) {
      const detail = err.response?.data?.detail
      if (Array.isArray(detail)) {
        setSubmitError(detail.map((d) => d.msg).join('; '))
      } else {
        setSubmitError(detail || 'Failed to submit job')
      }
    } finally {
      setLoading(false)
    }
  }

  // Get unique prefixes from uploaded files
  const filePrefixes = Array.from(new Set(files.map((f) => f.filename)))

  if (submitted) {
    return (
      <div className="max-w-xl mx-auto">
        <div className="card text-center py-10">
          <div className="w-16 h-16 bg-emerald-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
            <CheckCircle className="w-8 h-8 text-emerald-400" />
          </div>
          <h2 className="text-xl font-bold text-white mb-2">Job Submitted!</h2>
          <p className="text-slate-400 text-sm mb-1">
            Your job <span className="text-slate-200 font-medium">{submitted.name}</span> has been submitted to Slurm.
          </p>
          <p className="text-slate-500 text-xs font-mono mb-6">ID: {submitted.id}</p>

          <div className="flex items-center justify-center gap-3">
            <button
              onClick={() => navigate(`/jobs/${submitted.id}`)}
              className="btn-primary"
            >
              <ExternalLink className="w-4 h-4" />
              View Job Details
            </button>
            <button
              onClick={() => {
                setSubmitted(null)
                setForm({
                  name: '',
                  input_prefix: '',
                  command: DEFAULT_COMMAND,
                  cpus: 1,
                  memory_mb: 800,
                  time_limit: '01:00:00',
                })
              }}
              className="btn-secondary"
            >
              Submit Another
            </button>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-white">Submit HPC Job</h1>
        <p className="text-slate-400 text-sm mt-1">Configure and submit a new job to the cluster</p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-6">
        {submitError && (
          <div className="flex items-start gap-3 p-4 bg-red-500/10 border border-red-500/30 rounded-xl">
            <AlertCircle className="w-4 h-4 text-red-400 mt-0.5 shrink-0" />
            <p className="text-sm text-red-400">{submitError}</p>
          </div>
        )}

        {/* Job Identity */}
        <div className="card space-y-4">
          <h2 className="text-base font-semibold text-white border-b border-slate-700 pb-3">
            Job Configuration
          </h2>

          <div>
            <label className="form-label">Job Name *</label>
            <input
              type="text"
              value={form.name}
              onChange={(e) => handleChange('name', e.target.value)}
              className={`form-input ${errors.name ? 'border-red-500 focus:ring-red-500' : ''}`}
              placeholder="my-analysis-run"
            />
            {errors.name && (
              <p className="text-xs text-red-400 mt-1">{errors.name}</p>
            )}
            <p className="text-xs text-slate-500 mt-1">Letters, numbers, dashes, underscores only</p>
          </div>

          <div>
            <label className="form-label">Input Prefix *</label>
            {filesLoading ? (
              <div className="flex items-center gap-2 text-slate-400 text-sm">
                <Loader2 className="w-4 h-4 animate-spin" />
                Loading files...
              </div>
            ) : (
              <>
                {filePrefixes.length > 0 ? (
                  <select
                    value={form.input_prefix}
                    onChange={(e) => handleChange('input_prefix', e.target.value)}
                    className={`form-input ${errors.input_prefix ? 'border-red-500' : ''}`}
                  >
                    <option value="">Select a file or enter prefix below</option>
                    {filePrefixes.map((prefix) => (
                      <option key={prefix} value={prefix}>
                        {prefix}
                      </option>
                    ))}
                  </select>
                ) : null}
                <input
                  type="text"
                  value={form.input_prefix}
                  onChange={(e) => handleChange('input_prefix', e.target.value)}
                  className={`form-input mt-2 ${errors.input_prefix ? 'border-red-500' : ''}`}
                  placeholder="myfile.tar.gz  or  data-folder/"
                />
              </>
            )}
            {errors.input_prefix && (
              <p className="text-xs text-red-400 mt-1">{errors.input_prefix}</p>
            )}
            <p className="text-xs text-slate-500 mt-1">
              S3 key prefix under <span className="font-mono">input/&#123;user_id&#125;/</span>
            </p>
          </div>

          <div>
            <label className="form-label flex items-center gap-2">
              <Terminal className="w-3.5 h-3.5 text-slate-400" />
              Command *
            </label>
            <textarea
              value={form.command}
              onChange={(e) => handleChange('command', e.target.value)}
              rows={5}
              className={`form-input resize-none leading-relaxed ${errors.command ? 'border-red-500' : ''}`}
              placeholder="python main.py --input $INPUT_DIR --output $OUTPUT_DIR"
              spellCheck={false}
            />
            {errors.command && (
              <p className="text-xs text-red-400 mt-1">{errors.command}</p>
            )}
            <p className="text-xs text-slate-500 mt-1">
              Available env vars:{' '}
              <span className="font-mono">$INPUT_DIR</span>,{' '}
              <span className="font-mono">$OUTPUT_DIR</span>,{' '}
              <span className="font-mono">$WORK_DIR</span>,{' '}
              <span className="font-mono">$JOB_ID</span>
            </p>
          </div>
        </div>

        {/* Resources */}
        <div className="card space-y-5">
          <h2 className="text-base font-semibold text-white border-b border-slate-700 pb-3">
            Resource Allocation
          </h2>

          <div>
            <label className="form-label flex items-center gap-2">
              <Cpu className="w-3.5 h-3.5 text-slate-400" />
              CPUs: <span className="text-blue-400 font-bold ml-1">{form.cpus}</span>
            </label>
            <input
              type="range"
              min="1"
              max="8"
              step="1"
              value={form.cpus}
              onChange={(e) => handleChange('cpus', e.target.value)}
              className="w-full h-2 bg-slate-700 rounded-lg appearance-none cursor-pointer accent-blue-500 mt-2"
            />
            <div className="flex justify-between text-xs text-slate-500 mt-1">
              <span>1 CPU</span>
              <span>4 CPUs</span>
              <span>8 CPUs</span>
            </div>
            {errors.cpus && <p className="text-xs text-red-400 mt-1">{errors.cpus}</p>}
          </div>

          <div>
            <label className="form-label flex items-center gap-2">
              <MemoryStick className="w-3.5 h-3.5 text-slate-400" />
              Memory: <span className="text-blue-400 font-bold ml-1">{form.memory_mb} MB</span>
            </label>
            <input
              type="range"
              min="256"
              max="7500"
              step="256"
              value={form.memory_mb}
              onChange={(e) => handleChange('memory_mb', e.target.value)}
              className="w-full h-2 bg-slate-700 rounded-lg appearance-none cursor-pointer accent-blue-500 mt-2"
            />
            <div className="flex justify-between text-xs text-slate-500 mt-1">
              <span>256 MB</span>
              <span>~3.7 GB</span>
              <span>7500 MB</span>
            </div>
            {errors.memory_mb && <p className="text-xs text-red-400 mt-1">{errors.memory_mb}</p>}
          </div>

          <div>
            <label className="form-label flex items-center gap-2">
              <Clock className="w-3.5 h-3.5 text-slate-400" />
              Time Limit (HH:MM:SS)
            </label>
            <input
              type="text"
              value={form.time_limit}
              onChange={(e) => handleChange('time_limit', e.target.value)}
              className={`form-input max-w-48 ${errors.time_limit ? 'border-red-500' : ''}`}
              placeholder="01:00:00"
            />
            {errors.time_limit && (
              <p className="text-xs text-red-400 mt-1">{errors.time_limit}</p>
            )}
          </div>
        </div>

        {/* Submit */}
        <div className="flex items-center gap-4">
          <button type="submit" disabled={loading} className="btn-primary px-8 py-3">
            {loading ? (
              <>
                <Loader2 className="w-4 h-4 animate-spin" />
                Submitting...
              </>
            ) : (
              <>
                Submit Job
                <ChevronRight className="w-4 h-4" />
              </>
            )}
          </button>
          <button
            type="button"
            onClick={() => navigate('/')}
            className="btn-secondary"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
