#!/bin/bash
#
# update OS, create all hana partitions depending on input parameter from ARM template and install SAP HANA
# cat customscript.sh | base64 -w0
#

function log()
{
  message=$@
  echo "$message"
  echo "$(date -Iseconds): $message" >> /tmp/hanacustomscript
}

function setEnv()
{
  Uri=${1}
  HANAVER=${2}
  HANAUSR=${3}
  HANAPWD=${4}
  HANASID=${5}
  HANANUMBER=${6}
  vmSize=${7}
  SUBEMAIL=${8}
  SUBID=${9}
  SUBURL=${10}

  #if needed, register the machine
  if [ "$SUBEMAIL" != "" ]; then
    if [ "$SUBURL" != "" ]; then 
      SUSEConnect -e $SUBEMAIL -r $SUBID --url $SUBURL
    else 
      SUSEConnect -e $SUBEMAIL -r $SUBID
    fi
  fi

  #decode hana version parameter
  HANAVER=${HANAVER^^}
  if [ "${HANAVER}" = "SAP HANA PLATFORM EDITION 2.0 SPS01 REV 10 (51052030)" ]
  then
    hanapackage="51052030"
  else
    echo "not 51052030"
    if [ "$HANAVER" = "SAP HANA PLATFORM EDITION 2.0 SPS02 (51052325)" ]
    then
      hanapackage="51052325"
    else
      echo "not 51052325"
      if [ "$HANAVER" = "SAP HANA PLATFORM EDITION 2.0 SPS03 REV30 (51053061)" ]
      then
        hanapackage="51053061"
      else
        echo "not 51053061"
        if [ "$HANAVER" = "SAP HANA PLATFORM EDITION 2.0 SPS04 REV40 (51053787)" ]
        then
          hanapackage="51053787"
        else
          echo "not 51053787"
          if [ "$HANAVER" = "SAP HANA PLATFORM EDITION 2.0 SPS05 REV52" ]
          then
             hanapackage="SPS52"
          else
            echo "not 51053787, default to 51052325"
            hanapackage="51052325"
          fi
        fi
      fi
    fi
  fi

  #get the VM size via the instance api
  VMSIZE=`curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2017-08-01&format=text"`
}

function installPackages()
{
  log "installPackages start"

  # to handle issues with SMT registration:
  rm /etc/SUSEConnect
  rm -f /etc/zypp/{repos,services,credentials}.d/*
  rm -f /usr/lib/zypp/plugins/services/*
  sed -i '/^# Added by SMT reg/,+1d' /etc/hosts
  /usr/sbin/registercloudguest --force-new
  
  zypper install -y glibc-2.22-51.6
  zypper install -y systemd-228-142.1
  zypper install -y unrar
  zypper install -y sapconf
  zypper install -y saptune
  
  zypper in -t pattern -y sap-hana
  saptune solution apply HANA
  saptune daemon start

  log "installPackages done"
}

function enableSwap()
{
  log "enableSwap start"
  echo $Uri >> /tmp/url.txt

  cp -f /etc/waagent.conf /etc/waagent.conf.orig
  sedcmd="s/ResourceDisk.EnableSwap=n/ResourceDisk.EnableSwap=y/g"
  sedcmd2="s/ResourceDisk.SwapSizeMB=0/ResourceDisk.SwapSizeMB=2048/g"
  cat /etc/waagent.conf | sed $sedcmd | sed $sedcmd2 > /etc/waagent.conf.new
  cp -f /etc/waagent.conf.new /etc/waagent.conf

  #don't restart waagent, as this will kill the custom script.
  #service waagent restart

  log "enableSwap done" 
}

function createVolumes()
{
  log "createVolumes start"

  mkdir /etc/systemd/login.conf.d
  mkdir /hana
  mkdir /hana/data
  mkdir /hana/log
  mkdir /hana/shared
  mkdir /hana/backup
  mkdir /usr/sap

  # this assumes that 5 disks are attached at lun 0 through 4
  pvcreate -ff -y /dev/disk/azure/scsi1/lun0   
  pvcreate -ff -y  /dev/disk/azure/scsi1/lun1
  pvcreate -ff -y  /dev/disk/azure/scsi1/lun2
  pvcreate -ff -y  /dev/disk/azure/scsi1/lun3
  pvcreate -ff -y  /dev/disk/azure/scsi1/lun4
  pvcreate -ff -y  /dev/disk/azure/scsi1/lun5

  if [ $VMSIZE == "Standard_E16s_v3" ] || [ "$VMSIZE" == "Standard_E32s_v3" ] || [ "$VMSIZE" == "Standard_E64s_v3" ] || [ "$VMSIZE" == "Standard_GS5" ] || [ "$VMSIZE" == "Standard_M32ts" ] || [ "$VMSIZE" == "Standard_M32ls" ] || [ "$VMSIZE" == "Standard_M64ls" ] || [ $VMSIZE == "Standard_DS14_v2" ] ; then
    #shared volume creation
    sharedvglun="/dev/disk/azure/scsi1/lun0"
    vgcreate sharedvg $sharedvglun
    lvcreate -l 100%FREE -n sharedlv sharedvg 
  
    #usr volume creation
    usrsapvglun="/dev/disk/azure/scsi1/lun1"
    vgcreate usrsapvg $usrsapvglun
    lvcreate -l 100%FREE -n usrsaplv usrsapvg

    #backup volume creation
    backupvglun="/dev/disk/azure/scsi1/lun2"
    vgcreate backupvg $backupvglun
    lvcreate -l 100%FREE -n backuplv backupvg 

    #data volume creation
    datavg1lun="/dev/disk/azure/scsi1/lun3"
    datavg2lun="/dev/disk/azure/scsi1/lun4"
    datavg3lun="/dev/disk/azure/scsi1/lun5"
    vgcreate datavg $datavg1lun $datavg2lun $datavg3lun
    PHYSVOLUMES=3
    STRIPESIZE=64
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 70%FREE -n datalv datavg
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n loglv datavg


    mkfs.xfs /dev/datavg/datalv
    mkfs.xfs /dev/datavg/loglv
    mkfs -t xfs /dev/sharedvg/sharedlv 
    mkfs -t xfs /dev/backupvg/backuplv 
    mkfs -t xfs /dev/usrsapvg/usrsaplv
    mount -t xfs /dev/datavg/loglv /hana/log 
    echo "/dev/mapper/datavg-loglv /hana/log xfs defaults 0 0" >> /etc/fstab
  
  fi

  if [ $VMSIZE == "Standard_M64s" ]; then
    #this is the medium size
    # this assumes that 6 disks are attached at lun 0 through 5
   
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun6
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun7
    pvcreate -ff -y /dev/disk/azure/scsi1/lun8
    pvcreate -ff -y /dev/disk/azure/scsi1/lun9

    
    #shared volume creation
    sharedvglun="/dev/disk/azure/scsi1/lun0"
    vgcreate sharedvg $sharedvglun
    lvcreate -l 100%FREE -n sharedlv sharedvg 
  
    #usr volume creation
    usrsapvglun="/dev/disk/azure/scsi1/lun1"
    vgcreate usrsapvg $usrsapvglun
    lvcreate -l 100%FREE -n usrsaplv usrsapvg

    #backup volume creation
    backupvg1lun="/dev/disk/azure/scsi1/lun2"
    backupvg2lun="/dev/disk/azure/scsi1/lun3"
    vgcreate backupvg $backupvg1lun $backupvg2lun
    lvcreate -l 100%FREE -n backuplv backupvg 

    #data volume creation
    datavg1lun="/dev/disk/azure/scsi1/lun4"
    datavg2lun="/dev/disk/azure/scsi1/lun5"
    datavg3lun="/dev/disk/azure/scsi1/lun6"
    datavg4lun="/dev/disk/azure/scsi1/lun7"
    vgcreate datavg $datavg1lun $datavg2lun $datavg3lun $datavg4lun
    PHYSVOLUMES=4
    STRIPESIZE=64
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n datalv datavg

    #log volume creation
    logvg1lun="/dev/disk/azure/scsi1/lun8"
    logvg2lun="/dev/disk/azure/scsi1/lun9"
    vgcreate logvg $logvg1lun $logvg2lun
    PHYSVOLUMES=2
    STRIPESIZE=32
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n loglv logvg
    mount -t xfs /dev/logvg/loglv /hana/log 
  echo "/dev/mapper/logvg-loglv /hana/log xfs defaults 0 0" >> /etc/fstab

    mkfs.xfs /dev/datavg/datalv
    mkfs.xfs /dev/logvg/loglv
    mkfs -t xfs /dev/sharedvg/sharedlv 
    mkfs -t xfs /dev/backupvg/backuplv 
    mkfs -t xfs /dev/usrsapvg/usrsaplv
  
  fi

  if [ $VMSIZE == "Standard_M64ms" ] || [ $VMSIZE == "Standard_M128s" ]; then

    # this assumes that 6 disks are attached at lun 0 through 9
    
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun6
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun7
    pvcreate  -ff -y /dev/disk/azure/scsi1/lun8

   
    #shared volume creation
    sharedvglun="/dev/disk/azure/scsi1/lun0"
    vgcreate sharedvg $sharedvglun
    lvcreate -l 100%FREE -n sharedlv sharedvg 
  
    #usr volume creation
    usrsapvglun="/dev/disk/azure/scsi1/lun1"
    vgcreate usrsapvg $usrsapvglun
    lvcreate -l 100%FREE -n usrsaplv usrsapvg

    #backup volume creation
    backupvg1lun="/dev/disk/azure/scsi1/lun2"
    backupvg2lun="/dev/disk/azure/scsi1/lun3"
    vgcreate backupvg $backupvg1lun $backupvg2lun
    lvcreate -l 100%FREE -n backuplv backupvg 

    #data volume creation
    datavg1lun="/dev/disk/azure/scsi1/lun4"
    datavg2lun="/dev/disk/azure/scsi1/lun5"
    datavg3lun="/dev/disk/azure/scsi1/lun6"
    vgcreate datavg $datavg1lun $datavg2lun $datavg3lun 
    PHYSVOLUMES=3
    STRIPESIZE=64
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n datalv datavg

    #log volume creation
    logvg1lun="/dev/disk/azure/scsi1/lun7"
    logvg2lun="/dev/disk/azure/scsi1/lun8"
    vgcreate logvg $logvg1lun $logvg2lun
    PHYSVOLUMES=2
    STRIPESIZE=32
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n loglv logvg
    mount -t xfs /dev/logvg/loglv /hana/log   
  echo "/dev/mapper/logvg-loglv /hana/log xfs defaults 0 0" >> /etc/fstab

    mkfs.xfs /dev/datavg/datalv
    mkfs.xfs /dev/logvg/loglv
    mkfs -t xfs /dev/sharedvg/sharedlv 
    mkfs -t xfs /dev/backupvg/backuplv 
    mkfs -t xfs /dev/usrsapvg/usrsaplv
 
  fi

  if [ $VMSIZE == "Standard_M128ms" || [ $VMSIZE == "Standard_M208ms_v2" ]; then

    # this assumes that 6 disks are attached at lun 0 through 5
    
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun6
    pvcreate -ff -y  /dev/disk/azure/scsi1/lun7
    pvcreate  -ff -y /dev/disk/azure/scsi1/lun8
    pvcreate  -ff -y /dev/disk/azure/scsi1/lun9
    pvcreate  -ff -y /dev/disk/azure/scsi1/lun10

    #shared volume creation
    sharedvglun="/dev/disk/azure/scsi1/lun0"
    vgcreate sharedvg $sharedvglun
    lvcreate -l 100%FREE -n sharedlv sharedvg 
  
    #usr volume creation
    usrsapvglun="/dev/disk/azure/scsi1/lun1"
    vgcreate usrsapvg $usrsapvglun
    lvcreate -l 100%FREE -n usrsaplv usrsapvg

    #backup volume creation
    backupvg1lun="/dev/disk/azure/scsi1/lun2"
    backupvg2lun="/dev/disk/azure/scsi1/lun3"
    vgcreate backupvg $backupvg1lun $backupvg2lun
    lvcreate -l 100%FREE -n backuplv backupvg 

    #data volume creation
    datavg1lun="/dev/disk/azure/scsi1/lun4"
    datavg2lun="/dev/disk/azure/scsi1/lun5"
    datavg3lun="/dev/disk/azure/scsi1/lun6"
    datavg4lun="/dev/disk/azure/scsi1/lun7"
    datavg5lun="/dev/disk/azure/scsi1/lun8"
    vgcreate datavg $datavg1lun $datavg2lun $datavg3lun $datavg4lun $datavg5lun
    PHYSVOLUMES=4
    STRIPESIZE=64
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n datalv datavg

    #log volume creation
    logvg1lun="/dev/disk/azure/scsi1/lun9"
    logvg2lun="/dev/disk/azure/scsi1/lun10"
    vgcreate logvg $logvg1lun $logvg2lun
    PHYSVOLUMES=2
    STRIPESIZE=32
    lvcreate -i$PHYSVOLUMES -I$STRIPESIZE -l 100%FREE -n loglv logvg
    mount -t xfs /dev/logvg/loglv /hana/log 
    echo "/dev/mapper/logvg-loglv /hana/log xfs defaults 0 0" >> /etc/fstab

    mkfs.xfs /dev/datavg/datalv
    mkfs.xfs /dev/logvg/loglv
    mkfs -t xfs /dev/sharedvg/sharedlv 
    mkfs -t xfs /dev/backupvg/backuplv 
    mkfs -t xfs /dev/usrsapvg/usrsaplv
  fi

  mount -t xfs /dev/sharedvg/sharedlv /hana/shared
  mount -t xfs /dev/backupvg/backuplv /hana/backup 
  mount -t xfs /dev/usrsapvg/usrsaplv /usr/sap
  mount -t xfs /dev/datavg/datalv /hana/data


  echo "/dev/mapper/datavg-datalv /hana/data xfs defaults 0 0" >> /etc/fstab
  echo "/dev/mapper/sharedvg-sharedlv /hana/shared xfs defaults 0 0" >> /etc/fstab
  echo "/dev/mapper/backupvg-backuplv /hana/backup xfs defaults 0 0" >> /etc/fstab
  echo "/dev/mapper/usrsapvg-usrsaplv /usr/sap xfs defaults 0 0" >> /etc/fstab

  log "createVolumes done"
}

function prepareSAPBins()
{
  log "prepareSAPBins start"

  SAPBITSDIR="/hana/data/sapbits"

  if [ ! -d $SAPBITSDIR ]
  then
    mkdir $SAPBITSDIR
  fi

  cd $SAPBITSDIR

  if [ "${hanapackage}" = "51053787" ]
  then 
    mkdir ${hanapackage}
    cd ${hanapackage}
    /usr/bin/wget --quiet $Uri/SapBits/${hanapackage}.ZIP
    unzip ${hanapackage}.ZIP
  else
    if [ "${hanapackage}" = "SPS52" ]
    then
      mkdir ${hanapackage}
      cd ${hanapackage}
      /usr/bin/wget --quiet $Uri/SapBits/SAPCAR
      /usr/bin/wget --quiet $Uri/SapBits/IMDB_SERVER20_052_0-80002031.SAR
      chmod 777 SAPCAR
      ./SAPCAR -xvf IMDB_SERVER20_052_0-80002031.SAR
    else
      /usr/bin/wget --quiet $Uri/SapBits/${hanapackage}_part1.exe
      /usr/bin/wget --quiet $Uri/SapBits/${hanapackage}_part2.rar
      /usr/bin/wget --quiet $Uri/SapBits/${hanapackage}_part3.rar
      /usr/bin/wget --quiet $Uri/SapBits/${hanapackage}_part4.rar
      unrar  -o- x ${hanapackage}_part1.exe
    fi
  fi

  log "prepareSAPBins done"
}

function installHANA()
{
  log "installHANA start"

  cd $SAPBITSDIR
  /usr/bin/wget --quiet $Uri/SapBits/md5sums
  /usr/bin/wget --quiet "https://raw.githubusercontent.com/AzureCAT-GSI/SAP-HANA-ARM/master/hdbinst.cfg"

  myhost=`hostname`
  sedcmd1="s/REPLACE-WITH-HOSTNAME/$myhost/g"
  sedcmd2="s/\/hana\/shared\/sapbits\/51052325/\/hana\/data\/sapbits\/${hanapackage}/g"
  sedcmd3="s/root_user=root/root_user=$HANAUSR/g"
  sedcmd4="s/AweS0me@PW/$HANAPWD/g"
  sedcmd5="s/sid=H10/sid=$HANASID/g"
  sedcmd6="s/number=00/number=$HANANUMBER/g"
  cat hdbinst.cfg | sed $sedcmd1 | sed $sedcmd2 | sed $sedcmd3 | sed $sedcmd4 | sed $sedcmd5 | sed $sedcmd6 > hdbinst-local.cfg
  
  #put host entry in hosts file using instance metadata api
  VMIPADDR=`curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2017-08-01&format=text"`
  VMNAME=`hostname`
  
  echo $VMIPADDR $VMNAME >> /etc/hosts
  
  if [ "${hanapackage}" = "SPS52" ]
  then
    /hana/data/sapbits/${hanapackage}/SAP_HANA_DATABASE/hdblcm -b --configfile /hana/data/sapbits/hdbinst-local.cfg
  else
    # cd /hana/data/sapbits/${hanapackage}/DATA_UNITS/HDB_LCM_LINUX_X86_64
    /hana/data/sapbits/${hanapackage}/DATA_UNITS/HDB_LCM_LINUX_X86_64/hdblcm -b --configfile /hana/data/sapbits/hdbinst-local.cfg
  fi
  
  log "installHANA done"
}

function enableBackup()
{
  log "enableBackup start"

  cd /tmp
  /usr/bin/wget --quiet -O backupscript.sh https://aka.ms/ScriptForPermsOnHANA?clcid=0x0409
  chmod 777 backupscript.sh

  SIDADM=${HANASID,,}adm
  SYSTEMDB=${HANASID}SYSTEMDB
  HANAPORT=3${HANANUMBER}13

  su - $SIDADM -c "hdbuserstore set $SYSTEMDB localhost:$HANAPORT SYSTEM $HANAPWD"

  # it will restart waagent :(
  # /tmp/backupscript.sh -sk $SYSTEMDB

  log "enableBackup done"
}


################
# ### MAIN ### #
################

log "custom script start"

setEnv
installPackages
enableSwap
createVolumes
prepareSAPBins
installHANA
enableBackup

log "custom script done"

exit