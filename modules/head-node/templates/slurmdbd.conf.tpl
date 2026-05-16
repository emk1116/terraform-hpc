# ============================================================================
# slurmdbd.conf — Slurm accounting daemon connection to Aurora MySQL.
# Password is substituted at runtime by /opt/titan-hpc/bin/render-slurm-configs.sh
# which fetches it from Secrets Manager. Do NOT commit a rendered version.
# ============================================================================

AuthType=auth/munge
DbdHost=localhost
DbdPort=6819

# Storage backend — Aurora MySQL
StorageType=accounting_storage/mysql
StorageHost=${aurora_endpoint}
StoragePort=3306
StorageLoc=slurm_acct_db
StorageUser=slurm
StoragePass=__SLURM_DB_PASSWORD__

SlurmUser=slurm

# Logging
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurm/slurmdbd.pid
DebugLevel=info

# Performance
CommitDelay=1
PurgeEventAfter=12months
PurgeJobAfter=12months
PurgeResvAfter=12months
PurgeStepAfter=12months
PurgeSuspendAfter=12months
PurgeTXNAfter=12months
PurgeUsageAfter=12months
