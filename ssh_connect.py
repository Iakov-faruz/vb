import paramiko
client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    client.connect(hostname="10.161.199.60", username="yf", password="1", timeout=15)
    _, stdout, stderr = client.exec_command("hostname; whoami; uname -a; find /home /root /opt -maxdepth 4 -name 'test_T01.sh' 2>/dev/null; ls /home/yf/ 2>/dev/null")
    print(stdout.read().decode())
    print(stderr.read().decode(), end="")
    client.close()
except Exception as e:
    print(f"SSH_FAILED: {e}")