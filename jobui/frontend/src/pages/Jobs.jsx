import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../api.js";

function statusColor(s) {
  return {
    submitted: "bg-border",
    pending: "bg-yellow-100",
    running: "bg-accent",
    completed: "bg-green-100",
    failed: "bg-red-100",
    cancelled: "bg-border",
  }[s] || "bg-border";
}

function elapsed(job) {
  const start = job.started_at ? new Date(job.started_at) : null;
  const end = job.ended_at ? new Date(job.ended_at) : null;
  if (!start) return "—";
  const ms = (end || Date.now()) - start;
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export default function Jobs() {
  const [jobs, setJobs] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const load = () => api.get("/api/jobs").then(setJobs).finally(() => setLoading(false));
    load();
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, []);

  return (
    <div>
      <h1 className="text-3xl mono font-bold tracking-tight mb-8">jobs</h1>
      {loading && <div className="mono text-sm">loading...</div>}
      {!loading && jobs.length === 0 && (
        <div className="card text-center">
          <p className="text-muted">no jobs yet</p>
          <Link to="/submit" className="btn btn-primary mt-4 inline-block">
            submit first job
          </Link>
        </div>
      )}
      {jobs.length > 0 && (
        <div className="border border-border overflow-hidden overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-border bg-ink text-paper">
              <tr className="mono text-xs text-left">
                <th className="p-3">id</th>
                <th className="p-3">slurm</th>
                <th className="p-3">model</th>
                <th className="p-3">gpu</th>
                <th className="p-3">status</th>
                <th className="p-3 text-right">elapsed</th>
                <th className="p-3 text-right">cost</th>
                <th className="p-3 text-right">submitted</th>
              </tr>
            </thead>
            <tbody>
              {jobs.map((j) => (
                <tr key={j.id} className="border-b border-border hover:bg-paper">
                  <td className="p-3 mono">
                    <Link to={"/jobs/" + j.id} className="underline">#{j.id}</Link>
                  </td>
                  <td className="p-3 mono text-muted">{j.slurm_job_id || "—"}</td>
                  <td className="p-3 mono text-xs">
                    {j.model_display_name || j.model_key || `model #${j.model_id}`}
                  </td>
                  <td className="p-3 mono">
                    {j.gpu_count > 1 ? `${j.gpu_count}× ` : ""}{j.gpu_family}
                  </td>
                  <td className="p-3">
                    <span className={"pill " + statusColor(j.status)}>{j.status}</span>
                  </td>
                  <td className="p-3 mono text-right text-xs text-muted">
                    {elapsed(j)}
                  </td>
                  <td className="p-3 mono text-right">
                    ${Number(j.actual_cost_usd || j.estimated_cost_usd).toFixed(2)}
                  </td>
                  <td className="p-3 text-right text-muted text-xs">
                    {new Date(j.submitted_at).toLocaleString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
