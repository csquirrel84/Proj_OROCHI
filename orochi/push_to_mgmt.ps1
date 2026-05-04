param(
    [Parameter(Mandatory=$true)]
    [string]$IP,

    [string]$User = "ubuntu"
)

scp -r "E:\Projects\Proj_OROCHI\*" "${User}@${IP}:~/orochi/"
