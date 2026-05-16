import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../api.js";
import { useAuth } from "../auth.jsx";

export default function ChangePassword() {
  const { user, setUser } = useAuth();
  const navigate = useNavigate();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e) {
    e.preventDefault();
    if (next.length < 12) return setErr("password must be at least 12 chars");
    if (next !== confirm) return setErr("passwords don't match");
    setBusy(true);
    setErr("");
    try {
      await api.post("/api/auth/change-password", {
        current_password: current,
        new_password: next,
      });
      setUser({ ...user, must_change_password: false });
      navigate("/submit");
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="max-w-md mx-auto">
      <h1 className="text-2xl mono font-bold mb-2">change password</h1>
      <p className="text-muted text-sm mb-6">
        You're required to set a new password before using the platform.
      </p>
      <form onSubmit={onSubmit} className="space-y-4">
        <div>
          <label className="block text-xs mono mb-1">current password</label>
          <input
            type="password"
            className="input"
            value={current}
            onChange={(e) => setCurrent(e.target.value)}
            autoFocus
          />
        </div>
        <div>
          <label className="block text-xs mono mb-1">new password (min 12)</label>
          <input
            type="password"
            className="input"
            value={next}
            onChange={(e) => setNext(e.target.value)}
          />
        </div>
        <div>
          <label className="block text-xs mono mb-1">confirm</label>
          <input
            type="password"
            className="input"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
          />
        </div>
        {err && <div className="text-red-600 text-sm mono">{err}</div>}
        <button type="submit" disabled={busy} className="btn btn-primary">
          {busy ? "saving..." : "save"}
        </button>
      </form>
    </div>
  );
}
