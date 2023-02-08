#!/usr/bin/env bash

is_supported() {
  [[ "${DOCKERBUILD:-0}" == 1 ]] && [[ "$(lsb_release -r)" =~ .*10 ]] && return 1
  return 0
}

is_active() {
  is_supported || return 1

  metrics_services status > /dev/null 2>&1 || return 1
  # systemctl is-active -q prometheus-node-exporter || return 1
  return 0
}

tmpl_metrics_enabled() {
  (
  . /usr/local/etc/library.sh
  local param_active="$(findAppParam metrics.sh ACTIVE)"
  [[ "$param_active" == yes ]] || exit 1
  )
}

reload_metrics_config() {
  is_supported || return 0

  installTemplate ncp-metrics.cfg.sh "/usr/local/etc/ncp-metrics.cfg" || {
    echo -e "ERROR while generating ncp-metrics.conf!"
    return 1
  }
  service ncp-metrics-exporter status > /dev/null && {
    service ncp-metrics-exporter restart
    service ncp-metrics-exporter status > /dev/null 2>&1 || {
      rc=$?
      echo -e "WARNING: ncp-metrics-exporter failed to start (exit-code $rc)!"
      return $rc
    }
  } || return 0
}

metrics_services() {
  cmd="${1?}"

  if [[ "$cmd" =~ (start|stop|restart|reload|status) ]]
  then
    if ! isDocker && [[ "$INIT_SYSTEM" != "systemd" ]]
    then
      echo "Probably running in chroot. Ignoring 'metrics_services $cmd'..."
      return 0
    fi
    rc1=0
    rc2=0
    service prometheus-node-exporter "$cmd" || rc1=$?
    service ncp-metrics-exporter "$cmd" || rc2=$?
    [[ $rc1 > $rc2 ]] && return $rc1
    return $rc2
  fi

  if ! [[ "$cmd" =~ (en|dis)able ]]
  then
    echo -e "ERROR: Invalid command: metrics_services ${cmd}!"
    exit 1
  fi

  if isDocker
  then
    rc1=0
    rc2=0
    update-rc.d ncp-metrics-exporter "$cmd" || rc1=$?
    update-rc.d prometheus-node-exporter "$cmd" || rc2=$?
    [[ $rc1 > $rc2 ]] && return $rc1
    return $rc2
  else
    systemctl "$cmd" prometheus-node-exporter ncp-metrics-exporter
    return $?
  fi
}

install() {

  # Subshell to return on failure  instead of exiting (due to set -e)
  (

  set -e
  set +u

  is_supported || {
    echo -e "Metrics app is not supported in debian 10 docker containers. Installation will be skipped."
    return 0
  }

  cat > /etc/default/prometheus-node-exporter <<'EOF'
ARGS="--collector.filesystem.ignored-mount-points=\"^/(dev|proc|run|sys|mnt|var/log|var/lib/docker)($|/)\""
EOF

  arch="$(uname -m)"
  [[ "${arch}" =~ ^"arm" ]] && arch="armv7"

  mkdir -p /usr/local/lib/ncp-metrics
  wget -qO "/usr/local/lib/ncp-metrics/ncp-metrics-exporter" \
    "https://github.com/theCalcaholic/ncp-metrics-exporter/releases/download/v1.1.0/ncp-metrics-exporter-${arch}"
  chmod +x /usr/local/lib/ncp-metrics/ncp-metrics-exporter

  # Apply fix to init-d-script (https://salsa.debian.org/debian/sysvinit/-/commit/aa40516c)
  # Otherwise the init.d scripts of prometheus-node-exporter won't work
  # shellcheck disable=SC2016
  sed -i 's|status_of_proc "$DAEMON" "$NAME" ${PIDFILE:="-p ${PIDFILE}"}|status_of_proc ${PIDFILE:+-p "$PIDFILE"} "$DAEMON" "$NAME"|' /lib/init/init-d-script

  apt-get update --allow-releaseinfo-change
  installWithShadowWorkaround -o Dpkg::Options::=--force-confdef -o Dpkg::Options::="--force-confold" prometheus-node-exporter

  if isDocker
  then
    cat > /etc/init.d/ncp-metrics-exporter <<'EOF'
#!/bin/sh
# Generated by sysd2v v0.3  --  http://www.trek.eu.org/devel/sysd2v
# kFreeBSD do not accept scripts as interpreters, using #!/bin/sh and sourcing.
if [ true != "$INIT_D_SCRIPT_SOURCED" ] ; then
    set "$0" "$@"; INIT_D_SCRIPT_SOURCED=true . /lib/init/init-d-script
fi
### BEGIN INIT INFO
# Provides:       ncp-metrics-exporter
# Required-Start: $remote_fs
# Required-Stop:  $remote_fs
# Default-Start:  2 3 4 5
# Default-Stop:   0 1 6
# Description:    NCP Metrics Exporter
### END INIT INFO
set -a
NCP_CONFIG_DIR=/usr/local/etc
set +a

NAME=ncp-exporter
DAEMON=/usr/local/lib/ncp-metrics/ncp-metrics-exporter
PIDFILE=/var/run/ncp-metrics-exporter.pid
LOGFILE=/var/log/ncp-metrics.log
START_ARGS="--background --make-pidfile"
EOF
    chmod +x /etc/init.d/ncp-metrics-exporter
    update-rc.d ncp-metrics-exporter defaults

    cat > /etc/services-available.d/101ncp-metrics <<EOF
#!/usr/bin/env bash

source /usr/local/etc/library.sh
[[ "\$1" == "stop" ]] && {
  echo "stopping prometheus-node-exporter..."
  service prometheus-node-exporter stop
  echo "done."
  echo "stopping ncp-metrics-exporter"
  service ncp-metrics-exporter stop
  echo "done."
  exit 0
}

persistConfiguration /etc/default/prometheus-node-exporter

echo "starting prometheus-node-exporter..."
service prometheus-node-exporter start
[[ -n "\$(pgrep prometheus)" ]] || echo -e "ERROR: prometheus-node-exporter failed to start!"
echo "starting ncp-metrics-exporter
service ncp-metrics-exporter start
EOF
  chmod +x /etc/services-available.d/101ncp-metrics

  else #=> if not isDocker

    cat <<EOF > /etc/systemd/system/ncp-metrics-exporter.service
[Unit]
Description=NCP Metrics Exporter

[Service]
Environment=NCP_CONFIG_DIR=/usr/local/etc
ExecStart=/usr/local/lib/ncp-metrics/ncp-metrics-exporter
SyslogIdentifier=ncp-metrics
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

  fi

  metrics_services stop
  metrics_services disable

  )
}

configure() {
  set +u

  if [[ "$ACTIVE" != yes ]]
  then

    installTemplate nextcloud.conf.sh /etc/apache2/sites-available/nextcloud.conf || {
      installTemplate nextcloud.conf.sh /etc/apache2/sites-available/nextcloud.conf --allow-fallback
      echo -e "ERROR while generating nextcloud.conf! Exiting..."
      return 1
    }
    echo "Disabling and stopping services..."
    metrics_services disable
    metrics_services stop
    echo "done."
  else

    is_supported || {
      echo -e "Metrics app is not supported in debian 10 docker containers. Terminating..."
      return 0
    }

    [[ -n "$USER" ]] || {
      echo -e "ERROR: User can not be empty!" >&2
      return 1
    }

    if [[ "$METRICS_SKIP_PASSWORD_CONFIG" != "true" ]]
    then
      [[ -n "$PASSWORD" ]] || {
        echo -e "ERROR: Password can not be empty!" >&2
        return 1
      }

      [[ ${#PASSWORD} -ge 10 ]] || {
        echo -e "ERROR: Password must be at least 10 characters long!" >&2
        return 1
      }

      local htpasswd_file="/usr/local/etc/metrics.htpasswd"
      rm -f "${htpasswd_file}"
      echo "$PASSWORD" | htpasswd -ciB "${htpasswd_file}" "$USER"
    fi

    echo "Generate config..."
    reload_metrics_config
    echo "done."

    echo "Enabling and starting services..."
    metrics_services enable
    metrics_services start
    metrics_services status || {
      echo -e "ERROR: Metrics services not running!"
      return 1
    }
    echo "done."


    installTemplate nextcloud.conf.sh /etc/apache2/sites-available/nextcloud.conf || {
      installTemplate nextcloud.conf.sh /etc/apache2/sites-available/nextcloud.conf --allow-fallback
      echo -e "ERROR while generating nextcloud.conf! Exiting..."
      return 1
    }

    echo "Metrics endpoint enabled. You can test it at https://nextcloudpi.local/metrics/system and https://nextcloudpi.local/metrics/ncp (or under your NC domain under the same paths)"
  fi

  bash -c "sleep 2 && service apache2 reload" &>/dev/null &

}
