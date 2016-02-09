#!/bin/bash

for i in "$@"; do
    case $i in
        --exclude=*)
        EXCLUDE_OPT="${i#*=}"
        shift
        ;;
        *)
            # unknown option
        ;;
    esac
done

if [ -z $S3_BUCKET ]; then
  >&2 echo "S3_BUCKET variable is missing";
  exit 1;
fi

if [ ! -z $MYSQL_PASSWORD ]; then
  PASS_OPT="--password=${MYSQL_PASSWORD}"
fi

if [ ! -z $EXCLUDE_OPT ]; then
  EXCLUDE_OPT="|${EXCLUDE_OPT//,/|}"
fi

if [ "$1" == "backup" ]; then
  if [ -n "$2" ]; then
      databases=$2
  else
      databases=$(mysql -N -B --user=$MYSQL_USER --host=$MYSQL_HOST --port=$MYSQL_PORT ${PASS_OPT} -e "SHOW DATABASES;" | grep -Ev "(mysql|sys|information_schema|performance_schema${EXCLUDE_OPT})")
  fi

  if [ -z $databases ]; then
	   echo "No databases to backup"
  fi

  for db in $databases; do
    echo "== Backup: MySQL dump database: $db"

  	mkdir -p /tmp/dump/
  	if [ ! -z $SPLIT_SIZE ]; then
  		SPLITCMD="| split -d -b $SPLIT_SIZE - '/tmp/dump/$db.gz_part'"
  	else
  		SPLITCMD="> /tmp/dump/$db.gz"
  	fi
    DUMPCMD="mysqldump --force --opt --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --databases $db ${PASS_OPT} | gzip -c $SPLITCMD"
	  eval $DUMPCMD

    if [ $? == 0 ]; then
      find /tmp -name "$db.gz*" -exec basename {} \; > /tmp/dump/$db.filelist.txt
      aws s3 sync /tmp/dump/ s3://$S3_BUCKET/$S3_PATH/ --delete --exclude "*" --include "$db.*"

      if [ $? == 0 ]; then
          rm -f /tmp/dump/$db.gz*
          rmdir /tmp/dump
      else
          >&2 echo "ERROR: Couldn't transfer $db dump to S3"
      fi
    else
        >&2 echo "ERROR: Couldn't dump $db"
    fi
	    rm -Rf /tmp/dump
  done
elif [ "$1" == "restore" ]; then
  if [ -n "$2" ]; then
      archives=$2.gz
  else
      archives=`aws s3 ls s3://$S3_BUCKET/$S3_PATH/ | awk '{print $4}' ${EXCLUDE_OPT}`
  fi

  for archive in $archives; do
      tmp=/tmp/$archive

      echo "== Restore: MySQL restore database $archive"

      # TODO: Work with backup parts
      aws s3 cp s3://$S3_BUCKET/$S3_PATH/$archive $tmp

      if [ $? == 0 ]; then
          echo "...restoring"
          db=`basename --suffix=.gz $archive`

          if [ -n $MYSQL_PASSWORD ]; then
              yes | mysqladmin --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASSWORD drop $db

              mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASSWORD -e "CREATE DATABASE $db CHARACTER SET $RESTORE_DB_CHARSET COLLATE $RESTORE_DB_COLLATION"
              gunzip -c $tmp | mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASSWORD $db
          else
              yes | mysqladmin --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER drop $db

              mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER -e "CREATE DATABASE $db CHARACTER SET $RESTORE_DB_CHARSET COLLATE $RESTORE_DB_COLLATION"
              gunzip -c $tmp | mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER $db
          fi
      else
          rm $tmp
      fi
  done
else
    >&2 echo "You must provide either backup or restore command"
    exit 64
fi
