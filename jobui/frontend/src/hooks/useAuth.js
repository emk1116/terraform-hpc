import { useState, useEffect, useCallback } from 'react'
import { login as apiLogin, getMe } from '../api/auth'

const TOKEN_KEY = 'hpc_token'
const USER_KEY = 'hpc_user'

export const useAuth = () => {
  const [user, setUser] = useState(() => {
    try {
      const stored = localStorage.getItem(USER_KEY)
      return stored ? JSON.parse(stored) : null
    } catch {
      return null
    }
  })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const isAuthenticated = Boolean(user && localStorage.getItem(TOKEN_KEY))

  // Validate token on mount by fetching /auth/me
  useEffect(() => {
    const token = localStorage.getItem(TOKEN_KEY)
    if (!token) {
      setLoading(false)
      return
    }

    getMe()
      .then((userData) => {
        setUser(userData)
        localStorage.setItem(USER_KEY, JSON.stringify(userData))
      })
      .catch(() => {
        localStorage.removeItem(TOKEN_KEY)
        localStorage.removeItem(USER_KEY)
        setUser(null)
      })
      .finally(() => setLoading(false))
  }, [])

  const login = useCallback(async (username, password) => {
    setError(null)
    try {
      const tokenData = await apiLogin(username, password)
      localStorage.setItem(TOKEN_KEY, tokenData.access_token)

      const userData = await getMe()
      setUser(userData)
      localStorage.setItem(USER_KEY, JSON.stringify(userData))
      return userData
    } catch (err) {
      const message =
        err.response?.data?.detail || 'Login failed. Please check your credentials.'
      setError(message)
      throw new Error(message)
    }
  }, [])

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY)
    localStorage.removeItem(USER_KEY)
    setUser(null)
  }, [])

  return { user, loading, error, isAuthenticated, login, logout }
}
