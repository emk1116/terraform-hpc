import React, { useState, useEffect, useCallback } from 'react'
import { listFiles, deleteFile } from '../api/files'
import FileDropzone from '../components/FileDropzone'
import { Trash2, RefreshCw, HardDrive, Info, Loader2 } from 'lucide-react'

const formatBytes = (bytes) => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`
}

const formatDate = (isoString) => {
  if (!isoString) return '—'
  try {
    return new Date(isoString).toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return isoString
  }
}

export default function Upload() {
  const [files, setFiles] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [deletingKey, setDeletingKey] = useState(null)

  const fetchFiles = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const data = await listFiles()
      setFiles(data)
    } catch (err) {
      setError(err.response?.data?.detail || 'Failed to load files')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchFiles()
  }, [fetchFiles])

  const handleUploadComplete = useCallback(() => {
    // Refresh file list after successful upload
    setTimeout(fetchFiles, 500)
  }, [fetchFiles])

  const handleDelete = async (key) => {
    if (!window.confirm(`Delete file "${key.split('/').pop()}"?`)) return
    setDeletingKey(key)
    try {
      await deleteFile(key)
      setFiles((prev) => prev.filter((f) => f.key !== key))
    } catch (err) {
      alert(err.response?.data?.detail || 'Failed to delete file')
    } finally {
      setDeletingKey(null)
    }
  }

  const totalSize = files.reduce((sum, f) => sum + f.size, 0)

  return (
    <div className="space-y-6 max-w-4xl">
      <div>
        <h1 className="text-2xl font-bold text-white">Upload Input Files</h1>
        <p className="text-slate-400 text-sm mt-1">
          Upload files to S3 for use in HPC job submissions
        </p>
      </div>

      {/* Info banner */}
      <div className="flex items-start gap-3 p-4 bg-blue-500/10 border border-blue-500/20 rounded-xl">
        <Info className="w-4 h-4 text-blue-400 mt-0.5 shrink-0" />
        <div className="text-sm text-blue-300">
          <p className="font-medium">Files are ready to use in jobs</p>
          <p className="text-blue-400 mt-0.5 text-xs">
            Uploaded files will be available as input when submitting a job.
            Use the file name or folder prefix in the "Input Prefix" field during job submission.
          </p>
        </div>
      </div>

      {/* Upload zone */}
      <div className="card">
        <h2 className="text-lg font-semibold text-white mb-5">Upload Files</h2>
        <FileDropzone onUploadComplete={handleUploadComplete} />
      </div>

      {/* Existing files */}
      <div className="card">
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <HardDrive className="w-5 h-5 text-slate-400" />
            <h2 className="text-lg font-semibold text-white">
              Your Input Files
              {files.length > 0 && (
                <span className="ml-2 text-sm font-normal text-slate-400">
                  ({files.length} files, {formatBytes(totalSize)} total)
                </span>
              )}
            </h2>
          </div>
          <button
            onClick={fetchFiles}
            disabled={loading}
            className="btn-secondary text-sm py-1.5"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>

        {loading ? (
          <div className="flex items-center justify-center py-10">
            <Loader2 className="w-6 h-6 animate-spin text-slate-500" />
          </div>
        ) : error ? (
          <div className="text-center py-8">
            <p className="text-red-400 text-sm">{error}</p>
          </div>
        ) : files.length === 0 ? (
          <div className="text-center py-10 text-slate-500">
            <HardDrive className="w-10 h-10 mx-auto mb-3 opacity-40" />
            <p className="text-sm">No files uploaded yet</p>
            <p className="text-xs mt-1">Upload files above to get started</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-700">
                  <th className="table-header text-left pb-3 pr-4">Filename</th>
                  <th className="table-header text-right pb-3 pr-4">Size</th>
                  <th className="table-header text-left pb-3 pr-4">Uploaded</th>
                  <th className="table-header text-right pb-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {files.map((file) => (
                  <tr
                    key={file.key}
                    className="border-b border-slate-700/50 hover:bg-slate-700/20 transition-colors"
                  >
                    <td className="py-3 pr-4">
                      <span className="font-mono text-slate-200 text-xs">{file.filename}</span>
                    </td>
                    <td className="py-3 pr-4 text-right">
                      <span className="text-slate-400 text-xs">{formatBytes(file.size)}</span>
                    </td>
                    <td className="py-3 pr-4">
                      <span className="text-slate-400 text-xs">{formatDate(file.last_modified)}</span>
                    </td>
                    <td className="py-3 text-right">
                      <button
                        onClick={() => handleDelete(file.key)}
                        disabled={deletingKey === file.key}
                        className="inline-flex items-center gap-1 text-xs text-red-400 hover:text-red-300 transition-colors px-2 py-1 rounded hover:bg-red-500/10 disabled:opacity-40 disabled:cursor-not-allowed"
                      >
                        {deletingKey === file.key ? (
                          <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        ) : (
                          <Trash2 className="w-3.5 h-3.5" />
                        )}
                        Delete
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
