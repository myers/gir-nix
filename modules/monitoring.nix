# Ticket 24 — monitoring: node exporter and its textfile collectors, smartd,
# rasdaemon, ZED and the BMC sensor log.
#
# Ticket 05 puts every one of these in the day-one reliability set. The
# Prometheus *server* is dropped (stock Ubuntu sample config, `monitor:
# 'example'`, alertmanager aimed at a dead port; rebuild is ticket 18) — the
# **node exporter and its textfile collectors are not**. The exporter keeps
# producing metrics with nothing scraping it, which is the point: ticket 18's
# one hard constraint is that whatever replaces the server must survive k3s
# being down, and the data has to already be there when it arrives.
#
# What this module does NOT own:
#   * ipmievd            -> ipmievd.nix (hand-written unit; do not duplicate)
#   * netconsole         -> netconsole.nix
#   * kdump              -> kdump.nix
#   * the panic triggers -> sysctl.nix
#   * nut.prom / nut_selftest.prom / nut_events.prom -> nut.nix, which writes
#     them into the same textfile directory this module configures
#   * every `fileSystems` entry, and smartd's RequiresMountsFor on
#     /var/lib/smartmontools -> storage.nix (already there, line 364)
#
# THE TEXTFILE DIRECTORY IS `/var/lib/prometheus/node-exporter`.
# nut.nix line 96 carries a TODO asking this module to confirm that choice.
# Confirmed, and it is not arbitrary: it is Debian's compiled-in default for
# `--collector.textfile.directory`, it is where all seven .prom files on the
# live host already are, and nut.nix's events-repair state dir is symlinked
# into it (`nut_events.prom -> /var/lib/nut-events-repair/nut_events.prom`).
# Upstream node_exporter defaults that flag to the empty string, so on NixOS it
# MUST be passed explicitly or the textfile collector reads nothing at all and
# fails silently — the whole textfile half of the monitoring disappears with no
# error anywhere.
#
# Everything below was read from either
# logs/port-configs-20260919-191439/monitoring/ or the live host, 2026-09-19.
{ config, lib, pkgs, ... }:

let
  textfileDir = "/var/lib/prometheus/node-exporter";

  ##########################################################################
  # The three textfile-collector scripts that live on the host, embedded
  # verbatim from /usr/share/prometheus-node-exporter-collectors/ (Debian's
  # `prometheus-node-exporter-collectors` package, which nixpkgs does NOT
  # have — there is no `prometheus-node-exporter-collectors` attribute at the
  # pinned revision, only `prometheus-node-exporter` itself).
  #
  # The only edit to any of them: smartmon.sh's hardcoded `/usr/sbin/smartctl`
  # becomes a bare `smartctl`, resolved from the unit's `path`. Every other
  # byte matches the Ubuntu original, so `diff <(cat this) /usr/share/...`
  # stays a meaningful check during the soak.
  ##########################################################################

  smartmonScript = pkgs.writeShellScript "node-exporter-smartmon.sh" ''
      # Script informed by the collectd monitoring script for smartmontools (using smartctl)
      # by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
      # source at: http://devel.dob.sk/collectd-scripts/

      # TODO: This probably needs to be a little more complex.  The raw numbers can have more
      #       data in them than you'd think.
      #       http://arstechnica.com/civis/viewtopic.php?p=22062211

      # Formatting done via shfmt -i 2
      # https://github.com/mvdan/sh

      parse_smartctl_attributes_awk="$(
        cat <<'SMARTCTLAWK'
      $1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
        gsub(/-/, "_");
        printf "%s_value{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $4
        printf "%s_worst{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $5
        printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $6
        printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", $2, labels, $1, $10
      }
      SMARTCTLAWK
      )"

      smartmon_attrs="$(
        cat <<'SMARTMONATTRS'
      airflow_temperature_cel
      command_timeout
      current_pending_sector
      end_to_end_error
      erase_fail_count
      g_sense_error_rate
      hardware_ecc_recovered
      host_reads_32mib
      host_reads_mib
      host_writes_32mib
      host_writes_mib
      load_cycle_count
      media_wearout_indicator
      nand_writes_1gib
      offline_uncorrectable
      power_cycle_count
      power_on_hours
      program_fail_cnt_total
      program_fail_count
      raw_read_error_rate
      reallocated_event_count
      reallocated_sector_ct
      reported_uncorrect
      runtime_bad_block
      sata_downshift_count
      seek_error_rate
      spin_retry_count
      spin_up_time
      start_stop_count
      temperature_case
      temperature_celsius
      temperature_internal
      total_lbas_read
      total_lbas_written
      udma_crc_error_count
      unsafe_shutdown_count
      unused_rsvd_blk_cnt_tot
      wear_leveling_count
      workld_host_reads_perc
      workld_media_wear_indic
      workload_minutes
      SMARTMONATTRS
      )"
      smartmon_attrs="$(echo "''${smartmon_attrs}" | xargs | tr ' ' '|')"

      parse_smartctl_attributes() {
        local disk="$1"
        local disk_type="$2"
        local labels="disk=\"''${disk}\",type=\"''${disk_type}\""
        sed 's/^ \+//g' |
          awk -v labels="''${labels}" "''${parse_smartctl_attributes_awk}" 2>/dev/null |
          tr '[:upper:]' '[:lower:]' |
          grep -E "(''${smartmon_attrs})"
      }

      parse_smartctl_scsi_attributes() {
        local disk="$1"
        local disk_type="$2"
        local labels="disk=\"''${disk}\",type=\"''${disk_type}\""
        while read -r line; do
          attr_type="$(echo "''${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
          attr_value="$(echo "''${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
          case "''${attr_type}" in
          number_of_hours_powered_up_) power_on="$(echo "''${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
          Current_Drive_Temperature) temp_cel="$(echo "''${attr_value}" | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
          Blocks_sent_to_initiator_) lbas_read="$(echo "''${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
          Blocks_received_from_initiator_) lbas_written="$(echo "''${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
          Accumulated_start-stop_cycles) power_cycle="$(echo "''${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
          Elements_in_grown_defect_list) grown_defects="$(echo "''${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
          esac
        done
        [ -n "$power_on" ] && echo "power_on_hours_raw_value{''${labels},smart_id=\"9\"} ''${power_on}"
        [ -n "$temp_cel" ] && echo "temperature_celsius_raw_value{''${labels},smart_id=\"194\"} ''${temp_cel}"
        [ -n "$lbas_read" ] && echo "total_lbas_read_raw_value{''${labels},smart_id=\"242\"} ''${lbas_read}"
        [ -n "$lbas_written" ] && echo "total_lbas_written_raw_value{''${labels},smart_id=\"242\"} ''${lbas_written}"
        [ -n "$power_cycle" ] && echo "power_cycle_count_raw_value{''${labels},smart_id=\"12\"} ''${power_cycle}"
        [ -n "$grown_defects" ] && echo "grown_defects_count_raw_value{''${labels},smart_id=\"12\"} ''${grown_defects}"
      }

      parse_smartctl_info() {
        local -i smart_available=0 smart_enabled=0 smart_healthy=
        local disk="$1" disk_type="$2"
        local model_family=''' device_model=''' serial_number=''' fw_version=''' vendor=''' product=''' revision=''' lun_id='''
        while read -r line; do
          info_type="$(echo "''${line}" | cut -f1 -d: | tr ' ' '_')"
          info_value="$(echo "''${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
          case "''${info_type}" in
          Model_Family) model_family="''${info_value}" ;;
          Device_Model) device_model="''${info_value}" ;;
          Serial_Number) serial_number="''${info_value}" ;;
          Firmware_Version) fw_version="''${info_value}" ;;
          Vendor) vendor="''${info_value}" ;;
          Product) product="''${info_value}" ;;
          Revision) revision="''${info_value}" ;;
          Logical_Unit_id) lun_id="''${info_value}" ;;
          esac
          if [[ "''${info_type}" == 'SMART_support_is' ]]; then
            case "''${info_value:0:7}" in
            Enabled) smart_available=1; smart_enabled=1 ;;
            Availab) smart_available=1; smart_enabled=0 ;;
            Unavail) smart_available=0; smart_enabled=0 ;;
            esac
          fi
          if [[ "''${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]]; then
            case "''${info_value:0:6}" in
            PASSED) smart_healthy=1 ;;
            *) smart_healthy=0 ;;
            esac
          elif [[ "''${info_type}" == 'SMART_Health_Status' ]]; then
            case "''${info_value:0:2}" in
            OK) smart_healthy=1 ;;
            *) smart_healthy=0 ;;
            esac
          fi
        done
        echo "device_info{disk=\"''${disk}\",type=\"''${disk_type}\",vendor=\"''${vendor}\",product=\"''${product}\",revision=\"''${revision}\",lun_id=\"''${lun_id}\",model_family=\"''${model_family}\",device_model=\"''${device_model}\",serial_number=\"''${serial_number}\",firmware_version=\"''${fw_version}\"} 1"
        echo "device_smart_available{disk=\"''${disk}\",type=\"''${disk_type}\"} ''${smart_available}"
        echo "device_smart_enabled{disk=\"''${disk}\",type=\"''${disk_type}\"} ''${smart_enabled}"
        [[ "''${smart_healthy}" != "" ]] && echo "device_smart_healthy{disk=\"''${disk}\",type=\"''${disk_type}\"} ''${smart_healthy}"
      }

      output_format_awk="$(
        cat <<'OUTPUTAWK'
      BEGIN { v = "" }
      v != $1 {
        print "# HELP smartmon_" $1 " SMART metric " $1;
        print "# TYPE smartmon_" $1 " gauge";
        v = $1
      }
      {print "smartmon_" $0}
      OUTPUTAWK
      )"

      format_output() {
        sort |
          awk -F'{' "''${output_format_awk}"
      }

      smartctl_version="$(smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

      echo "smartctl_version{version=\"''${smartctl_version}\"} 1" | format_output

      if [[ "$(expr "''${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
        exit
      fi

      device_list="$(smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"

      for device in ''${device_list}; do
        disk="$(echo "''${device}" | cut -f1 -d'|')"
        type="$(echo "''${device}" | cut -f2 -d'|')"
        active=1
        echo "smartctl_run{disk=\"''${disk}\",type=\"''${type}\"}" "$(TZ=UTC date '+%s')"
        # Check if the device is in a low-power mode
        smartctl -n standby -d "''${type}" "''${disk}" > /dev/null || active=0
        echo "device_active{disk=\"''${disk}\",type=\"''${type}\"}" "''${active}"
        # Skip further metrics to prevent the disk from spinning up
        test ''${active} -eq 0 && continue
        # Get the SMART information and health
        smartctl -i -H -d "''${type}" "''${disk}" | parse_smartctl_info "''${disk}" "''${type}"
        # Get the SMART attributes
        case ''${type} in
        sat) smartctl -A -d "''${type}" "''${disk}" | parse_smartctl_attributes "''${disk}" "''${type}" ;;
        sat+megaraid*) smartctl -A -d "''${type}" "''${disk}" | parse_smartctl_attributes "''${disk}" "''${type}" ;;
        scsi) smartctl -A -d "''${type}" "''${disk}" | parse_smartctl_scsi_attributes "''${disk}" "''${type}" ;;
        megaraid*) smartctl -A -d "''${type}" "''${disk}" | parse_smartctl_scsi_attributes "''${disk}" "''${type}" ;;
        nvme*) smartctl -A -d "''${type}" "''${disk}" | parse_smartctl_scsi_attributes "''${disk}" "''${type}" ;;
        *)
            (>&2 echo "disk type is not sat, scsi, nvme or megaraid but ''${type}")
          exit
          ;;
        esac
      done | format_output
  '';

  nvmeScript = pkgs.writeShellScript "node-exporter-nvme-metrics.sh" ''
      set -eu

      # Dependencies: nvme-cli, jq (packages)
      # Based on code from
      # - https://github.com/prometheus/node_exporter/blob/master/text_collector_examples/smartmon.sh
      # - https://github.com/prometheus/node_exporter/blob/master/text_collector_examples/mellanox_hca_temp
      # - https://github.com/vorlon/check_nvme/blob/master/check_nvme.sh
      #
      # Author: Henk <henk@wearespindle.com>

      # Check if we are root
      if [ "$EUID" -ne 0 ]; then
        echo "''${0##*/}: Please run as root!" >&2
        exit 1
      fi

      # Check if programs are installed
      if ! command -v nvme >/dev/null 2>&1; then
        echo "''${0##*/}: nvme is not installed. Aborting." >&2
        exit 1
      fi

      output_format_awk="$(
        cat <<'OUTPUTAWK'
      BEGIN { v = "" }
      v != $1 {
        print "# HELP nvme_" $1 " SMART metric " $1;
        if ($1 ~ /_total$/)
          print "# TYPE nvme_" $1 " counter";
        else
          print "# TYPE nvme_" $1 " gauge";
        v = $1
      }
      {print "nvme_" $0}
      OUTPUTAWK
      )"

      format_output() {
        sort | awk -F'{' "''${output_format_awk}"
      }

      # Get the nvme-cli version
      nvme_version="$(nvme version | awk '$1 == "nvme" {print $3}')"
      echo "nvmecli{version=\"''${nvme_version}\"} 1" | format_output

      # Get devices
      device_list="$(nvme list -o json | jq -r '.Devices | .[].DevicePath')"

      # Loop through the NVMe devices
      for device in ''${device_list}; do
        json_check="$(nvme smart-log -o json "''${device}")"
        disk="''${device##*/}"

        # The temperature value in JSON is in Kelvin, we want Celsius
        value_temperature="$(echo "$json_check" | jq '.temperature - 273')"
        echo "temperature_celsius{device=\"''${disk}\"} ''${value_temperature}"

        value_available_spare="$(echo "$json_check" | jq '.avail_spare / 100')"
        echo "available_spare_ratio{device=\"''${disk}\"} ''${value_available_spare}"

        value_available_spare_threshold="$(echo "$json_check" | jq '.spare_thresh / 100')"
        echo "available_spare_threshold_ratio{device=\"''${disk}\"} ''${value_available_spare_threshold}"

        value_percentage_used="$(echo "$json_check" | jq '.percent_used / 100')"
        echo "percentage_used_ratio{device=\"''${disk}\"} ''${value_percentage_used}"

        value_critical_warning="$(echo "$json_check" | jq '.critical_warning')"
        echo "critical_warning_total{device=\"''${disk}\"} ''${value_critical_warning}"

        value_media_errors="$(echo "$json_check" | jq '.media_errors')"
        echo "media_errors_total{device=\"''${disk}\"} ''${value_media_errors}"

        value_num_err_log_entries="$(echo "$json_check" | jq '.num_err_log_entries')"
        echo "num_err_log_entries_total{device=\"''${disk}\"} ''${value_num_err_log_entries}"

        value_power_cycles="$(echo "$json_check" | jq '.power_cycles')"
        echo "power_cycles_total{device=\"''${disk}\"} ''${value_power_cycles}"

        value_power_on_hours="$(echo "$json_check" | jq '.power_on_hours')"
        echo "power_on_hours_total{device=\"''${disk}\"} ''${value_power_on_hours}"

        value_controller_busy_time="$(echo "$json_check" | jq '.controller_busy_time')"
        echo "controller_busy_time_seconds{device=\"''${disk}\"} ''${value_controller_busy_time}"

        value_data_units_written="$(echo "$json_check" | jq '.data_units_written')"
        echo "data_units_written_total{device=\"''${disk}\"} ''${value_data_units_written}"

        value_data_units_read="$(echo "$json_check" | jq '.data_units_read')"
        echo "data_units_read_total{device=\"''${disk}\"} ''${value_data_units_read}"

        value_host_read_commands="$(echo "$json_check" | jq '.host_read_commands')"
        echo "host_read_commands_total{device=\"''${disk}\"} ''${value_host_read_commands}"

        value_host_write_commands="$(echo "$json_check" | jq '.host_write_commands')"
        echo "host_write_commands_total{device=\"''${disk}\"} ''${value_host_write_commands}"
      done | format_output
  '';

  # Not a shell script — an awk program. Invoked as `awk -f`.
  ipmitoolAwk = pkgs.writeText "node-exporter-ipmitool.awk" ''
      #
      # Converts output of `ipmitool sensor` to prometheus format.
      #
      # With GNU awk:
      #   ipmitool sensor | ./ipmitool > ipmitool.prom
      #
      # With BSD awk:
      #   ipmitool sensor | awk -f ./ipmitool > ipmitool.prom
      #

      function export(values, name) {
      	if (values["metric_count"] < 1) {
      		return
      	}
      	delete values["metric_count"]

      	printf("# HELP %s%s %s sensor reading from ipmitool\n", namespace, name, help[name]);
      	printf("# TYPE %s%s gauge\n", namespace, name);
      	for (sensor in values) {
      		printf("%s%s{sensor=\"%s\"} %f\n", namespace, name, sensor, values[sensor]);
      	}
      }

      # Fields are Bar separated, with space padding.
      BEGIN {
      	FS = "[ ]*[|][ ]*";
      	namespace = "node_ipmi_";

      	# Friendly description of the type of sensor for HELP.
      	help["temperature_celsius"] = "Temperature";
      	help["volts"] = "Voltage";
      	help["power_watts"] = "Power";
      	help["speed_rpm"] = "Fan";
      	help["status"] = "Chassis status";

      	temperature_celsius["metric_count"] = 0;
      	volts["metric_count"] = 0;
      	power_watts["metric_count"] = 0;
      	speed_rpm["metric_count"] = 0;
      	status["metric_count"] = 0;
      }

      # Not a valid line.
      {
      	if (NF < 3) {
      		next
      	}
      }

      # $2 is value field.
      $2 ~ /na/ {
      	next
      }

      # $3 is type field.
      $3 ~ /degrees C/ {
      	temperature_celsius[$1] = $2;
      	temperature_celsius["metric_count"]++;
      }

      $3 ~ /Volts/ {
      	volts[$1] = $2;
      	volts["metric_count"]++;
      }

      $3 ~ /Watts/ {
      	power_watts[$1] = $2;
      	power_watts["metric_count"]++;
      }

      $3 ~ /RPM/ {
      	speed_rpm[$1] = $2;
      	speed_rpm["metric_count"]++;
      }

      $3 ~ /discrete/ {
      	status[$1] = sprintf("%d", substr($2,3,2));
      	status["metric_count"]++;
      }

      END {
      	export(temperature_celsius, "temperature_celsius");
      	export(volts, "volts");
      	export(power_watts, "power_watts");
      	export(speed_rpm, "speed_rpm");
      	export(status, "status");
      }
  '';

  ##########################################################################
  # /usr/local/sbin/gir-sensor-log.sh, embedded verbatim.
  #
  # This is the BMC witness from the August lockup investigation: it polls
  # `ipmitool sdr` every 10s and appends a CSV row of the voltage rails and
  # the thermals to /var/log/gir-sensors/sensors-YYYYMMDD.csv. It exists
  # because SOC_VRM overtemp resets this platform with nothing logged to the
  # OS, so the last CSV row is sometimes the only evidence of what the
  # hardware was doing at the moment of a wedge.
  ##########################################################################
  sensorLogScript = pkgs.writeShellScript "gir-sensor-log.sh" ''
      # Managed by arm-witnesses.sh. Polls the BMC and appends a CSV row.
      set -u

      INTERVAL=''${SENSOR_INTERVAL:-10}
      LOGDIR=/var/log/gir-sensors

      # Sensor names exactly as the BMC reports them. Voltage rails first, then
      # the thermals that matter for this investigation: SOC_VRM runs hottest on
      # this board (76 C observed at baseline) and VRM overtemp resets the
      # platform with nothing logged to the OS.
      SENSORS=(
          "12V" "5VCC" "3.3VCC" "VDDCR" "Vp1ABCD" "Vp1EFGH" "5VSB" "3.3VSB" "SOCRUN"
          "CPU Temp" "System Temp" "Peripheral Temp"
          "CPU_VRM Temp" "SOC_VRM Temp" "VRMABCD Temp" "VRMEFGH Temp"
          "DIMMABCD Temp" "DIMMEFGH Temp"
          "FAN1" "PCH_FAN"
      )

      mkdir -p "$LOGDIR"

      header() {
          local h="timestamp"
          for s in "''${SENSORS[@]}"; do h="$h,$(printf '%s' "$s" | tr ' ' '_')"; done
          printf '%s,load1\n' "$h"
      }

      while :; do
          file="$LOGDIR/sensors-$(date +%Y%m%d).csv"
          [[ -f "$file" ]] || header > "$file"

          # name=value for every sensor, in one KCS sweep.
          #
          # ipmitool emits two shapes depending on subcommand and version:
          #   narrow  name | reading | status                        (NF==3)
          #   wide    name | id | status | entity | reading          (NF==5)
          # The reading is the LAST field in the wide form and the SECOND in the
          # narrow one. Do not just take "the last numeric field" -- in the wide
          # form the entity id (e.g. 32.0) is numeric too, and for a sensor
          # reading "No Reading" that entity id would be captured as the value.
          readings="$(ipmitool sdr 2>/dev/null | awk -F'|' '
              NF >= 3 {
                  name = $1
                  val  = (NF >= 5) ? $5 : $2
                  gsub(/^[ \t]+|[ \t]+$/, "", name)
                  gsub(/^[ \t]+|[ \t]+$/, "", val)
                  split(val, a, " ")
                  if (a[1] ~ /^-?[0-9.]+$/) print name "=" a[1]
              }')"

          row="$(date --iso-8601=seconds)"
          for s in "''${SENSORS[@]}"; do
              v="$(printf '%s\n' "$readings" | awk -F= -v k="$s" '$1==k {print $2; exit}')"
              row="$row,''${v:-}"
          done
          row="$row,$(awk '{print $1}' /proc/loadavg)"

          printf '%s\n' "$row" >> "$file"
          sleep "$INTERVAL"
      done
  '';

  # Common runtime for the oneshot collectors. `sponge` (moreutils) is what
  # makes each .prom file appear atomically instead of being read half-written
  # by the exporter mid-scrape; Ubuntu's units rely on it too.
  collectorPath = with pkgs; [
    coreutils
    findutils # smartmon.sh pipes its attribute list through `xargs`
    gawk
    gnugrep
    gnused
    moreutils
    util-linux
  ];
in
{
  ############################################################################
  ## The textfile directory itself.
  ##
  ## On Ubuntu the prometheus-node-exporter package ships it. Here it has to
  ## be declared, and it has to exist before any writer runs. nut.nix already
  ## defends itself with `install -d` in its own ExecStartPre; this rule is
  ## the module-level guarantee, since monitoring.nix owns the directory.
  ############################################################################
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus 0755 root root -"
    "d ${textfileDir} 0755 root root -"
    # gir-sensor-log's CSV directory. The script mkdir -p's it, but the unit
    # is Restart=always and a failure loop on a missing parent is noise.
    # TODO(ticket 18): these CSVs are never rotated on Ubuntu either — about
    # 8 MB/day at SENSOR_INTERVAL=10. /var/log is rpool/nixos/log, per-OS.
    "d /var/log/gir-sensors 0755 root root -"
  ];

  ############################################################################
  ## Prometheus node exporter.
  ##
  ## Ubuntu's live ExecStart, read from /etc/default/prometheus-node-exporter
  ## and confirmed against the running argv on 2026-09-19:
  ##
  ##   /usr/bin/prometheus-node-exporter \
  ##     --no-collector.filesystem \
  ##     --collector.vmstat.fields=^(oom_kill|pgpg|pswp|pg.*fault|pgsteal|\
  ##       pgscan|allocstall|pageoutrun|kswapd|compact_|thp_|workingset).*
  ##
  ## That is the WHOLE collector configuration: the default-enabled set, minus
  ## `filesystem`, with the vmstat field regexp widened. It is not a hand-
  ## picked list, so `enabledCollectors` stays empty and only the two
  ## deviations are expressed.
  ##
  ##   * `filesystem` is off because this box has ~160 ZFS datasets; the
  ##     collector stats every mount on every scrape and on a wedging pool
  ##     that is itself a way to hang the exporter. Keep it off.
  ##   * The vmstat fields beyond the upstream default — pgsteal, pgscan,
  ##     allocstall, pageoutrun, kswapd, compact_, thp_, workingset — are the
  ##     reclaim counters added during the memory-pressure investigation. They
  ##     are the series that show an ARC/reclaim storm building. Do not trim
  ##     them back to the default.
  ##
  ## Third flag, new on NixOS: the textfile directory. See the header.
  ############################################################################
  services.prometheus.exporters.node = {
    enable = true;

    # Debian's default and the live listener: 0.0.0.0:9100.
    listenAddress = "0.0.0.0";
    port = 9100;

    enabledCollectors = [ ];
    disabledCollectors = [ "filesystem" ];

    extraFlags = [
      "--collector.vmstat.fields=^(oom_kill|pgpg|pswp|pg.*fault|pgsteal|pgscan|allocstall|pageoutrun|kswapd|compact_|thp_|workingset).*"
      "--collector.textfile.directory=${textfileDir}"
    ];

    # Ubuntu has no host firewall; NixOS enables one by default. Nothing
    # scrapes :9100 today because ticket 05 drops the Prometheus server, so
    # the port stays closed rather than being opened for no consumer.
    # TODO(ticket 18): the monitoring rebuild has to open this (or scrape over
    # loopback/k3s) — it is the first thing that will look broken.
    openFirewall = false;
  };

  ############################################################################
  ## Textfile collectors.
  ##
  ## Ticket 05 counts SIX on the live host. Two of them — `nut.prom` and
  ## `nut_selftest.prom` — belong to nut.nix and are not repeated here (a
  ## third file, `nut_events.prom`, is nut.nix's symlink into this directory).
  ## Of the four Ubuntu ships, three are ported below.
  ##
  ## THE FOURTH, `apt`, IS DROPPED — the one deviation from ticket 05 in this
  ## module. `prometheus-node-exporter-apt.timer` runs Debian's apt.sh to
  ## export `apt_upgrades_pending` and `node_reboot_required`. Neither has any
  ## meaning on NixOS: there is no apt, and "reboot required" is a property of
  ## whether the booted system's store path equals the current one. Porting it
  ## would mean writing a different collector with the same metric names,
  ## which is worse than an honest gap.
  ## TODO(ticket 18): if channel-drift / reboot-required visibility is wanted,
  ## write a NixOS-shaped collector then. It is a new metric, not a port.
  ##
  ## Schedules are Ubuntu's, verbatim: 15 min for smartmon and nvme, 1 min for
  ## ipmitool, all with OnBootSec=0.
  ############################################################################

  systemd.services.prometheus-node-exporter-smartmon = {
    description = "Collect SMART metrics for prometheus-node-exporter";
    path = collectorPath ++ [ pkgs.smartmontools ];
    serviceConfig = {
      Type = "oneshot";
      # sponge writes its temp file in TMPDIR, so pointing TMPDIR at the
      # textfile directory keeps the final rename on the same filesystem and
      # therefore atomic. Ubuntu's unit does exactly this.
      Environment = "TMPDIR=${textfileDir}";
      ExecStart = "${pkgs.writeShellScript "run-smartmon-collector" ''
        ${smartmonScript} | sponge ${textfileDir}/smartmon.prom
      ''}";
    };
  };

  systemd.timers.prometheus-node-exporter-smartmon = {
    description = "Run smart metrics collection every 15 minutes";
    wantedBy = [ "timers.target" ];
    unitConfig = {
      # Ubuntu's conditions. NVMe is excluded upstream with a TODO asking
      # whether smartmon.sh returns usable metrics for it; the nvme collector
      # below covers NVMe properly, so leave it alone.
      ConditionPathExistsGlob = [
        "|/dev/sd*"
        "|/dev/hd*"
      ];
    };
    timerConfig = {
      OnBootSec = "0";
      OnUnitActiveSec = "15min";
    };
  };

  systemd.services.prometheus-node-exporter-nvme = {
    description = "Collect NVMe metrics for prometheus-node-exporter";
    path = collectorPath ++ [
      pkgs.nvme-cli
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      Environment = "TMPDIR=${textfileDir}";
      ExecStart = "${pkgs.writeShellScript "run-nvme-collector" ''
        ${nvmeScript} | sponge ${textfileDir}/nvme.prom
      ''}";
    };
  };

  systemd.timers.prometheus-node-exporter-nvme = {
    description = "Run NVMe metrics collection every 15 minutes";
    wantedBy = [ "timers.target" ];
    unitConfig.ConditionPathExistsGlob = "/dev/nvme*";
    timerConfig = {
      OnBootSec = "0";
      OnUnitActiveSec = "15min";
    };
  };

  systemd.services.prometheus-node-exporter-ipmitool-sensor = {
    description = "Collect ipmitool sensor metrics for prometheus-node-exporter";
    after = [ "systemd-modules-load.service" ];
    path = collectorPath ++ [ pkgs.ipmitool ];
    serviceConfig = {
      Type = "oneshot";
      Environment = "TMPDIR=${textfileDir}";
      ExecStart = "${pkgs.writeShellScript "run-ipmitool-sensor-collector" ''
        ipmitool sensor | awk -f ${ipmitoolAwk} | sponge ${textfileDir}/ipmitool_sensor.prom
      ''}";
    };
  };

  systemd.timers.prometheus-node-exporter-ipmitool-sensor = {
    description = "Run ipmitool sensor metrics collection every minute";
    wantedBy = [ "timers.target" ];
    after = [ "systemd-modules-load.service" ];
    # /sys/class/ipmi is populated by ipmi_si + ipmi_devintf, which
    # ipmievd.nix's boot.kernelModules loads.
    unitConfig.ConditionDirectoryNotEmpty = "/sys/class/ipmi";
    timerConfig = {
      OnBootSec = "0";
      OnUnitActiveSec = "1min";
    };
  };

  ############################################################################
  ## smartd.
  ##
  ## Ubuntu's entire /etc/smartd.conf, once comments are stripped, is one line:
  ##
  ##   DEVICESCAN -d removable -n standby -m myers@maski.org \
  ##              -M exec /usr/share/smartmontools/smartd-runner
  ##
  ## and /etc/default/smartmontools adds nothing (every line is commented).
  ## The running daemon is `/usr/sbin/smartd -n`.
  ##
  ## Translating it:
  ##   * DEVICESCAN                 -> autodetect = true, devices = []
  ##   * -d removable -n standby    -> defaults.autodetected
  ##   * -a                         -> added explicitly. smartd.conf(5): "-a is
  ##     the default for ATA devices. If none of these other Directives is
  ##     given, then -a is assumed." Ubuntu's line gives none of them, so it
  ##     is already running with -a; writing it out changes nothing and makes
  ##     the NixOS-generated config self-describing.
  ##   * -m ... -M exec ...         -> notifications.mail. The module generates
  ##     its own `-m <nomailer> -M exec <script>` pair; Debian's
  ##     smartd-runner has no NixOS equivalent, and the generated script does
  ##     the same job (mail the message plus a full `smartctl -a`).
  ##
  ## `notifications.mail.enable` defaults to
  ## `config.services.mail.sendmailSetuidWrapper != null`, i.e. false until
  ## postfix exists, so it is forced true here. ticket 05 kept Postfix and
  ## fixed /etc/aliases; smartd is the one daemon that never depended on that
  ## fix because it names a real address, and that stays true here.
  ##
  ## Ticket 07 item 18 is the load-bearing line: the -A/-s prefixes. Debian
  ## compiles them in (`--with-attributelog`, `--with-savestates`), so
  ## `smartd -n` alone writes /var/lib/smartmontools/{attrlog.*,smartd.*}.
  ## nixpkgs does not, so without these two flags smartd starts fine, reports
  ## fine, and silently stops maintaining the 86 MB of per-drive attribute
  ## history on the shared rpool/srv/smartmontools dataset — and loses the
  ## saved state that makes "this attribute CHANGED" detection work across
  ## restarts. THE TRAILING DOTS ARE PART OF THE PREFIX; dropping them writes
  ## `/var/lib/smartmontoolsattrlog.…`.
  ##
  ## storage.nix already gives this unit
  ## `RequiresMountsFor=/var/lib/smartmontools`, so it fails closed if the
  ## dataset is missing rather than writing into the root filesystem.
  ############################################################################
  services.smartd = {
    enable = true;
    autodetect = true;
    devices = [ ];

    extraOptions = [
      "-A /var/lib/smartmontools/attrlog."
      "-s /var/lib/smartmontools/smartd."
    ];

    defaults.monitored = "-a -d removable -n standby";
    defaults.autodetected = "-a -d removable -n standby";

    notifications = {
      mail = {
        enable = true;
        recipient = "myers@maski.org";
        sender = "root";
        # The default. Postfix provides it; ticket 05 keeps Postfix natively.
        mailer = "/run/wrappers/bin/sendmail";
      };
      # Ubuntu's smartd-runner only mails (10mail is the sole script in
      # /etc/smartmontools/run.d). No wall, and this box is headless.
      wall.enable = false;
      x11.enable = false;
      systembus-notify.enable = false;
      test = false;
    };
  };

  ############################################################################
  ## rasdaemon.
  ##
  ## Ubuntu: `/usr/sbin/rasdaemon -f -r` with EnvironmentFile
  ## /etc/default/rasdaemon. `-f` is --foreground (systemd's job here) and
  ## `-r` is --record, the sqlite3 event DB that `ras-mc-ctl --errors` reads.
  ## `hardware.rasdaemon.record` defaults to true and produces exactly that,
  ## with StateDirectory=rasdaemon (/var/lib/rasdaemon).
  ##
  ## NOTE: the DB is per-OS. It is not on ticket 07's shared manifest, so the
  ## NixOS side starts with an empty error history and Ubuntu's 2 years of
  ## corrected-error counts stay on Ubuntu. That is the right call for a
  ## soak — a spurious "new" CE burst is easier to reason about than a merged
  ## history — but it does mean `ras-mc-ctl --errors` will look empty on day
  ## one. Expected, not a fault.
  ##
  ## `-f`/`-r` aside, the only Ubuntu configuration is the CE page-isolation
  ## block in /etc/default/rasdaemon, carried verbatim below. All three values
  ## happen to equal rasdaemon's own upstream defaults, so this is
  ## documentation more than change.
  ############################################################################
  hardware.rasdaemon = {
    enable = true;
    record = true;
    config = ''
      # Carried from Ubuntu's /etc/default/rasdaemon (CE page isolation).
      PAGE_CE_REFRESH_CYCLE="24h"
      PAGE_CE_THRESHOLD="50"
      PAGE_CE_ACTION="soft"
    '';
  };

  # nixpkgs writes hardware.rasdaemon.config to /etc/sysconfig/rasdaemon but
  # its unit does not read it — upstream's own rasdaemon.service carries
  # `EnvironmentFile=-/etc/sysconfig/rasdaemon` and the NixOS module drops it,
  # so the PAGE_CE_* settings above would never reach the daemon. Re-added
  # here. The `-` prefix keeps this harmless if the file ever stops existing.
  # TODO(upstream): worth a nixpkgs PR against
  # nixos/modules/services/hardware/rasdaemon.nix.
  systemd.services.rasdaemon.serviceConfig.EnvironmentFile = "-/etc/sysconfig/rasdaemon";

  ############################################################################
  ## ZED — the ZFS Event Daemon.
  ##
  ## This is how a failing disk gets reported on this box. There is no
  ## Prometheus server any more (ticket 05), so ZED's mail IS the disk-failure
  ## alerting path until ticket 18 lands. Getting the mail settings wrong here
  ## means a dead drive in a raidz3 goes unnoticed until the second one dies.
  ##
  ## `services.zfs.zed` is always active when ZFS is on; only the settings are
  ## ours. Ubuntu's /etc/zfs/zed.d/zed.rc is mode 0600 and could not be read
  ## without root (TODO below). The values below come from its immediate
  ## predecessor, `zed.rc.bak-20260827-164128` (mode 0644, taken by the
  ## 2026-08-27 edit), diffed against the packaged `zed.rc.dpkg-dist`:
  ##
  ##   ZED_EMAIL_ADDR            "root"          -> "myers@maski.org"
  ##   ZED_EMAIL_PROG            (unset)         -> "mail"
  ##   ZED_NOTIFY_VERBOSE        (unset, 0)      -> 1
  ##   ZED_NOTIFY_INTERVAL_SECS  3600            (unchanged)
  ##   ZED_USE_ENCLOSURE_LEDS    1               (unchanged)
  ##   ZED_SYSLOG_SUBCLASS_EXCLUDE "history_event" (unchanged)
  ##
  ## TODO(collect): the current zed.rc is one byte larger than that backup and
  ## was written 2026-08-27 16:41. Read it with root before Window B and diff
  ## against the six settings below:
  ##   sudo diff /etc/zfs/zed.d/zed.rc.bak-20260827-164128 /etc/zfs/zed.d/zed.rc
  ## A one-byte delta is most likely a `0`->`1` or a whitespace change, but it
  ## is the alerting path, so confirm rather than assume.
  ############################################################################
  services.zfs.zed.settings = {
    ZED_EMAIL_ADDR = [ "myers@maski.org" ];

    # Ubuntu uses bare `mail`. Pinned to a store path so it does not depend on
    # ZED's PATH, which nixpkgs sets and which does not include mailutils.
    #
    # Left deliberately NOT as `enableMail`: that option forces ZED_EMAIL_PROG
    # to the sendmail setuid wrapper and evaluates to an error while no MTA
    # module is configured. The upstream default for this setting is
    # `mkIf enableMail (mkDefault ...)`, so an explicit value here wins either
    # way and does not conflict once postfix lands.
    ZED_EMAIL_PROG = "${pkgs.mailutils}/bin/mail";
    ZED_EMAIL_OPTS = "-s '@SUBJECT@' @ADDRESS@";

    # One mail per hour per (event, pool, vdev) triple. The default, kept.
    ZED_NOTIFY_INTERVAL_SECS = 3600;

    # Ubuntu's 2026-08-27 change: notify even when the event carries no error
    # counters. Without it, scrub-finish and resilver-finish notifications are
    # suppressed when they are clean — which is exactly the mail you want
    # after a 45-hour bank10 scrub.
    ZED_NOTIFY_VERBOSE = 1;

    # Drive the enclosure fault LEDs. The *-led.sh scripts are installed by
    # nixpkgs' zed.d set (statechange-led, vdev_attach-led, vdev_clear-led,
    # pool_import-led), same as Ubuntu.
    ZED_USE_ENCLOSURE_LEDS = 1;

    # `history_event` is every `zfs`/`zpool` command ever run. With sanoid
    # taking snapshots every 15 minutes across ~25 datasets, this is the
    # difference between a readable journal and a useless one.
    ZED_SYSLOG_SUBCLASS_EXCLUDE = "history_event";
  };

  ############################################################################
  ## gir-sensor-log.
  ##
  ## Ticket 05 lists this as "hand-written unit". Note there is NO TIMER on
  ## the host and none is created here: the Ubuntu unit is a Type=simple
  ## infinite loop with `Restart=always` and its own `sleep $SENSOR_INTERVAL`,
  ## which is what keeps a 10-second sample rate without 8,640 systemd
  ## activations a day. Transcribed as-is:
  ##
  ##   [Unit] Description=Log BMC voltage rails and temperatures to CSV
  ##          After=multi-user.target
  ##   [Service] Type=simple
  ##          Environment=SENSOR_INTERVAL=10
  ##          ExecStart=/usr/local/sbin/gir-sensor-log.sh
  ##          Restart=always  RestartSec=15
  ##          Nice=10  IOSchedulingClass=idle
  ##   [Install] WantedBy=multi-user.target
  ##
  ## Nice=10 + IOSchedulingClass=idle matter: this thing runs forever and must
  ## never be what makes the box slow. Keep them.
  ##
  ## It needs /dev/ipmi0, so it runs as root and waits for the device the same
  ## way ipmievd.nix does.
  ############################################################################
  systemd.services.gir-sensor-log = {
    description = "Log BMC voltage rails and temperatures to CSV";

    after = [
      "multi-user.target"
      "systemd-modules-load.service"
    ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      ipmitool
      coreutils
      gawk
    ];

    unitConfig.ConditionPathExists = "/dev/ipmi0";

    environment.SENSOR_INTERVAL = "10";

    serviceConfig = {
      Type = "simple";
      ExecStart = "${sensorLogScript}";
      Restart = "always";
      RestartSec = "15";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  ############################################################################
  ## Tools the above assume are present interactively, matching Ubuntu.
  ## (ipmitool itself is installed by ipmievd.nix; not repeated here.)
  ############################################################################
  environment.systemPackages = with pkgs; [
    smartmontools
    nvme-cli
    moreutils # sponge, for hand-running a collector
  ];
}
