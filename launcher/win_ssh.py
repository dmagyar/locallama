#!/usr/bin/env python3
"""Run a command on the Windows build VM via SSH and print output."""
import sys
import paramiko
import select

HOST = '10.119.10.51'
USER = 'testuser'
PASS = 'testpass'

def run(cmd, timeout=300):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=15)
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    while True:
        r, _, _ = select.select([stdout.channel, stderr.channel], [], [], 2.0)
        if stdout.channel in r:
            data = stdout.channel.recv(8192)
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            else:
                if stdout.channel.exit_status_ready():
                    break
        if stderr.channel in r:
            data = stderr.channel.recv(8192)
            if data:
                sys.stderr.buffer.write(data)
                sys.stderr.buffer.flush()
            else:
                if stderr.channel.exit_status_ready():
                    break
        if stdout.channel.closed and stderr.channel.closed:
            break
    exit_code = stdout.channel.recv_exit_status()
    client.close()
    return exit_code

def scp_download(remote_path, local_path):
    """Download a file from the Windows VM."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=15)
    sftp = client.open_sftp()
    sftp.get(remote_path, local_path)
    sftp.close()
    client.close()

def scp_upload(local_path, remote_path):
    """Upload a file to the Windows VM."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASS, timeout=15)
    sftp = client.open_sftp()
    sftp.put(local_path, remote_path)
    sftp.close()
    client.close()

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'run'
    if mode == 'run' and len(sys.argv) > 2:
        rc = run(' '.join(sys.argv[2:]))
        sys.exit(rc)
    elif mode == 'download' and len(sys.argv) == 4:
        scp_download(sys.argv[2], sys.argv[3])
    elif mode == 'upload' and len(sys.argv) == 4:
        scp_upload(sys.argv[2], sys.argv[3])
    else:
        print(f"Usage: {sys.argv[0]} run <command>")
        print(f"       {sys.argv[0]} download <remote> <local>")
        print(f"       {sys.argv[0]} upload <local> <remote>")
