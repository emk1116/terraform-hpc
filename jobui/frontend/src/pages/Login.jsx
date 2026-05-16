import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../auth.jsx";

export default function Login() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      const res = await login(username, password);
      if (res.must_change_password) {
        navigate("/change-password");
      } else {
        navigate("/submit");
      }
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-paper">
      <div className="w-full max-w-sm card">
        <div className="flex items-center gap-3 mb-8">
          <div className="w-10 h-10 bg-accent flex items-center justify-center mono font-bold text-lg">
            t
          </div>
          <div>
            <div className="mono font-bold tracking-tight">TITAN HPC</div>
            <div className="text-xs text-muted">gpu inference platform</div>
          </div>
        </div>
        <form onSubmit={onSubmit} className="space-y-4">
          <div>
            <label className="block text-xs mono mb-1">username</label>
            <input
              className="input"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoFocus
            />
          </div>
          <div>
            <label className="block text-xs mono mb-1">password</label>
            <input
              type="password"
              className="input"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>
          {err && <div className="text-red-600 text-sm mono">{err}</div>}
          <button type="submit" disabled={busy} className="btn btn-primary w-full">
            {busy ? "signing in..." : "sign in"}
          </button>
        </form>
      </div>
    </div>
  );
}
