import client from './client'

export const submitJob = async (data) => {
  const response = await client.post('/jobs', data)
  return response.data
}

export const listJobs = async () => {
  const response = await client.get('/jobs')
  return response.data
}

export const getJob = async (id) => {
  const response = await client.get(`/jobs/${id}`)
  return response.data
}

export const getLogs = async (id) => {
  const response = await client.get(`/jobs/${id}/logs`)
  return response.data
}

export const getResults = async (id) => {
  const response = await client.get(`/jobs/${id}/results`)
  return response.data
}

export const cancelJob = async (id) => {
  const response = await client.delete(`/jobs/${id}`)
  return response.data
}
