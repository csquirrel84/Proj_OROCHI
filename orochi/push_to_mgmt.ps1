param(
    [Parameter(Mandatory=$true)]
    [string]$IP,

    [string]$User = "ubuntu"
)

# WARNING: keep this a plain overwrite-copy (scp -r). Do NOT switch to any
# mirror/delete mode (rsync --delete, robocopy /MIR): the management box keeps
# live state INSIDE the pushed tree that must survive pushes — per-operation
# configs (~/orochi/orochi/OP_*.env) and install.log.
#
# Also note: every push OVERWRITES group_vars/all.yml with this dev copy.
# Mutable state must never be persisted there — versions selected during prep
# are published to the artifact server (rita-version.txt etc.) or read from
# the registry, precisely so a push cannot revert them.
scp -r "E:\Projects\Proj_OROCHI\*" "${User}@${IP}:~/orochi/"
