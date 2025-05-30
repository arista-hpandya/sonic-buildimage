#!/bin/bash
#
# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
declare -A rshim2dpu

command_name="sonic-bfb-installer.sh"
usage(){
    echo "Syntax: $command_name -b|--bfb <BFB_Image_Path> --rshim|-r <rshim1,..rshimN> --dpu|-d <dpu1,..dpuN> --verbose|-v --config|-c <Options> --help|-h"
    echo "Arguments:"
    echo "-b|--bfb		Provide custom path for bfb image"
    echo "-r|--rshim		Install only on DPUs connected to rshim interfaces provided, mention all if installation is required on all connected DPUs"
    echo "-d|--dpu		Install on specified DPUs, mention all if installation is required on all connected DPUs"
    echo "-v|--verbose		Verbose installation result output"
    echo "-c|--config		Config file"
    echo "-h|--help		Help"
}
WORK_DIR=`mktemp -d -p "$DIR"`

wait_for_rshim_boot() {
    local -r rshim=$1
    local timeout=10
    
    while [ ! -e "/dev/${rshim}/boot" ] && [ $timeout -gt 0 ]; do
        sleep 1
        ((timeout--))
    done

    if [ ! -e "/dev/${rshim}/boot" ]; then
        echo "$rshim: Error: Boot file did not appear after 10 seconds"
        return 1
    fi
    return 0
}

remove_pci_device() {
    local -r rshim=$1
    local -r dpu=$2
    
    # Get bus_id and rshim_bus_id for this DPU
    local bus_id=$(dpumap.sh dpu2pcie $dpu)
    local rshim_bus_id=$(dpumap.sh rshim2pcie $rshim)

    # Check if both bus_id and rshim_bus_id devices exist
    if [ -n "$bus_id" ] && [ -n "$rshim_bus_id" ]; then
        if lspci -D | grep -q "$bus_id" && lspci -D | grep -q "$rshim_bus_id"; then
            echo "$rshim: Removing PCI device $bus_id"
            echo 1 > /sys/bus/pci/devices/$bus_id/remove
        fi
    fi
}

monitor_installation() {
    local -r rid=$1
    local -r pid=$2
    local -r total_time=$3
    local elapsed=0
    
    # Random interval between 3-10 seconds for progress updates
    local interval=$(($RANDOM%(10-3+1)+3))
    
    while kill -0 $pid 2>/dev/null; do
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -ne "\r$rid: Installing... $elapsed/$total_time seconds elapsed"
        if [ $elapsed -ge $total_time ]; then
            break
        fi
    done
    echo
}

bfb_install_call() {
    local -r rshim=$1
    local -r dpu=$2 
    local -r bfb=$3
    local -r appendix=$4
    local -r rid=${rshim#rshim}
    local -r result_file=$(mktemp "${WORK_DIR}/result_file.XXXXX")
    local -r timeout_secs=1200
    
    # Start rshim service and ensure it's stopped on exit
    systemctl start rshim@${rid}.service
    trap "systemctl stop rshim@${rid}.service" EXIT

    # Wait for boot file and remove PCI device
    if ! wait_for_rshim_boot "$rshim"; then
        exit 1
    fi
    remove_pci_device "$rshim" "$dpu"

    # Construct bfb-install command
    local cmd="timeout ${timeout_secs}s bfb-install -b $bfb -r $rshim"
    if [ -n "$appendix" ]; then
        cmd="$cmd -c $appendix"
    fi
    echo "Installing bfb image on DPU connected to $rshim using $cmd"

    # Run installation with progress monitoring
    trap 'kill_ch_procs' SIGINT SIGTERM SIGHUP
    eval "$cmd" > >(while IFS= read -r line; do echo "$rid: $line"; done >> "$result_file") 2>&1 &
    local cmd_pid=$!

    monitor_installation "$rid" $cmd_pid $timeout_secs

    # Check installation result
    wait $cmd_pid
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        echo "$rid: Error: Installation failed on connected DPU!"
    else
        echo "$rid: Installation Successful"
    fi

    # Show detailed output if verbose or error
    if [ $exit_status -ne 0 ] || [ $verbose = true ]; then
        cat "$result_file"
    fi

    # Stop rshim service and reset DPU
    systemctl stop rshim@${rid}.service
    echo "$rid: Resetting DPU $dpu"

    local reset_cmd="dpuctl dpu-reset --force $dpu"
    if [[ $verbose == true ]]; then
        reset_cmd="$reset_cmd -v"
    fi
    eval $reset_cmd
}

file_cleanup(){
    rm -rf "$WORK_DIR"
}

is_url() {
    local link=$1
    if [[ $link =~ https?:// ]]; then 
        echo "Detected URL. Downloading file"
        filename="${WORK_DIR}/sonic-nvidia-bluefield.bfb"
        curl -L -o "$filename" "$link"
        res=$?
        if test "$res" != "0"; then
            echo "the curl command failed with: $res"
            exit 1
        fi
        bfb="$filename"
        echo "bfb path changed to $bfb"
    fi
}

validate_rshim(){
    local provided_list=("$@")
    for item1 in "${provided_list[@]}"; do
        local found=0
        for item2 in "${dev_names_det[@]}"; do
            if [[ "$item1" = "$item2" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "$item1 is not detected! Please provide proper rshim interface list!"
            exit 1
        fi
    done
}

get_mapping(){
    local provided_list=("$@")

    for item1 in "${provided_list[@]}"; do
        var=$(dpumap.sh rshim2dpu $item1)
        if [ $? -ne 0 ]; then
            echo "$item1 does not have a valid dpu mapping!"
            exit 1
        fi
        rshim2dpu["$item1"]="$var"
    done
}

validate_dpus(){
    local provided_list=("$@")
    for item1 in "${provided_list[@]}"; do
        var=$(dpumap.sh dpu2rshim $item1)
        if [ $? -ne 0 ]; then
            echo "$item1 does not have a valid rshim mapping!"
            exit 1
        fi
        rshim2dpu["$var"]="$item1"
        dev_names+=("$var")
    done
}
check_for_root(){
    if [ "$EUID" -ne 0 ]
        then echo "Please run the script in sudo mode"
        exit
    fi
}

detect_rshims_from_pci(){
    # Get list of supported DPUs from dpumap.sh
    local dpu_list=$(dpumap.sh listdpus 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$dpu_list" ]; then
        echo "No supported DPUs found"
        return 1
    fi

    # For each DPU, check if its PCI exists and get corresponding rshim
    local detected_rshims=()
    while read -r dpu; do
        local bus_info=$(dpumap.sh dpu2pcie "$dpu" 2>/dev/null)
        if [ $? -eq 0 ] && [ ! -z "$bus_info" ] && [ -e "/sys/bus/pci/devices/$bus_info" ]; then
            local rshim=$(dpumap.sh dpu2rshim "$dpu" 2>/dev/null)
            if [ $? -eq 0 ] && [ ! -z "$rshim" ]; then
                detected_rshims+=("$rshim")
            fi
        fi
    done <<< "$dpu_list"

    if [ ${#detected_rshims[@]} -eq 0 ]; then
        echo "No rshim devices detected"
        return 1
    fi

    # Return unique sorted list of detected rshim devices
    printf '%s\n' "${detected_rshims[@]}" | sort -u
    return 0
}

main() {
    check_for_root

    # Parse command line arguments
    local config= bfb= rshim_dev= dpus= verbose=false
    parse_arguments "$@"

    # Validate BFB image
    if [ -z "$bfb" ]; then
        echo "Error: bfb image is not provided."
        usage
        exit 1
    fi
    is_url "$bfb"

    trap "file_cleanup" EXIT

    # Detect available rshim interfaces
    local dev_names_det=($(detect_rshims_from_pci))
    if [ "${#dev_names_det[@]}" -eq 0 ]; then
        echo "No rshim interfaces detected! Make sure to run the $command_name script from the host device/switch!"
        exit 1
    fi

    # Handle rshim/dpu selection
    local dev_names=()
    if [ -z "$rshim_dev" ]; then
        if [ -z "$dpus" ]; then
            echo "No rshim interfaces provided!"
            usage
            exit 1
        fi
        if [ "$dpus" = "all" ]; then
            rshim_dev="all"
        else
            IFS=',' read -ra dpu_names <<< "$dpus"
            validate_dpus "${dpu_names[@]}"
        fi
    fi

    if [ "$rshim_dev" = "all" ]; then
        dev_names=("${dev_names_det[@]}")
        echo "${#dev_names_det[@]} rshim interfaces detected:"
        echo "${dev_names_det[@]}"
    else
        if [ ${#dev_names[@]} -eq 0 ]; then
            IFS=',' read -ra dev_names <<< "$rshim_dev"
        fi
        validate_rshim "${dev_names[@]}"
    fi

    if [ ${#rshim2dpu[@]} -eq 0 ]; then
        get_mapping "${dev_names[@]}"
    fi

    # Sort devices and handle config files
    local sorted_devs=($(printf '%s\n' "${dev_names[@]}" | sort))
    local arr=()
    
    if [ -n "$config" ]; then
        echo "Using ${config} file/s"
        if [[ "$config" == *","* ]]; then
            IFS=',' read -r -a arr <<< "$config"
        else
            arr=("$config")
            for ((i=1; i<${#dev_names[@]}; i++)); do
                arr+=("$config")
            done
        fi

        validate_config_files "${sorted_devs[@]}" "${arr[@]}"
    fi

    # Install BFB on each device
    trap 'kill_ch_procs' SIGINT SIGTERM SIGHUP
    
    for i in "${!sorted_devs[@]}"; do
        rshim_name=${sorted_devs[$i]}
        dpu_name=${rshim2dpu[$rshim_name]}
        bfb_install_call "$rshim_name" "$dpu_name" "$bfb" "${arr[$i]}" &
    done
    wait
}

# Helper function to parse command line arguments
parse_arguments() {
    while [ "$1" != "--" ] && [ -n "$1" ]; do
        case $1 in
            --help|-h)
                usage
                exit 0
                ;;
            --bfb|-b)
                shift
                bfb=$1
                ;;
            --rshim|-r)
                shift
                rshim_dev=$1
                ;;
            --dpu|-d)
                shift
                dpus=$1
                ;;
            --config|-c)
                shift
                config=$1
                ;;
            --verbose|-v)
                verbose=true
                ;;
        esac
        shift
    done
}

# Helper function to validate config files
validate_config_files() {
    local -a sorted_devs=("${@:1:${#sorted_devs[@]}}")
    local -a arr=("${@:$((${#sorted_devs[@]}+1))}")

    if [ ${#arr[@]} -ne ${#sorted_devs[@]} ]; then
        echo "Length of config file list does not match the devices selected: ${sorted_devs[*]} and ${arr[*]}"
        exit 1
    fi

    for config_file in "${arr[@]}"; do
        if [ ! -f "$config_file" ]; then
            echo "Config provided $config_file is not a file! Please check"
            exit 1
        fi
    done
}

kill_all_descendant_procs() {
    local pid="$1"
    local self_kill="${2:-false}"
    if children="$(pgrep -P "$pid")"; then
        for child in $children; do
            kill_all_descendant_procs "$child" true
        done
    fi
    if [[ "$self_kill" == true ]]; then
        kill -9 "$pid" > /dev/null 2>&1
    fi
}

kill_ch_procs(){
    echo ""
    echo "Installation Interrupted.. killing All child procs"
    kill_all_descendant_procs $$
}
appendix=
verbose=false
main "$@"

