#!/usr/bin/env bash
#set -x
ESX_HOST=esx
TEMPLATE=MODEL

cmd=$1;
param=$2;

function list_vm {
  ssh $ESX_HOST vim-cmd vmsvc/getallvms
}

function kill_vm {
  vmid=$1
  ssh $ESX_HOST vim-cmd vmsvc/power.off $vmid
}

function start_vm {
  vmid=$1
  ssh $ESX_HOST vim-cmd vmsvc/power.on $vmid
}

function state_vm {
  vmid=$1
  state=`ssh $ESX_HOST "vim-cmd vmsvc/power.getstate $vmid | grep Powered" `
  echo $state
}

function vm_is_powered {
  ret=0;
  vmid=$1;
  pwr_state=`state_vm $vmid | awk '{ print $2}'`;
  if [ "$pwr_state" == "on" ]; then
    ret=1;
  fi
  return $ret;
}

function vm_id_for_name {
  vmname=$1
  tmpfile=/tmp/$RANDOM$RANDOM$RANDOM.tmp
  
  ssh $ESX_HOST << "EOF" > $tmpfile 2>&1
vim-cmd vmsvc/getallvms | grep -v Vmid | awk '{ print $1 " " $2 }'
EOF
    if [ $? == 0 ]; then 
      ret=`grep $vmname $tmpfile | awk '{ print $1 }'`;
      cnt=`echo $ret | wc -w`
      if [ $cnt -gt 1 ];then
        ret=0;
      fi  
      test -f $tmpfile && rm $tmpfile;
    else
      echo "Connection to ESX failed"
    fi   
  return $ret;
}

function copy_vm {
  src=$1;
  dst=$2;
}

function print_usage {
  echo "Usage: $0 list|deploy|start|stop|status VMNAME";
}

case $cmd in
  list)
    list_vm;
    ;;
  deploy)
    if [ $param != "" ];then
      echo "Create new VM from template $TEMPLATE";
      vm_id_for_name $TEMPLATE;
      id=$?
      if [ $id -gt 0 ]; then
          vm_is_powered $id;
          if [ "$?" -eq 0 ]; then
            echo "startujemy";
          else
            echo "ERROR: $TEMPLATE is powered on. Power off first!";
          fi 
      else
        echo "No such machine: $TEMPLATE";  
      fi
    else
      print_usage; 
    fi
    ;;
  start)
    if [ "$param" != "" ];then
      echo "Start machine $param:"
      vm_id_for_name $param;
      id=$?
      if [ $id -gt 0 ]; then
          vm_is_powered $id;
          if [ "$?" -eq 0 ]; then
            start_vm $id;
            echo "done.";
          else
            echo "$param is powered on";
          fi 
      else
        echo "No such machine: $param";  
      fi  
    else
      print_usage; 
    fi
    ;;
  stop)
    if [ "$param" != "" ];then
      echo "Stop machine $param:"
      vm_id_for_name $param;
      id=$?
      if [ $id -gt 0 ]; then
          vm_is_powered $id;
          if [ "$?" -eq 0 ]; then
            echo "$param is not running.";
          else
            kill_vm $id;
            echo "done.";
          fi 
      else
        echo "No such machine: $param";  
      fi  
    else
      print_usage; 
    fi
    ;;
    status)
    if [ "$param" != "" ];then
      echo -n "Virtual Machine $param is "
      vm_id_for_name $param;
      id=$?
      if [ $id -gt 0 ]; then
          vm_is_powered $id;
          if [ "$?" -eq 0 ]; then
            echo "powered off";
          else
            echo "powered on";
          fi 
      else
        echo "missing";  
      fi  
    else
      print_usage; 
    fi
    ;;   
  *)
    print_usage;
    ;;
esac
