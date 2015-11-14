#set -x

############### CONFIG ###############
WORKDIR=/tmp
SOURCE_NAME="tb-oapi"
CLONE_NAME="kopia"
CLONE_DATASTORE="datastore1"
VM_CLONE_DIR=/vmfs/volumes/${CLONE_DATASTORE}/${CLONE_NAME}
LOG_TO_STDOUT=1
LOG_LEVEL=debug
DISK_CLONE_FORMAT=thin
SNAPSHOT_TIMEOUT=3
############### CONFIG ###############
logger() {
    LOG_TYPE=$1
    MSG=$2

    if [[ "${LOG_LEVEL}" == "debug" ]] && [[ "${LOG_TYPE}" == "debug" ]] || [[ "${LOG_TYPE}" == "info" ]] || [[ "${LOG_TYPE}" == "dryrun" ]]; then
        TIME=$(date +%F" "%H:%M:%S)
        if [[ "${LOG_TO_STDOUT}" -eq 1 ]] ; then
            echo -e "${TIME} -- ${LOG_TYPE}: ${MSG}"
        fi

        if [[ -n "${LOG_OUTPUT}" ]] ; then
            echo -e "${TIME} -- ${LOG_TYPE}: ${MSG}" >> "${LOG_OUTPUT}"
        fi

    fi
}
startTimer() {
    START_TIME=$(date)
    S_TIME=$(date +%s)
}

endTimer() {
    END_TIME=$(date)
    E_TIME=$(date +%s)
    DURATION=$(echo $((E_TIME - S_TIME)))

    #calculate overall completion time
    if [[ ${DURATION} -le 60 ]] ; then
        logger "info" "Duration: ${DURATION} Seconds"
    else
        logger "info" "Duration: $(awk 'BEGIN{ printf "%.2f\n", '${DURATION}'/60}') Minutes"
    fi
}

getVMDKs() {
    #get all VMDKs listed in .vmx file
    VMDKS_FOUND=$(grep -iE '(^scsi|^ide)' "${VMX_PATH}" | grep -i fileName | awk -F " " '{print $1}')

    TMP_IFS=${IFS}
    IFS=${ORIG_IFS}
    #loop through each disk and verify that it's currently present and create array of valid VMDKS
    for DISK in ${VMDKS_FOUND}; do
        #extract the SCSI ID and use it to check for valid vmdk disk
        SCSI_ID=$(echo ${DISK%%.*})
        grep -i "^${SCSI_ID}.present" "${VMX_PATH}" | grep -i "true" > /dev/null 2>&1

        #if valid, then we use the vmdk file
        if [[ $? -eq 0 ]]; then
            #verify disk is not independent
            grep -i "^${SCSI_ID}.mode" "${VMX_PATH}" | grep -i "independent" > /dev/null 2>&1 
            if [[ $? -eq 1 ]]; then
                grep -i "^${SCSI_ID}.deviceType" "${VMX_PATH}" | grep -i "scsi-hardDisk" > /dev/null 2>&1

                #if we find the device type is of scsi-disk, then proceed
                if [[ $? -eq 0 ]]; then
                    DISK=$(grep -i "^${SCSI_ID}.fileName" "${VMX_PATH}" | awk -F "\"" '{print $2}')
                    echo "${DISK}" | grep "\/vmfs\/volumes" > /dev/null 2>&1

                    if [[ $? -eq 0 ]]; then
                        DISK_SIZE_IN_SECTORS=$(cat "${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                    else
                        DISK_SIZE_IN_SECTORS=$(cat "${VMX_DIR}/${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                    fi

                    DISK_SIZE=$(echo "${DISK_SIZE_IN_SECTORS}" | awk '{printf "%.0f\n",$1*512/1024/1024/1024}')
                    VMDKS="${DISK}###${DISK_SIZE}:${VMDKS}"
                    TOTAL_VM_SIZE=$((TOTAL_VM_SIZE+DISK_SIZE))
                else
                    #if the deviceType is NULL for IDE which it is, thanks for the inconsistency VMware
                    #we'll do one more level of verification by checking to see if an ext. of .vmdk exists
                    #since we can not rely on the deviceType showing "ide-hardDisk"
                    grep -i "^${SCSI_ID}.fileName" "${VMX_PATH}" | grep -i ".vmdk" > /dev/null 2>&1

                    if [[ $? -eq 0 ]]; then
                        DISK=$(grep -i "^${SCSI_ID}.fileName" "${VMX_PATH}" | awk -F "\"" '{print $2}')
                        echo "${DISK}" | grep "\/vmfs\/volumes" > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            DISK_SIZE_IN_SECTORS=$(cat "${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                        else
                            DISK_SIZE_IN_SECTORS=$(cat "${VMX_DIR}/${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                        fi
                        DISK_SIZE=$(echo "${DISK_SIZE_IN_SECTORS}" | awk '{printf "%.0f\n",$1*512/1024/1024/1024}')
                        VMDKS="${DISK}###${DISK_SIZE}:${VMDKS}"
                        TOTAL_VM_SIZE=$((TOTAL_VM_SIZE_IN+DISK_SIZE))
                   fi
                fi

            else
                #independent disks are not affected by snapshots, hence they can not be backed up
                DISK=$(grep -i "^${SCSI_ID}.fileName" "${VMX_PATH}" | awk -F "\"" '{print $2}')
                echo "${DISK}" | grep "\/vmfs\/volumes" > /dev/null 2>&1
                if [[ $? -eq 0 ]]; then
                    DISK_SIZE_IN_SECTORS=$(cat "${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                else
                    DISK_SIZE_IN_SECTORS=$(cat "${VMX_DIR}/${DISK}" | grep "VMFS" | grep ".vmdk" | awk '{print $2}')
                fi
                DISK_SIZE=$(echo "${DISK_SIZE_IN_SECTORS}" | awk '{printf "%.0f\n",$1*512/1024/1024/1024}')
                INDEP_VMDKS="${DISK}###${DISK_SIZE}:${INDEP_VMDKS}"
            fi
        fi
    done
    IFS=${TMP_IFS}
    logger "debug" "getVMDKs() - ${VMDKS}"
}

### init ##
init() {
    # ensure root user is running the script
    if [ ! $(env | grep -e "^USER=" | awk -F = '{print $2}') == "root" ]; then
        logger "info" "This script needs to be executed by \"root\"!"
        echo "ERROR: This script needs to be executed by \"root\"!"
        exit 1
    fi
    
    if [[ -f /usr/bin/vmware-vim-cmd ]]; then
        VMWARE_CMD=/usr/bin/vmware-vim-cmd
        VMKFSTOOLS_CMD=/usr/sbin/vmkfstools
    elif [[ -f /bin/vim-cmd ]]; then
        VMWARE_CMD=/bin/vim-cmd
        VMKFSTOOLS_CMD=/sbin/vmkfstools
    else
        logger "info" "ERROR: Unable to locate *vimsh*! You're not running ESX(i) 3.5+, 4.x+ or 5.0!"
        echo "ERROR: Unable to locate *vimsh*! You're not running ESX(i) 3.5+, 4.x+ or 5.0!"
        exit 1
    fi
    
    ESX_VERSION=$(vmware -v | awk '{print $3}')
    ESX_RELEASE=$(uname -r)
    
    case "${ESX_VERSION}" in
        5.0.0|5.1.0|5.5.0)    VER=5; break;;
        4.0.0|4.1.0)          VER=4; break;;
        3.5.0|3i)             VER=3; break;;
        *)              echo "You're not running ESX(i) 3.5, 4.x, 5.x!"; exit 1; break;;
    esac    

    NEW_VIMCMD_SNAPSHOT="no"
    ${VMWARE_CMD} vmsvc/snapshot.remove 2>&1 | grep -q "snapshotId"
    [[ $? -eq 0 ]] && NEW_VIMCMD_SNAPSHOT="yes"

    #if no logfile then provide default logfile in /tmp
    if [[ -z "${LOG_OUTPUT}" ]] ; then
        LOG_OUTPUT="/dev/console"
        echo "Logging output to \"${LOG_OUTPUT}\" ..."
    else
      touch "${LOG_OUTPUT}"
    fi
    # REDIRECT is used by the "tail" trick, use REDIRECT=/dev/null to redirect vmkfstool to STDOUT only
    if [[ "${LOG_TO_STDOUT}" -eq 1 ]] ; then
      REDIRECT="/dev/null"
    else
      REDIRECT=${LOG_OUTPUT}
    fi
}

### MAIN
main() {
    VM_INPUT=${WORKDIR}/vms_list
    ${VMWARE_CMD} vmsvc/getallvms | sed 's/[[:blank:]]\{3,\}/   /g' | fgrep "[" | fgrep "vmx-" | fgrep ".vmx" | fgrep "/" | awk -F'   ' '{print "\""$1"\";\""$2"\";\""$3"\""}' |  sed 's/\] /\]\";\"/g' > ${WORKDIR}/vms_list
    ORIG_IFS=${IFS}
    IFS='
'

    grep -q "${SOURCE_NAME}" ${VM_INPUT} > /dev/null 2>&1;
    if [[ $? -eq 0 ]]; then
      VM_NAME="${SOURCE_NAME}"
      VM_ID=$(grep -E \""${VM_NAME}\"" ${WORKDIR}/vms_list | awk -F ";" '{print $1}' | sed 's/"//g')               
      VMFS_VOLUME=$(grep -E "\"${VM_NAME}\"" ${WORKDIR}/vms_list | awk -F ";" '{print $3}' | sed 's/\[//;s/\]//;s/"//g')
      VMX_CONF=$(grep -E "\"${VM_NAME}\"" ${WORKDIR}/vms_list | awk -F ";" '{print $4}' | sed 's/\[//;s/\]//;s/"//g')
      VMX_PATH="/vmfs/volumes/${VMFS_VOLUME}/${VMX_CONF}"
      VMX_DIR=$(dirname "${VMX_PATH}")
  
      if [[ -f "${VMX_PATH}" ]] && [[ ! -z "${VMX_PATH}" ]]; then
        logger "info" "FOUND SOURCE ${VM_NAME}"
                
        ORGINAL_VM_POWER_STATE=$(${VMWARE_CMD} vmsvc/power.getstate ${VM_ID} | tail -1)
        CONTINUE_TO_BACKUP=1

        IFS="${OLD_IFS}"
        VMDKS=""
        INDEP_VMDKS=""

        getVMDKs
        
        OLD_IFS="${IFS}"
        IFS=":"
        for j in ${VMDKS}; do
            J_VMDK=$(echo "${j}" | awk -F "###" '{print $1}')
            J_VMDK_SIZE=$(echo "${j}" | awk -F "###" '{print $2}')
            logger "debug" "\t${J_VMDK}\t${J_VMDK_SIZE} GB"
        done
  
        HAS_INDEPENDENT_DISKS=0
        logger "debug" "INDEPENDENT VMDK(s): "
        for k in ${INDEP_VMDKS}; do
            HAS_INDEPENDENT_DISKS=1
            K_VMDK=$(echo "${k}" | awk -F "###" '{print $1}')
            K_VMDK_SIZE=$(echo "${k}" | awk -F "###" '{print $2}')
            logger "debug" "\t${K_VMDK}\t${K_VMDK_SIZE} GB"
        done
  
  
        logger "debug" "TOTAL_VM_SIZE_TO_CLONE: ${TOTAL_VM_SIZE} GB"
        if [[ ${HAS_INDEPENDENT_DISKS} -eq 1 ]] ; then
            logger "debug" "Snapshots can not be taken for indepdenent disks!"
            logger "info" "THIS VIRTUAL MACHINE WILL NOT BE CLONED!"
            CONTINUE_TO_BACKUP=0
        fi

        ls "${VMX_DIR}" | grep -q "\-delta\.vmdk" > /dev/null 2>&1;
        if [[ $? -eq 0 ]]; then            
            logger "info" "Snapshots found for this VM, please commit all snapshots before continuing!"
            logger "info" "THIS VIRTUAL MACHINE WILL NOT BE CLONED DUE TO EXISTING SNAPSHOTS!"
            CONTINUE_TO_BACKUP=0
        fi

        if [[ ${TOTAL_VM_SIZE} -eq 0 ]] ; then
            logger "debug" "THIS VIRTUAL MACHINE WILL NOT BE CLONED DUE TO EMPTY VMDK LIST!"
            CONTINUE_TO_BACKUP=0
        fi


        if [[ ${CONTINUE_TO_BACKUP} -eq 1 ]] ; then
            logger "info" "Initiate clone for ${VM_NAME}"
            startTimer
                    
            mkdir -p "${VM_CLONE_DIR}"
            cp "${VMX_PATH}" "${VM_CLONE_DIR}"
            
            SNAP_SUCCESS=1
            VM_VMDK_FAILED=0

            #powered on VMs only
            SNAPSHOT_NAME="cloneVM-temp-snapshot-$(date +%F)"
            logger "info" "Creating Snapshot \"${SNAPSHOT_NAME}\" for ${VM_NAME}"
            ${VMWARE_CMD} vmsvc/snapshot.create ${VM_ID} "${SNAPSHOT_NAME}" "${SNAPSHOT_NAME}" "${VM_SNAPSHOT_MEMORY}" "${VM_SNAPSHOT_QUIESCE}" > /dev/null 2>&1

            logger "debug" "Waiting for snapshot \"${SNAPSHOT_NAME}\" to be created"
            logger "debug" "Snapshot timeout set to: $((SNAPSHOT_TIMEOUT*60)) seconds"
            START_ITERATION=0
            while [[ $(${VMWARE_CMD} vmsvc/snapshot.get ${VM_ID} | wc -l) -eq 1 ]]; do
                if [[ ${START_ITERATION} -ge ${SNAPSHOT_TIMEOUT} ]] ; then
                    logger "info" "Snapshot timed out, failed to create snapshot: \"${SNAPSHOT_NAME}\" for ${VM_NAME}"
                    SNAP_SUCCESS=0
                    echo "ERROR: Unable to backup ${VM_NAME} due to snapshot creation" >> ${VM_BACKUP_DIR}/STATUS.error
                    break
                fi

                logger "debug" "Waiting for snapshot creation to be completed - Iteration: ${START_ITERATION} - sleeping for 60secs (Duration: $((START_ITERATION*30)) seconds)"
                sleep 60

                START_ITERATION=$((START_ITERATION + 1))
            done
            

        
            if [[ ${SNAP_SUCCESS} -eq 1 ]] ; then
                OLD_IFS="${IFS}"
                IFS=":"
                for j in ${VMDKS}; do
                    VMDK=$(echo "${j}" | awk -F "###" '{print $1}')


                        #added this section to handle VMDK(s) stored in different datastore than the VM
                        echo ${VMDK} | grep "^/vmfs/volumes" > /dev/null 2>&1
                        if [[ $? -eq 0 ]] ; then
                            SOURCE_VMDK="${VMDK}"
                            DS_UUID="$(echo ${VMDK#/vmfs/volumes/*})"
                            DS_UUID="$(echo ${DS_UUID%/*/*})"
                            VMDK_DISK="$(echo ${VMDK##/*/})"
                            mkdir -p "${VM_CLONE_DIR}/${DS_UUID}"
                            DESTINATION_VMDK="${VM_CLONE_DIR}/${DS_UUID}/${VMDK_DISK}"
                        else
                            SOURCE_VMDK="${VMX_DIR}/${VMDK}"
                            DESTINATION_VMDK="${VM_CLONE_DIR}/${VMDK}"
                        fi

                        #support for vRDM and deny pRDM
                        grep "vmfsPassthroughRawDeviceMap" "${SOURCE_VMDK}" > /dev/null 2>&1
                        if [[ $? -eq 1 ]] ; then
                            FORMAT_OPTION="UNKNOWN"
                            if [[ "${DISK_CLONE_FORMAT}" == "zeroedthick" ]] ; then
                                if [[ "${VER}" == "4" ]] || [[ "${VER}" == "5" ]] ; then
                                    FORMAT_OPTION="zeroedthick"
                                else
                                    FORMAT_OPTION=""
                                fi
                            elif [[ "${DISK_CLONE_FORMAT}" == "2gbsparse" ]] ; then
                                FORMAT_OPTION="2gbsparse"
                            elif [[ "${DISK_CLONE_FORMAT}" == "thin" ]] ; then
                                FORMAT_OPTION="thin"
                            elif [[ "${DISK_CLONE_FORMAT}" == "eagerzeroedthick" ]] ; then
                                if [[ "${VER}" == "4" ]] || [[ "${VER}" == "5" ]] ; then
                                    FORMAT_OPTION="eagerzeroedthick"
                                else
                                    FORMAT_OPTION=""
                                fi
                            fi

                            if  [[ "${FORMAT_OPTION}" == "UNKNOWN" ]] ; then
                                logger "info" "ERROR: wrong DISK_CLONE_FORMAT \"${DISK_BACKUP_FORMAT}\ specified for ${VM_NAME}"
                                VM_VMDK_FAILED=1
                            else
                                VMDK_OUTPUT=$(mktemp ${WORKDIR}/ghettovcb.XXXXXX)
                                tail -f "${VMDK_OUTPUT}" &
                                TAIL_PID=$!

                                ADAPTER_FORMAT=$(grep -i "ddb.adapterType" "${SOURCE_VMDK}" | awk -F "=" '{print $2}' | sed -e 's/^[[:blank:]]*//;s/[[:blank:]]*$//;s/"//g')

                                if  [[ -z "${FORMAT_OPTION}" ]] ; then
                                    logger "debug" "${VMKFSTOOLS_CMD} -i \"${SOURCE_VMDK}\" -a \"${ADAPTER_FORMAT}\" \"${DESTINATION_VMDK}\""
                                    ${VMKFSTOOLS_CMD} -i "${SOURCE_VMDK}" -a "${ADAPTER_FORMAT}" "${DESTINATION_VMDK}" > "${VMDK_OUTPUT}" 2>&1                  
                                else
                                    logger "debug" "${VMKFSTOOLS_CMD} -i \"${SOURCE_VMDK}\" -a \"${ADAPTER_FORMAT}\" -d \"${FORMAT_OPTION}\" \"${DESTINATION_VMDK}\""
                                    ${VMKFSTOOLS_CMD} -i "${SOURCE_VMDK}" -a "${ADAPTER_FORMAT}" -d "${FORMAT_OPTION}" "${DESTINATION_VMDK}" > "${VMDK_OUTPUT}" 2>&1
                                fi

                                VMDK_EXIT_CODE=$?
                                VMDK_EXIT_CODE=0
                                kill "${TAIL_PID}"
                                cat "${VMDK_OUTPUT}" >> "${REDIRECT}"
                                echo >> "${REDIRECT}"
                                echo
                                rm "${VMDK_OUTPUT}"

                                if [[ "${VMDK_EXIT_CODE}" != 0 ]] ; then
                                    logger "info" "ERROR: error in cloning of \"${SOURCE_VMDK}\" for ${VM_NAME}"
                                    VM_VMDK_FAILED=1
                                fi
                            fi
                        else
                            logger "info" "WARNING: A physical RDM \"${SOURCE_VMDK}\" was found for ${VM_NAME}, which will not be cloned"
                            VM_VMDK_FAILED=1
                        fi
                    
                done
                IFS="${OLD_IFS}"
            fi
            
            #powered on VMs only w/snapshots
            if [[ ${SNAP_SUCCESS} -eq 1 ]] && [[ "${ORGINAL_VM_POWER_STATE}" == "Powered on" ]] || [[ "${ORGINAL_VM_POWER_STATE}" == "Suspended" ]]; then
                if [[ "${NEW_VIMCMD_SNAPSHOT}" == "yes" ]] ; then
                    SNAPSHOT_ID=$(${VMWARE_CMD} vmsvc/snapshot.get ${VM_ID} | grep -E '(Snapshot Name|Snapshot Id)' | grep -A1 ${SNAPSHOT_NAME} | grep "Snapshot Id" | awk -F ":" '{print $2}' | sed -e 's/^[[:blank:]]*//;s/[[:blank:]]*$//')
                    ${VMWARE_CMD} vmsvc/snapshot.remove ${VM_ID} ${SNAPSHOT_ID} > /dev/null 2>&1
                else
                    ${VMWARE_CMD} vmsvc/snapshot.remove ${VM_ID} > /dev/null 2>&1
                fi

                #do not continue until all snapshots have been committed
                logger "info" "Removing snapshot from ${VM_NAME} ..."
                while ls "${VMX_DIR}" | grep -q "\-delta\.vmdk"; do
                    sleep 5
                done
            fi            
            
            
            endTimer
            
            if [[ ${SNAP_SUCCESS} -ne 1 ]] ; then
                    logger "info" "ERROR: Unable to backup ${VM_NAME} due to snapshot creation!\n"
                    [[ ${ENABLE_COMPRESSION} -eq 1 ]] && [[ $COMPRESSED_OK -eq 1 ]] || echo "ERROR: Unable to backup ${VM_NAME} due to snapshot creation" >> ${VM_BACKUP_DIR}/STATUS.error
                    VM_FAILED=1
            else
                    logger "info" "Successfully completed cloning ${VM_NAME} to ${CLONE_DATASTORE}/${CLONE_NAME}!\n"
                    VM_OK=1                    
            fi
        fi 
      else
        logger "info" "${SOURCE_NAME} VM configuration is not consistent with disk data"                
      fi                  
    else 
      logger "info" "${SOURCE_NAME} VM not found"
    fi
    
    IFS=${ORIG_IFS}
}

init;
main;  