#!/bin/bash
set -e

PIDS=()

cleanup() {
    echo "Shutting down..."
    # Stop in reverse dependency order
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait
    exit 0
}
trap cleanup SIGTERM SIGINT

wait_for_port() {
    local port=$1 name=$2 timeout=${3:-60}
    echo "-- Waiting for $name (port $port)..."
    for i in $(seq 1 "$timeout"); do
        if bash -c "echo >/dev/tcp/localhost/$port" 2>/dev/null; then
            echo "-- $name is ready"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $name did not become ready within ${timeout}s"
    exit 1
}

# --- Munge ---
echo "---> Starting munged..."
mkdir -p /run/munge
chown munge:munge /run/munge
chmod 0755 /run/munge
if [ -f /etc/munge/munge.key ]; then
    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key
fi
gosu munge /usr/sbin/munged -F &
PIDS+=($!)
# Wait for munge socket
for i in $(seq 1 30); do
    [ -S /run/munge/munge.socket.2 ] && break
    sleep 1
done

# --- Extra packages ---
if [ -n "${EXTRA_PACKAGES:-}" ]; then
    echo "---> Installing extra packages: ${EXTRA_PACKAGES}"
    dnf -y install ${EXTRA_PACKAGES}
fi

# --- SSH ---
echo "---> Configuring sshd..."
# Apply SSH environment variables to sshd_config (only if using default config)
if grep -q 'Environment variables (applied at startup' /etc/ssh/sshd_config 2>/dev/null; then
    [ -n "${SSH_PORT:-}" ] && \
        sed -i "s/^Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
    [ -n "${SSH_PERMIT_ROOT_LOGIN:-}" ] && \
        sed -i "s/^PermitRootLogin .*/PermitRootLogin ${SSH_PERMIT_ROOT_LOGIN}/" /etc/ssh/sshd_config
    [ "${SSH_PASSWORD_AUTH:-}" = "yes" ] && \
        sed -i "s/^PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
fi
# Set root password if provided
if [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd
    echo "-- Root password set"
fi
echo "---> Starting sshd..."
/usr/sbin/sshd -e &
PIDS+=($!)

# --- MariaDB ---
echo "---> Starting MariaDB..."
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "-- Initializing database..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
fi
/usr/libexec/mariadbd --user=mysql --skip-name-resolve --skip-host-cache &
PIDS+=($!)

echo "-- Waiting for MariaDB..."
for i in $(seq 1 60); do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi
    sleep 1
done

MYSQL_USER="${MYSQL_USER:-slurm}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-password}"
echo "-- Creating Slurm database if needed..."
mysql -e "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}'"
mysql -e "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'slurmctl' IDENTIFIED BY '${MYSQL_PASSWORD}'"
mysql -e "GRANT ALL ON slurm_acct_db.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION"
mysql -e "GRANT ALL ON slurm_acct_db.* TO '${MYSQL_USER}'@'slurmctl' WITH GRANT OPTION"
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db"

# --- JWT key ---
if [ ! -f /etc/slurm/jwt_hs256.key ]; then
    dd if=/dev/random of=/etc/slurm/jwt_hs256.key bs=32 count=1 2>/dev/null
    chown slurm:slurm /etc/slurm/jwt_hs256.key
    chmod 0600 /etc/slurm/jwt_hs256.key
    echo "-- JWT key generated"
fi

# --- envsubst slurmdbd.conf ---
if grep -q '${MYSQL_' /etc/slurm/slurmdbd.conf 2>/dev/null; then
    envsubst < /etc/slurm/slurmdbd.conf > /etc/slurm/slurmdbd.conf.tmp
    mv /etc/slurm/slurmdbd.conf.tmp /etc/slurm/slurmdbd.conf
    chown slurm:slurm /etc/slurm/slurmdbd.conf
    chmod 600 /etc/slurm/slurmdbd.conf
fi

# --- slurmdbd ---
echo "---> Starting slurmdbd..."
gosu slurm /usr/sbin/slurmdbd -Dvvv &
PIDS+=($!)
wait_for_port 6819 "slurmdbd"

# --- slurmctld ---
echo "---> Starting slurmctld..."
gosu slurm /usr/sbin/slurmctld -i -Dvvv &
PIDS+=($!)
for i in $(seq 1 60); do
    if scontrol ping 2>/dev/null | grep -q "UP"; then
        echo "-- slurmctld is ready"
        break
    fi
    sleep 1
done

# --- slurmd (3 nodes) ---
echo "---> Starting slurmd instances..."
# Pre-create per-node spool directories (SlurmdSpoolDir=/var/spool/slurm/%n)
for n in 1 2 3; do
    mkdir -p "/var/spool/slurm/node${n}"
    chown slurm:slurm "/var/spool/slurm/node${n}"
done
# Start slurmd instances with staggered delay to avoid cgroup v2 race condition
for n in 1 2 3; do
    /usr/sbin/slurmd -Dvvv -N "node${n}" &
    PIDS+=($!)
    sleep 1
done

# --- slurmrestd ---
echo "---> Starting slurmrestd..."
mkdir -p /var/run/slurmrestd
chown slurmrest:slurmrest /var/run/slurmrestd
SLURM_JWT=daemon gosu slurmrest /usr/sbin/slurmrestd -vvv \
    unix:/var/run/slurmrestd/slurmrestd.socket 0.0.0.0:6820 &
PIDS+=($!)

echo "---> All services started"

# If a command was passed (e.g. bash), exec it; otherwise wait
if [ $# -gt 0 ]; then
    exec "$@"
else
    wait
fi
