#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${NAMESPACE}-${JOB_NAME_HASH}" > "${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data and alerts"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_datastore
declare cloud_where_run
declare vsphere_url
source "${SHARED_DIR}/vsphere_context.sh"

vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${TFVARS_PATH})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${TFVARS_PATH})

echo "$(date -u --rfc-3339=seconds) - Creating govc.sh file..."
cat >> "${SHARED_DIR}/govc.sh" << EOF
export GOVC_URL="${vsphere_url}"
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
EOF

function collect_diagnostic_data {
  set +e  
  source "${SHARED_DIR}/govc.sh"
  vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"
  vcenter_state=${ARTIFACT_DIR}/vcenter_state
  mkdir ${vcenter_state}

  
  govc object.collect "/${GOVC_DATACENTER}/host" triggeredAlarmState &> ${vcenter_state}/host_alarms.log  
  clustervms=$(govc ls "${vm_path}-*")
  for vm in $clustervms; do    
    vmname=$(echo $vm | rev | cut -d'/' -f 1 | rev)
    echo Collecting alarms from $vm
    govc object.collect $vm triggeredAlarmState &> ${vcenter_state}/${vmname}_alarms.log
    echo Collecting metrics from $vm
    METRICS=$(govc metric.ls $vm)
    govc metric.sample -json -n 60 $vm $METRICS &> ${vcenter_state}/${vmname}_metrics.json    
    echo "$(date -u --rfc-3339=seconds) - capture console image from $vm"    
    govc vm.console -vm.ipath="$vm" -capture "${vcenter_state}/${vmname}.png"
  done
  first_vm=$(echo ${clustervms} | cut -d" " -f1)
  target_hw_version=$(govc vm.info -json=true "${first_vm}" | jq -r .VirtualMachines[0].Config.Version)
  echo "{\"hw_version\":  \"${target_hw_version}\", \"cloud\": \"${cloud_where_run}\"}" > "${ARTIFACT_DIR}/runtime-config.json"
  set -e
}

collect_diagnostic_data
