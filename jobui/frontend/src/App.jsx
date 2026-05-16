import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { useAuth } from "./auth.jsx";
import Login from "./pages/Login.jsx";
import Submit from "./pages/Submit.jsx";
import Jobs from "./pages/Jobs.jsx";
import JobDetail from "./pages/JobDetail.jsx";
import Admin from "./pages/Admin.jsx";
import ChangePassword from "./pages/ChangePassword.jsx";

function RequireAuth({ children }) {
  const { user, loading } = useAuth();
  const loc = useLocation();
  if (loading) return <div className="p-8 mono">loading...</div>;
  if (!user) return <Navigate to="/login" state={{ from: loc }} replace />;
  if (user.must_change_password && loc.pathname !== "/change-password") {
    return <Navigate to="/change-password" replace />;
  }
  return children;
}

function Shell({ children }) {
  const { user, logout } = useAuth();
  return (
    <div className="min-h-screen flex flex-col">
      <header className="border-b border-border bg-paper">
        <div className="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
          <Link to="/" className="flex items-center gap-3">
            <div className="w-8 h-8 bg-accent flex items-center justify-center mono font-bold">
              t
            </div>
            <span className="mono font-bold tracking-tight">TITAN HPC</span>
          </Link>
          <nav className="flex items-center gap-6 text-sm">
            <Link to="/submit" className="hover:underline">Submit</Link>
            <Link to="/jobs" className="hover:underline">Jobs</Link>
            {user?.role === "admin" && (
              <Link to="/admin" className="hover:underline">Admin</Link>
            )}
            <span className="text-muted mono text-xs">{user?.username}</span>
            <button onClick={logout} className="btn-ghost btn text-xs py-1">
              sign out
            </button>
          </nav>
        </div>
      </header>
      <main className="flex-1 max-w-6xl mx-auto w-full px-6 py-8">{children}</main>
      <footer className="border-t border-border mono text-xs text-muted p-4 text-center">
        titan-hpc &middot; gpu inference platform
      </footer>
    </div>
  );
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route
        path="/change-password"
        element={
          <RequireAuth>
            <Shell><ChangePassword /></Shell>
          </RequireAuth>
        }
      />
      <Route
        path="/"
        element={<Navigate to="/submit" replace />}
      />
      <Route
        path="/submit"
        element={<RequireAuth><Shell><Submit /></Shell></RequireAuth>}
      />
      <Route
        path="/jobs"
        element={<RequireAuth><Shell><Jobs /></Shell></RequireAuth>}
      />
      <Route
        path="/jobs/:id"
        element={<RequireAuth><Shell><JobDetail /></Shell></RequireAuth>}
      />
      <Route
        path="/admin"
        element={<RequireAuth><Shell><Admin /></Shell></RequireAuth>}
      />
    </Routes>
  );
}
