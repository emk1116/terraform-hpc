import React, { useState, useRef, useCallback } from 'react'
import { Upload, File, X, CheckCircle, AlertCircle, CloudUpload } from 'lucide-react'
import { uploadFile } from '../api/files'

const formatBytes = (bytes) => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`
}

const FileItem = ({ fileEntry, onRemove }) => {
  return (
    <div className="flex items-center gap-3 p-3 bg-slate-800 rounded-lg border border-slate-700">
      <div className="shrink-0">
        {fileEntry.status === 'success' ? (
          <CheckCircle className="w-5 h-5 text-emerald-400" />
        ) : fileEntry.status === 'error' ? (
          <AlertCircle className="w-5 h-5 text-red-400" />
        ) : (
          <File className="w-5 h-5 text-slate-400" />
        )}
      </div>

      <div className="flex-1 min-w-0">
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm font-medium text-slate-200 truncate">{fileEntry.file.name}</p>
          <span className="text-xs text-slate-500 shrink-0">{formatBytes(fileEntry.file.size)}</span>
        </div>

        {fileEntry.status === 'uploading' && (
          <div className="mt-1.5">
            <div className="flex items-center justify-between mb-1">
              <span className="text-xs text-slate-400">Uploading...</span>
              <span className="text-xs text-slate-400">{fileEntry.progress}%</span>
            </div>
            <div className="w-full bg-slate-700 rounded-full h-1.5">
              <div
                className="bg-blue-500 h-1.5 rounded-full transition-all duration-300"
                style={{ width: `${fileEntry.progress}%` }}
              />
            </div>
          </div>
        )}

        {fileEntry.status === 'success' && fileEntry.result && (
          <p className="text-xs text-emerald-400 mt-0.5 truncate">{fileEntry.result.message}</p>
        )}

        {fileEntry.status === 'error' && (
          <p className="text-xs text-red-400 mt-0.5">{fileEntry.error}</p>
        )}
      </div>

      {fileEntry.status !== 'uploading' && (
        <button
          onClick={() => onRemove(fileEntry.id)}
          className="shrink-0 p-1 text-slate-500 hover:text-red-400 rounded transition-colors"
        >
          <X className="w-4 h-4" />
        </button>
      )}
    </div>
  )
}

export default function FileDropzone({ onUploadComplete }) {
  const [isDragging, setIsDragging] = useState(false)
  const [files, setFiles] = useState([])
  const inputRef = useRef(null)
  const dragCounter = useRef(0)

  const addFiles = useCallback((newFiles) => {
    const entries = Array.from(newFiles).map((file) => ({
      id: `${file.name}-${file.size}-${Date.now()}-${Math.random()}`,
      file,
      status: 'pending',
      progress: 0,
      result: null,
      error: null,
    }))
    setFiles((prev) => [...prev, ...entries])
    // Auto-start uploads
    entries.forEach((entry) => startUpload(entry))
  }, [])

  const startUpload = useCallback(async (entry) => {
    setFiles((prev) =>
      prev.map((f) =>
        f.id === entry.id ? { ...f, status: 'uploading', progress: 0 } : f
      )
    )

    try {
      const result = await uploadFile(entry.file, (progress) => {
        setFiles((prev) =>
          prev.map((f) => (f.id === entry.id ? { ...f, progress } : f))
        )
      })

      setFiles((prev) =>
        prev.map((f) =>
          f.id === entry.id ? { ...f, status: 'success', progress: 100, result } : f
        )
      )

      if (onUploadComplete) {
        onUploadComplete(result)
      }
    } catch (err) {
      const message = err.response?.data?.detail || 'Upload failed'
      setFiles((prev) =>
        prev.map((f) =>
          f.id === entry.id ? { ...f, status: 'error', error: message } : f
        )
      )
    }
  }, [onUploadComplete])

  const handleDragEnter = useCallback((e) => {
    e.preventDefault()
    dragCounter.current++
    setIsDragging(true)
  }, [])

  const handleDragLeave = useCallback((e) => {
    e.preventDefault()
    dragCounter.current--
    if (dragCounter.current === 0) setIsDragging(false)
  }, [])

  const handleDragOver = useCallback((e) => {
    e.preventDefault()
  }, [])

  const handleDrop = useCallback(
    (e) => {
      e.preventDefault()
      dragCounter.current = 0
      setIsDragging(false)
      if (e.dataTransfer.files.length > 0) {
        addFiles(e.dataTransfer.files)
      }
    },
    [addFiles]
  )

  const handleFileChange = useCallback(
    (e) => {
      if (e.target.files.length > 0) {
        addFiles(e.target.files)
        e.target.value = ''
      }
    },
    [addFiles]
  )

  const removeFile = useCallback((id) => {
    setFiles((prev) => prev.filter((f) => f.id !== id))
  }, [])

  const hasFiles = files.length > 0
  const uploadingCount = files.filter((f) => f.status === 'uploading').length
  const successCount = files.filter((f) => f.status === 'success').length

  return (
    <div className="space-y-4">
      <div
        onDragEnter={handleDragEnter}
        onDragLeave={handleDragLeave}
        onDragOver={handleDragOver}
        onDrop={handleDrop}
        onClick={() => inputRef.current?.click()}
        className={`
          relative border-2 border-dashed rounded-xl p-10 text-center cursor-pointer transition-all duration-200
          ${isDragging
            ? 'border-blue-500 bg-blue-500/10 scale-[1.02]'
            : 'border-slate-600 hover:border-slate-500 hover:bg-slate-800/50'
          }
        `}
      >
        <input
          ref={inputRef}
          type="file"
          multiple
          className="hidden"
          onChange={handleFileChange}
        />

        <div className="flex flex-col items-center gap-3">
          <div className={`w-14 h-14 rounded-full flex items-center justify-center transition-colors ${
            isDragging ? 'bg-blue-500/20' : 'bg-slate-700'
          }`}>
            <CloudUpload className={`w-7 h-7 ${isDragging ? 'text-blue-400' : 'text-slate-400'}`} />
          </div>
          <div>
            <p className="text-sm font-medium text-slate-300">
              {isDragging ? 'Drop files here' : 'Drag & drop files here'}
            </p>
            <p className="text-xs text-slate-500 mt-1">or click to browse — any file type accepted</p>
          </div>
          {uploadingCount > 0 && (
            <div className="text-xs text-blue-400 font-medium">
              Uploading {uploadingCount} file{uploadingCount !== 1 ? 's' : ''}...
            </div>
          )}
          {successCount > 0 && uploadingCount === 0 && (
            <div className="text-xs text-emerald-400 font-medium">
              {successCount} file{successCount !== 1 ? 's' : ''} uploaded successfully
            </div>
          )}
        </div>
      </div>

      {hasFiles && (
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-medium text-slate-300">
              Files ({files.length})
            </h3>
            <button
              onClick={() => setFiles([])}
              className="text-xs text-slate-500 hover:text-slate-300 transition-colors"
            >
              Clear all
            </button>
          </div>
          <div className="space-y-2">
            {files.map((entry) => (
              <FileItem key={entry.id} fileEntry={entry} onRemove={removeFile} />
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
