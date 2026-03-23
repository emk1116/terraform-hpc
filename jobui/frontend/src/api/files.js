import client from './client'

export const uploadFile = async (file, onProgress) => {
  const formData = new FormData()
  formData.append('file', file)

  const response = await client.post('/files/upload', formData, {
    headers: { 'Content-Type': 'multipart/form-data' },
    timeout: 300000, // 5 minutes for large files
    onUploadProgress: (progressEvent) => {
      if (onProgress && progressEvent.total) {
        const percent = Math.round((progressEvent.loaded * 100) / progressEvent.total)
        onProgress(percent)
      }
    },
  })
  return response.data
}

export const listFiles = async () => {
  const response = await client.get('/files')
  return response.data
}

export const deleteFile = async (key) => {
  const response = await client.delete(`/files/${encodeURIComponent(key)}`)
  return response.data
}
