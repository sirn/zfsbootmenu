#!/bin/bash
# store current kernel log level
read -r printk < /proc/sys/kernel/printk
printk=${printk:0:1}

# Set it to 0
echo 0 > /proc/sys/kernel/printk

# shellcheck disable=SC1091
test -f /lib/zfsbootmenu-lib.sh && source /lib/zfsbootmenu-lib.sh
# shellcheck disable=SC1091
test -f zfsbootmenu-lib.sh && source zfsbootmenu-lib.sh

echo "Loading boot menu ..."
TERM=linux
# shellcheck disable=SC2034
CLEAR_SCREEN=0
tput reset

OLDIFS="$IFS"

export FZF_DEFAULT_OPTS="--layout=reverse-list --cycle \
  --inline-info --tac"

BASE="$( mktemp -d /tmp/zfs.XXXX )"

# I should probably just modprobe zfs right off the bat
modprobe zfs 2>/dev/null
udevadm settle

# try to set console options for display and interaction
# this is sometimes run as an initqueue hook, but cannot be guaranteed
test -x /lib/udev/console_init -a -c /dev/tty0 && /lib/udev/console_init tty0

# Find all pools by name that are listed as ONLINE, then import them
response="$( find_online_pools )"
ret=$?

if [ $ret -gt 0 ]; then
  import_success=0
  # shellcheck disable=SC2162
  IFS=',' read -a zpools <<<"${response}"
  for pool in "${zpools[@]}"; do
    import_pool "${pool}"
    ret=$?
    if [ $ret -eq 0 ]; then
      import_success=1
    fi
  done
  if [ $import_success -ne 1 ]; then
    emergency_shell "unable to successfully import a pool"
  fi
else
  # shellcheck disable=SC2154,SC2086
  if [ ${die_on_import_failure} -eq 1 ]; then
    emergency_shell "no pools available to import"
    exit;
  fi
fi

# Prefer a specific pool when checking for a bootfs value
# shellcheck disable=SC2154
if [ "${root}" = "zfsbootmenu" ]; then
  pool=
else
  pool="${root}"
fi

# Attempt to find the bootfs property
# shellcheck disable=SC2086
datasets="$( zpool list -H -o bootfs ${pool} )"
while read -r line; do
  if [ "${line}" = "-" ]; then
    BOOTFS=
  else
    BOOTFS="${line}"
    break
  fi
done <<<"${datasets}"

# If BOOTFS is not empty display the fast boot menu
fast_boot=0
if [[ -n "${BOOTFS}" ]]; then
  # Draw a countdown menu
  # shellcheck disable=SC2154
  if [[ ${menu_timeout} -gt 0 ]]; then
    # Clear the screen
    tput civis
    HEIGHT=$(tput lines)
    WIDTH=$(tput cols)
    tput clear

    # Draw the line centered on the screen
    mes="[ENTER] to boot"
    x=$(( (HEIGHT - 0) / 2 ))
    y=$(( (WIDTH - ${#mes}) / 2 ))
    tput cup $x $y
    echo -n "${mes}"

    # Draw the line centered on the screen
    mes="[ESC] boot menu"
    x=$(( x + 1 ))
    y=$(( (WIDTH - ${#mes}) / 2 ))
    tput cup $x $y
    echo -n "${mes}"

    x=$(( x + 1 ))
    tput cup $x $y

    IFS=''
    for (( i=menu_timeout; i>0; i--)); do
      mes="$( printf 'Booting %s in %0.2d seconds' "${BOOTFS}" "${i}" )"
      y=$(( (WIDTH - ${#mes}) / 2 ))
      tput cup $x $y
      echo -ne "${mes}"

      # Wait 1 second for input
      # shellcheck disable=SC2162
      read -s -N 1 -t 1 key
      # Escape key
      if [ "$key" = $'\e' ]; then
        break
      # Enter key
      elif [ "$key" = $'\x0a' ]; then
        fast_boot=1
        break
      fi
    done
    IFS="${OLDIFS}"
  elif [[ ${menu_timeout} -eq 0 ]]; then
    # Bypass the menu, immediately boot $BOOTFS
    fast_boot=1
  else
    # Make sure we bypass the other fastboot check
    i=1
  fi

  # Boot up if we timed out, or if the enter key was pressed
  # shellcheck disable=SC2034
  if [[ ${fast_boot} -eq 1 || $i -eq 0 ]]; then
    if ! key_wrapper "${BOOTFS}" ; then
      emergency_shell "unable to load required key for ${BOOTFS}"
    elif output=$( find_be_kernels "${BOOTFS}" ); then
      # Automatically select a kernel and boot it
      kexec_kernel "$( select_kernel "${BOOTFS}" )"
    fi
  fi
fi

##
# No automatic boot has taken place
# Look for BEs with kernels and present a selection menu
##

# Clear screen before a possible password prompt
tput clear

BE_SELECTED=0

while true; do
  tput civis

  if [ ${BE_SELECTED} -eq 0 ]; then
    # Populate the BE list, load any keys as necessary
    populate_be_list "${BASE}/env"
    if [ ! -f "${BASE}/env" ]; then
      emergency_shell "no boot environments with kernels found"
      continue
    fi

    bootenv="$( draw_be "${BASE}/env" )"
    ret=$?

    # key press
    # bootenv
    # shellcheck disable=SC2162
    IFS=, read key selected_be <<<"${bootenv}"

    if [ $ret -eq 0 ]; then
      BE_SELECTED=1
    fi
  fi

  if [ ${BE_SELECTED} -eq 1 ]; then
    # Either a boot will proceed, or the menu will be drawn fresh
    BE_SELECTED=0

    case "${key}" in
      "enter")
        if ! kexec_kernel "$( select_kernel "${selected_be}" )"; then
          continue
        fi
        exit
        ;;
      "alt-k")
        selection="$( draw_kernel "${selected_be}" )"
        ret=$?

        # Only continue if a selection was made
        [ $ret -eq 0 ] || continue

        # shellcheck disable=SC2162
        IFS=, read subkey selected_kernel <<< "${selection}"

        case "${subkey}" in
          "enter")
            if ! kexec_kernel "${selected_kernel}"; then
              continue
            fi
            exit
            ;;
          "alt-d")
            # shellcheck disable=SC2034
            IFS=' ' read -r fs kpath initrd <<< "${selected_kernel}"
            set_default_kernel "${fs}" "${kpath}"
            ;;
        esac
        ;;
      "alt-d")
        set_default_env "${selected_be}"
        ;;
      "alt-s")
        selection="$( draw_snapshots "${selected_be}" )"
        ret=$?

        # Only continue if a selection was made
        [ $ret -eq 0 ] || continue

        # shellcheck disable=SC2162
        IFS=, read subkey selected_snap <<< "${selection}"

        # Parent of the selected dataset, must be nonempty
        parent_ds="${selected_snap%/*}"
        [ -n "$parent_ds" ] || continue

        tput clear
        tput cnorm

        case "${subkey}" in
          "alt-d")
            draw_diff "${selected_snap}"
            BE_SELECTED=1
            continue
          ;;
        esac

        # Strip parent datasets
        pre_populated="${selected_snap##*/}"
        # Strip snapshot name and append NEW
        pre_populated="${pre_populated%%@*}_NEW"

        while true;
        do
          echo -e "\nNew boot environment name"
          read -r -e -i "${pre_populated}" -p "> " new_be
          if [ -n "${new_be}" ] ; then
            valid_name=$( echo "${new_be}" | tr -c -d 'a-zA-Z0-9-_.,' )
            # If the entered name is invalid, set the prompt to the valid form of the name
            if [[ "${new_be}" != "${valid_name}" ]]; then
              echo "${new_be} is invalid, ${valid_name} can be used"
              pre_populated="${valid_name}"
            elif zfs list -H -o name "${parent_ds}/${new_be}" >/dev/null 2>&1; then
              echo "${new_be} already exists, please use another name"
              pre_populated="${new_be}"
            else
              break
            fi
          fi
        done

        # Must have a nonempty name for the new BE
        [ -n "${new_be}" ] || continue

        clone_target="${parent_ds}/${new_be}"
        be_size="$( zfs list -H -o refer "${selected_snap}" )"
        echo -e "\nCreating ${clone_target} from ${selected_snap} (${be_size})"

        case "${subkey}" in
          "enter")
            duplicate_snapshot "${selected_snap}" "${clone_target}"
            ;;
          "alt-x")
            clone_snapshot "${selected_snap}" "${clone_target}"
            ;;
          "alt-c")
            clone_snapshot "${selected_snap}" "${clone_target}" "nopromote"
            ;;
        esac
        ;;
      "alt-r")
        emergency_shell "alt-r invoked"
        ;;
      "alt-c")
        tput clear
        tput cnorm

        echo ""
        zfsbootmenu-preview.sh "${BASE}" "${selected_be}" "${BOOTFS}"

        if [ -f "${BASE}/default_args" ]
        then
          ARGS="${BASE}/default_args"
        else
          ARGS="${BASE}/${selected_be}/default_args"
        fi

        while IFS= read -r line
        do
          def_args="${line}"
        done < "${ARGS}"
        echo -e "\nNew kernel command line"
        read -r -e -i "${def_args}" -p "> " cmdline
        if [ -n "${cmdline}" ] ; then
          echo "${cmdline}" > "${BASE}/default_args"
        fi
        ;;
    esac
  fi
done
