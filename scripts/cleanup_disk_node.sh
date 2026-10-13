#!/usr/bin/env bash
# Run on a DB node as root, or via:
# ansible all -b -K -m script -a 'scripts/cleanup_disk_node.sh --apply'
# Dry-run is the default. Never removes MySQL data, relay logs, volumes,
# containers, or the primary's binary logs.
set -Eeuo pipefail

apply=0
keep_binlogs=3
journal_limit=100M

usage() {
  cat <<'EOF'
Usage: cleanup_disk_node.sh [--dry-run|--apply] [--keep-binlogs N] [--journal-limit SIZE]

Default: show what would be cleaned, without changing anything.
--apply: clean APT cache, archived systemd journals, old Docker build cache
         and dangling images; purge old binlogs on a fully caught-up leaf
         replica only. The newest N binlogs are retained (minimum: 3).

The script NEVER deletes databases, active MySQL files, Docker volumes,
containers, or binlogs on the writable primary. Purged binlogs cannot be
recovered from that node without an external copy. Keep a verified backup.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) apply=0; shift ;;
    --apply) apply=1; shift ;;
    --keep-binlogs)
      (($# >= 2)) || { echo 'Missing --keep-binlogs value' >&2; exit 2; }
      keep_binlogs=$2; shift 2 ;;
    --journal-limit)
      (($# >= 2)) || { echo 'Missing --journal-limit value' >&2; exit 2; }
      journal_limit=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $keep_binlogs =~ ^[0-9]+$ ]] && ((keep_binlogs >= 3)) || {
  echo '--keep-binlogs must be an integer >= 3' >&2; exit 2;
}
[[ $journal_limit =~ ^[1-9][0-9]*[KMG]$ ]] || {
  echo '--journal-limit must be a size such as 100M' >&2; exit 2;
}
((EUID == 0)) || { echo 'Run as root (sudo or Ansible become)' >&2; exit 2; }

mysql_query() {
  docker exec mysql sh -c '
    MYSQL_PWD="$(cat /run/secrets/mysql_root_password)"
    export MYSQL_PWD
    exec mysql --protocol=socket --socket=/var/run/mysqld/mysqld.sock -uroot -NBe "$1"
  ' sh "$1"
}

mysql_status() {
  docker exec mysql sh -c '
    MYSQL_PWD="$(cat /run/secrets/mysql_root_password)"
    export MYSQL_PWD
    exec mysql --protocol=socket --socket=/var/run/mysqld/mysqld.sock -uroot -e "SHOW REPLICA STATUS\G"
  '
}

echo "Host: $(hostname -f)"
echo "Mode: $([[ $apply == 1 ]] && echo APPLY || echo DRY-RUN)"
echo 'Root filesystem before:'
df -h /
echo 'MySQL data size:'
du -sh /srv/mysql/data 2>/dev/null || true
echo 'Largest MySQL data directories:'
du -xhd1 /srv/mysql/data 2>/dev/null | sort -h | tail -n 7 || true
echo 'Docker usage:'
docker system df 2>/dev/null || true
echo 'Journal usage:'
journalctl --disk-usage 2>/dev/null || true

if ((apply)); then
  apt-get clean
  journalctl --vacuum-size="$journal_limit"
  docker builder prune -f --filter 'until=168h' >/dev/null
  docker image prune -f >/dev/null
else
  echo "Would clean APT cache, archived journals to $journal_limit,"
  echo 'old Docker build cache and dangling Docker images.'
fi

if ! command -v docker >/dev/null || ! docker inspect mysql >/dev/null 2>&1; then
  echo 'MySQL container unavailable: binlog purge skipped.' >&2
  exit 1
fi

role=$(mysql_query 'SELECT CONCAT(@@server_id," ",@@read_only," ",@@super_read_only)') || {
  echo 'MySQL query failed: binlog purge skipped.' >&2; exit 1;
}
read -r server_id read_only super_read_only <<<"$role"
[[ $server_id =~ ^[0-9]+$ ]] || { echo 'Invalid server ID; refusing purge.' >&2; exit 1; }

if [[ $read_only == 0 && $super_read_only == 0 ]]; then
  log_output=$(mysql_query 'SHOW BINARY LOGS')
  primary_binlog_bytes=$(awk '{sum += $2} END {printf "%.0f", sum}' <<<"$log_output")
  echo "Server $server_id is writable primary: ~$(numfmt --to=iec "$primary_binlog_bytes") of binlogs preserved."
  echo 'Primary binlog purge requires a verified backup and separate recovery decision.'
elif [[ $read_only == 1 && $super_read_only == 1 ]]; then
  echo "Server $server_id is read-only replica; checking safe-purge conditions."
  connection=$(mysql_query 'SELECT COUNT(*),COALESCE(MIN(SERVICE_STATE),"OFF"),COALESCE(MAX(SERVICE_STATE),"OFF"),COALESCE(MIN(GTID_SUBSET(RECEIVED_TRANSACTION_SET,@@global.gtid_executed)),0) FROM performance_schema.replication_connection_status')
  applier=$(mysql_query 'SELECT COUNT(*),COALESCE(MIN(SERVICE_STATE),"OFF"),COALESCE(MAX(SERVICE_STATE),"OFF") FROM performance_schema.replication_applier_status')
  read -r connection_count io_min io_max received_applied <<<"$connection"
  read -r applier_count sql_min sql_max <<<"$applier"
  status=$(mysql_status)
  lag=$(awk -F ': ' '/^[[:space:]]*Seconds_Behind_Source:/ {print $2}' <<<"$status")
  source_host=$(awk -F ': ' '/^[[:space:]]*Source_Host:/ {print $2}' <<<"$status")
  io_error=$(awk -F ': ' '/^[[:space:]]*Last_IO_Error:/ {print $2}' <<<"$status")
  sql_error=$(awk -F ': ' '/^[[:space:]]*Last_SQL_Error:/ {print $2}' <<<"$status")
  downstream=$(mysql_query 'SHOW REPLICAS')

  if [[ $connection_count != 1 || $io_min != ON || $io_max != ON ||
        $applier_count != 1 || $sql_min != ON || $sql_max != ON ||
        $received_applied != 1 || $lag != 0 || -z $source_host ||
        -n $io_error || -n $sql_error || -n $downstream ]]; then
    printf 'Unsafe replica state: source=%s IO=%s SQL=%s lag=%s received_applied=%s downstream=%s\n' \
      "$source_host" "$io_min" "$sql_min" "$lag" "$received_applied" "$([[ -n $downstream ]] && echo yes || echo no)" >&2
    echo 'Binlog purge refused; check SHOW REPLICA STATUS and topology.' >&2
    exit 1
  fi

  log_output=$(mysql_query 'SHOW BINARY LOGS')
  [[ -n $log_output ]] || { echo 'No binary logs reported; refusing purge.' >&2; exit 1; }
  mapfile -t log_rows <<<"$log_output"
  ((${#log_rows[@]} > keep_binlogs)) || {
    echo "Only ${#log_rows[@]} binlogs exist; nothing to purge.";
    echo 'Root filesystem after:'; df -h /; exit 0;
  }
  keep_index=$((${#log_rows[@]} - keep_binlogs))
  read -r target _ <<<"${log_rows[$keep_index]}"
  [[ $target =~ ^mysql-bin\.[0-9]+$ ]] || {
    echo "Unexpected binlog name: $target; refusing purge." >&2; exit 1;
  }
  reclaim=0
  for ((i=0; i<keep_index; i++)); do
    read -r name bytes _ <<<"${log_rows[$i]}"
    [[ $name =~ ^mysql-bin\.[0-9]+$ && $bytes =~ ^[0-9]+$ ]] || {
      echo 'Unexpected SHOW BINARY LOGS output; refusing purge.' >&2; exit 1;
    }
    ((reclaim += bytes)) || true
  done
  echo "Candidate: purge ${keep_index} older replica binlogs before $target (~$(numfmt --to=iec "$reclaim"))."
  if ((apply)); then
    # MySQL updates its own binlog index and GTID metadata. Never rm binlogs.
    mysql_query "PURGE BINARY LOGS TO '$target'" >/dev/null
    echo "Purged old replica binlogs; retained $keep_binlogs newest files."
  fi
else
  echo "Ambiguous read-only state ($read_only/$super_read_only); refusing purge." >&2
  exit 1
fi

echo 'Root filesystem after:'
df -h /
